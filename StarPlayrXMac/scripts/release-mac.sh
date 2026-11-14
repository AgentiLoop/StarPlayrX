#!/bin/zsh
# StarPlayrX for Mac — Developer ID release build.
#
# Full pipeline: archive (Universal) -> export (Developer ID) -> notarize app
# -> staple -> zip -> DMG (with /Applications symlink) -> sign + notarize DMG
# -> staple -> spctl verify -> sha256.
#
# Usage:
#   scripts/release-mac.sh 1.1.28 [build]   # bumps Info.plist + project.yml, commits, then builds
#   scripts/release-mac.sh 1.1.28            # builds without bumping (already bumped)
#   V=1.1.28 scripts/release-mac.sh          # env override for the version
#
# Requires:
#   - Xcode (xcodebuild, xcrun notarytool/stapler)
#   - A stored notary keychain profile (default: "App Store Connect Profile";
#     override with NOTARY_PROFILE=...)
#   - Team 469UCUB275 signing identity / provisioning (override with TEAM=...)
#
# Output: $OUT (default /tmp/spx-rel)
#   StarPlayrX-Mac-<V>.dmg / .zip, plus arch.xcarchive, out/StarPlayrX.app, logs.
# Publish afterwards with:
#   gh release create mac-<V> --target "$(git rev-parse HEAD)" --latest \
#     --notes-file notes.md /tmp/spx-rel/StarPlayrX-Mac-<V>.dmg /tmp/spx-rel/StarPlayrX-Mac-<V>.zip

set -e
setopt null_glob

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"          # repo root
PROJ="$ROOT/StarPlayrXMac/StarPlayrXMac.xcodeproj"
INFO_PLIST="$ROOT/StarPlayrXMac/Sources/Info.plist"
PROJECT_YML="$ROOT/StarPlayrXMac/project.yml"

V="${1:-${V:-}}"
BUILD="${2:-}"
[ -n "$V" ] || { echo "usage: $0 <version> [build]   (or V=<version> $0)" >&2; exit 2; }

R="${OUT:-/tmp/spx-rel}"
PROFILE="${NOTARY_PROFILE:-App Store Connect Profile}"
TEAM="${TEAM:-469UCUB275}"
SIGN_ID="${SIGN_ID:-Developer ID Application: Todd Bruss ($TEAM)}"

# --- optional version bump ---------------------------------------------------
if [ -n "$BUILD" ]; then
  plutil -replace CFBundleShortVersionString -string "$V" "$INFO_PLIST"
  plutil -replace CFBundleVersion -string "$BUILD" "$INFO_PLIST"
  sed -i '' "s/^version: .*/version: $V/" "$PROJECT_YML"
  if [ -n "$(git -C "$ROOT" status --porcelain -- "$INFO_PLIST" "$PROJECT_YML")" ]; then
    git -C "$ROOT" add "$INFO_PLIST" "$PROJECT_YML"
    git -C "$ROOT" commit -m "Bump StarPlayrXMac to $V (build $BUILD)" >/dev/null
    echo "== bumped to $V (build $BUILD), committed $(git -C "$ROOT" rev-parse --short HEAD)"
  fi
fi

rm -rf $R/arch.xcarchive $R/out $R/dmg $R/notarize.zip \
       $R/StarPlayrX-Mac-$V.zip $R/StarPlayrX-Mac-$V.dmg
mkdir -p $R/out $R/dmg

cat > $R/export.plist <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>method</key><string>developer-id</string>
<key>signingStyle</key><string>automatic</string>
<key>teamID</key><string>$TEAM</string>
</dict></plist>
EOF

echo "== archive ($V)"
xcodebuild archive -project "$PROJ" -scheme StarPlayrXMac -configuration Release \
  -archivePath $R/arch.xcarchive ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO \
  ENABLE_HARDENED_RUNTIME=YES DEVELOPMENT_TEAM=$TEAM -allowProvisioningUpdates | tail -3

echo "== export"
xcodebuild -exportArchive -archivePath $R/arch.xcarchive -exportPath $R/out \
  -exportOptionsPlist $R/export.plist -allowProvisioningUpdates | tail -3

APP=$R/out/StarPlayrX.app
# Date.<= / Date.>= are @backDeployed(before: macOS 27.2): weak-linked, and missing from early 27.2 betas (jump to 0x0).
if nm -m -arch all "$APP/Contents/MacOS/StarPlayrX" | grep -q 'weak external _\$s10Foundation4DateV2[lg]eoi'; then
  echo "== ABORT: binary weak-links Date.<= / Date.>= (write !(a > b) / !(a < b) instead)" >&2; exit 1
fi
codesign -dv --verbose=2 "$APP" 2>&1 | grep -E "Authority=Developer|flags|TeamIdentifier"
lipo -archs "$APP/Contents/MacOS/StarPlayrX"
plutil -p "$APP/Contents/Info.plist" | grep -E "CFBundleShortVersionString|CFBundleVersion"

echo "== notarize app"
ditto -c -k --keepParent "$APP" $R/notarize.zip
xcrun notarytool submit $R/notarize.zip --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$APP"
ditto -c -k --keepParent "$APP" $R/StarPlayrX-Mac-$V.zip

echo "== dmg"
cp -R "$APP" $R/dmg/
ln -s /Applications $R/dmg/Applications
hdiutil create -volname "StarPlayrX" -srcfolder $R/dmg -ov -format UDZO $R/StarPlayrX-Mac-$V.dmg
codesign --sign "$SIGN_ID" --timestamp $R/StarPlayrX-Mac-$V.dmg
xcrun notarytool submit $R/StarPlayrX-Mac-$V.dmg --keychain-profile "$PROFILE" --wait
xcrun stapler staple $R/StarPlayrX-Mac-$V.dmg

echo "== verify"
spctl -a -vv "$APP"
spctl -a -t open --context context:primary-signature -vv $R/StarPlayrX-Mac-$V.dmg
shasum -a 256 $R/StarPlayrX-Mac-$V.dmg $R/StarPlayrX-Mac-$V.zip
echo "== DONE  dmg+zip in $R (StarPlayrX-Mac-$V.*)"
