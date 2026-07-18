#!/bin/bash
set -euo pipefail

STATE_DIR="$HOME/.claude-autoresume"
LAUNCH_AGENTS_DIR="$HOME/Library/LaunchAgents"
PLIST_LABEL="com.samhuang.claude-autoresume"
PLIST_PATH="$LAUNCH_AGENTS_DIR/$PLIST_LABEL.plist"

echo "==> Stopping and unloading LaunchAgent..."
launchctl bootout "gui/$(id -u)" "$PLIST_PATH" >/dev/null 2>&1 || true
rm -f "$PLIST_PATH"

echo "==> Removed plist. Leaving logs and state in $STATE_DIR (delete manually if you don't want them)."
echo "Done."
