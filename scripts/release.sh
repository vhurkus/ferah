#!/bin/zsh
# Publishes the version in Resources/Info.plist: notarized DMG, GitHub release, Homebrew tap update.
# Usage: bump CFBundleShortVersionString, commit, then: NOTARY_PROFILE=ferah-notary scripts/release.sh
set -euo pipefail
cd "${0:A:h}/.."

: "${NOTARY_PROFILE:?Set NOTARY_PROFILE (see scripts/make-dmg.sh)}"
version=$(plutil -extract CFBundleShortVersionString raw Resources/Info.plist)
tag="v$version"
dmg="build/Ferah-$version.dmg"

[[ -z $(git status --porcelain) ]] || { echo "Commit your changes first." >&2; exit 1; }
git rev-parse "$tag" >/dev/null 2>&1 && { echo "$tag already exists: bump the version first." >&2; exit 1; }

scripts/test.sh >/dev/null
scripts/make-dmg.sh
sha=$(shasum -a 256 "$dmg" | awk '{print $1}')

git tag "$tag"
git push origin HEAD "$tag"
gh release create "$tag" "$dmg" --repo vhurkus/ferah --title "Ferah $version" --generate-notes

# Point the tap's cask at the new release.
tap=$(mktemp -d)
gh repo clone vhurkus/homebrew-tap "$tap" -- --quiet
sed -i '' -e "s/^  version \".*\"/  version \"$version\"/" -e "s/^  sha256 \".*\"/  sha256 \"$sha\"/" "$tap/Casks/ferah.rb"
git -C "$tap" commit -qam "Update Ferah to $version"
git -C "$tap" push -q
rm -rf "$tap"
echo "Released Ferah $version: brew upgrade --cask ferah"
