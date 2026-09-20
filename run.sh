#!/bin/bash
# Quick dev-loop build+launch: Debug config, uses Xcode's normal DerivedData
# (faster incremental builds than build.sh's clean Release export). For a
# stable .app to drag into /Applications, use build.sh instead.
set -euo pipefail

cd "$(dirname "$0")"

xcodegen generate
xcodebuild -project ADBScreen.xcodeproj -scheme ADBScreen -configuration Debug build

APP_PATH="$(xcodebuild -project ADBScreen.xcodeproj -scheme ADBScreen -configuration Debug -showBuildSettings 2>/dev/null \
  | awk -F'= ' '/BUILT_PRODUCTS_DIR/{print $2; exit}')/ADBScreen.app"

osascript -e 'tell application "ADBScreen" to quit' 2>/dev/null || true
# Launch the freshly built bundle, not a stale instance registered with
# LaunchServices under the same bundle identifier.
open -n "$APP_PATH"
echo "Launched: $APP_PATH"
