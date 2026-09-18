#!/usr/bin/env bash
#
# Build the WPSD radio binaries from source, natively for the target arch.
#
# Mirrors upstream's build-all.sh (repo.w0chp.net/WPSD-Dev/WPSD_CustomBinaries-Source,
# branch arm64) rather than calling it: that script hardcodes SRC_DIR/DEST_DIR to
# the maintainer's ~/dev and ends with a `git commit` into the binaries repo.
#
# Each subproject's `install` target writes to $HOME/dev/WPSD-Binaries/, which is
# unpatchable without forking their makefiles -- so we create that path as a
# plain directory and let the stock targets land there.
#
set -euo pipefail

SRC=${SRC:-/build/src}
DEST="$HOME/dev/WPSD-Binaries"
OUT=${OUT:-/out/usr/local/bin}
ARCH=${TARGETARCH:-$(dpkg --print-architecture)}
JOBS=$(nproc)

mkdir -p "$DEST" "$OUT"

echo "==> building WPSD binaries for ${ARCH} with ${JOBS} jobs"

# --- version stamp ----------------------------------------------------------
# .wpsd-sys-cache parses `MMDVMHost -v` to fill the dashboard's version fields
# for BOTH MMDVMHost and ircddbgateway, so this string is user-visible.
STAMP="$(date -u +%Y%m%d)_WPSD-docker"
cd "$SRC"
find . -name Version.h -exec sed -i \
    -e "/const char\* VERSION =/ s/\"[^\"]*\"/\"${STAMP}\"/" \
    -e "/const wxString VERSION =/ s/wxT(\"[^\"]*\");/wxT(\"${STAMP}\");/" {} \;
echo "    version stamp: ${STAMP}"

# --- display libraries (arm64 only) -----------------------------------------
# ArduiPi_OLED drives I2C/SPI OLED panels through bcm2835 register access, and
# MMDVMHost's Makefile.WPSD links wiringPi for HD44780 and PCF8574 panels.
# Neither means anything on amd64, which uses MMDVMHost's stock Makefile instead.
MMDVM_MAKEFILE=Makefile
MMDVM_EXTRA_CFLAGS='-DHAS_SRC'

if [[ $ARCH == arm64 || $ARCH == armhf || $ARCH == arm ]]; then
    echo "==> ArduiPi_OLED"
    cd "$SRC/ArduiPi_OLED"
    echo Raspberry > hwplatform          # autogen.sh asks this interactively
    make -j"$JOBS" CXX='g++ -include cstdint' CC='gcc -include stdint.h'
    make install
    ldconfig

    echo "==> WiringPi (maintained fork; arm64- and Pi5-capable)"
    # WiringPi's ./build calls sudo for its install steps. The builder already
    # runs as root, so a passthrough stub is lighter than pulling sudo in.
    { echo '#!/bin/sh'; echo 'exec "$@"'; } > /usr/local/bin/sudo
    chmod +x /usr/local/bin/sudo
    git clone --depth 1 https://github.com/WiringPi/WiringPi.git /build/WiringPi
    cd /build/WiringPi
    ./build
    rm -f /usr/local/bin/sudo
    ldconfig

    MMDVM_MAKEFILE=Makefile.WPSD
    MMDVM_EXTRA_CFLAGS=''
else
    echo "==> skipping ArduiPi_OLED + WiringPi (not applicable to ${ARCH})"
fi

# --- toolchain compatibility ------------------------------------------------
# Upstream builds on an older toolchain. GCC 13 stopped including <cstdint>
# transitively, so several subprojects (DAPNETGateway, MMDVM_CM, ...) fail on
# Trixie's GCC 14 with "'uint32_t' was not declared in this scope".
#
# Force-including the header is preferable to patching their sources: make gives
# command-line variables precedence over in-makefile assignments, so this
# overrides `CXX = c++` without touching a single upstream file, and it cannot
# drift when upstream edits the makefiles.
CXX_FIX='c++ -include cstdint'
CC_FIX='cc -include stdint.h'

# --- helpers ----------------------------------------------------------------
build() {                               # build <subdir> [makefile]
    local dir=$1 mk=${2:-Makefile}
    echo "==> ${dir}  (-f ${mk})"
    cd "$SRC/$dir"
    make -f "$mk" clean >/dev/null 2>&1 || true
    make -f "$mk" -j"$JOBS" CXX="$CXX_FIX" CC="$CC_FIX"
    make -f "$mk" install   CXX="$CXX_FIX" CC="$CC_FIX"
    make -f "$mk" clean >/dev/null 2>&1 || true
}

# Some subprojects' install targets do not write to $DEST:
#   NXDNParrot has no install target at all (upstream's build-all.sh does not
#   call one either), and MMDVMHost's STOCK Makefile installs to /usr/local/bin
#   while its Makefile.WPSD installs to $HOME/dev/WPSD-Binaries. Place those by
#   hand so both makefile paths land in the same place.
build_noinstall() {                     # build_noinstall <subdir> <makefile> <bin>...
    local dir=$1 mk=$2; shift 2
    echo "==> ${dir}  (-f ${mk}, manual install)"
    cd "$SRC/$dir"
    make -f "$mk" clean >/dev/null 2>&1 || true
    make -f "$mk" -j"$JOBS" CXX="$CXX_FIX" CC="$CC_FIX"
    install -m 755 "$@" "$DEST/"
    make -f "$mk" clean >/dev/null 2>&1 || true
}

