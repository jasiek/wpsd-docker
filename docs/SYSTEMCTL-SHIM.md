# The `systemctl` shim

WPSD drives every service through systemd. There is no systemd in a container,
so `rootfs/usr/local/bin/systemctl` stands in. This documents what it must
satisfy and how each unit is handled.

## Why a shim rather than porting WPSD

Three properties of the appliance make substitution cheaper than a rewrite:

**1. The unit files are already delegating shells.** Every radio unit is four
lines wrapping a script:

```ini
# /lib/systemd/system/ysfgateway.service
[Service]
Type=forking
ExecStart=/usr/local/sbin/ysfgateway.service start
ExecStop=/usr/local/sbin/ysfgateway.service stop
ExecReload=/usr/local/sbin/ysfgateway.service restart
```

`/usr/local/sbin/ysfgateway.service` implements `start|stop|restart|status`
itself, and it does the work that matters: gating on config
(`test -r /etc/dstar-radio.mmdvmhost || exit 0`), waiting for an IP address,
creating `/var/log/pi-star` with the right ownership, running the daemon at
`nice -n -10`, and chaining dependants. The shim routes to those scripts instead
of reimplementing any of it.

**2. WPSD ships its own process supervisor.** `/usr/local/sbin/pistar-watchdog`
is a Python loop that reads `/etc/mmdvmhost`, and for every enabled mode calls
`systemctl is-active` then `systemctl restart` if it is down, every 120 seconds.
Give it a working `systemctl` and it supervises all ~20 radio daemons unchanged.
That is why s6 only manages ten processes rather than thirty.

**3. Each wrapper script names its own process.** `mmdvmhost.service` opens with
`DAEMON=MMDVMHost`. The shim derives its unit → process table by reading that
line from the script it is about to drive:

```sh
daemon=$(sed -n 's/^DAEMON=//p' /usr/local/sbin/"$unit".service | head -1)
pgrep -x "$daemon" >/dev/null
```

`/usr/local/sbin` is a live git clone that upstream resets, so a hardcoded table
would rot silently on the next `git pull`. Reading the declaration from the file
it drives cannot.

## Unit classes

| Class | Selection rule | Handling |
| --- | --- | --- |
| 1. script | `/usr/local/sbin/<unit>.service` is executable | `exec` that script with the verb; `is-active` via `pgrep -x $DAEMON` |
| 2. s6 | unit is in `s6_name()` | `s6-svc -u` / `-d` / `-r` on `/run/service/<name>`; `is-active` via `s6-svstat -o up` |
| 3. timer | name ends `.timer` | schedule lives in `/etc/cron.d/wpsd-timers`; verbs succeed as no-ops, `enable`/`disable` toggle a marker |
| 4. noop | anything else | exit 0. Boot-media and host-hardware units have no container meaning, and callers only test the exit status |
| 5. state | `enable disable mask unmask reenable preset is-enabled` | marker files under `/var/lib/wpsd-units/` |

### Class 1 — the radio daemons (24 units)

```
aprsgateway    dapnetgateway  dgidgateway    dmr2nxdn      dmr2ysf
dmrgateway     ircddbgateway  mmdvmhost      nextiondriver nxdngateway
nxdnparrot     p25gateway     p25parrot      pistar-ap     pistar-remote
pistar-upnp    pistar-watchdog timercontrol  timeserver    ysf2dmr
ysf2nxdn       ysf2p25        ysfgateway     ysfparrot
```

### Class 2 — the s6-supervised processes

| Unit name(s) seen in WPSD | s6 service |
| --- | --- |
| `nginx` | `nginx` |
| `php8.4-fpm`, `php8.2-fpm`, `php7.4-fpm`, `php-fpm` | `php-fpm` |
| `cron`, `crond` | `cron` |
| `avahi-daemon` | `avahi` |
| `vnstat` | `vnstat` |
| `shellinabox` | `shellinabox` |
| `gpsd` | `gpsd` |
| `smbd`, `nmbd` | `samba` |
| `dnsmasq` | `dnsmasq` |
| `hostapd` | `hostapd` |

The older PHP-FPM names are mapped deliberately: `.wpsd-running-tasks` branches
on `$OS_VER` and would reach for `php8.2-fpm` on a Bookworm-flavoured checkout.

### Class 4 — reported active rather than merely tolerated

`always_active()` returns true for `systemd-timesyncd`, `systemd-journald`,
`dbus`, `systemd-logind` and the network/basic/multi-user targets. For
timesyncd this is not a white lie: `admin/sysinfo.php` runs
`systemctl status systemd-timesyncd.service | grep -o running` to light its NTP
indicator, and a container's clock genuinely *is* synchronised — by the host.

## Output that gets parsed, not displayed

Three call sites read the text, so the shim reproduces systemd's keywords:

| Caller | Pattern | Requirement |
| --- | --- | --- |
| `.wpsd-display-driver-helper:47` | `status nextiondriver.service \| grep 'disabled;'` | `Loaded:` line must carry `enabled;` or `disabled;` |
| `.wpsd-nightly-tasks:158` | `status nextiondriver.service \| grep masked` | `Loaded:` line must say `masked` when masked |
| `admin/sysinfo.php:124` | `status systemd-timesyncd.service \| grep -o running` | `Active:` line must contain `running` |
| `wpsd-services:28` | `status=$(systemctl is-active "$s")` | `is-active` must print `active`/`inactive` on stdout |
| `mmdvmhost/functions.php:579` | `shell_exec("systemctl is-active …")` | same |

Exit codes follow systemd: `is-active` returns 3 when inactive, `is-enabled`
returns 1 when disabled or masked.

## Absolute-path callers

`pistar-watchdog` invokes `/bin/systemctl` by absolute path, and `sudo` resets
`PATH` to `secure_path`. The Dockerfile therefore symlinks the shim into `/bin`,
`/usr/bin` and `/sbin` as well as leaving it at `/usr/local/bin`. The same is
done for `journalctl`, `timedatectl`, `nmcli`, `reboot`, `poweroff`, `halt` and
`shutdown`.

## Companion shims

| Shim | Why it exists |
| --- | --- |
| `journalctl` | `.wpsd-running-tasks` calls `--rotate`, `--vacuum-time=24h`, `--vacuum-size=5M` to keep the journal off the SD card. No-ops here; reads tail the s6 log |
| `timedatectl` | The dashboard's timezone selector calls `set-timezone` 9 times, plus `list-timezones` and `timesync-status` |
| `nmcli` | NetworkManager owns the host's radios, not the container's netns. Queries return empty so wifi-manager renders "no interfaces"; writes refuse loudly |
| `reboot` / `shutdown` / `poweroff` / `halt` | The dashboard has reboot and shutdown buttons (`sudo reboot`, `sudo shutdown -h now`). They recycle PID 1 after `wpsd-services fullstop` |

No `vcgencmd` shim is needed: `includes/hw_info.php` reads
`/sys/class/thermal/thermal_zone0/temp` directly and guards it with
`file_exists`, so the CPU-temperature panel hides itself when absent.

## Regression test

`tests/systemctl-calls.txt` is every distinct `systemctl` invocation extracted
from the appliance's dashboard and scripts. `tests/smoke.sh` replays it against
the shim. When upstream adds a unit, the extraction diff shows it.
