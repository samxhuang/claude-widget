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
It reimplements the flock + atomic tmp+rename write on purpose rather than
sharing code, so the deployed payload stays a flat set of files.

Commands (stdout is machine-readable JSON, one object, on success):
  dump            -> {"v":1,"now":<epoch float>,"state":{...}}   (state read under flock)
  dump --usage    -> same, plus "tokens_hourly": {...}           (hourly lane only)
  apply-toggles   -> reads stdin JSON {"<sid>":{"enabled":bool,
                     "force_resume":bool,"resume_armed":bool}, ...}; applies
                     ONLY those whitelisted keys to EXISTING entries, under
                     flock, atomic save; prints {"ok":true,"applied":N}

A missing state.json is not an error: dump emits an empty state, apply-toggles
applies to nothing (0). Only keys present in each incoming entry are touched;
entries are never created and no other fields are modified.
"""

import fcntl
import json
import os
import sys
import time
from pathlib import Path

# Keys the Mac is allowed to push back into the remote state. Everything else
# in state.json is remote-daemon-owned and must be left untouched.
TOGGLE_KEYS = ("enabled", "force_resume", "resume_armed")


def state_dir() -> Path:
    """Remote state directory. Matches the daemon's HOME/.claude-autoresume;
    AUTORESUME_STATE_DIR overrides it (used by tests and unusual layouts)."""
    override = os.environ.get("AUTORESUME_STATE_DIR")
    if override:
        return Path(override).expanduser()
    return Path.home() / ".claude-autoresume"


def state_file() -> Path:
    return state_dir() / "state.json"


def lock_file() -> Path:
    return state_dir() / "state.json.lock"


def tokens_hourly_file() -> Path:
    return state_dir() / "usage" / "tokens_hourly.json"


class StateLock:
    """Exclusive lock shared with the remote daemon's StateLock — same path,
    same semantics — so reads/writes here serialize against poll cycles."""

    def __enter__(self):
        state_dir().mkdir(parents=True, exist_ok=True)
        self._fh = open(lock_file(), "w")
        fcntl.flock(self._fh, fcntl.LOCK_EX)
        return self

    def __exit__(self, *exc):
        fcntl.flock(self._fh, fcntl.LOCK_UN)
        self._fh.close()


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
    tmp.replace(state_file())


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
    out = {"v": 1, "now": now, "state": state}
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
                    entry[key] = updates[key]
                    touched = True
            if touched:
                applied += 1
                changed = True
        if changed:
            save_state(state)
    json.dump({"ok": True, "applied": applied}, sys.stdout)
    sys.stdout.write("\n")
    return 0


def main(argv) -> int:
    args = argv[1:]
    if not args:
        sys.stderr.write("usage: remote_ctl.py {dump [--usage] | apply-toggles}\n")
        return 2
    cmd = args[0]
    rest = args[1:]
    if cmd == "dump":
        return cmd_dump(with_usage=("--usage" in rest))
    if cmd == "apply-toggles":
        return cmd_apply_toggles()
    sys.stderr.write(f"unknown command: {cmd}\n")
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
