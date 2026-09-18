# reference/

Assets extracted from the upstream appliance image by
`scripts/extract-reference.sh`. Nothing here ships in the runtime image.

| Path | What it is | Why it is kept |
| --- | --- | --- |
| `units/etc/`, `units/lib/` | the appliance's 71 systemd unit files | the specification the `systemctl` shim is written against. When upstream adds a unit, re-running the extraction shows it as a diff |
| `rootfs/usr-local-sbin/` | the WPSD service wrapper scripts as shipped | lets you read the `DAEMON=` declarations and the start/stop logic the shim delegates to, without mounting the image |
| `rootfs/lib-armhf/` | `libwiringPi`, `libwiringPiDev`, `libArduiPi_OLED` | load-time dependencies of the shipped armhf `MMDVMHost` with no Debian package anywhere. Needed only by `Dockerfile.armhf-reference` |
| `rootfs/fstab`, `rc.local`, `passwd`, `group`, `php-fpm-www.conf` | appliance system config | what the container reproduces, and what it deliberately does not |
| `Dockerfile.armhf-reference` | the appliance's own binaries in a container | behaviour diffing against the native build |

`reference/rootfs/` is gitignored — it is a verbatim copy of GPL'd upstream
material and regenerating it takes one command.

## Diffing the native build against the reference

```sh
./scripts/extract-reference.sh
docker build -f reference/Dockerfile.armhf-reference --platform linux/arm/v7 \
             -t wpsd:armhf-reference .
```

Then bring both up and compare the rendered pages. Expected differences:

* the version strings (`<date>_WPSD-docker` vs `<date>_WPSD`)
* the platform string (`Generic … class computer` either way, but the CPU differs)
* the UUID (pseudo-serial vs the Pi's device-tree serial)
* CPU temperature (present only if the host exposes a thermal zone)

Anything else is worth investigating.
