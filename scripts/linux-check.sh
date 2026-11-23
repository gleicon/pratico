#!/usr/bin/env bash
# Builds the daemon for Linux and runs its unit tests there, in the pinned Swift image on
# pratico itself (as build-init.sh does). The build directory is a volume, kept between runs.
# Usage: scripts/linux-check.sh [build|test]    (default: test)
#        [KARCH=x86_64] scripts/linux-check.sh host <out-dir>  release daemon and shim, static (musl):
#                                                what a host installs, arm64 (default) or x86_64
set -euo pipefail

SWIFT_IMAGE=swift@sha256:1ba0416be43dc57ba6ff7d02114356cad1ab17364024b7669385e3fe41a224aa  # 6.3.3-noble, as build-init.sh
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# The static Linux SDK build-init.sh fetches: musl, and libarchive, its codecs and libcrypto
# as static libraries, so a host needs nothing installed for pratico.
SDK_URL=https://download.swift.org/swift-6.3.3-release/static-sdk/swift-6.3.3-RELEASE/swift-6.3.3-RELEASE_static-linux-0.1.0.artifactbundle.tar.gz
SDK_SHA256=87c3eaf908e67c0e13a84367119e12273cec1d2cd3d81f7d74bb36722d6b607b  # swift.org release data
export DOCKER_HOST="${DOCKER_HOST:-unix://$HOME/.pratico/docker.sock}"

# libarchive and its codecs, which ContainerizationArchive links (dev headers: the image has none).
# apparmor: its parser checks the shim's profile (HostInstallTests).
deps='apt-get -qq update >/dev/null && apt-get -qq install -y --no-install-recommends libarchive-dev libbz2-dev liblzma-dev libssl-dev apparmor >/dev/null'

case "${1:-test}" in
build) cmd='swift build --scratch-path /build --product pratico-daemon && swift build --scratch-path /build --product pratico-shim' ;;
test) cmd='swift test --scratch-path /build --filter "PraticoCoreTests|PraticoDaemonKitTests"' ;;
host)
    OUT="$(mkdir -p "${2:?usage: scripts/linux-check.sh host <out-dir>}" && cd "$2" && pwd)"
    sdk="$ROOT/.cache/init/sdk/static-sdk.artifactbundle.tar.gz"
    mkdir -p "$(dirname "$sdk")"
    if [ ! -f "$sdk" ]; then curl -fL --retry 3 -o "$sdk.part" "$SDK_URL" && mv "$sdk.part" "$sdk"; fi
    [ "$(shasum -a 256 "$sdk" | cut -d' ' -f1)" = "$SDK_SHA256" ] || { echo "linux-check: $sdk does not match its SHA-256" >&2; exit 1; }
    # libarchive and its codecs at their current releases, ahead of the SDK's own copies.
    KARCH="${KARCH:-arm64}"
    case "$KARCH" in arm64) triple=aarch64-swift-linux-musl ;; x86_64) triple=x86_64-swift-linux-musl ;; *) echo "linux-check: KARCH is arm64 or x86_64" >&2; exit 2 ;; esac
    libs="$ROOT/.cache/libs/out-$KARCH"
    KARCH="$KARCH" "$ROOT/scripts/build-libs.sh" "$libs" >&2
    out=(-v "$OUT":/out -v "$(dirname "$sdk")":/sdk:ro -v "$libs":/libs:ro -e SDK_SHA256="$SDK_SHA256" -e TRIPLE="$triple")
    deps=true
    # A rename, not a copy over the file: a test host may be running the old binaries.
    cmd='swift sdk list | grep -q static-linux || swift sdk install /sdk/static-sdk.artifactbundle.tar.gz --checksum "$SDK_SHA256" >/dev/null || exit 1
        flags="--scratch-path /build/static-$TRIPLE -c release --swift-sdk $TRIPLE -Xcc -I/libs/include -Xlinker -L/libs/lib -Xlinker -s"
        for p in pratico-daemon pratico-shim; do swift build $flags --product $p || exit 1; done
        bin=$(swift build $flags --show-bin-path)
        for p in pratico-daemon pratico-shim; do
            grep -q "libarchive $(grep -o "libarchive-[0-9.]*" /libs/versions | cut -d- -f2)" $bin/$p || { echo "$p: not linked with /libs" >&2; exit 1; }
            cp $bin/$p /out/.$p.new && mv -f /out/.$p.new /out/$p || exit 1
        done' ;;
*) echo "usage: scripts/linux-check.sh [build|test|host <out-dir>]" >&2; exit 2 ;;
esac

# SwiftPM on Linux reused a build plan that predates a file added to the vendored package
# (its compile list lacked it): planning again each run is cheap, compiling stays incremental.
replan='find /build -maxdepth 4 -name description.json -delete'
deps="$replan && $deps"

docker volume inspect pratico-linux-build >/dev/null 2>&1 || docker volume create pratico-linux-build >/dev/null
docker run --rm --cpus "$(sysctl -n hw.ncpu)" -m 12g \
    -v "$ROOT":/src:ro -v pratico-linux-build:/build ${out[@]+"${out[@]}"} -w /src \
    "$SWIFT_IMAGE" sh -c "$deps && $cmd"
