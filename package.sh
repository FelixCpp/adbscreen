#!/bin/bash
# Builds a distributable ADBScreen.dmg for handing to other people.
#
# Unlike build.sh/run.sh (which are ad-hoc-signed for local development and
# never leave your machine), this script produces an artifact meant to run
# on *someone else's* Mac, which means Gatekeeper needs to trust it:
#
#   - Ad-hoc signing (the project.yml default, CODE_SIGN_IDENTITY="-") is
#     only trusted on the machine that built it. On any other Mac, macOS
#     shows "ADBScreen is damaged and can't be opened" and refuses to run it.
#   - A real Developer ID Application signature + Apple notarization is
#     what makes Gatekeeper accept the app on other people's machines.
#
# Usage:
#   ./package.sh
#     -> ad-hoc build, unsigned/unnotarized DMG for testing the packaging
#        flow itself (still won't run un-quarantined on other Macs).
#
#   DEVELOPER_ID_APPLICATION="Developer ID Application: Jane Doe (TEAMID)" \
#   NOTARY_PROFILE="adbscreen-notary" \
#   ./package.sh
#     -> signs with your Developer ID, submits to Apple for notarization
#        using credentials stored via:
#          xcrun notarytool store-credentials adbscreen-notary \
#            --apple-id you@example.com --team-id TEAMID --password <app-specific-password>
#        and staples the notarization ticket to the DMG. This is the
#        artifact you actually hand out.
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="ADBScreen"
DEVELOPER_ID_APPLICATION="${DEVELOPER_ID_APPLICATION:-}"
NOTARY_PROFILE="${NOTARY_PROFILE:-}"
ENTITLEMENTS="Sources/ADBScreen/ADBScreen.entitlements"

echo "==> Regenerating Xcode project"
xcodegen generate

VERSION="$(xcodebuild -project "$APP_NAME.xcodeproj" -scheme "$APP_NAME" -showBuildSettings 2>/dev/null \
  | awk -F'= ' '/ MARKETING_VERSION/{print $2; exit}')"
VERSION="${VERSION:-0.0.0}"

echo "==> Building (Release, version $VERSION)"
DERIVED_DATA="$(mktemp -d)"
BUILD_ARGS=(
  -project "$APP_NAME.xcodeproj"
  -scheme "$APP_NAME"
  -configuration Release
  -derivedDataPath "$DERIVED_DATA"
)

if [ -n "$DEVELOPER_ID_APPLICATION" ]; then
  echo "    Signing with: $DEVELOPER_ID_APPLICATION"
  BUILD_ARGS+=(
    CODE_SIGN_IDENTITY="$DEVELOPER_ID_APPLICATION"
    CODE_SIGNING_REQUIRED=YES
    CODE_SIGN_STYLE=Manual
    ENABLE_HARDENED_RUNTIME=YES
    OTHER_CODE_SIGN_FLAGS="--timestamp"
  )
else
  echo "    WARNING: DEVELOPER_ID_APPLICATION not set — building ad-hoc." >&2
  echo "    The resulting DMG will NOT open via Gatekeeper on other Macs." >&2
fi

xcodebuild "${BUILD_ARGS[@]}" build

BUILT_APP="$DERIVED_DATA/Build/Products/Release/$APP_NAME.app"
if [ ! -d "$BUILT_APP" ]; then
  echo "Build did not produce $APP_NAME.app — aborting." >&2
  exit 1
fi

if [ -n "$DEVELOPER_ID_APPLICATION" ]; then
  # xcodebuild's "Copy Bundle Resources" phase does NOT re-sign the nested
  # adbscreen-airplay-helper executable it copies in — only files placed
  # via "Embed"/"Copy Files (Code Sign on Copy)" phases get that. An
  # unsigned nested Mach-O binary makes Apple's notary service reject the
  # whole submission, so it's signed explicitly here before signing the
  # outer app bundle.
  echo "==> Re-signing embedded helper binary"
  codesign --force --options runtime --timestamp \
    --sign "$DEVELOPER_ID_APPLICATION" \
    "$BUILT_APP/Contents/Resources/adbscreen-airplay-helper"

  echo "==> Signing app bundle"
  codesign --force --deep --options runtime --timestamp \
    --entitlements "$ENTITLEMENTS" \
    --sign "$DEVELOPER_ID_APPLICATION" \
    "$BUILT_APP"

  echo "==> Verifying signature"
  codesign --verify --deep --strict --verbose=2 "$BUILT_APP"
fi

echo "==> Staging DMG contents"
rm -rf dist
mkdir -p dist
STAGING="$(mktemp -d)"
cp -R "$BUILT_APP" "$STAGING/$APP_NAME.app"
ln -s /Applications "$STAGING/Applications"

DMG_PATH="dist/$APP_NAME-$VERSION.dmg"
echo "==> Creating $DMG_PATH"
hdiutil create -volname "$APP_NAME" -srcfolder "$STAGING" -ov -format UDZO "$DMG_PATH"

rm -rf "$STAGING" "$DERIVED_DATA"

if [ -n "$DEVELOPER_ID_APPLICATION" ] && [ -n "$NOTARY_PROFILE" ]; then
  echo "==> Submitting to Apple notary service (this can take a few minutes)"
  xcrun notarytool submit "$DMG_PATH" --keychain-profile "$NOTARY_PROFILE" --wait

  echo "==> Stapling notarization ticket"
  xcrun stapler staple "$DMG_PATH"

  echo "==> Verifying Gatekeeper acceptance"
  spctl --assess --type open --context context:primary-signature -v "$DMG_PATH"
elif [ -n "$DEVELOPER_ID_APPLICATION" ]; then
  echo "==> Skipping notarization (NOTARY_PROFILE not set)"
  echo "    The DMG is signed but Gatekeeper will still block it on other Macs until notarized."
fi

echo ""
echo "Done: $(pwd)/$DMG_PATH"
