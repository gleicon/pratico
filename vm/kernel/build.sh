#!/bin/bash
# Runs inside the build container (scripts/build-kernel.sh): installs a toolchain from a
# fixed Debian snapshot, then builds the kernel from the verified tarball in /in.
set -euo pipefail
: "${KBUILD_BUILD_TIMESTAMP:?}"

source /in/snapshot.sh
DEBIAN_FRONTEND=noninteractive apt-get -qq install -y --no-install-recommends \
    bc bison cpio dwarves flex gcc libc6-dev libelf-dev libssl-dev make python3 xz-utils >/dev/null

# Same path every build: it is in the kernel's debug info, so it is part of the result.
rm -rf /kbuild/linux
mkdir -p /kbuild/linux
tar -xf /in/linux.tar.xz -C /kbuild/linux --strip-components=1
cd /kbuild/linux
cp /in/config-arm64 .config
scripts/kconfig/merge_config.sh -m -O . .config /in/config-pratico >/dev/null
make -s ARCH=arm64 olddefconfig
missing=0
while IFS= read -r line; do
    case "$line" in
        CONFIG_*|"# CONFIG_"*" is not set") grep -qxF "$line" .config || { echo "kernel: $line did not survive olddefconfig" >&2; missing=1; } ;;
    esac
done < /in/config-pratico
[ "$missing" = 0 ]

export KBUILD_BUILD_USER=pratico KBUILD_BUILD_HOST=pratico KBUILD_BUILD_VERSION=1
# JOBS=1: pahole encodes BTF on one thread, deterministic whatever pahole's version.
make -s ARCH=arm64 -j"$(nproc)" JOBS=1 LOCALVERSION=-pratico Image
cp arch/arm64/boot/Image /out/vmlinux
cp .config /out/config
# The kernel's types, for the guest's BPF probes (scripts/build-bpf.sh): built against
# this kernel's own layout, so they need no relocation at load.
objcopy -O binary --only-section=.BTF vmlinux /out/vmlinux.btf
echo "kernel: $(make -s ARCH=arm64 LOCALVERSION=-pratico kernelrelease)"
