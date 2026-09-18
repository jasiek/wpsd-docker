#!/usr/bin/env bash
#
# Replays every distinct systemctl invocation the WPSD appliance makes against the
# shim. Runs INSIDE the container; tests/smoke.sh copies it in and executes it.
#
# Each call gets a fresh scratch state directory. The call list is alphabetical, so
# `mask pistar-watchdog` sorts before `start pistar-watchdog` -- and refusing to
# start a masked unit is correct systemd behaviour, not a bug. The scratch dir also
# keeps the running container's own unit state untouched.
#
CALLS=${1:-/tmp/calls.txt}
STATE=/tmp/replay-units
total=0
bad=0

while IFS= read -r call; do
    [ -z "$call" ] && continue
    # Two-word greps such as "systemctl daemon-reload" have no unit argument; the
    # verb is covered elsewhere.
    [ "$(echo "$call" | wc -w)" -lt 3 ] && continue

    case $call in
        # Do not tear the container down, and do not let the AP-mode or host
        # networking units rewrite interface configuration.
        *reboot*|*poweroff*|*halt*|*"stop "*)                          continue ;;
        *pistar-ap*|*hostapd*|*dnsmasq*|*NetworkManager*|*networking*) continue ;;
    esac

    total=$((total + 1))
    rm -rf "$STATE"
    WPSD_UNIT_STATE="$STATE" $call >/dev/null 2>&1
    rc=$?
    [ "$rc" -eq 0 ] && continue

    # systemd exits 3 from status/is-active for an inactive unit and 1 from
    # is-enabled for a disabled one. The shim matches that, so those are passes.
    case $call in
        *status*|*is-active*|*is-enabled*|*is-failed*)
            if [ "$rc" -eq 1 ] || [ "$rc" -eq 3 ]; then continue; fi ;;
    esac

    bad=$((bad + 1))
    [ "$bad" -le 8 ] && echo "        $call -> rc=$rc"
done < "$CALLS"

rm -rf "$STATE"
echo "TOTAL=$total BAD=$bad"
