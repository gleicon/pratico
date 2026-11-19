#!/bin/bash
# Sourced by the build containers (vm/kernel/build.sh, vm/bpf/build.sh): points apt at
# Debian's archive as of $APT_SNAPSHOT, so every build installs the same packages.
: "${APT_SNAPSHOT:?}"
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
