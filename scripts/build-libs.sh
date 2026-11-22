#!/usr/bin/env bash
# Builds the C libraries pratico's static Linux binaries link (docs/design/remote.md):
# libarchive, which unpacks every image layer, and its codecs zlib, bzip2 and xz, as static
# musl libraries at their current releases. The static Swift SDK carries its own copies,
# fixed at its release, and a static binary takes no distribution's security updates: these
# go in instead, and move with upstream. Inputs are pinned: each tarball by the SHA-256 its
# release records, the build image by digest.
#
#   scripts/build-libs.sh <out-dir>   # writes <out-dir>/{include,lib}
set -euo pipefail

ZLIB_VERSION=1.4
ZLIB_SHA256=4f11c512053d7bab8d9e9b89bde3575add3e4c50a383b42ef6cb837035fc5a7c  # GitHub release asset digest
ZLIB_URL="https://github.com/madler/zlib/releases/download/v$ZLIB_VERSION/zlib-$ZLIB_VERSION.tar.xz"
BZIP2_VERSION=1.0.8
BZIP2_SHA256=ab5a03176ee106d3f0fa90e381da478ddae405918153cca248e682cd0c4a2269  # sourceware.org/bzip2
BZIP2_URL="https://sourceware.org/pub/bzip2/bzip2-$BZIP2_VERSION.tar.gz"
XZ_VERSION=5.8.4
XZ_SHA256=4ce24038fd4221e0d13bc1a2de7a4db56e90b92b3bf75321f6c14be73f65de4b  # GitHub release asset digest
XZ_URL="https://github.com/tukaani-project/xz/releases/download/v$XZ_VERSION/xz-$XZ_VERSION.tar.xz"
LIBARCHIVE_VERSION=3.8.11
LIBARCHIVE_SHA256=a3dc0872b1b39da34dc18ef1b944f0f11ffd37425d70ae04be679279f1cf43d2  # GitHub release asset digest
LIBARCHIVE_URL="https://github.com/libarchive/libarchive/releases/download/v$LIBARCHIVE_VERSION/libarchive-$LIBARCHIVE_VERSION.tar.xz"
BUILD_IMAGE=alpine@sha256:f59abe656b692d901e184be3445e084786602108599d2a51d229c0f5a48c71bf  # 3.24

OUT="$(mkdir -p "${1:?usage: scripts/build-libs.sh <out-dir>}" && cd "$1" && pwd)"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CACHE="$ROOT/.cache/libs"
export DOCKER_HOST="${DOCKER_HOST:-unix://$HOME/.pratico/docker.sock}"
STAMP="zlib-$ZLIB_VERSION bzip2-$BZIP2_VERSION xz-$XZ_VERSION libarchive-$LIBARCHIVE_VERSION"
mkdir -p "$CACHE/in"

if [ -f "$OUT/lib/libarchive.a" ] && [ "$(cat "$OUT/versions" 2>/dev/null)" = "$STAMP" ]; then
    echo "libs: $OUT ($STAMP), built already"
    exit 0
fi
fetch() {  # name url sha256
    local file="$CACHE/$1"
    if [ ! -f "$file" ]; then
        curl -fsSL --retry 3 -o "$file.part" "$2"
        mv "$file.part" "$file"
    fi
    [ "$(shasum -a 256 "$file" | cut -d' ' -f1)" = "$3" ] || { echo "libs: $file does not match its SHA-256" >&2; exit 1; }
    ln -f "$file" "$CACHE/in/$1"
}
fetch "zlib-$ZLIB_VERSION.tar.xz" "$ZLIB_URL" "$ZLIB_SHA256"
fetch "bzip2-$BZIP2_VERSION.tar.gz" "$BZIP2_URL" "$BZIP2_SHA256"
fetch "xz-$XZ_VERSION.tar.xz" "$XZ_URL" "$XZ_SHA256"
fetch "libarchive-$LIBARCHIVE_VERSION.tar.xz" "$LIBARCHIVE_URL" "$LIBARCHIVE_SHA256"

rm -rf "$OUT/include" "$OUT/lib" "$OUT/versions"
docker run --rm --cpus "${CPUS:-8}" --memory "${MEMORY:-4g}" \
    -v "$CACHE/in:/in:ro" -v "$OUT:/out" \
    -e ZLIB="zlib-$ZLIB_VERSION" -e BZIP2="bzip2-$BZIP2_VERSION" -e XZ="xz-$XZ_VERSION" -e LIBARCHIVE="libarchive-$LIBARCHIVE_VERSION" \
    "$BUILD_IMAGE" sh -euc '
        apk add -q --no-cache build-base xz
        export CFLAGS="-O2 -fPIC -fstack-protector-strong -D_FORTIFY_SOURCE=2" PREFIX=/out
        mkdir -p /src && cd /src
        tar -xf /in/$ZLIB.tar.xz && (cd $ZLIB && ./configure --static --prefix=/out >/dev/null && make -s -j8 install >/dev/null)
        tar -xf /in/$BZIP2.tar.gz && (cd $BZIP2 && make -s -j8 libbz2.a CFLAGS="$CFLAGS -D_FILE_OFFSET_BITS=64" >/dev/null \
            && install -m 644 libbz2.a /out/lib/ && install -m 644 bzlib.h /out/include/)
        tar -xf /in/$XZ.tar.xz && (cd $XZ && ./configure -q --prefix=/out --disable-shared --enable-static \
            --disable-xz --disable-xzdec --disable-lzmadec --disable-lzmainfo --disable-scripts --disable-doc --disable-nls >/dev/null \
            && make -s -j8 install >/dev/null)
        # Only what layers use: tar and its gzip, bzip2 and xz filters. No crypto, no XML, no
        # ACL or xattr libraries: they are unused and would each be one more thing to patch.
        tar -xf /in/$LIBARCHIVE.tar.xz && (cd $LIBARCHIVE && CPPFLAGS="-I/out/include" LDFLAGS="-L/out/lib" ./configure -q --prefix=/out \
            --disable-shared --enable-static --disable-bsdtar --disable-bsdcpio --disable-bsdcat --disable-bsdunzip \
            --with-zlib --with-bz2lib --with-lzma --without-zstd --without-lz4 --without-openssl --without-xml2 --without-expat \
            --without-libb2 --without-mbedtls --without-nettle --without-cng --without-iconv --disable-acl --disable-xattr >/dev/null \
            && make -s -j8 install >/dev/null)
        rm -rf /out/bin /out/share /out/lib/pkgconfig /out/lib/*.la /out/lib/cmake'
for lib in libz.a libbz2.a liblzma.a libarchive.a; do
    [ -f "$OUT/lib/$lib" ] || { echo "libs: $OUT/lib/$lib missing" >&2; exit 1; }
done
echo "$STAMP" >"$OUT/versions"
echo "libs: $OUT ($STAMP)"
