#!/usr/bin/env bash
# The Linux host release (docs/design/remote.md): scripts/host-payload.sh's files in
# pratico-<version>-linux-arm64/, tarred owned by root and without macOS metadata, and its
# SHA-256. A host installs it with `sudo ./pratico-<version>-linux-arm64/pratico-daemon install`.
# Usage: scripts/linux-dist.sh <version> <out.tar.gz>
set -euo pipefail

VERSION="${1:?usage: scripts/linux-dist.sh <version> <out.tar.gz>}"
TAR="${2:?usage: scripts/linux-dist.sh <version> <out.tar.gz>}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
NAME="pratico-$VERSION-linux-arm64"
WORK="$ROOT/.build/linux-dist"

rm -rf "$WORK" && mkdir -p "$WORK/$NAME" "$(dirname "$TAR")"
"$ROOT/scripts/host-payload.sh" "$WORK/$NAME"
got=$(file -b "$WORK/$NAME/pratico-daemon")
case "$got" in *"ARM aarch64"*"statically linked"*) ;; *) echo "linux-dist: pratico-daemon is not a static arm64 binary: $got" >&2; exit 1 ;; esac
COPYFILE_DISABLE=1 tar -czf "$TAR" -C "$WORK" --no-mac-metadata --no-xattrs --uid 0 --gid 0 --uname root --gname root "$NAME"
(cd "$(dirname "$TAR")" && shasum -a 256 "$(basename "$TAR")" >"$(basename "$TAR").sha256")
echo "linux-dist: $TAR $(cut -d' ' -f1 "$TAR.sha256")"
