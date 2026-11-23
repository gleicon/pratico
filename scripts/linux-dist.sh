#!/usr/bin/env bash
# The Linux host release (docs/design/remote.md): scripts/host-payload.sh's files in
# pratico-<version>-linux-<arch>/, tarred owned by root and without macOS metadata, and its
# SHA-256. A host installs it with `sudo ./pratico-<version>-linux-<arch>/pratico-daemon install`.
# Usage: [KARCH=x86_64] scripts/linux-dist.sh <version> <out.tar.gz>
set -euo pipefail

VERSION="${1:?usage: scripts/linux-dist.sh <version> <out.tar.gz>}"
TAR="${2:?usage: scripts/linux-dist.sh <version> <out.tar.gz>}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
KARCH="${KARCH:-arm64}"
export KARCH
NAME="pratico-$VERSION-linux-$KARCH"
WORK="$ROOT/.build/linux-dist-$KARCH"

rm -rf "$WORK" && mkdir -p "$WORK/$NAME" "$(dirname "$TAR")"
"$ROOT/scripts/host-payload.sh" "$WORK/$NAME"
got=$(file -b "$WORK/$NAME/pratico-daemon")
want=$([ "$KARCH" = arm64 ] && echo "ARM aarch64" || echo "x86-64")
case "$got" in *"$want"*"statically linked"*) ;; *) echo "linux-dist: pratico-daemon is not a static $KARCH binary: $got" >&2; exit 1 ;; esac
COPYFILE_DISABLE=1 tar -czf "$TAR" -C "$WORK" --no-mac-metadata --no-xattrs --uid 0 --gid 0 --uname root --gname root "$NAME"
(cd "$(dirname "$TAR")" && shasum -a 256 "$(basename "$TAR")" >"$(basename "$TAR").sha256")
echo "linux-dist: $TAR $(cut -d' ' -f1 "$TAR.sha256")"
