#!/usr/bin/env bash
#
# Build wpsd-docker from scratch, and optionally test, export or publish it.
#
#   scripts/build.sh                                  build for this machine
#   scripts/build.sh --test                            build, then run the smoke test
#   scripts/build.sh --export wpsd.tar.gz              build + a portable tarball
#   scripts/build.sh --platform linux/amd64,linux/arm64 --export wpsd-oci.tar
#   scripts/build.sh --tag jasiek/wpsd:latest --platform linux/amd64,linux/arm64 --push
#
# Everything WPSD comes from W0CHP's own servers at build time -- nothing is
# vendored -- so this needs network access. Budget ten minutes for the native
# path and about twenty per emulated architecture.
#
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO"

TAGS=()
PLATFORM=""
EXPORT=""
PUSH=0
RUN_TEST=0
NO_CACHE=""
EXTRA=()
MULTIARCH_BUILDER=wpsd-multiarch

die()  { echo "error: $*" >&2; exit 1; }
step() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }

while [[ $# -gt 0 ]]; do
    case $1 in
        -t|--tag)       TAGS+=("${2:?}"); shift 2 ;;
        -p|--platform)  PLATFORM=${2:?}; shift 2 ;;
        -e|--export)    EXPORT=${2:?}; shift 2 ;;
        --push)         PUSH=1; shift ;;
        --test)         RUN_TEST=1; shift ;;
        --no-cache)     NO_CACHE=--no-cache; shift ;;
        --ref)          EXTRA+=(--build-arg "WPSD_SCRIPTS_REF=${2:?}"
                                --build-arg "WPSD_WEB_REF=${2}"); shift 2 ;;
        --src-branch)   EXTRA+=(--build-arg "WPSD_SRC_BRANCH=${2:?}"); shift 2 ;;
        -h|--help)      sed -n '3,14p' "${BASH_SOURCE[0]}" | sed 's/^#\s\?//'; exit 0 ;;
        *)              die "unknown option: $1  (try --help)" ;;
    esac
done

[[ ${#TAGS[@]} -eq 0 ]] && TAGS=(wpsd:local)
PRIMARY_TAG=${TAGS[0]}

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

[[ $PUSH -eq 1 && -n $EXPORT ]] && die "--push and --export are mutually exclusive"
if [[ $PUSH -eq 1 ]]; then
    for t in "${TAGS[@]}"; do
        [[ $t == */* ]] || die "--push needs a namespaced tag, e.g. --tag user/wpsd:latest (got '$t')"
    done
fi

TAG_ARGS=()
for t in "${TAGS[@]}"; do TAG_ARGS+=(--tag "$t"); done

# The default "docker" buildx driver supports neither multi-platform results nor
# the OCI exporter, so those need a docker-container builder. It persists and
# keeps its own build cache for later runs.
# NB: every optional array below is expanded as ${arr[@]+"${arr[@]}"}. bash 3.2,
# which is what macOS ships, treats "${arr[@]}" on an EMPTY array as an unset
# variable under `set -u` and aborts. The guard form is the portable spelling.
BUILDER_ARGS=()
if [[ $MULTI -eq 1 || ( -n $EXPORT && $MULTI -eq 1 ) ]]; then
    if ! docker buildx inspect "$MULTIARCH_BUILDER" >/dev/null 2>&1; then
        step "creating buildx builder '$MULTIARCH_BUILDER' (docker-container driver)"
        docker buildx create --name "$MULTIARCH_BUILDER" --driver docker-container --bootstrap >/dev/null
    fi
    BUILDER_ARGS=(--builder "$MULTIARCH_BUILDER")
fi

# What to do with the result.
OUTPUT_ARGS=()
if [[ $PUSH -eq 1 ]]; then
    OUTPUT_ARGS=(--push)
elif [[ $MULTI -eq 1 ]]; then
    # A multi-platform result cannot go into the classic docker image store, so
    # write an OCI archive -- which is what "one exportable file" means anyway.
    [[ -n $EXPORT ]] || die "--platform with several architectures needs --export FILE or --push"
    OUTPUT_ARGS=(--output "type=oci,dest=$EXPORT")
else
    OUTPUT_ARGS=(--load)
fi

step "building ${TAGS[*]} for $PLATFORM"
if [[ $MULTI -eq 1 || $PLATFORM != "$HOST_PLATFORM" ]]; then
    cat <<'NOTE'
    Note: at least one target is not this host's architecture, so the ~20 C++
    projects compile under QEMU emulation. Expect it to take a while.
NOTE
fi

docker buildx build ${BUILDER_ARGS[@]+"${BUILDER_ARGS[@]}"} $NO_CACHE ${EXTRA[@]+"${EXTRA[@]}"} \
    --platform "$PLATFORM" \
    "${TAG_ARGS[@]}" \
    "${OUTPUT_ARGS[@]}" \
    .

if [[ $PUSH -eq 1 ]]; then
    step "pushed"
    for t in "${TAGS[@]}"; do
        echo "    $t"
        docker buildx imagetools inspect "$t" 2>/dev/null \
            | grep -E '^ +(Name|MediaType|Platform):' | sed 's/^/      /' || true
    done
    step "done"
    exit 0
fi

if [[ $MULTI -eq 1 ]]; then
    step "wrote OCI archive: $EXPORT ($(du -h "$EXPORT" | cut -f1))"
    echo "    load it with:  docker load -i $EXPORT"
    echo "    (needs Docker's containerd image store for a multi-arch archive)"
    step "done"
    exit 0
fi

step "built $PRIMARY_TAG  ($(docker image inspect "$PRIMARY_TAG" --format '{{.Os}}/{{.Architecture}}'), $(docker image inspect "$PRIMARY_TAG" --format '{{.Size}}' | awk '{printf "%.0f MB", $1/1024/1024}'))"
docker run --rm --entrypoint /usr/local/bin/MMDVMHost "$PRIMARY_TAG" -v

if [[ -n $EXPORT ]]; then
    step "exporting to $EXPORT"
    case $EXPORT in
        *.gz)  docker save "$PRIMARY_TAG" | gzip -1 > "$EXPORT" ;;
        *)     docker save "$PRIMARY_TAG" -o "$EXPORT" ;;
    esac
    echo "    $EXPORT ($(du -h "$EXPORT" | cut -f1))"
    echo "    load it with:  docker load -i $EXPORT"
fi

if [[ $RUN_TEST -eq 1 ]]; then
    step "running the smoke test"
    name=wpsd-buildtest
    docker rm -f "$name" >/dev/null 2>&1 || true
    docker run -d --name "$name" --cap-add SYS_NICE -p 18080:80 "$PRIMARY_TAG" >/dev/null
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
    docker run -d --name wpsd -p 8080:80 --cap-add SYS_NICE $PRIMARY_TAG
  or, with config and logs in volumes:
    docker compose up -d

Then open http://localhost:8080/  (admin: pi-star / raspberry -- change it)
EOF