# --- build, in upstream's order ---------------------------------------------
build APRSGateway
if [[ -n $MMDVM_EXTRA_CFLAGS ]]; then
    # The stock Makefile omits the resampler; MMDVMHost's Conf.cpp needs
    # -DHAS_SRC for the [Modem] resampler options the WPSD config files set.
    cd "$SRC/MMDVMHost"
    sed -i "s|^CFLAGS  = |CFLAGS  = ${MMDVM_EXTRA_CFLAGS} |" "$MMDVM_MAKEFILE"
    sed -i "s|^LIBS    = |LIBS    = -lsamplerate |" "$MMDVM_MAKEFILE"
fi
build_noinstall MMDVMHost "$MMDVM_MAKEFILE" MMDVMHost RemoteCommand
build DAPNETGateway
build DMRGateway Makefile.WPSD
build AMBEServer
build ircDDBGateway
build MMDVMCal
build MMDVM_CM/DMR2YSF
build MMDVM_CM/DMR2NXDN
build MMDVM_CM/YSF2DMR
build MMDVM_CM/YSF2P25
build MMDVM_CM/YSF2NXDN
build NXDNClients/NXDNGateway
build_noinstall NXDNClients/NXDNParrot Makefile NXDNParrot
build P25Clients/P25Gateway
build P25Clients/P25Parrot
build YSFClients/YSFGateway
build YSFClients/DGIdGateway
build YSFClients/YSFParrot
build NextionDriver
build teensy_loader_cli

# --- collect ----------------------------------------------------------------
cd "$DEST"
strip --strip-unneeded ./* 2>/dev/null || true
cp -a ./* "$OUT/"

# The display libraries have to travel with the binaries that link them.
#
# Copying by glob does not work: WiringPi's ./build puts the real .so.3.20 files
# in /usr/local/lib and leaves ABSOLUTE symlinks in /usr/lib, so a glob over
# /usr/lib matches only the links and silently ships no library at all. Resolve
# the real file wherever it landed, then rebuild the SONAME and development links
# as RELATIVE symlinks so they stay valid in the runtime image.
if [[ $ARCH == arm64 || $ARCH == armhf || $ARCH == arm ]]; then
    mkdir -p /out/usr/local/lib
    for stem in libwiringPi libwiringPiDev libArduiPi_OLED; do
        real=$(find /usr/lib /usr/local/lib -maxdepth 1 -name "${stem}.so*" -type f -print -quit)
        if [[ -z $real ]]; then
            echo "ERROR: ${stem} was not built -- MMDVMHost would fail to load" >&2
            exit 1
        fi
        base=$(basename "$real")
        install -m 755 "$real" "/out/usr/local/lib/$base"
        soname=$(readelf -d "$real" | sed -n 's/.*SONAME.*\[\(.*\)\]/\1/p')
        [[ -n $soname && $soname != "$base" ]] && ln -sfn "$base" "/out/usr/local/lib/$soname"
        ln -sfn "$base" "/out/usr/local/lib/${stem}.so"
        echo "    ${stem}: ${base} (soname ${soname:-none})"
    done

    # WiringPi's `gpio` CLI: wpsd-modemreset and wpsd-modemupgrade strobe the
    # modem reset line with it, and wpsd-modemupgrade calls it by the absolute
    # path /usr/bin/gpio. Ships setuid on the appliance for the same reason.
    if [[ -x /usr/local/bin/gpio ]]; then
        install -m 4755 /usr/local/bin/gpio /out/usr/local/bin/gpio
        echo "    gpio CLI: installed"
    fi
fi

# Assert the set WPSD's service wrappers and dashboard actually invoke. Without
# this, a subproject whose install target writes somewhere unexpected -- which is
# exactly how MMDVMHost behaved on the stock Makefile path -- is a silently
# incomplete image rather than a failed build.
REQUIRED="MMDVMHost RemoteCommand DMRGateway ircddbgatewayd timeserverd
          timercontrold starnetserverd YSFGateway DGIdGateway YSFParrot
          NXDNGateway NXDNParrot P25Gateway P25Parrot DAPNETGateway APRSGateway
          YSF2DMR YSF2P25 YSF2NXDN DMR2YSF DMR2NXDN NextionDriver MMDVMCal
          AMBEserver teensy_loader_cli"
missing=""
for b in $REQUIRED; do
    [[ -x $OUT/$b ]] || missing="$missing $b"
done
if [[ -n $missing ]]; then
    echo "ERROR: these binaries were not collected into ${OUT}:${missing}" >&2
    echo "       present:" >&2
    ls -1 "$OUT" | sed 's/^/         /' >&2
    exit 1
fi

echo "==> built $(find "$OUT" -maxdepth 1 -type f -executable | wc -l) executables"
"$OUT/MMDVMHost" -v
