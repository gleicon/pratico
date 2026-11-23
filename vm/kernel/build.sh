#!/bin/bash
# Runs inside the build container (scripts/build-kernel.sh): installs a toolchain from a
# fixed Debian snapshot, then builds the kernel from the verified tarball in /in. KARCH is
# arm64 (native) or x86_64 (cross-compiled, for Linux hosts on x86_64).
set -euo pipefail
: "${KBUILD_BUILD_TIMESTAMP:?}"
KARCH="${KARCH:-arm64}"

source /in/snapshot.sh
cross=()
[ "$KARCH" = arm64 ] || cross=(gcc-x86-64-linux-gnu binutils-x86-64-linux-gnu)
DEBIAN_FRONTEND=noninteractive apt-get -qq install -y --no-install-recommends \
    bc bison cpio dwarves flex gcc libc6-dev libelf-dev libssl-dev make python3 xz-utils ${cross[@]+"${cross[@]}"} >/dev/null
objcopy_k=objcopy
[ "$KARCH" = arm64 ] || objcopy_k=x86_64-linux-gnu-objcopy
make_k() {
    if [ "$KARCH" = arm64 ]; then make -s ARCH=arm64 "$@"; else make -s ARCH=x86_64 CROSS_COMPILE=x86_64-linux-gnu- "$@"; fi
}

# Same path every build: it is in the kernel's debug info, so it is part of the result.
rm -rf /kbuild/linux
mkdir -p /kbuild/linux
tar -xf /in/linux.tar.xz -C /kbuild/linux --strip-components=1
cd /kbuild/linux
cp "/in/config-$KARCH" .config
scripts/kconfig/merge_config.sh -m -O . .config /in/config-pratico >/dev/null
make_k olddefconfig
missing=0
while IFS= read -r line; do
    case "$line" in
        CONFIG_*|"# CONFIG_"*" is not set") grep -qxF "$line" .config || { echo "kernel: $line did not survive olddefconfig" >&2; missing=1; } ;;
    esac
done < /in/config-pratico
[ "$missing" = 0 ]

export KBUILD_BUILD_USER=pratico KBUILD_BUILD_HOST=pratico KBUILD_BUILD_VERSION=1
# JOBS=1: pahole encodes BTF on one thread, deterministic whatever pahole's version.
if [ "$KARCH" = arm64 ]; then
    make_k -j"$(nproc)" JOBS=1 LOCALVERSION=-pratico Image
    cp arch/arm64/boot/Image /out/vmlinux
else
    # Cloud Hypervisor boots the ELF through its PVH entry (CONFIG_PVH); stripped of the
    # symbols, which the kernel does not need at runtime.
    make_k -j"$(nproc)" JOBS=1 LOCALVERSION=-pratico vmlinux
    "$objcopy_k" --strip-debug vmlinux /out/vmlinux
fi
cp .config /out/config
# The kernel's types, for the guest's BPF probes (scripts/build-bpf.sh): built against
# this kernel's own layout, so they need no relocation at load.
"$objcopy_k" -O binary --only-section=.BTF vmlinux /out/vmlinux.btf
echo "kernel: $(make_k LOCALVERSION=-pratico kernelrelease) $KARCH"
