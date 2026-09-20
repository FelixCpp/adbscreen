#!/bin/bash
# Clean reinstall: resets every macOS privacy permission ADBScreen was ever
# granted (Local Network, Screen Recording, ...), forgets its app
# preferences (remembered devices/connections, onboarding state, window
# layout), removes any existing .app copy, then rebuilds fresh via
# build.sh — so the next launch starts from a truly blank slate and walks
# through the onboarding checklist again instead of auto-reconnecting to
# whatever was connected before.
set -euo pipefail

cd "$(dirname "$0")"

BUNDLE_ID="com.felixbusch.adbscreen"

echo "==> Quitting ADBScreen (if running)"
osascript -e 'tell application "ADBScreen" to quit' 2>/dev/null || true

echo "==> Resetting macOS privacy permissions for $BUNDLE_ID"
tccutil reset All "$BUNDLE_ID"

echo "==> Forgetting app preferences (remembered devices, onboarding state, window layout)"
defaults delete "$BUNDLE_ID" 2>/dev/null || true

echo "==> Removing existing app copies"
rm -rf build/ADBScreen.app
if [ -d /Applications/ADBScreen.app ]; then
  rm -rf /Applications/ADBScreen.app
  echo "    removed /Applications/ADBScreen.app"
fi

echo "==> Removing stale DerivedData (from Xcode/run.sh builds, not build.sh's own temp dir)"
find ~/Library/Developer/Xcode/DerivedData -maxdepth 1 -iname "ADBScreen-*" -exec rm -rf {} +

echo "==> Rebuilding"
./build.sh

echo ""
echo "Done. Move build/ADBScreen.app to /Applications, or run it in place with:"
echo "  open build/ADBScreen.app"
