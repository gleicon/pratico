#!/usr/bin/env bash
# Builds virtiofsd (Apache-2.0 / BSD-3-Clause), which serves volumes and bind mounts to
# Cloud Hypervisor VMs on Linux hosts (docs/design/remote.md), as one static binary (musl,
# with libseccomp and libcap-ng from scripts/build-libs.sh, at their current releases), in
# a pratico VM, for arm64 or x86_64 (KARCH). Inputs are pinned: the crate by the SHA-256
# crates.io's index records, its dependencies by its Cargo.lock, the build image by digest.
# virtiofsd publishes no aarch64 binaries, so pratico builds its own, and x86_64 alike.
#
#   [KARCH=x86_64] scripts/build-virtiofsd.sh <out-dir>   # writes <out-dir>/virtiofsd
set -euo pipefail

VIRTIOFSD_VERSION=1.15.0
VIRTIOFSD_SHA256=aeac41b813d490bb11941595b0ba09e49b8884dbe0d47f5df2fd891c8e0ecace  # index.crates.io/vi/rt/virtiofsd
VIRTIOFSD_URL="https://static.crates.io/crates/virtiofsd/virtiofsd-$VIRTIOFSD_VERSION.crate"
BUILD_IMAGE=rust@sha256:8d0e82abfdf9a38071e07cabc5afba4ddbe077631a80e4e742a760c38beadc33  # 1.100.0, alpine 3.24
# x86_64's standard library for that toolchain, which the image lacks: pinned by the hash Rust's
# signed channel manifest (channel-rust-1.100.0.toml) records for it, not fetched by rustup.
RUST_STD_X86=rust-std-1.100.0-x86_64-unknown-linux-musl
RUST_STD_X86_SHA256=9d5211bc7b40195f9700a6f9133831832a32f50d0e2a2c0ae8af801e7656de5c
RUST_STD_X86_URL="https://static.rust-lang.org/dist/2026-11-12/$RUST_STD_X86.tar.xz"

OUT="$(mkdir -p "${1:?usage: [KARCH=x86_64] scripts/build-virtiofsd.sh <out-dir>}" && cd "$1" && pwd)"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
KARCH="${KARCH:-arm64}"
case "$KARCH" in arm64) target=aarch64-unknown-linux-musl ;; x86_64) target=x86_64-unknown-linux-musl ;; *) echo "virtiofsd: KARCH is arm64 or x86_64" >&2; exit 2 ;; esac
LIBS="$ROOT/.cache/libs/out-$KARCH"
KARCH="$KARCH" "$ROOT/scripts/build-libs.sh" "$LIBS" >&2
CACHE="$ROOT/.cache/virtiofsd"
export DOCKER_HOST="${DOCKER_HOST:-unix://$HOME/.pratico/docker.sock}"
mkdir -p "$CACHE/in"

STAMP="$VIRTIOFSD_VERSION $(cat "$LIBS/versions")"
if [ -x "$OUT/virtiofsd" ] && [ -f "$OUT/virtiofsd.linked" ] && [ "$(cat "$OUT/virtiofsd.version" 2>/dev/null)" = "$STAMP" ]; then
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
if [ "$KARCH" = x86_64 ]; then
    std="$CACHE/$RUST_STD_X86.tar.xz"
    [ -f "$std" ] || { curl -fsSL --retry 3 -o "$std.part" "$RUST_STD_X86_URL" && mv "$std.part" "$std"; }
    [ "$(shasum -a 256 "$std" | cut -d' ' -f1)" = "$RUST_STD_X86_SHA256" ] || { echo "virtiofsd: $std does not match its SHA-256" >&2; exit 1; }
    ln -f "$std" "$CACHE/in/rust-std.tar.xz"
fi

docker volume create "pratico-virtiofsd-build-$KARCH" >/dev/null
docker run --rm --cpus "${CPUS:-8}" --memory "${MEMORY:-8g}" -e TARGET="$target" \
    -v "$CACHE/in:/in:ro" -v "$LIBS:/libs:ro" -v "$OUT:/out" -v "pratico-virtiofsd-build-$KARCH:/build" "$BUILD_IMAGE" sh -euc '
        apk add -q --no-cache musl-dev
        # x86_64 from arm64: Rust'"'"'s musl target carries its own C runtime, linked with rust-lld.
        if [ "$TARGET" != aarch64-unknown-linux-musl ]; then
            apk add -q --no-cache xz bash
            mkdir -p /tmp/std && xz -dc /in/rust-std.tar.xz | tar -x -C /tmp/std --strip-components=1
            /tmp/std/install.sh --prefix="$(rustc --print sysroot)" --disable-ldconfig >/dev/null
        fi
        rm -rf /build/src && mkdir -p /build/src
        tar -xzf /in/virtiofsd.crate -C /build/src --strip-components=1
        cd /build/src
        # As virtiofsd builds its own static release: the -sys crates link static libraries
        # only when asked; these are scripts/build-libs.sh'"'"'s.
        export LIBSECCOMP_LINK_TYPE=static LIBSECCOMP_LIB_PATH=/libs/lib LIBCAPNG_LINK_TYPE=static LIBCAPNG_LIB_PATH=/libs/lib
        flags="-C target-feature=+crt-static"
        [ "$TARGET" = aarch64-unknown-linux-musl ] || flags="$flags -C linker=rust-lld"
        CARGO_HOME=/build/cargo RUSTFLAGS="$flags" cargo build -q --release --locked --target "$TARGET"
        install -m 755 "target/$TARGET/release/virtiofsd" /out/virtiofsd
        grep -oE "(libseccomp|libcap-ng)-[0-9.]+" /libs/versions >/out/virtiofsd.linked'
want=$([ "$KARCH" = arm64 ] && echo "ARM aarch64" || echo "x86-64")
file "$OUT/virtiofsd" 2>/dev/null | grep -E "statically linked|static-pie linked" | grep -q "$want" || { echo "virtiofsd: $OUT/virtiofsd is not a static $KARCH binary" >&2; exit 1; }
# What it links, for THIRD_PARTY_NOTICES.
sed 's/^/virtiofsd: linked /' "$OUT/virtiofsd.linked"
echo "$STAMP" >"$OUT/virtiofsd.version"
echo "virtiofsd: $OUT/virtiofsd $VIRTIOFSD_VERSION $(shasum -a 256 "$OUT/virtiofsd" | cut -d' ' -f1)"
