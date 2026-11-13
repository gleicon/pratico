#!/usr/bin/env bash
# Cuts a GitHub release: version tag vX.Y.Z[-pre] plus the DMG and its SHA-256.
# Refuses to run unless the version is proper semver, matches the code and
# Info.plist, the tree is clean, and the tag does not exist yet.
# Usage: scripts/release.sh <version>    (or: make release VERSION=x.y.z)
#   SKIP_E2E=1   skip the end-to-end suite (unit tests still run)
#   PRERELEASE=1 mark the GitHub release as a pre-release (implied by a -suffix)
set -euo pipefail

VERSION="${1:?usage: scripts/release.sh <version>}"
TAG="v$VERSION"
die() { echo "release: $*" >&2; exit 1; }

[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?$ ]] || die "'$VERSION' is not semver (x.y.z or x.y.z-pre)"
code_version=$(sed -n 's/.*static let version = "\(.*\)"/\1/p' Sources/PraticoCore/Pratico.swift)
plist_version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Support/Info.plist)
[ "$code_version" = "$VERSION" ] || die "Pratico.version is $code_version, not $VERSION"
# Apple requires a plain x.y.z here, so a -pre suffix is not part of it.
[ "$plist_version" = "${VERSION%%-*}" ] || die "Info.plist CFBundleShortVersionString is $plist_version, not ${VERSION%%-*}"
[ -z "$(git status --porcelain)" ] || die "working tree is not clean"
git rev-parse -q --verify "refs/tags/$TAG" >/dev/null && die "tag $TAG already exists locally"
git ls-remote --exit-code --tags origin "refs/tags/$TAG" >/dev/null 2>&1 && die "tag $TAG already exists on origin"
command -v gh >/dev/null || die "gh is required"
gh auth status >/dev/null 2>&1 || die "gh is not logged in"

make test
[ "${SKIP_E2E:-0}" = 1 ] || make e2e
make dmg VERSION="$VERSION"
DMG="dist/Pratico-$VERSION.dmg"
hdiutil verify "$DMG" >/dev/null
(cd dist && shasum -a 256 "Pratico-$VERSION.dmg" >"Pratico-$VERSION.dmg.sha256")

git tag -a "$TAG" -m "Pratico $VERSION"
git push origin HEAD
git push origin "$TAG"

flags=()
if [ "${PRERELEASE:-0}" = 1 ] || [[ "$VERSION" == *-* ]]; then flags+=(--prerelease); fi
gh release create "$TAG" "$DMG" "$DMG.sha256" --title "Pratico $VERSION" --verify-tag "${flags[@]}" \
    --notes "$(printf 'Ad-hoc signed, not notarized: approve the first launch in System Settings > Privacy & Security ("Open Anyway"), or run `xattr -dr com.apple.quarantine /Applications/Pratico.app`. Requires macOS 26 on Apple silicon; nothing else to install.\n\nSHA-256: %s' "$(cut -d' ' -f1 "$DMG.sha256")")"
echo "released $TAG"
