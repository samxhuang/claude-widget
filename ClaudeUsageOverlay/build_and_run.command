#!/bin/bash
set -e
cd "$(dirname "$0")"

echo "==> Building Claude Usage Overlay (this can take a minute the first time)..."
swift build -c release
echo "==> Build succeeded."

echo "==> Killing any running instance..."
pkill -f "ClaudeUsageOverlay.app/Contents/MacOS/ClaudeUsageOverlay" 2>/dev/null || true
sleep 1

echo "==> Packaging as ClaudeUsageOverlay.app..."
APP="ClaudeUsageOverlay.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp Info.plist "$APP/Contents/Info.plist"
cp .build/release/ClaudeUsageOverlay "$APP/Contents/MacOS/ClaudeUsageOverlay"

# Ad-hoc sign the bundle (R-4): unsigned arm64 binaries won't launch at all,
# and a consistent bundle signature keeps Gatekeeper's story to the documented
# "unidentified developer -> right-click Open" path instead of "damaged".
# (A Developer ID + notarization step would replace this for a "real" release.)
echo "==> Ad-hoc signing..."
codesign --force --deep -s - "$APP"

LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister"
if [ -x "$LSREGISTER" ]; then
  echo "==> Registering with Launch Services..."
  "$LSREGISTER" -f "$(pwd)/$APP"
fi

echo "==> Launching app (look for the gauge icon in your menu bar)..."
open "$APP"

sleep 1
echo "==> Done. You can close this window now."
