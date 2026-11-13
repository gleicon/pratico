#!/usr/bin/env bash
# Writes the acknowledgements the app and DMG ship (SPEC D-28): pratico's license, the
# license and notice files of every resolved Swift package, and what the bundled guest
# kernel and init are, with the kernel's GPL-2.0 source offer.
# Usage: scripts/acknowledgements.sh <out-file>
set -euo pipefail

OUT="${1:?usage: scripts/acknowledgements.sh <out-file>}"
CHECKOUTS=.build/checkouts
KATA_VERSION=$(sed -n 's/^KATA_VERSION=//p' scripts/fetch-runtime-assets.sh)
KERNEL=$(sed -n 's|^KERNEL_MEMBER=.*/vmlinux-||p' scripts/fetch-runtime-assets.sh)  # 6.18.15-186: Kata's build number
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
    echo "Guest init"
    echo "----------"
    echo "vminitd, from apple/containerization, Apache-2.0 (license below, under containerization)."
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
} >"$OUT"
