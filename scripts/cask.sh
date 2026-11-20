#!/usr/bin/env bash
# Publishes the Homebrew cask for a released version to the tap, from Support/cask.rb and
# the release's own .sha256. Rerunnable; release.sh runs it after publishing the DMG.
# Usage: scripts/cask.sh <version>
#   TAP=<owner/repo>  the tap repository (default gleicon/homebrew-pratico)
set -euo pipefail

VERSION="${1:?usage: scripts/cask.sh <version>}"
TAP="${TAP:-gleicon/homebrew-pratico}"
REPO=gleicon/pratico
FILE=Casks/pratico.rb
die() { echo "cask: $*" >&2; exit 1; }

[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "'$VERSION' is not a plain x.y.z version"
command -v gh >/dev/null || die "gh is required"
sha=$(gh release download "v$VERSION" -R "$REPO" -p "Pratico-$VERSION.dmg.sha256" -O - | cut -d' ' -f1)
[[ "$sha" =~ ^[0-9a-f]{64}$ ]] || die "no SHA-256 published for v$VERSION"

cask=$(sed -e "s/@VERSION@/$VERSION/" -e "s/@SHA256@/$sha/" "$(dirname "$0")/../Support/cask.rb")
current=$(gh api "repos/$TAP/contents/$FILE" --jq .sha 2>/dev/null || true)
args=(-f message="pratico $VERSION" -f content="$(printf '%s\n' "$cask" | base64)")
[ -z "$current" ] || args+=(-f sha="$current")
gh api -X PUT "repos/$TAP/contents/$FILE" "${args[@]}" >/dev/null
echo "cask: $TAP at $VERSION"
