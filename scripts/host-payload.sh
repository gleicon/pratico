#!/usr/bin/env bash
# Assembles what a Linux host runs (docs/design/remote.md): pratico-daemon and pratico-shim
# (static, scripts/linux-check.sh host), Cloud Hypervisor's static release binary checked
# against the digest GitHub records for it, virtiofsd (scripts/build-virtiofsd.sh), the
# kernel and init, and THIRD_PARTY_NOTICES. The test host runs it; the release tars it.
#
#   [KARCH=x86_64] scripts/host-payload.sh <out-dir>
set -euo pipefail

CH_VERSION=v55.0
KARCH="${KARCH:-arm64}"
case "$KARCH" in
arm64) ch_asset=cloud-hypervisor-static-aarch64 CH_SHA256=446de7552dacc83bc86d1137e7ffa7c2d204cdda4850eac4f2d2666d63c0f697 sfx="" ;;
x86_64) ch_asset=cloud-hypervisor-static CH_SHA256=ce7133bf535ed5a4e2a63ea1f26025445a5b1241f73ddfb81ff2fbcb2e803a59 sfx="-x86_64" ;;
*) echo "host-payload: KARCH is arm64 or x86_64" >&2; exit 2 ;;
esac
export KARCH
CH_URL="https://github.com/cloud-hypervisor/cloud-hypervisor/releases/download/$CH_VERSION/$ch_asset"

OUT="$(mkdir -p "${1:?usage: [KARCH=x86_64] scripts/host-payload.sh <out-dir>}" && cd "$1" && pwd)"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ASSETS="${PRATICO_RUNTIME_ASSETS:-$ROOT/.build/runtime-assets$sfx}"
CACHE="$ROOT/.cache/host$sfx"
[ -f "$ASSETS/vmlinux" ] || { echo "host-payload: runtime assets missing in $ASSETS: run KARCH=$KARCH scripts/fetch-runtime-assets.sh $ASSETS" >&2; exit 1; }
mkdir -p "$CACHE" "$OUT/runtime"

ch="$CACHE/$ch_asset-$CH_VERSION"
if [ ! -f "$ch" ]; then
    curl -fsSL --retry 3 -o "$ch.part" "$CH_URL" && mv "$ch.part" "$ch"
fi
[ "$(shasum -a 256 "$ch" | cut -d' ' -f1)" = "$CH_SHA256" ] || { echo "host-payload: $ch does not match its SHA-256" >&2; exit 1; }
install -m 755 "$ch" "$OUT/cloud-hypervisor"

"$ROOT/scripts/build-virtiofsd.sh" "$CACHE/virtiofsd" >&2
install -m 755 "$CACHE/virtiofsd/virtiofsd" "$OUT/virtiofsd"

"$ROOT/scripts/linux-check.sh" host "$OUT" >&2

# As installed: the layout alone, never an ingest/ a daemon left in a development copy.
cp "$ASSETS/vmlinux" "$ASSETS/kernel-config" "$OUT/runtime/"
rm -rf "$OUT/runtime/vminit" && cp -R "$ASSETS/vminit" "$OUT/runtime/" && rm -rf "$OUT/runtime/vminit/ingest"

(cd "$ROOT" && VIRTIOFSD_LINKED="$CACHE/virtiofsd/virtiofsd.linked" scripts/acknowledgements.sh "$OUT/THIRD_PARTY_NOTICES" linux)
echo "host-payload: $OUT"
