# Hardware, and what a container cannot reproduce

## The modem

MMDVMHost supports four `[Modem] Protocol` values, and three of them work in a
container. This is the single biggest reason WPSD containerises well.

### 1. `Protocol=udp` — network-attached modem, nothing to pass through

```ini
[Modem]
Protocol=udp
ModemAddress=192.168.1.50
ModemPort=3334
LocalAddress=0.0.0.0
LocalPort=3335
```

No `--device`, no privileges, no host-arch requirement. The container can live on
a different machine from the radio hardware entirely.

### 2. `Protocol=uart` — USB hotspot board

ZUMspot USB, MMDVM_HS on a USB-serial adapter, DVMEGA USB, and similar:

```yaml
devices:
  - /dev/ttyACM0:/dev/ttyACM0
```
```ini
[Modem]
Protocol=uart
UARTPort=/dev/ttyACM0
UARTSpeed=460800
```

The `mmdvm` user is in `dialout` (gid 20) to match the appliance, so no extra
permission work is needed — provided the host's `dialout` gid is also 20, which
it is on Debian and Raspberry Pi OS. On other hosts, check `ls -l /dev/ttyACM0`
and add `group_add: ["<host gid>"]` to the compose service if it differs.

### 3. `Protocol=null` — no radio at all

The dashboard, gateways, watchdog and cron work; nothing transmits. This is what
`tests/smoke.sh` uses, and it makes "does the stack run?" a CI question rather
than a hardware question.

### 4. GPIO hat — needs a real Raspberry Pi host

A hat on the Pi's 40-pin header talks over `/dev/ttyAMA0` and needs GPIO for the
modem reset line:

```yaml
devices:
  - /dev/ttyAMA0:/dev/ttyAMA0
  - /dev/gpiomem:/dev/gpiomem
  - /dev/i2c-1:/dev/i2c-1     # also enables OLED displays
```

Only meaningful on an arm64 Pi host with the image built for arm64.

## Displays

| Display | Bus | arm64 | amd64 |
| --- | --- | --- | --- |
| Nextion / TJC | UART — pass the serial device | yes | yes |
| OLED (SSD1306/SH1106) | I²C — pass `/dev/i2c-1` | yes | no |
| HD44780 | GPIO via wiringPi | yes | no |
| PCF8574 | I²C + GPIO | yes | no |

The amd64 build uses MMDVMHost's stock `Makefile`, which has no wiringPi or
ArduiPi_OLED. Nextion still works because it is a serial protocol, not GPIO.
The Python helpers (`.wpsd-oled.text.py`, `.wpsd-nextion-text.py`) are present on
both, but their `RPi.GPIO` imports only resolve on ARM.

Set `Display=OLED` or `Display=Nextion` under `[General]` in `/etc/mmdvmhost`,
exactly as on the appliance — the display service units are shimmed and the
`wpsd-oled-*` / `wpsd-nx-*` boot and shutdown units are handled as no-ops.

## `/sys/firmware/devicetree/base/serial-number`

`.wpsd-sys-cache` reads this for the dashboard's UUID field:

```sh
GU=$(cat /sys/firmware/devicetree/base/serial-number | tr -cd '[:print:]\n')
```

`/sys` is read-only sysfs in a container, so `compose.yaml` mounts a tmpfs at
`/sys/firmware` and `01-init` seeds a stable pseudo-serial from `/etc/machine-id`.
Without that mount the field renders blank — degraded, not fatal.

## CPU temperature

No shim needed. `includes/hw_info.php` reads
`/sys/class/thermal/thermal_zone0/temp` directly and guards it with
`file_exists`, so the panel hides itself where the host does not expose one.
Linux hosts generally do; Docker Desktop's VM does not.

## Platform string

`.wpsd-platform-detect` parses `/proc/cpuinfo` for Pi / Odroid / Artik / sun8i
signatures and falls back to `Generic <cpu> class computer`. In a container that
fallback is the honest answer, and it is left alone.

## `nice -n -10`

MMDVMHost is started at `nice -n -10` by its wrapper script for timing stability
— DMR slots are 30 ms. A container cannot lower its niceness without
`cap_add: [SYS_NICE]`, which `compose.yaml` grants. Without it the `nice` call
fails, the daemon still starts, and you may see slot timing errors under load.

## Not reproduced

| Appliance feature | Why not | Consequence |
| --- | --- | --- |
| WiFi AP mode + captive portal (`10.42.42.251`) | needs to own a host radio: `network_mode: host` plus `NET_ADMIN`/`NET_RAW` | hostapd and dnsmasq are installed and the nginx vhost ships, but the `wpsd` vhost is the only one enabled. Configure the host's network instead |
| `nmcli` / wifi-manager page | NetworkManager owns the host's radios, not the container's netns | the stub returns an empty device list so the page renders "no interfaces" rather than erroring |
| `resize2fs-once`, `.wpsd-expand` | no SD card to grow into | shimmed to no-ops; grow the volume or the host filesystem |
| `rpi-eeprom-update`, `rpi-update` | firmware belongs to the host | not installed |
| `dphys-swapfile` | swap belongs to the host | not installed |
| `wpsd-modemreset` GPIO strobe | needs `/dev/gpiomem` | works on an arm64 Pi host with the device passed through; a no-op elsewhere |
| `systemd-timesyncd` | container inherits the host clock | reported active, because it genuinely is synchronised |
| The upstream nightly `git pull` | would overwrite the natively-built binaries | off by default; rebuild the image instead. See ARCHITECTURE.md |

## Security posture

`www-data` has unrestricted passwordless `sudo`. That is not an oversight
inherited carelessly — it is how WPSD works. The dashboard issues 167 `sudo sed`,
56 `sudo chmod` and 47 `sudo systemctl` calls; the web UI *is* the
configuration-management layer. Narrowing it breaks every admin page.

What guards it is the HTTP basic auth on `/admin` (`pi-star` / `raspberry` by
default — **change it**, via `/admin/` → Security, or `htpasswd /var/www/.htpasswd
pi-star`).

Consequences worth being explicit about:

- Do not publish the container's port 80 to an untrusted network. Bind it to
  localhost or a management VLAN.
- Anyone who can reach `/admin` with the credentials has root inside the
  container. Give it no more host access than the modem device it needs.
- Do not run it with `--privileged`. Nothing here requires it; `SYS_NICE` is the
  only capability added, and AP mode's `NET_ADMIN` is opt-in and commented out.
