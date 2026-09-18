#!/usr/bin/env bash
#
# Build wpsd-docker from scratch, and optionally export it as a single file.
#
#   scripts/build.sh                          # build for this machine
#   scripts/build.sh --test                   # build, then run the smoke test
#   scripts/build.sh --export wpsd.tar.gz     # build + save a portable tarball
#   scripts/build.sh --platform linux/amd64,linux/arm64 --export wpsd-oci.tar
#
# Everything WPSD comes from W0CHP's own servers at build time -- nothing is
# vendored -- so this needs network access and takes roughly ten minutes for the
# native path (about twenty per emulated architecture).
#
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO"

TAG=wpsd:local
PLATFORM=""
EXPORT=""
RUN_TEST=0
NO_CACHE=""
EXTRA=()

die()  { echo "error: $*" >&2; exit 1; }
step() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }

while [[ $# -gt 0 ]]; do
    case $1 in
        -t|--tag)       TAG=${2:?} ; shift 2 ;;
        -p|--platform)  PLATFORM=${2:?}; shift 2 ;;
        -e|--export)    EXPORT=${2:?}; shift 2 ;;
        --test)         RUN_TEST=1; shift ;;
        --no-cache)     NO_CACHE=--no-cache; shift ;;
        --ref)          EXTRA+=(--build-arg "WPSD_SCRIPTS_REF=${2:?}"
                                --build-arg "WPSD_WEB_REF=${2}"); shift 2 ;;
        --src-branch)   EXTRA+=(--build-arg "WPSD_SRC_BRANCH=${2:?}"); shift 2 ;;
        -h|--help)      sed -n '3,12p' "${BASH_SOURCE[0]}" | sed 's/^#\s\?//'; exit 0 ;;
        *)              die "unknown option: $1  (try --help)" ;;
    esac
done

command -v docker >/dev/null || die "docker not found"
docker info >/dev/null 2>&1   || die "cannot talk to the docker daemon"

HOST_ARCH=$(docker info --format '{{.Architecture}}' 2>/dev/null)
case $HOST_ARCH in
    aarch64|arm64) HOST_PLATFORM=linux/arm64 ;;
    x86_64|amd64)  HOST_PLATFORM=linux/amd64 ;;
    *)             HOST_PLATFORM="" ;;
esac
[[ -z $PLATFORM ]] && PLATFORM=${HOST_PLATFORM:-linux/amd64}

MULTI=0
[[ $PLATFORM == *,* ]] && MULTI=1

step "building $TAG for $PLATFORM"
[[ $MULTI -eq 1 || $PLATFORM != "$HOST_PLATFORM" ]] && cat <<'NOTE'
    Note: this is not the host's native architecture, so the ~20 C++ projects
    compile under QEMU emulation. Expect it to take a while.
NOTE

if [[ $MULTI -eq 1 ]]; then
    # A multi-platform result cannot go into the classic docker image store, so
    # write an OCI archive instead -- which is exactly what you want for a
    # portable single file. Load it elsewhere with `docker load -i <file>`
    # (needs the containerd image store) or push it to a registry.
    [[ -n $EXPORT ]] || die "--platform with several architectures needs --export FILE (an OCI archive)"
    docker buildx build $NO_CACHE ${EXTRA[@]+"${EXTRA[@]}"} \
        --platform "$PLATFORM" \
        --tag "$TAG" \
        --output "type=oci,dest=$EXPORT" \
        .
    step "wrote OCI archive: $EXPORT ($(du -h "$EXPORT" | cut -f1))"
    echo "    load it with:  docker load -i $EXPORT"
    exit 0
fi

docker buildx build $NO_CACHE ${EXTRA[@]+"${EXTRA[@]}"} \
    --platform "$PLATFORM" \
    --tag "$TAG" \
    --load \
    .

step "built $TAG  ($(docker image inspect "$TAG" --format '{{.Os}}/{{.Architecture}}'), $(docker image inspect "$TAG" --format '{{.Size}}' | awk '{printf "%.0f MB", $1/1024/1024}'))"
docker run --rm --entrypoint /usr/local/bin/MMDVMHost "$TAG" -v

if [[ -n $EXPORT ]]; then
    step "exporting to $EXPORT"
    case $EXPORT in
        *.gz)  docker save "$TAG" | gzip -1 > "$EXPORT" ;;
        *)     docker save "$TAG" -o "$EXPORT" ;;
    esac
    echo "    $EXPORT ($(du -h "$EXPORT" | cut -f1))"
    echo "    load it with:  docker load -i $EXPORT"
fi

if [[ $RUN_TEST -eq 1 ]]; then
    step "running the smoke test"
    # The suite drives a container named by $CONTAINER; use a throwaway one so a
    # running deployment is left alone.
    name=wpsd-buildtest
    docker rm -f "$name" >/dev/null 2>&1 || true
    docker run -d --name "$name" --cap-add SYS_NICE -p 18080:80 "$TAG" >/dev/null
    trap 'docker rm -f '"$name"' >/dev/null 2>&1 || true' EXIT
    for _ in $(seq 1 40); do
        curl -fsS -o /dev/null http://localhost:18080/ 2>/dev/null && break
        sleep 5
    done
    CONTAINER=$name URL=http://localhost:18080 ./tests/smoke.sh
fi

step "done"
cat <<EOF

Run it:
    docker run -d --name wpsd -p 8080:80 --cap-add SYS_NICE $TAG
  or, with config and logs in volumes:
    docker compose up -d

Then open http://localhost:8080/  (admin: pi-star / raspberry -- change it)
EOF
