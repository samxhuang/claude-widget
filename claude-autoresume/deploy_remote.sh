#!/bin/bash
# deploy_remote.sh — deploy (or remove) the claude-autoresume daemon on a
# remote host over ssh. Non-interactive and machine-parseable: every ssh/scp
# uses BatchMode so it NEVER prompts, and progress is emitted as marker lines
# for the widget's HostDeployer to drive its step checklist:
#
#   @@STEP:<connect|python|copy|service|start|verify>   at each stage start
#   @@OK version=<hash>                                 on success
#   @@FAIL:<short reason>                                on error
#
# Human-readable detail goes on plain surrounding lines. Exit code mirrors the
# final marker (0 on @@OK, 1 on @@FAIL). Works identically run by hand.
#
# Usage:
#   deploy_remote.sh <user@host|ssh-alias>              deploy
#   deploy_remote.sh <user@host|ssh-alias> --uninstall  stop + remove remote bin/
#
# Runs both from ~/.claude-autoresume/bin/ (payload staged beside it by
# install.sh) and from the repo checkout (payload = sibling .py files); the
# payload dir is resolved relative to this script's own location.

set -uo pipefail   # intentionally NOT -e: we emit @@FAIL ourselves on error

# --- marker helpers ---------------------------------------------------------
step() { echo "@@STEP:$1"; }
ok()   { echo "@@OK version=$1"; exit 0; }
fail() { echo "@@FAIL:$1"; exit 1; }

# --- args -------------------------------------------------------------------
HOST=""
UNINSTALL=0
for arg in "$@"; do
  case "$arg" in
    --uninstall) UNINSTALL=1 ;;
    -*) echo "unknown option: $arg" >&2; echo "usage: deploy_remote.sh <user@host|ssh-alias> [--uninstall]" >&2; exit 2 ;;
    *) if [ -z "$HOST" ]; then HOST="$arg"; else echo "unexpected extra argument: $arg" >&2; exit 2; fi ;;
  esac
done
if [ -z "$HOST" ]; then
  echo "usage: deploy_remote.sh <user@host|ssh-alias> [--uninstall]" >&2
  exit 2
fi

