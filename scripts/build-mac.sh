#!/bin/zsh
# Builds a Release LocalScribe.app for this Mac and packages it as dist/LocalScribe.dmg.
# Signed "to run locally" (ad-hoc): no expiry, no Apple account needed.
set -euo pipefail
cd "$(dirname "$0")/.."

ROOT=$PWD
BUILD="$ROOT/build.noindex"   # .noindex: Spotlight and Launchpad ignore build products
DIST="$ROOT/dist"

xcodegen generate --quiet
xcodebuild -project LocalScribe.xcodeproj -scheme LocalScribe -configuration Release \
  -destination 'platform=macOS' -derivedDataPath "$BUILD" \
  CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= \
  build | grep -E "error:|warning: .*App/|BUILD" || true

APP="$BUILD/Build/Products/Release/LocalScribe.app"
[[ -d "$APP" ]] || { echo "Build failed"; exit 1; }

rm -rf "$DIST" && mkdir -p "$DIST/dmg"
cp -R "$APP" "$DIST/dmg/"
ln -s /Applications "$DIST/dmg/Applications"
hdiutil create -volname "LocalScribe" -srcfolder "$DIST/dmg" -ov -format UDZO "$DIST/LocalScribe.dmg" >/dev/null
rm -rf "$DIST/dmg"
# Keep Launchpad tidy: the build product shouldn't show up as a second LocalScribe.
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u "$APP" >/dev/null 2>&1 || true
echo "Created $DIST/LocalScribe.dmg"
