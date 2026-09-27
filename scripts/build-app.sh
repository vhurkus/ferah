#!/bin/zsh
# Builds build/Ferah.app with the Command Line Tools (no Xcode needed).
# Usage: scripts/build-app.sh [debug|release]   (default: release)
set -euo pipefail
cd "${0:A:h}/.."

config=${1:-release}
# SwiftPM with the Command Line Tools stamps the deployment target (15.0) as the SDK version.
# macOS then treats the app as built with an old SDK and draws it in compatibility mode
# (old title bar, misaligned sidebar edge). Stamp the real SDK version instead.
sdk=$(xcrun --show-sdk-version)
flags=(-Xlinker -platform_version -Xlinker macos -Xlinker 15.0 -Xlinker "$sdk")
swift build -c "$config" "${flags[@]}"
bin="$(swift build -c "$config" "${flags[@]}" --show-bin-path)/MacCleaner"

app=build/Ferah.app
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin" "$app/Contents/MacOS/Ferah"
cp Resources/Info.plist "$app/Contents/Info.plist"
cp -R Resources/*.lproj "$app/Contents/Resources/"
plutil -lint "$app/Contents/Info.plist" >/dev/null

# App icon from Design/AppIcon-1024.png (render it with Design/make-icon.swift).
iconset=build/AppIcon.iconset
rm -rf "$iconset" && mkdir -p "$iconset"
for s in 16 32 128 256 512; do
  sips -z $s $s Design/AppIcon-1024.png --out "$iconset/icon_${s}x${s}.png" >/dev/null
  sips -z $((s * 2)) $((s * 2)) Design/AppIcon-1024.png --out "$iconset/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$iconset" -o "$app/Contents/Resources/AppIcon.icns"

otool -l "$app/Contents/MacOS/Ferah" | grep -q "sdk $sdk" || { echo "SDK version stamp missing" >&2; exit 1; }

# Sign with a stable identity when one exists, so macOS privacy grants (Full Disk Access)
# survive rebuilds. Override with SIGN_IDENTITY=-, or a "Developer ID Application: …" name to distribute.
# Prefers Developer ID (needed to distribute), then Apple Development.
identities=$(security find-identity -v -p codesigning)
found=$(awk -F'"' '/Developer ID Application/ {print $2; exit}' <<< "$identities")
[[ -n $found ]] || found=$(awk -F'"' '/Apple Development/ {print $2; exit}' <<< "$identities")
identity=${SIGN_IDENTITY:-$found}
identity=${identity:--}
# Notarization needs a secure timestamp; only release builds signed with a Developer ID get one.
timestamp=--timestamp=none
[[ $config == release && $identity == "Developer ID Application"* ]] && timestamp=--timestamp
codesign --force --options runtime $timestamp --entitlements Resources/Ferah.entitlements --sign "$identity" "$app"
codesign --verify --strict "$app"
echo "Built $app ($config, signed: $identity)"
