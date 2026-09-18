# syntax=docker/dockerfile:1
#
# WPSD (amateur-radio digital-voice hotspot) in a container.
#
# The upstream appliance is a Raspbian Trixie SD-card image with an armhf
# userland and ~40 systemd units. This builds the same software natively for the
# host's architecture and runs it under s6-overlay with a systemctl shim.
#
# Nothing is vendored: the dashboard's README asks that the code not be mirrored
# elsewhere, so every WPSD component is fetched from W0CHP's own servers at build
# time. See docs/ARCHITECTURE.md.

ARG DEBIAN_TAG=trixie
ARG S6_VERSION=3.2.3.2

# Arch is a BRANCH in upstream's repos, not a build flag. The arm64 branch holds
# the 64-bit-clean sources and compiles for amd64 too; master is the armhf branch.
ARG WPSD_SRC_BRANCH=arm64
ARG WPSD_SRC_REPO=https://repo.w0chp.net/WPSD-Dev/WPSD_CustomBinaries-Source.git
ARG WPSD_BIN_REPO=https://repo.w0chp.net/WPSD-Dev/WPSD-Binaries.git
ARG WPSD_SCRIPTS_REPO=https://wpsd-swd.w0chp.net/WPSD-SWD/WPSD-Scripts.git
ARG WPSD_WEB_REPO=https://wpsd-swd.w0chp.net/WPSD-SWD/WPSD-WebCode.git
ARG WPSD_SCRIPTS_REF=master
ARG WPSD_WEB_REF=master


# ---------------------------------------------------------------------------
# Stage: builder -- compile the radio daemons
# ---------------------------------------------------------------------------
FROM debian:${DEBIAN_TAG} AS builder

