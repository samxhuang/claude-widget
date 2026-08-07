#!/usr/bin/env python3
"""remote_ctl.py — Mac <-> remote-host state.json bridge (contract C4).

Runs on a REMOTE host (deployed to ~/.claude-autoresume/bin/ by
deploy_remote.sh) and is driven over ssh by the Mac's remote_sync worker. It
reads and mutates the remote host's own ~/.claude-autoresume/state.json under
the SAME flock the daemon uses (state.json.lock), so a `dump`/`apply-toggles`
call and a remote poll cycle can never interleave and lose an update.

Deliberately standalone: it does NOT import autoresume.py. The daemon runs
under the system python3 via systemd/nohup with no pip deps, and this script
must run in that same bare-stdlib environment on Linux and macOS, python3>=3.9.
It reimplements the state/config read-modify-write logic on purpose rather than
sharing autoresume.py's, so the deployed payload stays a flat set of files.

The one exception is `platform_compat` (also stdlib-only, also in the deploy
payload): the file-lock and atomic-replace PRIMITIVES must be bit-identical to
the daemon's or the cross-process locking protocol is broken by construction,
so they come from the shared OS seam rather than being re-typed here.

Commands (stdout is machine-readable JSON, one object, on success):
  dump            -> {"v":1,"now":<epoch float>,"state":{...},
                      "retention_minutes":N}                     (state read under flock)
  dump --usage    -> same, plus "tokens_hourly": {...}           (hourly lane only)
  apply-toggles   -> reads stdin JSON {"<sid>":{"enabled":bool,
                     "force_resume":bool,"resume_armed":bool}, ...}; applies
                     ONLY those whitelisted keys to EXISTING entries, under
                     flock, atomic save; prints {"ok":true,"applied":N}
  apply-config    -> reads stdin JSON {"sessions":{"idle_retention_minutes":N}}
                     and merges ONLY that one key into this host's
                     config.json (every other key preserved; file created if
                     absent), under a config.json.lock flock consistent with
                     the Mac side's config locking, atomic tmp+rename;
                     prints {"ok":true}. This is the ONE sanctioned non-widget
                     config.json writer, and only on a remote host, solely as
                     a relay of the widget's Settings — the daemon itself
                     still never writes config.json anywhere. The remote
                     daemon's poll loop re-reads config.json's sessions block
                     on mtime change (see autoresume.main), so the pushed
                     retention takes effect within one poll, no restart.

"retention_minutes" in dump is the host's EFFECTIVE
sessions.idle_retention_minutes (defaulted + clamped the same way
autoresume_config.load_config does it — reimplemented inline below because
this script must stay standalone).

A missing state.json is not an error: dump emits an empty state, apply-toggles
applies to nothing (0). Only keys present in each incoming entry are touched;
entries are never created and no other fields are modified.
"""

import json
import os
import sys
import time
from pathlib import Path

import platform_compat  # The ONE OS seam: FileLock + replace_with_retry

# Keys the Mac is allowed to push back into the remote state. Everything else
# in state.json is remote-daemon-owned and must be left untouched.
TOGGLE_KEYS = ("enabled", "force_resume", "resume_armed")

# Effective-retention defaults/clamps. Mirror autoresume_config's
# DEFAULT/MIN/MAX_IDLE_RETENTION_MINUTES — duplicated on purpose: this script
# must stay standalone (no imports beyond stdlib) on the remote host.
DEFAULT_IDLE_RETENTION_MINUTES = 30
MIN_IDLE_RETENTION_MINUTES = 5
MAX_IDLE_RETENTION_MINUTES = 24 * 60


def state_dir() -> Path:
    """Remote state directory. Matches the daemon's HOME/.claude-autoresume;
    AUTORESUME_STATE_DIR overrides it (used by tests and unusual layouts)."""
    override = os.environ.get("AUTORESUME_STATE_DIR")
    if override:
        return Path(override).expanduser()
    # NOTE: the daemon deliberately does NOT honor AUTORESUME_STATE_DIR (its
    # STATE_DIR is platform_compat.state_dir() flat), so the override lives
    # here and only here. Keep that asymmetry.
    return platform_compat.state_dir()


