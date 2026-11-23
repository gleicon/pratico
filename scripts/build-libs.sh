#!/usr/bin/env bash
# Builds the C libraries pratico's static Linux binaries link (docs/design/remote.md), as
# static musl libraries at their current releases, for arm64 or x86_64 (KARCH): libarchive,
# which unpacks every image layer, and its codecs zlib, bzip2 and xz, for the daemon and
# shim; libseccomp and libcap-ng, for virtiofsd. The static Swift SDK carries its own copies
# of some, fixed at its release, and a static binary takes no distribution's security
# updates: these go in instead, and move with upstream. Built with the pinned Swift image's
# clang against the SDK's musl sysroot, the same toolchain as the daemon; the kernel headers
# (UAPI) come from the guest kernel's own verified source. Inputs are pinned by SHA-256.
#
#   [KARCH=x86_64] scripts/build-libs.sh <out-dir>   # writes <out-dir>/{include,lib}
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
LIBSECCOMP_VERSION=2.6.2
LIBSECCOMP_SHA256=6b845d352c6d7887d8d134c43d86850d40f5dcee11ad1675c18197ae4d869d42  # GitHub release asset digest
LIBSECCOMP_URL="https://github.com/seccomp/libseccomp/releases/download/v$LIBSECCOMP_VERSION/libseccomp-$LIBSECCOMP_VERSION.tar.gz"
# libcap-ng publishes 0.9 releases as git tags only (its tarball site stops at 0.8.5): the
# tag's archive (commit c382c641ca5730442289c09d3c3d30cc2c8635a9), hashed when pinned.
LIBCAPNG_VERSION=0.9.6
LIBCAPNG_SHA256=399040138e0ca62fa2bcabd63da9af4431a246ef7a654561a0ca3cb00010a539  # computed 2026-11-23
LIBCAPNG_URL="https://github.com/stevegrubb/libcap-ng/archive/refs/tags/v$LIBCAPNG_VERSION.tar.gz"
SWIFT_IMAGE=swift@sha256:1ba0416be43dc57ba6ff7d02114356cad1ab17364024b7669385e3fe41a224aa  # 6.3.3-noble, as scripts/linux-check.sh
KERNEL_VERSION=$(sed -n 's/^KERNEL_VERSION=//p' "$(dirname "$0")/build-kernel.sh")
KERNEL_SHA256=$(sed -n 's/^KERNEL_SHA256=\([0-9a-f]*\).*/\1/p' "$(dirname "$0")/build-kernel.sh")

OUT="$(mkdir -p "${1:?usage: [KARCH=x86_64] scripts/build-libs.sh <out-dir>}" && cd "$1" && pwd)"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
KARCH="${KARCH:-arm64}"
case "$KARCH" in
arm64) triple=aarch64-linux-musl sdkarch=aarch64 karch=arm64 ;;
x86_64) triple=x86_64-linux-musl sdkarch=x86_64 karch=x86_64 ;;
*) echo "libs: KARCH is arm64 or x86_64" >&2; exit 2 ;;
esac
CACHE="$ROOT/.cache/libs"
SDK="$ROOT/.cache/init/sdk/static-sdk.artifactbundle.tar.gz"
SDK_SHA256=$(sed -n 's/^SDK_SHA256=\([0-9a-f]*\).*/\1/p' "$ROOT/scripts/linux-check.sh")
export DOCKER_HOST="${DOCKER_HOST:-unix://$HOME/.pratico/docker.sock}"
STAMP="$KARCH zlib-$ZLIB_VERSION bzip2-$BZIP2_VERSION xz-$XZ_VERSION libarchive-$LIBARCHIVE_VERSION libseccomp-$LIBSECCOMP_VERSION libcap-ng-$LIBCAPNG_VERSION linux-$KERNEL_VERSION"
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
fetch "libseccomp-$LIBSECCOMP_VERSION.tar.gz" "$LIBSECCOMP_URL" "$LIBSECCOMP_SHA256"
fetch "libcap-ng-$LIBCAPNG_VERSION.tar.gz" "$LIBCAPNG_URL" "$LIBCAPNG_SHA256"
kernel="$ROOT/.cache/kernel/linux-$KERNEL_VERSION.tar.xz"
[ "$(shasum -a 256 "$kernel" 2>/dev/null | cut -d' ' -f1)" = "$KERNEL_SHA256" ] || { echo "libs: $kernel missing or not its SHA-256: run scripts/build-kernel.sh" >&2; exit 1; }
ln -f "$kernel" "$CACHE/in/linux.tar.xz"
[ "$(shasum -a 256 "$SDK" 2>/dev/null | cut -d' ' -f1)" = "$SDK_SHA256" ] || { echo "libs: $SDK missing or not its SHA-256: run scripts/linux-check.sh host" >&2; exit 1; }

