# Architecture

## What the appliance is

`WPSD_RPi-Trixie.img` is a 3.8 GB Raspbian Trixie (Debian 13) SD-card image.
Two properties dominate every design decision here, and both were confirmed by
loop-mounting the image rather than inferred:

**It has a 64-bit kernel over a 32-bit userland.** `/boot` carries
`vmlinuz-6.12.34+rpt-rpi-v8` (arm64), but `dpkg --print-architecture` reports
`armhf`, the apt sources pin `Architectures: armhf`, and every WPSD binary is
`ELF 32-bit LSB executable, ARM, EABI5`. Those binaries run natively on a 64-bit
Pi (the kernel keeps AArch32 support) but Apple Silicon has no AArch32 at all, so
on a Mac they need QEMU. This image builds from source instead.

**Everything is systemd.** ~40 units: one per radio daemon, `OnStartupSec` timers
used purely for startup ordering, `OnCalendar` timers for periodic work, and a
dashboard that shells out to `sudo systemctl` in 47 places.

## What WPSD actually is

Three git checkouts on top of stock Debian packages:

| Path | Upstream | Contents |
| --- | --- | --- |
| `/usr/local/bin` | `WPSD-Binaries` | the compiled radio daemons + 8 MB of modem firmware blobs |
| `/usr/local/sbin` | `WPSD-Scripts` | the service wrappers, the watchdog, the updater |
| `/var/www/dashboard` | `WPSD-WebCode` | 159 PHP files |
| `/usr/local/etc` | `hostfiles.w0chp.net` | 39 MB of host, talkgroup and DMR-ID data, refreshed hourly |

Everything else — nginx, PHP 8.4, cron, avahi, gpsd, samba — is `apt install`.
Debian Trixie ships PHP 8.4, so the web stack needs no third-party repository to
match the appliance exactly.

## Stage layout

```
builder (debian:trixie)
  ├─ clone WPSD_CustomBinaries-Source @ branch arm64
  ├─ stamp Version.h  ->  <date>_WPSD-docker
  ├─ arm64 only: build ArduiPi_OLED + WiringPi into /usr/local
  ├─ build ~20 subprojects in upstream's order
  └─ /out/usr/local/{bin,lib}

s6 (debian:trixie-slim)
  └─ s6-overlay + syslogd-overlay for the target arch

runtime (debian:trixie-slim)
  ├─ apt: nginx, php8.4-fpm, cron, avahi, gpsd, samba, vnstat, shellinabox, ...
  ├─ clone WPSD-Scripts  -> /usr/local/sbin      (keeps .git)
  ├─ clone WPSD-WebCode  -> /var/www/dashboard   (keeps .git)
  ├─ COPY --from=builder /out/
  ├─ COPY --from=s6 /
  └─ COPY rootfs/    (shims, nginx conf, s6 services, config seeds)
```

### Why architecture is a branch, not a flag

Upstream builds natively on each board and commits the result. `WPSD-Binaries`
has branches `master` (armhf), `arm64` and `mqtt`; `WPSD_CustomBinaries-Source`
has `master` and `arm64`. We clone the `arm64` source branch because it holds the
64-bit-clean sources, and those compile for amd64 too.

### Why nothing is vendored

The dashboard's README asks that the code not be mirrored to GitHub or elsewhere.
Cloning from `repo.w0chp.net` and `wpsd-swd.w0chp.net` at build time satisfies
both the GPL and that request. It also means the build fails loudly if upstream
changes, rather than silently shipping a stale fork.

### Why the dashboard keeps its `.git`

`config/version.php` renders the version string by shelling out:

```php
$versionCmd = exec("git --work-tree=/var/www/dashboard --git-dir=/var/www/dashboard/.git rev-parse --short=10 $gitBranch");
```

`.wpsd-common-funcs` does the same for `$dashVer`. Strip the `.git` directory and
the dashboard header renders `WPSD Dashboard Ver.#` with nothing after it.
`/usr/local/sbin` keeps its `.git` for the same reason. `/usr/local/bin`
deliberately does **not** get one — see the self-updater below.

### The wiringPi split

`MMDVMHost/Makefile.WPSD` compiles `-DOLED -DHD44780 -DPCF8574_DISPLAY` and links
`-lwiringPi -lwiringPiDev -lArduiPi_OLED`. `ArduiPi_OLED` is in the source tree;
wiringPi is not, and has no amd64 port.

| Target | Makefile | Display support |
| --- | --- | --- |
| arm64 / armhf | `Makefile.WPSD` + WiringPi from the maintained fork | OLED, HD44780, PCF8574, Nextion |
| amd64 | stock `Makefile` + `-DHAS_SRC -lsamplerate` | Nextion only (serial, not GPIO) |

The stock `Makefile` omits the resampler, so the build script injects `-DHAS_SRC`
and `-lsamplerate`: the WPSD config files set `[Modem]` resampler options that
`Conf.cpp` only parses when that macro is defined.

## Finding the packages WPSD actually needs

