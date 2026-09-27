#!/bin/zsh
# Packages build/Ferah.app into build/Ferah-<version>.dmg with an Applications shortcut.
# Usage: scripts/make-dmg.sh   (builds a release app first)
#
# To distribute outside your own Mac, sign with a Developer ID and notarize:
#   xcrun notarytool store-credentials ferah-notary --apple-id <id> --team-id <team>   (once)
#   SIGN_IDENTITY="Developer ID Application: …" NOTARY_PROFILE=ferah-notary scripts/make-dmg.sh
set -euo pipefail
cd "${0:A:h}/.."

scripts/build-app.sh release
version=$(plutil -extract CFBundleShortVersionString raw Resources/Info.plist)
dmg=build/Ferah-$version.dmg
stage=build/dmg
rm -rf "$stage" "$dmg"
mkdir -p "$stage"
cp -R build/Ferah.app "$stage/"
ln -s /Applications "$stage/Applications"
hdiutil create -volname "Ferah" -srcfolder "$stage" -fs HFS+ -format UDZO -ov "$dmg" >/dev/null
rm -rf "$stage"
hdiutil verify "$dmg" >/dev/null

if [[ -n ${NOTARY_PROFILE:-} ]]; then
  # Read the whole output first: awk exiting early would SIGPIPE codesign and trip pipefail.
  signature=$(codesign -dvv build/Ferah.app 2>&1)
  identity=$(awk -F= '/^Authority=Developer ID Application/ {print $2; exit}' <<< "$signature")
  [[ -n $identity ]] || { echo "Notarizing needs a Developer ID Application signature (set SIGN_IDENTITY)" >&2; exit 1; }
  codesign --force --timestamp --sign "$identity" "$dmg"
  xcrun notarytool submit "$dmg" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$dmg"
  spctl --assess --type open --context context:primary-signature "$dmg"
  echo "Created and notarized $dmg"
else
  echo "Created $dmg (not notarized: set NOTARY_PROFILE to notarize)"
fi