def state_file() -> Path:
    return state_dir() / "state.json"


def lock_file() -> Path:
    return state_dir() / "state.json.lock"


def tokens_hourly_file() -> Path:
    return state_dir() / "usage" / "tokens_hourly.json"


def config_file() -> Path:
    return state_dir() / "config.json"


def config_lock_file() -> Path:
    return state_dir() / "config.json.lock"


class StateLock:
    """Exclusive lock shared with the remote daemon's StateLock — same path,
    same primitive (platform_compat.FileLock), same semantics — so reads/writes
    here serialize against poll cycles."""

    def __enter__(self):
        state_dir().mkdir(parents=True, exist_ok=True)
        self._lock = platform_compat.FileLock(lock_file())
        self._lock.__enter__()
        return self

    def __exit__(self, *exc):
        self._lock.__exit__(*exc)


def load_state() -> dict:
    """Read state.json. Missing or unreadable/corrupt => empty dict (a remote
    host with no interrupted sessions is the normal cold-start case)."""
    path = state_file()
    if not path.exists():
        return {}
    try:
        data = json.loads(path.read_text())
    except (json.JSONDecodeError, OSError, ValueError):
        return {}
    return data if isinstance(data, dict) else {}


def save_state(state: dict) -> None:
    """Atomic tmp+rename write, mirroring autoresume.save_state so a reader
    (daemon or the widget) never observes a half-written file."""
    d = state_dir()
    d.mkdir(parents=True, exist_ok=True)
    tmp = state_file().with_suffix(".json.tmp")
    tmp.write_text(json.dumps(state, indent=2))
    platform_compat.replace_with_retry(tmp, state_file())


class ConfigLock:
    """Exclusive lock on config.json.lock — the same lock discipline the
    Mac's widget uses around its config.json writes, so an apply-config here
    can never interleave with any other config writer on this host."""

    def __enter__(self):
        state_dir().mkdir(parents=True, exist_ok=True)
        self._lock = platform_compat.FileLock(config_lock_file())
        self._lock.__enter__()
        return self

    def __exit__(self, *exc):
        self._lock.__exit__(*exc)


def _load_raw_config() -> dict:
    """config.json as-is (NO defaulting — apply-config must preserve every
    key it doesn't own). Missing/unreadable/malformed -> empty dict."""
    path = config_file()
    if not path.exists():
        return {}
    try:
        data = json.loads(path.read_text())
    except (json.JSONDecodeError, OSError, ValueError):
        return {}
    return data if isinstance(data, dict) else {}


def effective_retention_minutes() -> int:
    """The host's effective sessions.idle_retention_minutes: an
    autoresume_config.load_config-style defaulted+clamped read, inlined
    (minimal, stdlib-only) because remote_ctl stays standalone."""
    sessions = _load_raw_config().get("sessions")
    if not isinstance(sessions, dict):
        return DEFAULT_IDLE_RETENTION_MINUTES
    retention = sessions.get("idle_retention_minutes")
    if isinstance(retention, bool) or not isinstance(retention, (int, float)):
        return DEFAULT_IDLE_RETENTION_MINUTES
    return int(min(MAX_IDLE_RETENTION_MINUTES,
                   max(MIN_IDLE_RETENTION_MINUTES, retention)))


def load_tokens_hourly() -> dict:
    path = tokens_hourly_file()
    if not path.exists():
        return {}
    try:
        data = json.loads(path.read_text())
    except (json.JSONDecodeError, OSError, ValueError):
        return {}
    return data if isinstance(data, dict) else {}


def cmd_dump(with_usage: bool) -> int:
    # Take the state snapshot under the lock so it is internally consistent
    # with respect to concurrent daemon writes.
    with StateLock():
        state = load_state()
        now = time.time()
    out = {"v": 1, "now": now, "state": state,
           # Effective sessions.idle_retention_minutes on this host, so the
           # Mac's remote_sync can converge it with the widget's setting.
           "retention_minutes": effective_retention_minutes()}
    if with_usage:
        # Usage tokens live in usage/tokens_hourly.json, written atomically by
        # the collector; a plain read outside the state lock is fine.
        out["tokens_hourly"] = load_tokens_hourly()
    json.dump(out, sys.stdout)
    sys.stdout.write("\n")
    return 0