ARG WPSD_SRC_BRANCH
ARG WPSD_SRC_REPO
ARG TARGETARCH
ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential git ca-certificates pkg-config \
        libsamplerate0-dev libwxgtk3.2-dev libgps-dev libi2c-dev libusb-dev \
    && rm -rf /var/lib/apt/lists/*

RUN git clone --depth 1 --branch "${WPSD_SRC_BRANCH}" "${WPSD_SRC_REPO}" /build/src \
    && git -C /build/src rev-parse HEAD > /build/src-commit

COPY scripts/build-binaries.sh /build/build-binaries.sh
RUN TARGETARCH="${TARGETARCH}" SRC=/build/src OUT=/out/usr/local/bin \
        /build/build-binaries.sh

# The modem firmware blobs and flashing helpers the dashboard's modem-upgrade
# page serves. Only this subdirectory is taken from the prebuilt-binaries repo;
# the executables themselves are the ones just compiled above.
ARG WPSD_BIN_REPO
# A partial clone (--filter=blob:none) would fetch ~8 MB instead of 89 MB, but
# this Gitea instance does not advertise uploadpack.allowFilter, so it fails.
RUN git clone --depth 1 --branch master "${WPSD_BIN_REPO}" /build/bin-repo \
    && cp -a /build/bin-repo/firmware /out/usr/local/bin/firmware \
    && cp -a /build/bin-repo/LICENSE  /out/usr/local/bin/LICENSE \
    && rm -rf /build/bin-repo


# ---------------------------------------------------------------------------
# Stage: s6 -- fetch the supervision suite
# ---------------------------------------------------------------------------
FROM debian:${DEBIAN_TAG}-slim AS s6

ARG S6_VERSION
ARG TARGETARCH
ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends curl ca-certificates xz-utils \
    && rm -rf /var/lib/apt/lists/*

RUN set -eux; \
    case "${TARGETARCH}" in \
        amd64) s6arch=x86_64  ;; \
        arm64) s6arch=aarch64 ;; \
        arm)   s6arch=armhf   ;; \
        *) echo "unsupported TARGETARCH=${TARGETARCH}" >&2; exit 1 ;; \
    esac; \
    mkdir -p /s6; \
    base="https://github.com/just-containers/s6-overlay/releases/download/v${S6_VERSION}"; \
    for t in "noarch" "${s6arch}" "symlinks-noarch"; do \
        curl -fsSL "${base}/s6-overlay-${t}.tar.xz" -o "/tmp/${t}.tar.xz"; \
        tar -C /s6 -Jxpf "/tmp/${t}.tar.xz"; \
    done; \
    curl -fsSL "${base}/syslogd-overlay-noarch.tar.xz" -o /tmp/syslogd.tar.xz; \
    tar -C /s6 -Jxpf /tmp/syslogd.tar.xz


# ---------------------------------------------------------------------------
# Stage: runtime
# ---------------------------------------------------------------------------
FROM debian:${DEBIAN_TAG}-slim

ARG TARGETARCH
ARG WPSD_SCRIPTS_REPO
ARG WPSD_WEB_REPO
ARG WPSD_SCRIPTS_REF
ARG WPSD_WEB_REF
ENV DEBIAN_FRONTEND=noninteractive

# Trixie ships PHP 8.4, which is exactly what the appliance runs -- no third
# party PHP repository needed.
RUN apt-get update && apt-get install -y --no-install-recommends \
        nginx \
        php8.4-fpm php8.4-cli php8.4-mbstring php8.4-zip php8.4-readline \
        cron sudo bash git curl wget rsync jq \
        procps psmisc iproute2 net-tools iputils-ping bc file \
        apache2-utils lsb-release locales tzdata ca-certificates \
        unzip zip p7zip-full bzip2 nano \
        iptables fdisk openssh-client \
        libsamplerate0 libwxbase3.2-1t64 libgps30t64 libi2c0 libusb-0.1-4 \
        vnstat shellinabox avahi-daemon avahi-utils libnss-mdns \
        gpsd gpsd-clients samba samba-common-bin \
        miniupnpc dnsmasq hostapd wireless-tools iw nftables \
        python3 python3-luma.oled python3-serial python3-smbus2 \
        python3-psutil python3-configargparse python3-libgpiod i2c-tools \
    && rm -rf /var/lib/apt/lists/*

# Raspberry Pi GPIO bindings exist only on ARM. The OLED/Nextion helper scripts
# import these; on amd64 they degrade to "no display", which is honest.
RUN set -eux; \
    if [ "${TARGETARCH}" = "arm64" ] || [ "${TARGETARCH}" = "arm" ]; then \
        apt-get update; \
        apt-get install -y --no-install-recommends \
            python3-rpi.gpio python3-gpiozero pigpio python3-pigpio || true; \
        rm -rf /var/lib/apt/lists/*; \
    fi

# Users and groups.
#
# The UIDs matter: /usr/local/etc, /var/log/pi-star and the rest live in volumes,
# so pi-star must be 1000 and mmdvm 1001 to match the appliance -- that keeps
# ownership correct across a rebuild and lets you drop in files copied off an SD
# card. The appliance's gpio/i2c/spi GIDs (993/998/999) do NOT matter and cannot
# be honoured anyway: Debian's system accounts for samba, avahi and gpsd have
# already taken that range by this point, and device access is governed by the
# HOST's GIDs on a passed-through device regardless. See docs/HARDWARE.md.
RUN set -eux; \
    for g in gpio i2c spi; do getent group "$g" >/dev/null || groupadd -r "$g"; done; \
    getent group  1000 >/dev/null || groupadd -g 1000 pi-star; \
    getent passwd 1000 >/dev/null || useradd -u 1000 -g 1000 -m -s /bin/bash pi-star; \
    getent group  1001 >/dev/null || groupadd -g 1001 mmdvm; \
    getent passwd 1001 >/dev/null || \
        useradd -u 1001 -g 1001 -m -s /bin/bash -c 'MMDVM Service Account' mmdvm; \
    usermod -aG dialout,spi,i2c,gpio,sudo pi-star; \
    usermod -aG dialout,spi,i2c,gpio      mmdvm; \
    usermod -aG dialout,spi,i2c,gpio      www-data; \
    echo 'pi-star:raspberry' | chpasswd; \
    id pi-star; id mmdvm

# --- WPSD components -------------------------------------------------------
# /usr/local/sbin and the dashboard keep their .git: config/version.php and
# .wpsd-common-funcs both run `git rev-parse` against them to render the version
# string. /usr/local/bin deliberately does NOT get one -- see docs/ARCHITECTURE.md
# on the self-updater.
RUN git clone --branch "${WPSD_SCRIPTS_REF}" "${WPSD_SCRIPTS_REPO}" /tmp/scripts \
    && cp -a /tmp/scripts/. /usr/local/sbin/ \
    && rm -rf /tmp/scripts \
    && git -C /usr/local/sbin rev-parse --short=10 HEAD > /etc/.wpsd-scripts-ref

RUN rm -rf /var/www/html \
    && git clone --branch "${WPSD_WEB_REF}" "${WPSD_WEB_REPO}" /var/www/dashboard \
    && chown -R www-data:www-data /var/www/dashboard \
    && git config --system --add safe.directory /var/www/dashboard \
    && git config --system --add safe.directory /usr/local/sbin

COPY --from=builder /out/usr/local/bin/ /usr/local/bin/
COPY --from=builder /out/usr/local/lib/ /usr/local/lib/

# Assert the binaries actually resolve their shared libraries HERE, not just in
# the builder where the dev packages were still installed. A missing
# libwiringPi.so used to surface only at runtime as an empty version field on the
# dashboard; this turns that into a failed build.
RUN set -eux; \
    ldconfig; \
    for b in MMDVMHost DMRGateway ircddbgatewayd YSFGateway NXDNGateway \
             P25Gateway DAPNETGateway APRSGateway NextionDriver; do \
        ldd "/usr/local/bin/$b" | grep -q 'not found' \
            && { echo "FATAL: $b has unresolved libraries"; ldd "/usr/local/bin/$b"; exit 1; } \
            || true; \
    done; \
    MMDVMHost -v; \
    DMRGateway -v

COPY --from=s6 /s6/ /

# --- our overlay: shims, nginx config, s6 services, config seeds ------------
COPY rootfs/ /

# The shim must win for absolute-path callers too: pistar-watchdog invokes
# /bin/systemctl directly, and sudo resets PATH to secure_path.
RUN set -eux; \
    for t in systemctl journalctl timedatectl nmcli reboot poweroff halt shutdown; do \
        ln -sf "/usr/local/bin/${t}" "/bin/${t}"; \
        ln -sf "/usr/local/bin/${t}" "/usr/bin/${t}"; \
        ln -sf "/usr/local/bin/${t}" "/sbin/${t}"; \
    done

RUN set -eux; \
    [ -x /usr/local/bin/gpio ] && ln -sf /usr/local/bin/gpio /usr/bin/gpio || true; \
    rm -f /etc/nginx/sites-enabled/default; \
    ln -sf /etc/nginx/sites-available/wpsd /etc/nginx/sites-enabled/wpsd; \
    chmod 0440 /etc/sudoers.d/wpsd-www; \
    chmod 0644 /etc/cron.d/wpsd-timers; \
    mkdir -p /var/log/pi-star /var/log/wpsd /var/lib/wpsd-units \
             /run/php /var/lib/php/sessions /boot/firmware; \
    chown mmdvm:mmdvm /var/log/pi-star; chmod 775 /var/log/pi-star; \
    sed -i 's/^Listen /#Listen /' /etc/shellinabox/* 2>/dev/null || true; \
    localedef -i en_US -c -f UTF-8 -A /usr/share/locale/locale.alias en_US.UTF-8 || true

ENV LANG=en_US.UTF-8 \
    S6_KEEP_ENV=1 \
    S6_BEHAVIOUR_IF_STAGE2_FAILS=2 \
    S6_CMD_WAIT_FOR_SERVICES_MAXTIME=0 \
    S6_LOGGING=0 \
    WPSD_ALLOW_SELF_UPDATE=0 \
    WPSD_TZ=Etc/UTC \
    WPSD_ENABLE_AVAHI=1 \
    WPSD_ENABLE_VNSTAT=1 \
    WPSD_ENABLE_SHELLINABOX=0 \
    WPSD_ENABLE_GPSD=0 \
    WPSD_ENABLE_SAMBA=0 \
    WPSD_ENABLE_DNSMASQ=0 \
    WPSD_ENABLE_HOSTAPD=0

EXPOSE 80 443
VOLUME ["/usr/local/etc", "/var/log/pi-star", "/var/lib/wpsd-units"]

HEALTHCHECK --interval=60s --timeout=10s --start-period=90s --retries=3 \
    CMD curl -fsS -o /dev/null http://127.0.0.1/ || exit 1

ENTRYPOINT ["/init"]
