#!/bin/bash
# Builds ADBScreen and exports it to ./build/ADBScreen.app — a stable path
# (unlike Xcode's DerivedData, which gets a fresh random path on a clean
# build) that you can drag straight into /Applications.
set -euo pipefail

cd "$(dirname "$0")"

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

echo ""
echo "Done: $(pwd)/build/ADBScreen.app"
echo "Move it to /Applications, or run it in place with:"
echo "  open build/ADBScreen.app"
