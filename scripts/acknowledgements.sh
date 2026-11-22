#!/usr/bin/env bash
# Writes the acknowledgements the app and DMG ship (SPEC D-28): pratico's license, the
# license and notice files of every resolved Swift package, and what the bundled guest
# kernel and init are, with the kernel's GPL-2.0 source offer. `linux` writes the Linux
# host release's (THIRD_PARTY_NOTICES): the same, plus what its static binaries link and the
# VMM and virtiofsd it carries.
# Usage: scripts/acknowledgements.sh <out-file> [linux]
set -euo pipefail

OUT="${1:?usage: scripts/acknowledgements.sh <out-file> [linux]}"
KIND="${2:-mac}"
if [ "$KIND" = linux ]; then CONFIG_AT="runtime/kernel-config in this release"; else CONFIG_AT="Contents/Resources/runtime/kernel-config in this app"; fi
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
    echo "  - its configuration, $CONFIG_AT"
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
    echo "The init image also carries the flight recorder's BPF probes, Pratico's own code (MIT,"
    echo "declared Dual MIT/GPL to the kernel), built against the shipped kernel's types; their"
    echo "source is vm/bpf in Pratico's repository at this release's tag."
    echo "Their license texts follow."
    libs=(musl swift swift-foundation swift-corelibs-libdispatch swift-foundation-icu icu)
    if [ "$KIND" = linux ]; then
        echo
        echo "Linux host binaries"
        echo "-------------------"
        echo "pratico-daemon and pratico-shim are static Linux binaries built with the Swift static"
        echo "Linux SDK, with the same runtime as the guest init above, and libarchive, zlib, bzip2"
        echo "and xz's liblzma built by the Pratico project from their release sources"
        echo "(scripts/build-libs.sh). The release also carries, unmodified:"
        echo "  - cloud-hypervisor, Cloud Hypervisor's static release binary (Apache-2.0 and BSD-3-Clause)"
        linked="${VIRTIOFSD_LINKED:?linux notices need VIRTIOFSD_LINKED, the virtiofsd.linked build-virtiofsd.sh writes}"
        echo "  - virtiofsd, built by the Pratico project from its crates.io source (Apache-2.0 and"
        echo "    BSD-3-Clause; scripts/build-virtiofsd.sh), statically linked with Alpine's"
        echo "    $(xargs <"$linked" | sed 's/ /, /g')"
        echo "    (libseccomp: LGPL-2.1-or-later; libcap-ng's library: LGPL-2.1-or-later). Their"
        echo "    source is Alpine's (https://gitlab.alpinelinux.org/alpine/aports, main/libseccomp and"
        echo "    main/libcap-ng) over upstream's releases; to relink virtiofsd with other versions,"
        echo "    rebuild it from its source with scripts/build-virtiofsd.sh, as LGPL-2.1 section 6 allows."
        echo "Their license texts follow."
        libs+=(libarchive zlib bzip2 xz cloud-hypervisor virtiofsd lgpl-2.1)
    fi
    for f in "${libs[@]}"; do
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
