#!/usr/bin/env bash
# Builds virtiofsd (Apache-2.0 / BSD-3-Clause), which serves volumes and bind mounts to
# Cloud Hypervisor VMs on Linux hosts (docs/design/remote.md), as one static binary (musl,
# libseccomp and libcap-ng linked in), in a pratico VM. Inputs are pinned: the crate by the
# SHA-256 crates.io's index records, its dependencies by its Cargo.lock, the build image by
# digest. virtiofsd publishes no aarch64 binaries, so pratico builds its own.
#
#   scripts/build-virtiofsd.sh <out-dir>   # writes <out-dir>/virtiofsd
set -euo pipefail

VIRTIOFSD_VERSION=1.15.0
VIRTIOFSD_SHA256=aeac41b813d490bb11941595b0ba09e49b8884dbe0d47f5df2fd891c8e0ecace  # index.crates.io/vi/rt/virtiofsd
VIRTIOFSD_URL="https://static.crates.io/crates/virtiofsd/virtiofsd-$VIRTIOFSD_VERSION.crate"
BUILD_IMAGE=rust@sha256:8d0e82abfdf9a38071e07cabc5afba4ddbe077631a80e4e742a760c38beadc33  # 1.100.0, alpine 3.24

OUT="$(mkdir -p "${1:?usage: scripts/build-virtiofsd.sh <out-dir>}" && cd "$1" && pwd)"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CACHE="$ROOT/.cache/virtiofsd"
export DOCKER_HOST="${DOCKER_HOST:-unix://$HOME/.pratico/docker.sock}"
mkdir -p "$CACHE/in"

if [ -x "$OUT/virtiofsd" ] && [ "$(cat "$OUT/virtiofsd.version" 2>/dev/null)" = "$VIRTIOFSD_VERSION" ]; then
    echo "virtiofsd: $OUT/virtiofsd $VIRTIOFSD_VERSION, built already"
    exit 0
fi
crate="$CACHE/virtiofsd-$VIRTIOFSD_VERSION.crate"
if [ ! -f "$crate" ]; then
    curl -fsSL --retry 3 -o "$crate.part" "$VIRTIOFSD_URL"
    mv "$crate.part" "$crate"
fi
[ "$(shasum -a 256 "$crate" | cut -d' ' -f1)" = "$VIRTIOFSD_SHA256" ] || { echo "virtiofsd: $crate does not match its SHA-256" >&2; exit 1; }
ln -f "$crate" "$CACHE/in/virtiofsd.crate"

docker volume create pratico-virtiofsd-build >/dev/null
docker run --rm --cpus "${CPUS:-8}" --memory "${MEMORY:-8g}" \
    -v "$CACHE/in:/in:ro" -v "$OUT:/out" -v pratico-virtiofsd-build:/build "$BUILD_IMAGE" sh -euc '
        apk add -q --no-cache musl-dev libseccomp-static libcap-ng-static
        rm -rf /build/src && mkdir -p /build/src
        tar -xzf /in/virtiofsd.crate -C /build/src --strip-components=1
        cd /build/src
        # As virtiofsd builds its own static release: the -sys crates link static libraries
        # only when asked.
        export LIBSECCOMP_LINK_TYPE=static LIBSECCOMP_LIB_PATH=/usr/lib LIBCAPNG_LINK_TYPE=static LIBCAPNG_LIB_PATH=/usr/lib
        CARGO_HOME=/build/cargo RUSTFLAGS="-C target-feature=+crt-static" cargo build -q --release --locked --target aarch64-unknown-linux-musl
        install -m 755 target/aarch64-unknown-linux-musl/release/virtiofsd /out/virtiofsd
        apk list -I libseccomp-static libcap-ng-static 2>/dev/null | cut -d" " -f1 | sed "s/^/virtiofsd: linked /"'
file "$OUT/virtiofsd" 2>/dev/null | grep -q "statically linked" || { echo "virtiofsd: $OUT/virtiofsd is not static" >&2; exit 1; }
echo "$VIRTIOFSD_VERSION" >"$OUT/virtiofsd.version"
echo "virtiofsd: $OUT/virtiofsd $VIRTIOFSD_VERSION $(shasum -a 256 "$OUT/virtiofsd" | cut -d' ' -f1)"
