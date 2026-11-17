#!/bin/bash
# Builds pratico's guest kernel in a pratico VM (maintainer tooling, not part of the
# app). Inputs are pinned: the kernel.org tarball by SHA-256, the build image by digest,
# its packages by a Debian snapshot date. The result must match vm/kernel/vmlinux.sha256;
# UPDATE=1 records a new one (a new kernel or config), REPRO=1 builds twice and compares.
#
#   scripts/build-kernel.sh <out-dir>   # writes <out-dir>/vmlinux and <out-dir>/config
set -euo pipefail

KERNEL_VERSION=6.18.63
KERNEL_SHA256=81764a545072d160748beff4d9de2e7d95aa9f16e8261110288f067a2cc61d71  # kernel.org sha256sums.asc
KERNEL_URL="https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-$KERNEL_VERSION.tar.xz"
KERNEL_DATE="2026-11-10 00:00:00 UTC"  # its release date, as the build's timestamp
BUILD_IMAGE=debian@sha256:9c6e381421d0f48d1b8133e573f33c185ee16cbf505eda9c4a8a4791b25ea8a6  # trixie 13.7
APT_SNAPSHOT=20261115T000000Z

OUT="${1:?usage: scripts/build-kernel.sh <out-dir>}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CACHE="$ROOT/.cache/kernel"
LOCK="$ROOT/vm/kernel/vmlinux.sha256"
export DOCKER_HOST="${DOCKER_HOST:-unix://$HOME/.pratico/docker.sock}"
mkdir -p "$CACHE/in" "$OUT"

verify() {  # file, expected digest
    [ "$(shasum -a 256 "$1" | cut -d' ' -f1)" = "$2" ] || { echo "kernel: $1 does not match its SHA-256" >&2; return 1; }
}

tarball="$CACHE/linux-$KERNEL_VERSION.tar.xz"
if [ ! -f "$tarball" ]; then
    curl -fL --retry 3 -o "$tarball.part" "$KERNEL_URL"
    mv "$tarball.part" "$tarball"
fi
verify "$tarball" "$KERNEL_SHA256"
ln -f "$tarball" "$CACHE/in/linux.tar.xz"
cp "$ROOT/Vendor/containerization/kernel/config-arm64" "$ROOT/vm/kernel/config-pratico" "$ROOT/vm/kernel/build.sh" "$CACHE/in/"

build() {  # out-dir
    mkdir -p "$1"
    docker volume create pratico-kernel-build >/dev/null
    docker run --rm --cpus "${CPUS:-8}" --memory "${MEMORY:-8g}" \
        -e APT_SNAPSHOT="$APT_SNAPSHOT" -e KBUILD_BUILD_TIMESTAMP="$KERNEL_DATE" \
        -v "$CACHE/in:/in:ro" -v "$1:/out" -v pratico-kernel-build:/kbuild \
        "$BUILD_IMAGE" /in/build.sh
}

build "$OUT"
sum=$(shasum -a 256 "$OUT/vmlinux" | cut -d' ' -f1)
if [ "${REPRO:-0}" = 1 ]; then
    build "$CACHE/again"
    verify "$CACHE/again/vmlinux" "$sum" || { echo "kernel: two builds differ: not reproducible" >&2; exit 1; }
    echo "kernel: two builds match"
fi
if [ "${UPDATE:-0}" = 1 ]; then
    echo "$sum  vmlinux  # Linux $KERNEL_VERSION, vm/kernel/config-pratico" > "$LOCK"
    echo "kernel: recorded $sum"
elif [ -f "$LOCK" ]; then
    verify "$OUT/vmlinux" "$(cut -d' ' -f1 "$LOCK")"
fi
echo "kernel: $OUT/vmlinux $sum"
