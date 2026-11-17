#!/usr/bin/env bash
# Fetches the embedded runtime's assets at build time (docs/design/runtime.md) and checks
# them against pinned SHA-256 digests. Users never download these: they ship in the app.
#
#   kernel   vmlinux pratico builds from kernel.org's source (GPL-2.0) with
#            scripts/build-kernel.sh, checked against vm/kernel/vmlinux.sha256; built
#            once (about half an hour), then cached in .cache/kernel.
#   vminit   init image pratico builds from apple/containerization's vminitd source
#            (Apache-2.0, Vendor/containerization) with scripts/build-init.sh, checked
#            against vm/init/vminit.sha256; an OCI layout, cached in .cache/init.
#
# Usage: scripts/fetch-runtime-assets.sh <out-dir>     (or: make assets)
# Once built, both are reused from .cache, so later builds are offline.
set -euo pipefail

OUT="${1:?usage: scripts/fetch-runtime-assets.sh <out-dir>}"

sha() { shasum -a 256 "$1" | cut -d' ' -f1; }
verify() {  # file, expected digest
    local got
    got=$(sha "$1")
    [ "$got" = "$2" ] || { echo "checksum mismatch for $1: want $2 got $got" >&2; exit 1; }
}

mkdir -p "$OUT"

# --- Kernel ------------------------------------------------------------------
KERNEL_SHA256=$(cut -d' ' -f1 vm/kernel/vmlinux.sha256)
built=.cache/kernel/out
if [ ! -f "$built/vmlinux" ] || [ "$(sha "$built/vmlinux")" != "$KERNEL_SHA256" ]; then
    scripts/build-kernel.sh "$built"
fi
verify "$built/vmlinux" "$KERNEL_SHA256"
cp "$built/vmlinux" "$OUT/vmlinux"
cp "$built/config" "$OUT/kernel-config"

# --- vminit OCI layout ----------------------------------------------------------
INIT_SHA256=$(cut -d' ' -f1 vm/init/vminit.sha256)
init=.cache/init/out
manifest() { sed -n 's/.*"digest":"sha256:\([0-9a-f]*\)".*/\1/p' "$init/vminit/index.json" 2>/dev/null; }
if [ "$(manifest)" != "$INIT_SHA256" ]; then
    scripts/build-init.sh "$init"
fi
verify "$init/vminit/blobs/sha256/$INIT_SHA256" "$INIT_SHA256"
rm -rf "$OUT/vminit"
cp -R "$init/vminit" "$OUT/vminit"
echo "runtime assets in $OUT: kernel $(sed -n 's/^KERNEL_VERSION=//p' scripts/build-kernel.sh), vminit $(sed -n 's/.*"io.containerd.image.name":"\([^"]*\)".*/\1/p' "$OUT/vminit/index.json")"
