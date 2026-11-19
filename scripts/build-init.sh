#!/bin/bash
# Builds pratico's guest init (vminitd, vmexec) in a pratico VM from the vendored
# apple/containerization source (maintainer tooling, not part of the app). Inputs are
# pinned: the Swift image by digest, the static Linux SDK by SHA-256, the Swift
# packages by Package.resolved. The image's manifest digest must match
# vm/init/vminit.sha256; UPDATE=1 records a new one, REPRO=1 builds twice and compares.
#
#   scripts/build-init.sh <out-dir>   # writes <out-dir>/vminit, an OCI layout
set -euo pipefail

SWIFT_IMAGE=swift@sha256:1ba0416be43dc57ba6ff7d02114356cad1ab17364024b7669385e3fe41a224aa  # 6.3.3-noble
SDK_URL=https://download.swift.org/swift-6.3.3-release/static-sdk/swift-6.3.3-RELEASE/swift-6.3.3-RELEASE_static-linux-0.1.0.artifactbundle.tar.gz
SDK_SHA256=87c3eaf908e67c0e13a84367119e12273cec1d2cd3d81f7d74bb36722d6b607b  # swift.org release data
INIT_VERSION=0.54.0-pratico
IMAGE_REPO=dev.pratico/vminit  # not a registry: never pulled, loaded from the app; tagged by content
UPSTREAM_COMMIT=baf212e5a8e432e539beee325050aa26443a154d  # Vendor/README.md

OUT="${1:?usage: scripts/build-init.sh <out-dir>}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CACHE="$ROOT/.cache/init"
LOCK="$ROOT/vm/init/vminit.sha256"
export DOCKER_HOST="${DOCKER_HOST:-unix://$HOME/.pratico/docker.sock}"
mkdir -p "$CACHE/sdk" "$OUT"

sdk="$CACHE/sdk/static-sdk.artifactbundle.tar.gz"
if [ ! -f "$sdk" ]; then
    curl -fL --retry 3 -o "$sdk.part" "$SDK_URL"
    mv "$sdk.part" "$sdk"
fi
[ "$(shasum -a 256 "$sdk" | cut -d' ' -f1)" = "$SDK_SHA256" ] || { echo "init: $sdk does not match its SHA-256" >&2; exit 1; }

# The flight recorder's probes (scripts/build-bpf.sh), as pinned.
BPF="${BPF_DIR:-$ROOT/.cache/bpf/out}"
[ "$(shasum -a 256 "$BPF/recorder.bpf.o" 2>/dev/null | cut -d' ' -f1)" = "$(cut -d' ' -f1 "$ROOT/vm/bpf/recorder.sha256")" ] ||
    { echo "init: $BPF/recorder.bpf.o is missing or does not match vm/bpf/recorder.sha256: run scripts/build-bpf.sh" >&2; exit 1; }

build() {  # out-dir
    mkdir -p "$1"
    docker volume create pratico-init-build >/dev/null
    docker run --rm --cpus "${CPUS:-8}" --memory "${MEMORY:-8g}" --network bridge \
        -e SDK_SHA256="$SDK_SHA256" -e IMAGE_REPO="$IMAGE_REPO" -e INIT_VERSION="$INIT_VERSION" \
        -e BUILD_TIME="$INIT_VERSION" -e GIT_COMMIT="$UPSTREAM_COMMIT" \
        -v "$ROOT/Vendor/containerization:/src:ro" -v "$ROOT/vm/init:/in:ro" -v "$CACHE/sdk:/sdk:ro" -v "$BPF:/bpf:ro" -v "$1:/out" -v pratico-init-build:/build \
        "$SWIFT_IMAGE" /in/build.sh
}
digest() { sed -n 's/.*"digest":"sha256:\([0-9a-f]*\)".*/\1/p' "$1/vminit/index.json"; }

build "$OUT"
sum=$(digest "$OUT")
if [ "${REPRO:-0}" = 1 ]; then
    build "$CACHE/again"
    [ "$(digest "$CACHE/again")" = "$sum" ] || { echo "init: two builds differ: not reproducible" >&2; exit 1; }
    echo "init: two builds match"
fi
if [ "${UPDATE:-0}" = 1 ]; then
    echo "$sum  vminit manifest  # $IMAGE_REPO, Vendor/containerization/vminitd" > "$LOCK"
    echo "init: recorded $sum"
elif [ -f "$LOCK" ]; then
    [ "$sum" = "$(cut -d' ' -f1 "$LOCK")" ] || { echo "init: manifest sha256:$sum does not match $LOCK" >&2; exit 1; }
fi
echo "init: $OUT/vminit sha256:$sum"
