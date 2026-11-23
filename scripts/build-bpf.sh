#!/bin/bash
# Builds the guest's BPF probes (vm/bpf) in a pratico VM (maintainer tooling, not part of
# the app), against the types of the kernel scripts/build-kernel.sh built: its vmlinux.btf,
# checked by the kernel's pinned hash. The build image is pinned by digest and its
# packages by a Debian snapshot date. The result must match vm/bpf/recorder.sha256;
# UPDATE=1 records a new one, REPRO=1 builds twice and compares.
#
#   scripts/build-bpf.sh <kernel-out-dir> <out-dir>   # writes <out-dir>/recorder.bpf.o
set -euo pipefail

BUILD_IMAGE=debian@sha256:9c6e381421d0f48d1b8133e573f33c185ee16cbf505eda9c4a8a4791b25ea8a6  # trixie 13.7
APT_SNAPSHOT=20261115T000000Z

KERNEL="${1:?usage: scripts/build-bpf.sh <kernel-out-dir> <out-dir>}"
OUT="${2:?usage: scripts/build-bpf.sh <kernel-out-dir> <out-dir>}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CACHE="$ROOT/.cache/bpf"
KARCH="${KARCH:-arm64}"  # x86_64: probes for the x86_64 kernel (its own types)
case "$KARCH" in arm64) sfx="" ;; x86_64) sfx="-x86_64" ;; *) echo "bpf: KARCH is arm64 or x86_64" >&2; exit 2 ;; esac
LOCK="$ROOT/vm/bpf/recorder$sfx.sha256"
export DOCKER_HOST="${DOCKER_HOST:-unix://$HOME/.pratico/docker.sock}"
mkdir -p "$CACHE/in" "$OUT"

verify() {  # file, expected digest
    [ "$(shasum -a 256 "$1" | cut -d' ' -f1)" = "$2" ] || { echo "bpf: $1 does not match its SHA-256" >&2; return 1; }
}

# The types must be the shipped kernel's: its BTF came out of the same build as vmlinux.
verify "$KERNEL/vmlinux" "$(cut -d' ' -f1 "$ROOT/vm/kernel/vmlinux$sfx.sha256")"
[ -s "$KERNEL/vmlinux.btf" ] || { echo "bpf: $KERNEL/vmlinux.btf is missing: run scripts/build-kernel.sh" >&2; exit 1; }
cp "$KERNEL/vmlinux.btf" "$ROOT/vm/bpf/recorder.bpf.c" "$ROOT/vm/bpf/recorder.h" "$ROOT/vm/bpf/build.sh" "$ROOT/vm/snapshot.sh" "$CACHE/in/"

build() {  # out-dir
    mkdir -p "$1"
    docker run --rm -e APT_SNAPSHOT="$APT_SNAPSHOT" -v "$CACHE/in:/in:ro" -v "$1:/out" "$BUILD_IMAGE" /in/build.sh
}

build "$OUT"
sum=$(shasum -a 256 "$OUT/recorder.bpf.o" | cut -d' ' -f1)
if [ "${REPRO:-0}" = 1 ]; then
    build "$CACHE/again$sfx"
    verify "$CACHE/again$sfx/recorder.bpf.o" "$sum" || { echo "bpf: two builds differ: not reproducible" >&2; exit 1; }
    echo "bpf: two builds match"
fi
if [ "${UPDATE:-0}" = 1 ]; then
    echo "$sum  recorder.bpf.o  # vm/bpf, against vm/kernel/vmlinux$sfx.sha256's kernel" > "$LOCK"
    echo "bpf: recorded $sum"
elif [ -f "$LOCK" ]; then
    verify "$OUT/recorder.bpf.o" "$(cut -d' ' -f1 "$LOCK")"
fi
echo "bpf: $OUT/recorder.bpf.o $sum"