def cmd_apply_toggles() -> int:
    raw = sys.stdin.read()
    try:
        payload = json.loads(raw) if raw.strip() else {}
    except (json.JSONDecodeError, ValueError) as e:
        json.dump({"ok": False, "error": f"bad stdin json: {e}"}, sys.stdout)
        sys.stdout.write("\n")
        return 1
    if not isinstance(payload, dict):
        json.dump({"ok": False, "error": "stdin json must be an object"}, sys.stdout)
        sys.stdout.write("\n")
        return 1

    applied = 0
    with StateLock():
        state = load_state()
        changed = False
        for sid, updates in payload.items():
            entry = state.get(sid)
            # Never create entries; only touch sessions the remote daemon
            # already knows about.
            if not isinstance(entry, dict) or not isinstance(updates, dict):
                continue
            touched = False
            for key in TOGGLE_KEYS:
                if key in updates:
                    # Hardening: coerce to bool so a malformed payload can't
                    # write arbitrary JSON into widget-owned toggle fields.
                    entry[key] = bool(updates[key])
                    touched = True
            if touched:
                applied += 1
                changed = True
        if changed:
            save_state(state)
    json.dump({"ok": True, "applied": applied}, sys.stdout)
    sys.stdout.write("\n")
    return 0


def _fail(message: str) -> int:
    json.dump({"ok": False, "error": message}, sys.stdout)
    sys.stdout.write("\n")
    return 1


def cmd_apply_config() -> int:
    """Merge the widget's sessions.idle_retention_minutes into THIS host's
    config.json — the retention-relay write (see the module docstring for why
    this is the one sanctioned non-widget config writer). Touches ONLY that
    single key: every other top-level key, and every other key inside an
    existing "sessions" block, is preserved byte-for-byte at the JSON level.
    Runs under ConfigLock (config.json.lock flock), writes atomically
    (tmp+rename), creates the file if absent."""
    raw = sys.stdin.read()
    try:
        payload = json.loads(raw) if raw.strip() else {}
    except (json.JSONDecodeError, ValueError) as e:
        return _fail(f"bad stdin json: {e}")
    if not isinstance(payload, dict):
        return _fail("stdin json must be an object")
    sessions = payload.get("sessions")
    if not isinstance(sessions, dict):
        return _fail('missing "sessions" object')
    retention = sessions.get("idle_retention_minutes")
    if isinstance(retention, bool) or not isinstance(retention, (int, float)):
        return _fail('"sessions.idle_retention_minutes" must be a number')

    with ConfigLock():
        config = _load_raw_config()
        existing_sessions = config.get("sessions")
        if not isinstance(existing_sessions, dict):
            existing_sessions = {}
        existing_sessions["idle_retention_minutes"] = retention
        config["sessions"] = existing_sessions
        d = state_dir()
        d.mkdir(parents=True, exist_ok=True)
        tmp = config_file().with_suffix(".json.tmp")
        tmp.write_text(json.dumps(config, indent=2))
        platform_compat.replace_with_retry(tmp, config_file())

    json.dump({"ok": True}, sys.stdout)
    sys.stdout.write("\n")
    return 0


def main(argv) -> int:
    args = argv[1:]
    if not args:
        sys.stderr.write("usage: remote_ctl.py {dump [--usage] | apply-toggles | apply-config}\n")
        return 2
    cmd = args[0]
    rest = args[1:]
    if cmd == "dump":
        return cmd_dump(with_usage=("--usage" in rest))
    if cmd == "apply-toggles":
        return cmd_apply_toggles()
    if cmd == "apply-config":
        return cmd_apply_config()
    sys.stderr.write(f"unknown command: {cmd}\n")
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
