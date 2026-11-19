#!/bin/bash
# Runs inside the build container (scripts/build-bpf.sh): installs clang and bpftool from
# a fixed Debian snapshot, writes the kernel's types as C from its BTF, and compiles the
# probes against them.
set -euo pipefail

source /in/snapshot.sh
DEBIAN_FRONTEND=noninteractive apt-get -qq install -y --no-install-recommends bpftool clang llvm >/dev/null

mkdir -p /work
cd /work
cp /in/recorder.bpf.c /in/recorder.h .
bpftool btf dump file /in/vmlinux.btf format c > vmlinux.h
# No debug info: it would carry the build path, and the loader reads only code, maps,
# and the symbols that name them.
clang -O2 -target bpf -mcpu=v3 -Wall -Werror -c recorder.bpf.c -o recorder.bpf.o
llvm-strip --strip-debug recorder.bpf.o
cp recorder.bpf.o /out/recorder.bpf.o
echo "bpf: $(clang --version | head -1)"