rm -rf "$OUT/include" "$OUT/lib" "$OUT/versions"
docker run --rm --cpus "${CPUS:-8}" --memory "${MEMORY:-6g}" \
    -v "$CACHE/in:/in:ro" -v "$SDK:/sdk.tar.gz:ro" -v "$OUT:/out" \
    -e TRIPLE="$triple" -e SDKARCH="$sdkarch" -e KARCH="$karch" \
    -e ZLIB="zlib-$ZLIB_VERSION" -e BZIP2="bzip2-$BZIP2_VERSION" -e XZ="xz-$XZ_VERSION" -e LIBARCHIVE="libarchive-$LIBARCHIVE_VERSION" \
    -e LIBSECCOMP="libseccomp-$LIBSECCOMP_VERSION" -e LIBCAPNG="libcap-ng-$LIBCAPNG_VERSION" \
    "$SWIFT_IMAGE" bash -euc '
        apt-get -qq update >/dev/null && DEBIAN_FRONTEND=noninteractive apt-get -qq install -y --no-install-recommends \
            make autoconf automake libtool pkg-config gperf xz-utils rsync >/dev/null
        mkdir -p /src /sysroot && cd /src
        tar -xzf /sdk.tar.gz -C /src --wildcards "*/musl-1.2.5.sdk/$SDKARCH/*"
        cp -a /src/*/*/swift-linux-musl/musl-1.2.5.sdk/$SDKARCH/. /sysroot/
        # The guest kernel'"'"'s own UAPI headers, for libseccomp and libcap-ng.
        tar -xJf /in/linux.tar.xz && make -s -C linux-* ARCH=$KARCH headers_install INSTALL_HDR_PATH=/kh >/dev/null
        # The SDK'"'"'s compiler-rt and crt objects, not libgcc, which a musl sysroot has none of.
        export CC="clang --target=$TRIPLE --sysroot=/sysroot -resource-dir=/sysroot/usr/lib/swift/clang"
        export AR=llvm-ar RANLIB=llvm-ranlib
        export CFLAGS="-O2 -fPIC -fstack-protector-strong -D_FORTIFY_SOURCE=2"
        export CPPFLAGS="-I/out/include -I/kh/include" LDFLAGS="-L/out/lib -rtlib=compiler-rt -unwindlib=none -fuse-ld=lld -static"
        host=(--host=$TRIPLE --prefix=/out --disable-shared --enable-static)
        mkdir -p /out/include /out/lib
        tar -xf /in/$ZLIB.tar.xz && (cd $ZLIB && CHOST=$TRIPLE ./configure --static --prefix=/out >/dev/null && make -s -j8 install >/dev/null)
        tar -xf /in/$BZIP2.tar.gz && (cd $BZIP2 && make -s -j8 libbz2.a CC="$CC" AR=$AR RANLIB=$RANLIB CFLAGS="$CFLAGS -D_FILE_OFFSET_BITS=64" >/dev/null \
            && install -m 644 libbz2.a /out/lib/ && install -m 644 bzlib.h /out/include/)
        tar -xf /in/$XZ.tar.xz && (cd $XZ && ./configure -q "${host[@]}" --disable-xz --disable-xzdec --disable-lzmadec \
            --disable-lzmainfo --disable-scripts --disable-doc --disable-nls >/dev/null && make -s -j8 install >/dev/null)
        # Only what layers use: tar and its gzip, bzip2 and xz filters. No crypto, no XML, no
        # ACL or xattr libraries: they are unused and would each be one more thing to patch.
        tar -xf /in/$LIBARCHIVE.tar.xz && (cd $LIBARCHIVE && ./configure -q "${host[@]}" \
            --disable-bsdtar --disable-bsdcpio --disable-bsdcat --disable-bsdunzip --with-zlib --with-bz2lib --with-lzma \
            --without-zstd --without-lz4 --without-openssl --without-xml2 --without-expat --without-libb2 --without-mbedtls \
            --without-nettle --without-cng --without-iconv --disable-acl --disable-xattr >/dev/null && make -s -j8 install >/dev/null)
        tar -xf /in/$LIBSECCOMP.tar.gz && (cd $LIBSECCOMP && ./configure -q "${host[@]}" --disable-python >/dev/null && make -s -j8 install >/dev/null)
        tar -xf /in/$LIBCAPNG.tar.gz && (cd $LIBCAPNG && ./autogen.sh >/dev/null 2>&1 && ./configure -q "${host[@]}" \
            --without-python3 >/dev/null && make -s -j8 -C src install >/dev/null \
            && install -m 644 src/cap-ng.h /out/include/)
        rm -rf /out/bin /out/share /out/lib/pkgconfig /out/lib/*.la /out/lib/cmake'
for lib in libz.a libbz2.a liblzma.a libarchive.a libseccomp.a libcap-ng.a; do
    [ -f "$OUT/lib/$lib" ] || { echo "libs: $OUT/lib/$lib missing" >&2; exit 1; }
done
echo "$STAMP" >"$OUT/versions"
echo "libs: $OUT ($STAMP)"
