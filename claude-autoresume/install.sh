#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

STATE_DIR="$HOME/.claude-autoresume"
INSTALL_DIR="$STATE_DIR/bin"
LAUNCH_AGENTS_DIR="$HOME/Library/LaunchAgents"
PLIST_LABEL="com.samhuang.claude-autoresume"
PLIST_PATH="$LAUNCH_AGENTS_DIR/$PLIST_LABEL.plist"

echo "==> Locating claude and python3..."
CLAUDE_BIN="$(command -v claude || true)"
if [ -z "$CLAUDE_BIN" ]; then
  echo "ERROR: could not find 'claude' on your PATH."
  echo "Install/locate Claude Code first, then re-run this script."
  exit 1
fi
CLAUDE_BIN_DIR="$(dirname "$CLAUDE_BIN")"

PYTHON3_BIN="$(command -v python3 || true)"
if [ -z "$PYTHON3_BIN" ]; then
  echo "ERROR: could not find 'python3' on your PATH."
  exit 1
fi

echo "    claude:  $CLAUDE_BIN"
echo "    python3: $PYTHON3_BIN"

echo "==> Installing daemon script to $INSTALL_DIR ..."
mkdir -p "$INSTALL_DIR" "$STATE_DIR/logs"
cp autoresume.py "$INSTALL_DIR/autoresume.py"
chmod +x "$INSTALL_DIR/autoresume.py"
cp cowork_resume.py "$INSTALL_DIR/cowork_resume.py"
cp usage_collector.py "$INSTALL_DIR/usage_collector.py"
cp plan_fit.py "$INSTALL_DIR/plan_fit.py"
cp autoresume_config.py "$INSTALL_DIR/autoresume_config.py"

echo "==> Staging remote-deploy payload into $INSTALL_DIR ..."
# The widget invokes deploy_remote.sh at runtime (Add Host in Settings), so the
# script, the service-unit template, and remote_ctl.py must all live beside the
# daemon payload it ships.
cp remote_ctl.py "$INSTALL_DIR/remote_ctl.py"
chmod +x "$INSTALL_DIR/remote_ctl.py"
cp deploy_remote.sh "$INSTALL_DIR/deploy_remote.sh"
chmod +x "$INSTALL_DIR/deploy_remote.sh"
cp autoresume.service.template "$INSTALL_DIR/autoresume.service.template"
# remote_sync.py is authored by a parallel workstream (WS-4). Guard its copy so
# install.sh still succeeds if run before that file lands; every other cp above
# hard-fails as before.
cp -f remote_sync.py "$INSTALL_DIR/remote_sync.py" 2>/dev/null || \
  echo "    (remote_sync.py not present yet — skipping; Mac-side sync arrives with WS-4)"

echo "==> Writing LaunchAgent plist to $PLIST_PATH ..."
mkdir -p "$LAUNCH_AGENTS_DIR"
sed \
  -e "s|__PYTHON3__|$PYTHON3_BIN|g" \
  -e "s|__SCRIPT_PATH__|$INSTALL_DIR/autoresume.py|g" \
  -e "s|__CLAUDE_BIN__|$CLAUDE_BIN|g" \
  -e "s|__CLAUDE_BIN_DIR__|$CLAUDE_BIN_DIR|g" \
  -e "s|__STATE_DIR__|$STATE_DIR|g" \
  com.samhuang.claude-autoresume.plist.template > "$PLIST_PATH"

echo "==> Loading LaunchAgent..."
# Unload first in case a previous version is already running.
launchctl bootout "gui/$(id -u)" "$PLIST_PATH" >/dev/null 2>&1 || true
launchctl bootstrap "gui/$(id -u)" "$PLIST_PATH"
launchctl enable "gui/$(id -u)/$PLIST_LABEL"

echo "==> Done."
echo ""
echo "The daemon is now running in the background and will also start automatically at login."
echo "Logs:"
echo "  $STATE_DIR/daemon.log        (what it's doing)"
echo "  $STATE_DIR/logs/<session>.log (output from each auto-resumed session)"
echo ""
echo "To check it's alive:   launchctl print gui/$(id -u)/$PLIST_LABEL"
echo "To uninstall:          ./uninstall.sh"
