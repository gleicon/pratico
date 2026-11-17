#!/usr/bin/env bash
# Fetches the embedded runtime's assets at build time (docs/design/runtime.md) and checks
# them against pinned SHA-256 digests. Users never download these: they ship in the app.
#
#   kernel   vmlinux pratico builds from kernel.org's source (GPL-2.0) with
#            scripts/build-kernel.sh, checked against vm/kernel/vmlinux.sha256; built
#            once (about half an hour), then cached in .cache/kernel.
#   vminit   linux/arm64 image of apple/containerization's vminitd (Apache-2.0), as an
#            OCI layout directory.
#
# Usage: scripts/fetch-runtime-assets.sh <out-dir>     (or: make assets)
# Downloads are cached in .cache/assets, so later builds are offline.
set -euo pipefail

OUT="${1:?usage: scripts/fetch-runtime-assets.sh <out-dir>}"
CACHE="${PRATICO_ASSET_CACHE:-.cache/assets}"

KERNEL_SHA256=dece388830720fe8bddb41552fff5f486240aeece5acc0aebc1812761e3e3f66

VMINIT_REPO=apple/containerization/vminit
VMINIT_TAG=0.54.0
VMINIT_MANIFEST_SHA256=9a96afedb91d48be2b089c97664045acd8832fbe6ccac336876fa93ff58cd7fe  # linux/arm64 image manifest

sha() { shasum -a 256 "$1" | cut -d' ' -f1; }
verify() {  # file, expected digest
    local got
    got=$(sha "$1")
    [ "$got" = "$2" ] || { echo "checksum mismatch for $1: want $2 got $got" >&2; exit 1; }
}

mkdir -p "$CACHE" "$OUT"

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
layout="$CACHE/vminit-$VMINIT_TAG"
if [ ! -f "$layout/index.json" ]; then
    rm -rf "$layout.part" && mkdir -p "$layout.part/blobs/sha256"
    token=$(curl -fsS "https://ghcr.io/token?scope=repository:$VMINIT_REPO:pull" | sed -n 's/.*"token":"\([^"]*\)".*/\1/p')
    get() {  # digest-or-tag, accept header, output file
        curl -fsSL -H "Authorization: Bearer $token" -H "Accept: $2" -o "$3" "https://ghcr.io/v2/$VMINIT_REPO/${4:-manifests}/$1"
    }
    blob() {  # digest → layout blob, verified
        local d="${1#sha256:}" f="$layout.part/blobs/sha256/${1#sha256:}"
        get "$1" "*/*" "$f" blobs
        verify "$f" "$d"
    }
    manifest="$layout.part/blobs/sha256/$VMINIT_MANIFEST_SHA256"
    get "sha256:$VMINIT_MANIFEST_SHA256" "application/vnd.oci.image.manifest.v1+json" "$manifest"
    verify "$manifest" "$VMINIT_MANIFEST_SHA256"
    for d in $(grep -oE 'sha256:[0-9a-f]{64}' "$manifest" | sort -u); do blob "$d"; done
    size=$(wc -c <"$manifest" | tr -d ' ')
    printf '{"imageLayoutVersion":"1.0.0"}' >"$layout.part/oci-layout"
    cat >"$layout.part/index.json" <<EOF
{"schemaVersion":2,"manifests":[{"mediaType":"application/vnd.oci.image.manifest.v1+json","digest":"sha256:$VMINIT_MANIFEST_SHA256","size":$size,"platform":{"architecture":"arm64","os":"linux"},"annotations":{"org.opencontainers.image.ref.name":"$VMINIT_TAG","io.containerd.image.name":"ghcr.io/$VMINIT_REPO:$VMINIT_TAG"}}]}
EOF
    mv "$layout.part" "$layout"
fi
rm -rf "$OUT/vminit"
cp -R "$layout" "$OUT/vminit"
echo "runtime assets in $OUT: kernel $(sed -n 's/^KERNEL_VERSION=//p' scripts/build-kernel.sh), vminit $VMINIT_TAG"
