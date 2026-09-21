#!/bin/bash
# Fully uninstalls ADBScreen: quits it, resets every macOS privacy
# permission it was ever granted (Local Network, Screen Recording, ...),
# forgets its app preferences (remembered devices/connections, onboarding
# state, window layout), resets Mac-wide iOS device pairing (so "Trust
# This Computer?" has to happen again), and removes the installed .app.
set -euo pipefail

cd "$(dirname "$0")"

BUNDLE_ID="com.felixbusch.adbscreen"

echo "==> Quitting ADBScreen (if running)"
osascript -e 'tell application "ADBScreen" to quit' 2>/dev/null || true

echo "==> Resetting macOS privacy permissions for $BUNDLE_ID"
tccutil reset All "$BUNDLE_ID"

echo "==> Forgetting app preferences (remembered devices, onboarding state, window layout)"
defaults delete "$BUNDLE_ID" 2>/dev/null || true

# macOS/Xcode's own iPhone/iPad pairing record (created the first time any
# app on this Mac — Xcode, Finder, ADBScreen, ...— establishes a trusted
# developer connection to a given device) lives outside any app sandbox at
# /var/db/lockdown/<UDID>.plist and survives app uninstalls, "Forget This
# Device", and even removing the signing Team from the Xcode project — see
# USBiOSDiscovery's doc comment: this pairing is very likely what actually
# unlocks the `.muxed` AVCaptureDevice (direct iPhone/iPad-as-camera) path,
# not anything ADBScreen itself does. Wiping it here is the only way to get
# back to a truly "never trusted this Mac" state so onboarding/pairing can
# be re-tested from scratch. This is Mac-wide, not ADBScreen-specific: it
# re-triggers the "Trust This Computer?" prompt (and Xcode's own device
# pairing) for every iOS device previously paired with this Mac, not just
# the one used for testing.
echo "==> Resetting iOS device pairing records (/var/db/lockdown) — will re-trigger \"Trust This Computer?\" for ALL iOS devices on this Mac"
sudo rm -f /var/db/lockdown/*.plist 2>/dev/null || true

echo "==> Removing installed app"
if [ -d /Applications/ADBScreen.app ]; then
  rm -rf /Applications/ADBScreen.app
  echo "    removed /Applications/ADBScreen.app"
fi

echo "Done."
