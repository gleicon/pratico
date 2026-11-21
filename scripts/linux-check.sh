#!/usr/bin/env bash
# Builds the daemon for Linux and runs its unit tests there, in the pinned Swift image on
# pratico itself (as build-init.sh does). The build directory is a volume, kept between runs.
# Usage: scripts/linux-check.sh [build|test]    (default: test)
#        scripts/linux-check.sh host <out-dir>  release daemon and shim, Swift linked in
set -euo pipefail

SWIFT_IMAGE=swift@sha256:1ba0416be43dc57ba6ff7d02114356cad1ab17364024b7669385e3fe41a224aa  # 6.3.3-noble, as build-init.sh
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export DOCKER_HOST="${DOCKER_HOST:-unix://$HOME/.pratico/docker.sock}"

# libarchive and its codecs, which ContainerizationArchive links (dev headers: the image has none).
deps='apt-get -qq update >/dev/null && apt-get -qq install -y --no-install-recommends libarchive-dev libbz2-dev liblzma-dev libssl-dev >/dev/null'

case "${1:-test}" in
build) cmd='swift build --scratch-path /build --product pratico-daemon && swift build --scratch-path /build --product pratico-shim' ;;
test) cmd='swift test --scratch-path /build --filter "PraticoCoreTests|PraticoDaemonKitTests"' ;;
host)
    OUT="$(mkdir -p "${2:?usage: scripts/linux-check.sh host <out-dir>}" && cd "$2" && pwd)"
    out=(-v "$OUT":/out)
    # A rename, not a copy over the file: a test host may be running the old binaries.
    cmd='for p in pratico-daemon pratico-shim; do swift build --scratch-path /build -c release --static-swift-stdlib --product $p || exit 1; done && for p in pratico-daemon pratico-shim; do cp /build/release/$p /out/.$p.new && mv -f /out/.$p.new /out/$p || exit 1; done' ;;
*) echo "usage: scripts/linux-check.sh [build|test|host <out-dir>]" >&2; exit 2 ;;
esac

docker volume inspect pratico-linux-build >/dev/null 2>&1 || docker volume create pratico-linux-build >/dev/null
docker run --rm --cpus "$(sysctl -n hw.ncpu)" -m 12g \
    -v "$ROOT":/src:ro -v pratico-linux-build:/build ${out[@]+"${out[@]}"} -w /src \
    "$SWIFT_IMAGE" sh -c "$deps && $cmd"