Guessing the runtime package list from the appliance's `dpkg` manual-install set
overshoots (it includes `build-essential`, `gdb`, kernel images) and still misses
things, because WPSD shells out constantly. A precise answer comes from diffing
command sets, using the appliance itself as the oracle:

```sh
# every command word referenced by the scripts and the dashboard
{ grep -rhoE '(^|[;|&(]|\bsudo |\bexec |\$\()[[:space:]]*[a-z][a-z0-9_.-]{2,}' /usr/local/sbin
  grep -rhoE '(shell_exec|exec|system|passthru)\("[^"]+' /var/www/dashboard --include='*.php' | sed 's/.*("//'
} | ... | sort -u > cands

# keep only the ones that are real commands ON THE APPLIANCE, then subtract
# whatever the container already has
comm -12 cands appliance-cmds | comm -23 - container-cmds
```

That reduced 751 noisy candidates to 19 real ones, of which four mattered:

| Missing | Used by | Resolution |
| --- | --- | --- |
| `bunzip2` | `wpsd-hostfile-update` unpacks the host-file archive | added `bzip2` — without it the fetch fails at `tar (child): bzip2: Cannot exec` and every reflector list stays empty |
| `iptables`, `ip6tables`, `*-save` | `pistar-firewall`, and `.wpsd-common-funcs` reads `/etc/iptables.rules` to decide `fwState` | added `iptables` |
| `gpio` | `wpsd-modemreset` and `wpsd-modemupgrade` strobe the modem reset line, the latter via the absolute path `/usr/bin/gpio` | WiringPi's CLI, installed setuid from the builder and symlinked into `/usr/bin` on arm |
| `scp` | `wpsd-backup` can copy a backup to a remote host | added `openssh-client` |
| `fdisk` | `.wpsd-expand`, and sysinfo's disk panel | added |

