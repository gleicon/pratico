#!/usr/bin/env bash
# Writes the acknowledgements the app and DMG ship (SPEC D-28): pratico's license, the
# license and notice files of every resolved Swift package, and what the bundled guest
# kernel and init are, with the kernel's GPL-2.0 source offer.
# Usage: scripts/acknowledgements.sh <out-file>
set -euo pipefail

OUT="${1:?usage: scripts/acknowledgements.sh <out-file>}"
CHECKOUTS=.build/checkouts
LINUX=$(sed -n 's/^KERNEL_VERSION=//p' scripts/build-kernel.sh)
LINUX_SHA256=$(sed -n 's/^KERNEL_SHA256=\([0-9a-f]*\).*/\1/p' scripts/build-kernel.sh)
VERSION=$(sed -n 's/.*version = "\(.*\)".*/\1/p' Sources/PraticoCore/Pratico.swift)
[ -d "$CHECKOUTS" ] || { echo "acknowledgements: no $CHECKOUTS; build first" >&2; exit 1; }

{
    echo "Pratico acknowledgements"
    echo "========================"
    echo
    echo "Pratico is MIT licensed:"
    echo
    cat LICENSE
    echo
    echo "Guest kernel"
    echo "------------"
    echo "Pratico ships a Linux kernel (Linux $LINUX), built by the Pratico project from the"
    echo "unmodified kernel.org source. Linux is licensed under GPL-2.0"
    echo "(https://www.kernel.org/doc/html/latest/process/license-rules.html)."
    echo "Its corresponding source:"
    echo "  - linux-$LINUX.tar.xz, SHA-256 $LINUX_SHA256:"
    echo "    https://cdn.kernel.org/pub/linux/kernel/v${LINUX%%.*}.x/linux-$LINUX.tar.xz"
    echo "  - its configuration, Contents/Resources/runtime/kernel-config in this app"
    echo "  - the build scripts: https://github.com/gleicon/pratico/tree/v$VERSION/vm/kernel"
    echo "    and scripts/build-kernel.sh"
    echo "For three years from the date you received this copy of Pratico, a copy of that source"
    echo "is available on request at https://github.com/gleicon/pratico/issues."
    echo
    echo "Guest init"
    echo "----------"
    echo "vminitd and vmexec, built by the Pratico project from apple/containerization's source"
    echo "(Apache-2.0, license below, under containerization; files Pratico changed say so, and"
    echo "Vendor/README.md in Pratico's source lists them). They are static Linux binaries built"
    echo "with the Swift static Linux SDK, so they also contain:"
    echo "  - musl libc (MIT)"
    echo "  - the Swift runtime and standard library (Apache-2.0 with Runtime Library Exception)"
    echo "  - swift-foundation and swift-corelibs-libdispatch (Apache-2.0 with Runtime Library Exception)"
    echo "  - swift-foundation-icu and ICU data (Apache-2.0; ICU under the Unicode License V3)"
    echo "  - swift-crypto (BoringSSL), swift-nio, swift-nio-ssl, grpc-swift, swift-protobuf"
    echo "    (licenses below, under Swift packages)"
    echo "Their license texts follow."
    for f in musl swift swift-foundation swift-corelibs-libdispatch swift-foundation-icu icu; do
        echo
        echo "== $f =="
        echo
        cat "Support/licenses/$f.txt"
    done
    echo
    echo "Swift packages"
    echo "--------------"
    for dir in Vendor/*/ "$CHECKOUTS"/*/; do
        name=$(basename "$dir")
        [ "$dir" != "$CHECKOUTS/$name/" ] || [ ! -d "Vendor/$name" ] || continue  # vendored: listed once, from Vendor
        files=()
        for f in LICENSE LICENSE.txt LICENSE.md NOTICE NOTICE.txt NOTICES.txt; do
            [ -f "$dir$f" ] && files+=("$dir$f")
        done
        [ ${#files[@]} -gt 0 ] || continue
        echo
        echo "== $name =="
        for f in "${files[@]}"; do echo; cat "$f"; done
    done
} >"$OUT"
