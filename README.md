# wpsd-docker

Runs [WPSD](https://wpsd.radio/) — W0CHP's amateur-radio digital-voice hotspot
software — in a container, built from source for your machine's architecture.

Not an official WPSD project. Upstream provides no support for containers.

```sh
docker compose build          # compiles the radio daemons (~10 min)
docker compose up -d
open http://localhost:8080/   # admin pages: pi-star / raspberry -- change this
```

With no modem attached the dashboard comes up and the radio daemons stay down,
which is what the appliance does before Configuration is run.

First boot takes a couple of minutes: it fetches ~27 MB of host, talkgroup and
DMR-ID data into a volume (without it the gateways cannot resolve a reflector).
After that, a restart has the dashboard serving in about 10 seconds and
MMDVMHost running about 15 seconds in — the service wrapper waits for an
interface to get an IP and then sleeps 5 s, exactly as on the appliance.

## What you get

MMDVMHost, DMRGateway, ircDDBGateway, YSFGateway, DGIdGateway, NXDNGateway,
P25Gateway, DAPNETGateway, APRSGateway, the three parrots, the five cross-mode
bridges, MMDVMCal, NextionDriver — and the full PHP dashboard including every
admin page, driven by a `systemctl` shim so nothing upstream had to be patched.

## Attaching a modem

Pick whichever matches your hardware, then set it under `[Modem]` in
`/etc/mmdvmhost` (or through the dashboard's Configuration page):

| Hardware | Compose | `Protocol` |
| --- | --- | --- |
| Network-attached modem | nothing | `udp` + `ModemAddress`/`ModemPort` |
| USB hotspot board | `devices: [/dev/ttyACM0:/dev/ttyACM0]` | `uart`, `UARTPort=/dev/ttyACM0` |
| GPIO hat (Pi host only) | `devices: [/dev/ttyAMA0, /dev/gpiomem, /dev/i2c-1]` | `uart`, `UARTPort=/dev/ttyAMA0` |
| None — dashboard only | nothing | `null` |

See [docs/HARDWARE.md](docs/HARDWARE.md).

## Verifying it works

```sh
./tests/smoke.sh
```

Checks s6 supervision, replays every `systemctl` call the appliance makes against
the shim, asserts the parsed-output contracts the dashboard depends on, confirms
all the binaries are present and native, exercises the web stack and its auth,
and starts MMDVMHost against a null modem.

## Expected noise before you configure it

Until you run the dashboard's Configuration page once, the php-fpm log carries
`Undefined array key "Modem" in .../admin/configure.php` warnings. That is the
appliance's own pre-configuration state, not a container problem:
`/etc/dstar-radio.mmdvmhost` is written by `configure.php`, and until it exists
the page has no `[Modem]` section to read. `display_errors` is `Off`, so they
never reach the browser. They stop once a modem is configured.

For the same reason `wpsd-services status` reports every radio daemon `INACTIVE`
on a fresh install — each wrapper script gates on that file. `pistar-watchdog`,
`cron` and the timers should be `ACTIVE`.

## Configuration

| Variable | Default | Effect |
| --- | --- | --- |
| `WPSD_TZ` | `Etc/UTC` | initial timezone; the dashboard can change it afterwards |
| `WPSD_ALLOW_SELF_UPDATE` | `0` | `1` restores upstream's nightly `git reset --hard`. **It will overwrite the binaries this image built** |
| `WPSD_ENABLE_AVAHI` | `1` | mDNS, so `http://wpsd.local/` resolves |
| `WPSD_ENABLE_VNSTAT` | `1` | the dashboard's network traffic graph |
| `WPSD_ENABLE_SHELLINABOX` | `0` | web terminal on port 2222 |
| `WPSD_ENABLE_GPSD` | `0` | needs `WPSD_GPSD_DEVICE` passed through |
| `WPSD_ENABLE_SAMBA` | `0` | file sharing |
| `WPSD_ENABLE_DNSMASQ` / `_HOSTAPD` | `0` | AP mode; needs `network_mode: host` and `NET_ADMIN` |

## Updating

Rebuild. `docker compose build --pull && docker compose up -d`. Your config,
logs and host files live in volumes and survive it.

The image gates WPSD's three in-place updaters, which would `git reset --hard
origin/master` over `/usr/local/bin` and replace the natively-built binaries with
upstream's armhf ones. What is *not* gated is the hourly host-file fetch: those
files are what let the gateways resolve reflectors and talkgroups, and the
software cannot route a call without them. Details in
[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md#the-in-place-updaters).

## Size

~610 MB. Most of it is the Debian runtime plus the optional daemons the appliance
also ships (samba, avahi, gpsd, vnstat, shellinabox, the Python display stack).
The WPSD parts are small: 16 MB of compiled binaries, 21 MB of dashboard, and
27 MB of host-file data that lives in a volume rather than the image.

Worth knowing if you trim it further: `gpsd-clients` is deliberately absent. In
Trixie it depends on `python3-matplotlib`, which pulls in sympy and mpmath for
about 250 MB — and nothing in WPSD calls `gpspipe`, `cgps` or `gpsmon`.

## Architecture support

| Target | Status |
| --- | --- |
| `linux/arm64` | full — OLED, HD44780, PCF8574 and Nextion displays |
| `linux/amd64` | full except GPIO/I²C displays (Nextion over serial still works) |

```sh
docker buildx build --platform linux/arm64,linux/amd64 -t wpsd:local .
```

## Repository layout

```
Dockerfile                builder / s6 / runtime stages
compose.yaml
scripts/
  build-binaries.sh       mirrors upstream's build-all.sh, natively
  extract-reference.sh    dev-time: pull configs and unit files out of the .img
rootfs/
  usr/local/bin/systemctl the shim, plus journalctl/timedatectl/nmcli/reboot/...
  etc/s6-overlay/         the service tree and init scripts
  etc/cron.d/wpsd-timers  the five former systemd timers
  etc/wpsd-defaults/      config seeds copied into /etc on first run
reference/units/          the appliance's systemd units -- the shim's spec
tests/
  smoke.sh                hardware-free acceptance test
  systemctl-calls.txt     every systemctl call the appliance makes
docs/
  ARCHITECTURE.md         how it is put together and why
  SYSTEMCTL-SHIM.md       the shim's contract, unit by unit
  HARDWARE.md             modems, displays, and what a container cannot do
```

## Building from the appliance image

Not required — the build clones everything from W0CHP's servers. But if you have
`WPSD_RPi-Trixie.img`, `scripts/extract-reference.sh` refreshes the config seeds
and the systemd units the shim is written against:

```sh
./scripts/extract-reference.sh WPSD_RPi-Trixie.img
```

## Security

`www-data` has unrestricted passwordless `sudo`, because the WPSD dashboard *is*
the configuration-management layer — 167 `sudo sed` calls, 47 `sudo systemctl`.
What guards it is the basic auth on `/admin`. **Change the default password** and
do not publish port 80 to an untrusted network. Details in
[docs/HARDWARE.md](docs/HARDWARE.md#security-posture).

## Licence

WPSD is GPL — `WPSD-WebCode` and `WPSD_CustomBinaries-Source` GPL-3.0,
`WPSD-Binaries` and `WPSD-Scripts` GPL-2.0 — and W0CHP publishes the full source.
Nothing from those repos is vendored here: the build clones from
`repo.w0chp.net` and `wpsd-swd.w0chp.net`, which respects both the GPL and
upstream's request that the code not be mirrored elsewhere.

Upstream also asks that its update and hostfile backends not be consumed by
unsanctioned clients. This image leaves the self-updater off, keeps upstream's
request jitter and user-agent strings on the hourly hostfile fetch, and does not
present itself as official WPSD. Please do not point a fleet of these at
`hostfiles.w0chp.net`.

The glue in this repository (Dockerfile, shims, s6 services, docs) is offered
under GPL-2.0-or-later, to stay compatible with what it wraps.