Deliberately still missing, because they act on things a container does not own:
`ifup`/`ifdown` and `wpa_cli` (host networking — the `nmcli` stub covers the
dashboard's pages), `modprobe`/`rmmod` (host kernel), `resize2fs` (no SD card).
`make` is builder-only. `edit`, `print` and `uuid` were false positives.

## Process model

```
PID 1  s6-svscan
  │
  ├─ oneshot 01-init          timezone, machine-id, pseudo device-tree serial,
  │                           config seeding, boot sentinels, self-update gate
  ├─ oneshot 02-hostfiles     first-run fetch of the 39 MB host-file set
  ├─ longrun  php-fpm         php-fpm8.4 -F
  ├─ longrun  nginx           nginx -g 'daemon off'
  ├─ longrun  cron            carries the five former systemd timers
  ├─ longrun  avahi vnstat shellinabox gpsd samba dnsmasq hostapd   (env-gated)
  ├─ oneshot 10-wpsd-start    wpsd-services start   (down hook: fullstop)
  └─ longrun  pistar-watchdog supervises the ~20 radio daemons via the shim
```

Ten supervised processes, not thirty, because **WPSD ships its own supervisor**.
`pistar-watchdog` polls `systemctl is-active` for every mode enabled in
`/etc/mmdvmhost` and restarts what died, every 120 s. Give it a working
`systemctl` and the radio daemons look after themselves — which is also why
s6 never needs to know that `ysf2dmr` depends on `YSFGateway` and `DMRGateway`.

`10-wpsd-start` replaces both `mmdvmhost.timer` (`OnStartupSec=30`) and
`dmrgateway.timer` (`OnStartupSec=20`): those timers existed only as a startup
delay, and `wpsd-services start` already sequences the daemons correctly.

Optional daemons park themselves rather than restart-looping. Their `run` script
checks its env flag and, when off, calls `s6-svc -d` on its own service directory
and `exec`s `s6-pause`: `-d` sets want-down and TERMs the parked process, so the
supervisor leaves it alone. `systemctl start <unit>` still brings it up.

See [SYSTEMCTL-SHIM.md](SYSTEMCTL-SHIM.md) for the shim itself.

## Timers → cron

| Former unit | systemd schedule | cron line |
| --- | --- | --- |
| `wpsd-cache.timer` | `OnCalendar=*-*-* *:*:00` | `* * * * *` |
| `wpsd-log-cleanup.timer` | `OnUnitActiveSec=1min` | `* * * * *` as `mmdvm` |
| `wpsd-running-tasks.timer` | hourly, `RandomizedDelaySec=1h` | `0 * * * *` + `sleep $((RANDOM % 3600))` |
| `wpsd-hostfile-update.timer` | hourly, `RandomizedDelaySec=3600` | `17 * * * *` + `sleep $((RANDOM % 1800))` |
| `wpsd-nightly-tasks.timer` | 01:00, `RandomizedDelaySec=2h59m` | `0 1 * * *`, gated off by default |

The randomised delays are load-shedding for W0CHP's servers, not cosmetics —
thousands of hotspots would otherwise fire on the hour. cron has no equivalent,
so the jitter is a `sleep` prefix. cron also does not inherit the container
environment, so the nightly job is gated on a marker file `01-init` writes from
`WPSD_ALLOW_SELF_UPDATE` rather than on the variable.

## The in-place updaters

Three separate mechanisms rewrite the installation in place, and they are not
equivalent, so each is handled on its own terms.

| Mechanism | What it does | Handling |
| --- | --- | --- |
| `.wpsd-nightly-tasks` | `git reset --hard origin/master` + `git pull` over `/usr/local/{bin,sbin}` and the dashboard, nightly | not scheduled at all — the cron line requires `/var/lib/wpsd-units/.self-update-allowed` |
| `wpsd-update` | the same, on demand from the dashboard's Update button | replaced by a gate wrapper; the original is kept as `wpsd-update.upstream` |
| `.wpsd-slipstream-tasks` | `curl -Ls <backend> \| bash` as root, hourly | gated the same way |
| `.wpsd-first-boot` | pulls all three repos on first boot | `touch /boot/.WPSD_Booted`, the sentinel it checks |

On the appliance the nightly reset *is* the update mechanism. Here it would
replace the natively-built binaries with upstream's **armhf** ones and break the
image, so rebuilding is the update path. `WPSD_ALLOW_SELF_UPDATE=1` restores all
of it, with a warning in the log.

`.wpsd-slipstream-tasks` deserves the separate mention: it pipes unreviewed remote
code into `bash` as root every hour. That is a reasonable design for an appliance
the author controls end to end, and a poor one for an image somebody else built.

### Why `OptIntoDiags = false` is *not* used

That flag is upstream's own off switch for the updaters — `.wpsd-running-tasks`
and `.wpsd-nightly-tasks` both exit early when it is false. It is tempting, and
it is wrong: `wpsd-hostfile-update` honours the same flag.

```sh
# wpsd-hostfile-update, line 23
if [ "$OptIntoDiags_value" != 'true' ]; then
  echo "User has opted out of updates and diagnostics. Exiting..."
  exit 1
fi
```

With it false, `/usr/local/etc` never fills, and the gateways cannot resolve a
single reflector or talkgroup — the hotspot looks like it works and routes
nothing. Trading call routing for update suppression is the wrong deal, so the
updaters are gated individually and `OptIntoDiags` is left as the user's choice.

This was caught by the container's own first boot:

```
[wpsd-hostfiles] first run: fetching host files (this takes a minute)
Starting WPSD Host, TG, and ID DB files update script...
User has opted out of updates and diagnostics. Exiting...
```

## Volumes

| Volume | Mount | Why |
| --- | --- | --- |
| `wpsd-hostfiles` | `/usr/local/etc` | 39 MB, regenerated upstream continuously — never bake it in |
| `wpsd-logs` | `/var/log/pi-star` | the last-heard history the dashboard renders |
| `wpsd-state` | `/var/lib/wpsd-units` | shim enable/disable/mask markers |
| `wpsd-config` | `/etc/wpsd` | the dashboard's `/etc` configuration, copied in and out by `wpsd-config-sync` |

### Why the config volume copies instead of mounting

WPSD's configuration is ~30 files spread across `/etc`, and the dashboard edits
them with `sudo sed -i` in 167 places. Every mounting strategy breaks on one of
those two facts:

* A volume cannot be mounted over `/etc`.
* Bind-mounting the files individually breaks `sed -i`: sed edits in place by
  writing a temporary file and renaming it over the target, and rename fails with
  `EBUSY` on a bind mount.
* Symlinking them into a volume breaks it more quietly. GNU `sed -i` without
  `--follow-symlinks` *replaces* the symlink with a regular file, so the first
  save silently detaches `/etc` from the volume and every later change is lost on
  recreate.

So the files stay ordinary files in `/etc`, and `wpsd-config-sync` copies them:
`restore` at init (before the factory seeds, so the volume wins), `save` every
minute from cron and again from the shutdown hook. A `docker kill` can therefore
lose at most a minute of configuration changes, and `sed -i` behaves exactly as
it does on the appliance. `/etc/mmdvmhost` is stored flat as `etc__mmdvmhost`;
`wpsd-config-sync list` shows the state of each file.

The appliance mounts a dozen paths as tmpfs via `/etc/fstab` to spare the SD card.
Only the ones the software needs to exist are reproduced (`/run`, `/tmp`,
`/var/lib/php/sessions`); wear levelling is not a container concern.

## Licensing

All four upstream repos are GPL — `WPSD-WebCode` and `WPSD_CustomBinaries-Source`
GPL-3.0, `WPSD-Binaries` and `WPSD-Scripts` GPL-2.0 — and W0CHP publishes the
full source, so building and redistributing a container image is permitted.

Alongside that, upstream asks that the code not be mirrored elsewhere, states
that the update and hostfile backends are deliberately proprietary and should not
be consumed by unsanctioned clients, and provides no support whatsoever for
containers or modified installs. This project respects that by cloning from
W0CHP's own servers, keeping the upstream request jitter and user agents, leaving
self-update off, and not presenting itself as official WPSD.
