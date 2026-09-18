#!/usr/bin/env bash
#
# Hardware-free acceptance test. Run against a started container:
#
#   docker compose up -d && ./tests/smoke.sh
#
# Covers: the shim answers every systemctl call WPSD makes, the web stack serves
# the dashboard, and MMDVMHost runs against a null modem.
#
set -uo pipefail

CONTAINER=${CONTAINER:-wpsd}
URL=${URL:-http://localhost:8080}
DASH_USER=${DASH_USER:-pi-star}
DASH_PASS=${DASH_PASS:-raspberry}

pass=0; fail=0
ok()   { printf '  \033[32mok\033[0m    %s\n' "$1"; pass=$((pass+1)); }
bad()  { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; fail=$((fail+1)); }
head_() { printf '\n\033[1m%s\033[0m\n' "$1"; }
dex()  { docker exec "$CONTAINER" "$@"; }

head_ "container"
if dex true 2>/dev/null; then ok "container '$CONTAINER' is running"
else bad "container '$CONTAINER' is not running"; exit 1; fi

head_ "readiness"
# pistar-watchdog is the last service in the s6 dependency chain: it waits on
# 10-wpsd-start, which runs `wpsd-services start` and walks 25 units, several of
# which sleep. Gate the assertions on it rather than racing the boot.
ready=0
for _ in $(seq 1 40); do
    if [[ $(dex /command/s6-svstat -o up /run/service/pistar-watchdog 2>/dev/null) == true ]]; then
        ready=1; break
    fi
    sleep 5
done
[[ $ready -eq 1 ]] && ok "s6 tree finished starting" \
                   || bad "s6 tree did not finish starting within 200s"

head_ "s6 supervision"
for svc in nginx php-fpm cron pistar-watchdog; do
    if [[ $(dex /command/s6-svstat -o up "/run/service/$svc" 2>/dev/null) == true ]]; then
        ok "s6: $svc is up"
    else
        bad "s6: $svc is not up"
    fi
done

head_ "shim: verbs WPSD relies on"
for u in nginx cron php8.4-fpm systemd-timesyncd; do
    out=$(dex systemctl is-active "$u" 2>/dev/null)
    [[ $out == active ]] && ok "is-active $u -> active" || bad "is-active $u -> '$out'"
done
# is-active must exit 3, not 1, for an inactive unit -- wpsd-services tests $?
dex systemctl is-active --quiet mmdvmhost; rc=$?
[[ $rc -eq 0 || $rc -eq 3 ]] && ok "is-active exit code is 0 or 3 (got $rc)" \
                             || bad "is-active exit code $rc (want 0 or 3)"

# The parsed-output contract; see docs/SYSTEMCTL-SHIM.md
# `systemctl status` exits 3 for an inactive unit, as systemd does, so capture the
# output rather than piping it -- pipefail would report the exit code, not grep's.
out=$(dex systemctl status systemd-timesyncd.service 2>&1)
[[ $out == *running* ]] && ok "status systemd-timesyncd contains 'running'" \
    || bad "status systemd-timesyncd missing 'running' (sysinfo.php NTP panel)"

dex systemctl mask nextiondriver.service >/dev/null 2>&1
out=$(dex systemctl status nextiondriver.service 2>&1)
[[ $out == *masked* ]] && ok "status of a masked unit contains 'masked'" \
    || bad "status of a masked unit missing 'masked' (.wpsd-nightly-tasks)"

dex systemctl unmask nextiondriver.service >/dev/null 2>&1
dex systemctl disable nextiondriver.service >/dev/null 2>&1
out=$(dex systemctl status nextiondriver.service 2>&1)
[[ $out == *"disabled;"* ]] && ok "status of a disabled unit contains 'disabled;'" \
    || bad "status of a disabled unit missing 'disabled;' (.wpsd-display-driver-helper)"
dex systemctl enable nextiondriver.service >/dev/null 2>&1

head_ "shim: replay every call the appliance makes"
if [[ -f tests/systemctl-calls.txt && -f tests/replay-systemctl.sh ]]; then
    # /tmp is a tmpfs mount in this container and `docker cp` cannot write into a
    # mount point, so stage the files under /var/tmp instead.
    if ! docker cp tests/systemctl-calls.txt "$CONTAINER:/var/tmp/calls.txt" >/dev/null 2>&1 \
    || ! docker cp tests/replay-systemctl.sh "$CONTAINER:/var/tmp/replay.sh" >/dev/null 2>&1; then
        bad "could not stage the replay into the container"
    else
        replay=$(dex bash /var/tmp/replay.sh /var/tmp/calls.txt 2>&1)
        echo "$replay" | grep -v '^TOTAL=' || true
        summary=$(echo "$replay" | grep -o 'TOTAL=[0-9]* BAD=[0-9]*' | tail -1)
        tot=$(echo "$summary" | sed -n 's/TOTAL=\([0-9]*\).*/\1/p')
        bd=$(echo "$summary" | sed -n 's/.*BAD=\([0-9]*\)/\1/p')
        if [[ -z $summary ]]; then
            bad "replay produced no summary -- see output above"
        elif [[ $bd -eq 0 ]]; then
            ok "replayed $tot calls, none errored"
        else
            bad "$bd of $tot calls returned an unexpected error"
        fi
    fi
else
    bad "call list or replay script missing -- run scripts/extract-reference.sh"
fi

head_ "companion shims"
dex timedatectl set-timezone Europe/London >/dev/null 2>&1 \
    && [[ $(dex cat /etc/timezone) == Europe/London ]] \
    && ok "timedatectl set-timezone writes /etc/timezone" \
    || bad "timedatectl set-timezone did not take"
dex timedatectl list-timezones | grep -q '^Europe/London$' \
    && ok "timedatectl list-timezones populates the dashboard selector" \
    || bad "timedatectl list-timezones is empty"
dex journalctl --vacuum-time=24h >/dev/null 2>&1 \
    && ok "journalctl --vacuum-time is a no-op success" \
    || bad "journalctl --vacuum-time failed (.wpsd-running-tasks aborts)"

head_ "binaries"
for b in MMDVMHost DMRGateway YSFGateway NXDNGateway P25Gateway ircddbgatewayd \
         DAPNETGateway APRSGateway YSF2DMR NextionDriver MMDVMCal; do
    dex test -x "/usr/local/bin/$b" && ok "present: $b" || bad "missing: $b"
done
ver=$(dex /usr/local/bin/MMDVMHost -v 2>/dev/null)
[[ $ver == *WPSD* ]] && ok "MMDVMHost -v: $ver" || bad "MMDVMHost -v gave '$ver'"
arch=$(dex sh -c 'file -b /usr/local/bin/MMDVMHost | cut -d, -f1-2')
ok "built for: $arch"

head_ "web stack"
code=$(curl -s -o /dev/null -w '%{http_code}' "$URL/")
[[ $code == 200 ]] && ok "GET / -> 200" || bad "GET / -> $code"
curl -s "$URL/" | grep -q 'WPSD Dashboard Ver' \
    && ok "dashboard renders its version string (git metadata intact)" \
    || bad "dashboard version string missing -- /var/www/dashboard/.git lost?"
code=$(curl -s -o /dev/null -w '%{http_code}' "$URL/admin/configure.php")
[[ $code == 401 ]] && ok "/admin is behind basic auth -> 401" || bad "/admin -> $code (want 401)"
code=$(curl -su "$DASH_USER:$DASH_PASS" -o /dev/null -w '%{http_code}' "$URL/admin/configure.php")
[[ $code == 200 ]] && ok "/admin/configure.php with credentials -> 200" || bad "/admin authed -> $code"
n=$(curl -su "$DASH_USER:$DASH_PASS" "$URL/admin/configure.php" | grep -c '<select')
[[ ${n:-0} -gt 5 ]] && ok "configure.php rendered $n <select> controls" \
                    || bad "configure.php rendered only ${n:-0} <select> controls"

head_ "privilege path the dashboard depends on"
dex sudo -u www-data sudo -n systemctl is-active nginx >/dev/null 2>&1 \
    && ok "www-data can sudo systemctl without a password" \
    || bad "www-data sudo is broken -- every admin page will fail"

head_ "null modem: MMDVMHost actually runs"
dex bash -c '
  set -e
  grep -q "^Protocol=" /etc/mmdvmhost || exit 9
  sed -i "s/^Protocol=.*/Protocol=null/" /etc/mmdvmhost
  # MMDVMHost only starts when a modem has been configured; fake the sentinel.
  [ -f /etc/dstar-radio.mmdvmhost ] || printf "[Modem]\nHardware=null\n" > /etc/dstar-radio.mmdvmhost
' >/dev/null 2>&1 && ok "configured a null modem" || bad "could not configure a null modem"
dex systemctl restart mmdvmhost >/dev/null 2>&1
# The wrapper script waits for an interface to have an IP and then sleeps 5s
# before exec'ing the daemon, so poll rather than guessing a sleep.
for _ in $(seq 1 12); do
    dex pgrep -x MMDVMHost >/dev/null 2>&1 && break
    sleep 3
done
if dex pgrep -x MMDVMHost >/dev/null 2>&1; then
    ok "MMDVMHost is running against the null modem"
    dex bash -c 'ls /var/log/pi-star/MMDVM-*.log >/dev/null 2>&1' \
        && ok "MMDVMHost is writing /var/log/pi-star/MMDVM-*.log" \
        || bad "no MMDVM log written"
else
    bad "MMDVMHost did not stay up (docker exec $CONTAINER cat /var/log/pi-star/MMDVM-\$(date -u +%F).log)"
fi

head_ "config persistence"
dex bash -c 'sed -i "s/^Callsign=.*/Callsign=SMOKE1/" /etc/mmdvmhost' 2>/dev/null \
    && ok "sed -i works on /etc/mmdvmhost (the dashboard's edit mechanism)" \
    || bad "sed -i on /etc/mmdvmhost failed -- every admin save would break"
# First: the real store, to prove a dashboard edit lands in the volume.
dex wpsd-config-sync save -q >/dev/null 2>&1 && ok "wpsd-config-sync save" || bad "wpsd-config-sync save failed"
dex grep -q '^Callsign=SMOKE1' /etc/wpsd/etc__mmdvmhost 2>/dev/null \
    && ok "the edit reached the wpsd-config volume" \
    || bad "the edit did not reach the volume -- config is lost on recreate"

# Then the save/clobber/restore round trip against a SCRATCH store. Using the real
# one would race the minutely `wpsd-config-sync save` cron job: if it fired between
# the clobber and the restore it would persist the clobbered value and the restore
# would correctly be a no-op.
dex env WPSD_CONFIG_STORE=/var/tmp/cfgtest wpsd-config-sync save -q >/dev/null 2>&1
dex bash -c 'sed -i "s/^Callsign=.*/Callsign=CLOBBER/" /etc/mmdvmhost' 2>/dev/null
dex env WPSD_CONFIG_STORE=/var/tmp/cfgtest wpsd-config-sync restore -q >/dev/null 2>&1
dex grep -q '^Callsign=SMOKE1' /etc/mmdvmhost \
    && ok "wpsd-config-sync restore reinstates the saved value" \
    || bad "restore did not reinstate the saved value"
dex rm -rf /var/tmp/cfgtest >/dev/null 2>&1
dex bash -c 'sed -i "s/^Callsign=.*/Callsign=WPSD42/" /etc/mmdvmhost; wpsd-config-sync save -q' >/dev/null 2>&1

head_ "watchdog"
dex systemctl is-active --quiet pistar-watchdog 2>/dev/null \
    && ok "pistar-watchdog is supervising" \
    || bad "pistar-watchdog is not running"

printf '\n\033[1m%d passed, %d failed\033[0m\n' "$pass" "$fail"
[[ $fail -eq 0 ]]
