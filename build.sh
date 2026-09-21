#!/bin/bash
# Builds ADBScreen and installs it straight into /Applications/ADBScreen.app
# — no manual "mv"/drag-and-drop needed. Also keeps a copy at
# ./build/ADBScreen.app, a stable path (unlike Xcode's DerivedData, which
# gets a fresh random path on a clean build) useful for CI/inspection.
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="ADBScreen.app"
INSTALL_DIR="/Applications"
INSTALL_PATH="$INSTALL_DIR/$APP_NAME"

echo "==> Regenerating Xcode project"
xcodegen generate

echo "==> Building (Release)"
DERIVED_DATA="$(mktemp -d)"
xcodebuild \
  -project ADBScreen.xcodeproj \
  -scheme ADBScreen \
  -configuration Release \
  -derivedDataPath "$DERIVED_DATA" \
  build

BUILT_APP="$DERIVED_DATA/Build/Products/Release/ADBScreen.app"
if [ ! -d "$BUILT_APP" ]; then
  echo "Build did not produce ADBScreen.app — aborting." >&2
  exit 1
fi

echo "==> Exporting to ./build/ADBScreen.app"
rm -rf build
mkdir -p build
cp -R "$BUILT_APP" build/ADBScreen.app
rm -rf "$DERIVED_DATA"

echo "==> Installing to $INSTALL_PATH"
osascript -e 'tell application "ADBScreen" to quit' 2>/dev/null || true
if [ -w "$INSTALL_DIR" ]; then
  rm -rf "$INSTALL_PATH"
  cp -R build/ADBScreen.app "$INSTALL_PATH"
else
  echo "    $INSTALL_DIR not writable — retrying with sudo"
  sudo rm -rf "$INSTALL_PATH"
  sudo cp -R build/ADBScreen.app "$INSTALL_PATH"
fi

echo ""
echo "Done: $INSTALL_PATH"
echo "Launch it with:"
echo "  open \"$INSTALL_PATH\""
