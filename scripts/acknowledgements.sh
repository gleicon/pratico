#!/usr/bin/env bash
# Writes the acknowledgements the app and DMG ship (SPEC D-28): pratico's license, the
# license and notice files of every resolved Swift package, and what the bundled guest
# kernel and init are, with the kernel's GPL-2.0 source offer.
# Usage: scripts/acknowledgements.sh <out-file>
set -euo pipefail

OUT="${1:?usage: scripts/acknowledgements.sh <out-file>}"
CHECKOUTS=.build/checkouts
KATA_VERSION=$(sed -n 's/^KATA_VERSION=//p' scripts/fetch-runtime-assets.sh)
KERNEL=$(sed -n 's|^KERNEL_MEMBER=.*/vmlinux-||p' scripts/fetch-runtime-assets.sh)  # e.g. 6.18.56-208: Linux version and Kata's build number
LINUX=${KERNEL%-*}
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
    echo "Pratico ships a Linux kernel (vmlinux-$KERNEL) from the Kata Containers $KATA_VERSION"
    echo "release, unmodified. Linux is licensed under GPL-2.0"
    echo "(https://www.kernel.org/doc/html/latest/process/license-rules.html)."
    echo "Its corresponding source is the Linux $LINUX source with the Kata Containers $KATA_VERSION"
    echo "kernel configuration and patches:"
    echo "  https://github.com/kata-containers/kata-containers/tree/$KATA_VERSION/tools/packaging/kernel"
    echo "  https://cdn.kernel.org/pub/linux/kernel/"
    echo "For three years from the date you received this copy of Pratico, a copy of that source"
    echo "is available on request at https://github.com/gleicon/pratico/issues."
    echo
    echo "The kernel is built and published by the Kata Containers project"
    echo "(https://katacontainers.io, Apache-2.0 for the project's own code; license at the end)."
    echo
    echo "Guest init"
    echo "----------"
    echo "vminitd and vmexec, from apple/containerization (Apache-2.0, license below, under"
    echo "containerization), published by Apple as the vminit image. They are static Linux"
    echo "binaries built with the Swift static Linux SDK, so they also contain:"
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
    for dir in "$CHECKOUTS"/*/; do
        name=$(basename "$dir")
        files=()
        for f in LICENSE LICENSE.txt LICENSE.md NOTICE NOTICE.txt NOTICES.txt; do
            [ -f "$dir$f" ] && files+=("$dir$f")
        done
        [ ${#files[@]} -gt 0 ] || continue
        echo
        echo "== $name =="
        for f in "${files[@]}"; do echo; cat "$f"; done
    done
    echo
    echo "== kata-containers =="
    echo
    cat Support/licenses/kata-containers.txt
} >"$OUT"