# --- resolve this script's directory (symlink-safe) -------------------------
SOURCE="${BASH_SOURCE[0]}"
while [ -h "$SOURCE" ]; do
  DIR="$(cd -P "$(dirname "$SOURCE")" && pwd)"
  SOURCE="$(readlink "$SOURCE")"
  [[ "$SOURCE" != /* ]] && SOURCE="$DIR/$SOURCE"
done
SCRIPT_DIR="$(cd -P "$(dirname "$SOURCE")" && pwd)"

SERVICE_TEMPLATE="$SCRIPT_DIR/autoresume.service.template"

# The .py payload shipped to the remote. remote_sync.py MUST be included:
# autoresume.py imports it unconditionally at module top (`import remote_sync`),
# so omitting it makes the remote daemon crash with ModuleNotFoundError before
# main() ever runs (systemd Restart=always then crash-loops every RestartSec).
# On a remote with no config.json its RemoteSync worker just idles harmlessly.
PAYLOAD_FILES=(autoresume.py platform_compat.py cowork_resume.py usage_collector.py plan_fit.py autoresume_config.py remote_ctl.py remote_sync.py)

# --- ssh/scp wrappers (never prompt) ---------------------------------------
SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=5)
rssh() { ssh "${SSH_OPTS[@]}" "$HOST" "$@"; }
rscp() { scp "${SSH_OPTS[@]}" "$@"; }

REMOTE_SERVICE="claude-autoresume.service"

# ===========================================================================
# Uninstall
# ===========================================================================
if [ "$UNINSTALL" -eq 1 ]; then
  step connect
  echo "Checking ssh to $HOST ..."
  rssh 'echo ok' >/dev/null 2>&1 || fail "connect: cannot ssh to $HOST (BatchMode; check key-based auth / host)"

  step service
  echo "Stopping and removing remote daemon on $HOST (state/transcripts left intact) ..."
  # Best-effort teardown of whichever install path is present.
  rssh '
    systemctl --user disable --now claude-autoresume.service >/dev/null 2>&1 || true
    rm -f ~/.config/systemd/user/claude-autoresume.service
    systemctl --user daemon-reload >/dev/null 2>&1 || true
    if [ -f ~/.claude-autoresume/daemon.pid ]; then
      kill "$(cat ~/.claude-autoresume/daemon.pid)" 2>/dev/null || true
      rm -f ~/.claude-autoresume/daemon.pid
    fi
    rm -rf ~/.claude-autoresume/bin
  ' || fail "service: uninstall commands failed on remote"
  echo "Removed ~/.claude-autoresume/bin and the service/pidfile; state.json, usage/, and transcripts untouched."
  ok "uninstalled"
fi

# ===========================================================================
# Deploy
# ===========================================================================

# Version = order-independent digest of the .py payload we are about to ship.
compute_version() {
  local sums
  if command -v sha256sum >/dev/null 2>&1; then
    sums=$(for f in "$@"; do sha256sum "$f"; done | awk '{print $1}' | sort | sha256sum | awk '{print $1}')
  elif command -v shasum >/dev/null 2>&1; then
    sums=$(for f in "$@"; do shasum -a 256 "$f"; done | awk '{print $1}' | sort | shasum -a 256 | awk '{print $1}')
  else
    return 1
  fi
  echo "${sums:0:12}"
}

# Resolve + validate local payload paths.
PAYLOAD_PATHS=()
for f in "${PAYLOAD_FILES[@]}"; do
  p="$SCRIPT_DIR/$f"
  if [ ! -f "$p" ]; then
    fail "copy: missing local payload file $f (looked in $SCRIPT_DIR)"
  fi
  PAYLOAD_PATHS+=("$p")
done
if [ ! -f "$SERVICE_TEMPLATE" ]; then
  fail "service: missing autoresume.service.template in $SCRIPT_DIR"
fi

VERSION="$(compute_version "${PAYLOAD_PATHS[@]}")" || fail "copy: cannot compute version hash (no sha256sum/shasum)"

# --- connect ---------------------------------------------------------------
step connect
echo "Checking ssh to $HOST ..."
rssh 'echo ok' >/dev/null 2>&1 || fail "connect: cannot ssh to $HOST (BatchMode never prompts — needs working key-based auth and a known host)"
echo "ssh ok."

# --- python preflight ------------------------------------------------------
# NOTE: we resolve the remote interpreter via `command -v python3` and install
# the daemon under it. The Mac-side remote_sync runtime, however, invokes the
# interpreter named in each host's config "python" field (see
# _remote_ctl_command in remote_sync.py). Those diverge only on a hand-edited
# config; a custom "python" MUST match what deploy installed with here, or
# remote_ctl runs under a different Python than the daemon.
step python
REMOTE_PY="$(rssh 'command -v python3 || true' 2>/dev/null | tr -d '\r')"
if [ -z "$REMOTE_PY" ]; then
  fail "python: python3 not found on remote PATH"
fi
if ! rssh 'python3 -c "import sys; sys.exit(0 if sys.version_info >= (3,9) else 1)"' >/dev/null 2>&1; then
  RV="$(rssh 'python3 -c "import sys;print(\"%d.%d\"%sys.version_info[:2])"' 2>/dev/null | tr -d '\r')"
  fail "python: remote python3 too old (need >= 3.9, found ${RV:-unknown})"
fi
echo "remote python3: $REMOTE_PY (>= 3.9)"

REMOTE_HOME="$(rssh 'echo $HOME' 2>/dev/null | tr -d '\r')"
[ -z "$REMOTE_HOME" ] && fail "python: could not resolve remote \$HOME"
CLAUDE_REMOTE="$(rssh 'command -v claude || true' 2>/dev/null | tr -d '\r')"
if [ -z "$CLAUDE_REMOTE" ]; then
  echo "warning: 'claude' not found on remote PATH — auto-resume will not be able to launch sessions there until it is installed."
fi

# --- copy ------------------------------------------------------------------
step copy
echo "Creating remote ~/.claude-autoresume/bin and copying payload ..."
rssh 'mkdir -p ~/.claude-autoresume/bin ~/.claude-autoresume/logs' || fail "copy: mkdir on remote failed"
rscp "${PAYLOAD_PATHS[@]}" "$HOST:.claude-autoresume/bin/" >/dev/null 2>&1 || fail "copy: scp of payload failed"
rssh 'chmod +x ~/.claude-autoresume/bin/autoresume.py ~/.claude-autoresume/bin/remote_ctl.py' >/dev/null 2>&1 || true
echo "copied: ${PAYLOAD_FILES[*]}"

# --- service ---------------------------------------------------------------
step service
# Detect a usable `systemctl --user`. A non-login ssh session often lacks
# XDG_RUNTIME_DIR/DBUS_SESSION_BUS_ADDRESS, so the plain probe fails even though
# the user bus is running — retry with them set explicitly before falling back
# to nohup. SYSTEMD_PREFIX (a literal string; the remote shell expands $(id -u))
# is prepended to every subsequent `systemctl --user` call so they hit the same
# bus the probe succeeded on.
USE_SYSTEMD=0
SYSTEMD_PREFIX=""
SYSTEMD_PATH=""
if rssh 'command -v systemctl >/dev/null 2>&1'; then
  if rssh 'systemctl --user show-environment >/dev/null 2>&1'; then
    USE_SYSTEMD=1
    SYSTEMD_PATH="systemd --user (default session bus)"
  elif rssh 'XDG_RUNTIME_DIR="/run/user/$(id -u)" DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$(id -u)/bus" systemctl --user show-environment >/dev/null 2>&1'; then
    USE_SYSTEMD=1
    SYSTEMD_PREFIX='XDG_RUNTIME_DIR="/run/user/$(id -u)" DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$(id -u)/bus" '
    SYSTEMD_PATH="systemd --user (explicit XDG_RUNTIME_DIR=/run/user/\$(id -u))"
  fi
fi

if [ "$USE_SYSTEMD" -eq 1 ]; then
  echo "service path: $SYSTEMD_PATH"
  echo "Installing systemd --user unit ..."
  RENDERED="$(mktemp 2>/dev/null || echo /tmp/claude-autoresume.service.$$)"
  trap 'rm -f "$RENDERED"' EXIT
  sed \
    -e "s|__PYTHON3__|$REMOTE_PY|g" \
    -e "s|__SCRIPT_PATH__|$REMOTE_HOME/.claude-autoresume/bin/autoresume.py|g" \
    -e "s|__CLAUDE_BIN__|$CLAUDE_REMOTE|g" \
    -e "s|__STATE_DIR__|$REMOTE_HOME/.claude-autoresume|g" \
    "$SERVICE_TEMPLATE" > "$RENDERED" || fail "service: rendering unit template failed"
  rssh 'mkdir -p ~/.config/systemd/user' || fail "service: mkdir ~/.config/systemd/user failed"
  rscp "$RENDERED" "$HOST:.config/systemd/user/$REMOTE_SERVICE" >/dev/null 2>&1 || fail "service: scp of unit file failed"
  rssh "${SYSTEMD_PREFIX}systemctl --user daemon-reload" || fail "service: systemctl --user daemon-reload failed"
  echo "unit installed at ~/.config/systemd/user/$REMOTE_SERVICE"
  # Linger keeps the user manager (and thus the daemon) alive after logout.
  if rssh 'loginctl enable-linger "$USER"' >/dev/null 2>&1; then
    echo "loginctl linger enabled (daemon survives logout)."
  else
    echo "warning: could not enable loginctl linger — the remote daemon may stop when you log out. Run 'loginctl enable-linger <user>' as an admin if you want it to persist."
  fi
else
  echo "service path: nohup + pidfile (no usable 'systemctl --user' on remote)"
fi

# --- start -----------------------------------------------------------------
step start
if [ "$USE_SYSTEMD" -eq 1 ]; then
  echo "Enabling and starting the service ..."
  rssh "${SYSTEMD_PREFIX}systemctl --user enable --now claude-autoresume.service" || fail "start: systemctl --user enable --now failed"
  echo "service enabled and started."
else
  echo "Starting daemon with nohup ..."
  # Kill any previous instance, then relaunch detached, recording the pid.
  rssh "
    if [ -f ~/.claude-autoresume/daemon.pid ]; then
      kill \"\$(cat ~/.claude-autoresume/daemon.pid)\" 2>/dev/null || true
    fi
    AUTORESUME_REMOTE=1 CLAUDE_BIN='$CLAUDE_REMOTE' nohup '$REMOTE_PY' ~/.claude-autoresume/bin/autoresume.py \
      </dev/null >> ~/.claude-autoresume/launchd.out.log 2>> ~/.claude-autoresume/launchd.err.log &
    echo \$! > ~/.claude-autoresume/daemon.pid
  " || fail "start: nohup launch failed"
  echo "daemon started (pid recorded in ~/.claude-autoresume/daemon.pid)."
fi

# --- verify ----------------------------------------------------------------
step verify
echo "Verifying remote_ctl.py dump ..."
DUMP="$(rssh 'python3 ~/.claude-autoresume/bin/remote_ctl.py dump' 2>/dev/null)"
if [ -z "$DUMP" ]; then
  fail "verify: remote_ctl.py dump returned no output"
fi
# Parse locally (we have python3 here) to confirm the contract shape.
if ! printf '%s' "$DUMP" | python3 -c 'import sys,json; d=json.load(sys.stdin); assert d.get("v")==1 and isinstance(d.get("state"),dict) and "now" in d' >/dev/null 2>&1; then
  fail "verify: remote_ctl.py dump did not return parseable {v,now,state}"
fi
echo "verify ok: remote_ctl.py dump returned a valid state envelope."

# The dump above is a STANDALONE remote_ctl.py invocation — it succeeds even if
# the *daemon* is dead (Type=simple/nohup both report "started" before the
# process crashes at import or in main()). So separately confirm the daemon is
# actually staying up: a payload/import failure crash-loops under
# Restart=always (RestartSec=5), which the dump check alone would never catch.
# Wait past one RestartSec window before judging so a single restart shows up.
echo "Confirming the daemon is staying up (waiting past one restart window) ..."
sleep 7
if [ "$USE_SYSTEMD" -eq 1 ]; then
  # A crash-looping unit is "activating"/"failed", or "active" with NRestarts>0
  # after our wait — a healthy one is "active" with NRestarts=0.
  ACTIVE="$(rssh "${SYSTEMD_PREFIX}systemctl --user is-active claude-autoresume.service" 2>/dev/null | tr -d '\r')"
  NRESTARTS="$(rssh "${SYSTEMD_PREFIX}systemctl --user show claude-autoresume.service -p NRestarts --value" 2>/dev/null | tr -d '\r')"
  if [ "$ACTIVE" != "active" ] || { [ -n "$NRESTARTS" ] && [ "$NRESTARTS" != "0" ]; }; then
    echo "daemon unhealthy: is-active=${ACTIVE:-unknown} NRestarts=${NRESTARTS:-unknown}"
    fail "verify: remote daemon is not staying up (crash-loop?) — check remote ~/.claude-autoresume/daemon.log and launchd.err.log"
  fi
  echo "verify ok: daemon active and stable (NRestarts=${NRESTARTS:-0})."
else
  # nohup path: confirm the recorded pid is still alive after the wait.
  DPID="$(rssh 'cat ~/.claude-autoresume/daemon.pid 2>/dev/null' 2>/dev/null | tr -d '\r')"
  if [ -z "$DPID" ] || ! rssh "kill -0 $DPID" >/dev/null 2>&1; then
    echo "daemon pid ${DPID:-unknown} not alive after start"
    fail "verify: remote daemon exited after launch (crash?) — check remote ~/.claude-autoresume/daemon.log and launchd.err.log"
  fi
  echo "verify ok: daemon pid $DPID still alive."
fi

ok "$VERSION"
