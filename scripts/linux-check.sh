#!/usr/bin/env bash
# Builds the daemon for Linux and runs its unit tests there, in the pinned Swift image on
# pratico itself (as build-init.sh does). The build directory is a volume, kept between runs.
# Usage: scripts/linux-check.sh [build|test]    (default: test)
#        scripts/linux-check.sh host <out-dir>  release daemon and shim, static (musl): what a host installs
set -euo pipefail

SWIFT_IMAGE=swift@sha256:1ba0416be43dc57ba6ff7d02114356cad1ab17364024b7669385e3fe41a224aa  # 6.3.3-noble, as build-init.sh
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# The static Linux SDK build-init.sh fetches: musl, and libarchive, its codecs and libcrypto
# as static libraries, so a host needs nothing installed for pratico.
SDK_URL=https://download.swift.org/swift-6.3.3-release/static-sdk/swift-6.3.3-RELEASE/swift-6.3.3-RELEASE_static-linux-0.1.0.artifactbundle.tar.gz
SDK_SHA256=87c3eaf908e67c0e13a84367119e12273cec1d2cd3d81f7d74bb36722d6b607b  # swift.org release data
export DOCKER_HOST="${DOCKER_HOST:-unix://$HOME/.pratico/docker.sock}"

# libarchive and its codecs, which ContainerizationArchive links (dev headers: the image has none).
deps='apt-get -qq update >/dev/null && apt-get -qq install -y --no-install-recommends libarchive-dev libbz2-dev liblzma-dev libssl-dev >/dev/null'

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
    "$ROOT/scripts/build-libs.sh" "$ROOT/.cache/libs/out" >&2
    out=(-v "$OUT":/out -v "$(dirname "$sdk")":/sdk:ro -v "$ROOT/.cache/libs/out":/libs:ro -e SDK_SHA256="$SDK_SHA256")
    deps=true
    # A rename, not a copy over the file: a test host may be running the old binaries.
    cmd='swift sdk list | grep -q static-linux || swift sdk install /sdk/static-sdk.artifactbundle.tar.gz --checksum "$SDK_SHA256" >/dev/null || exit 1
        flags="--scratch-path /build/static -c release --swift-sdk aarch64-swift-linux-musl -Xcc -I/libs/include -Xlinker -L/libs/lib -Xlinker -s"
        for p in pratico-daemon pratico-shim; do swift build $flags --product $p || exit 1; done
        bin=$(swift build $flags --show-bin-path)
        for p in pratico-daemon pratico-shim; do
            grep -q "libarchive $(cut -d" " -f4 /libs/versions | cut -d- -f2)" $bin/$p || { echo "$p: not linked with /libs" >&2; exit 1; }
            cp $bin/$p /out/.$p.new && mv -f /out/.$p.new /out/$p || exit 1
        done' ;;
*) echo "usage: scripts/linux-check.sh [build|test|host <out-dir>]" >&2; exit 2 ;;
esac

docker volume inspect pratico-linux-build >/dev/null 2>&1 || docker volume create pratico-linux-build >/dev/null
docker run --rm --cpus "$(sysctl -n hw.ncpu)" -m 12g \
    -v "$ROOT":/src:ro -v pratico-linux-build:/build ${out[@]+"${out[@]}"} -w /src \
    "$SWIFT_IMAGE" sh -c "$deps && $cmd"
