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
# Same floor deploy_remote.sh enforces for remotes: the daemon uses 3.9+
# syntax/stdlib behavior, and an older exotic PATH python3 would pass install
# then crash-loop under launchd with no useful message.
if ! "$PYTHON3_BIN" -c 'import sys; raise SystemExit(0 if sys.version_info >= (3, 9) else 1)'; then
  echo "ERROR: python3 at $PYTHON3_BIN is older than 3.9."
  exit 1
fi

echo "    claude:  $CLAUDE_BIN"
echo "    python3: $PYTHON3_BIN"

echo "==> Installing daemon script to $INSTALL_DIR ..."
mkdir -p "$INSTALL_DIR" "$STATE_DIR/logs"
cp autoresume.py "$INSTALL_DIR/autoresume.py"
chmod +x "$INSTALL_DIR/autoresume.py"
# platform_compat.py: the OS seam (locks/paths/process table/spawn/atomic
# replace). Top-level import of autoresume.py, usage_collector.py, plan_fit.py
# and remote_ctl.py — the daemon will not start without it.
cp platform_compat.py "$INSTALL_DIR/platform_compat.py"
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
# deploy_remote.py is the stdlib-Python port of deploy_remote.sh (same marker
# protocol, no bash needed — see docs/windows-port-plan.md §1.4). Staged
# ALONGSIDE the .sh, not replacing it: HostDeployer.swift still runs the shell
# version, and the cutover waits on a real-remote verification.
cp deploy_remote.py "$INSTALL_DIR/deploy_remote.py"
chmod +x "$INSTALL_DIR/deploy_remote.py"
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
