#!/bin/bash
# Runs inside the build container (scripts/build-kernel.sh): installs a toolchain from a
# fixed Debian snapshot, then builds the kernel from the verified tarball in /in.
set -euo pipefail
: "${APT_SNAPSHOT:?}" "${KBUILD_BUILD_TIMESTAMP:?}"

rm -f /etc/apt/sources.list.d/*
cat > /etc/apt/sources.list.d/snapshot.sources <<SOURCES
Types: deb
URIs: http://snapshot.debian.org/archive/debian/$APT_SNAPSHOT
Suites: trixie trixie-updates
Components: main
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg

Types: deb
URIs: http://snapshot.debian.org/archive/debian-security/$APT_SNAPSHOT
Suites: trixie-security
Components: main
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg
SOURCES
apt-get -qq -o Acquire::Check-Valid-Until=false update
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
echo "kernel: $(make -s ARCH=arm64 LOCALVERSION=-pratico kernelrelease)"
