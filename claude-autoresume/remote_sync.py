"""Mac-side remote/SSH session sync (WS-4).

Feature 2 "Shape C": the same stdlib daemon runs on each remote host and does
the real classification + auto-resume there; this module runs on the *Mac*
daemon, fetches each remote host's state over ssh, and merges it into the
shared `~/.claude-autoresume/state.json` so the widget shows remote sessions
alongside local ones. Auto-resume for a remote session fires natively on that
remote host — the Mac NEVER runs `claude --resume` for a remote entry (see the
`"host" in entry` guards in autoresume.py's resume/prune functions).

Design
------
* One daemon thread (`_remote_sync_worker`, started from autoresume.main() with
  the same daemon=True pattern as the usage-analytics worker). It is ALWAYS
  started — a host the widget adds at runtime only writes config.json, nothing
  restarts the daemon, so the thread must already be alive to notice it. When
  no host is configured (and no leftover `host::` entries remain) the tick takes
  a cheap idle early-out that never touches StateLock. It re-reads config.json
  on mtime change (via autoresume_config.config_mtime) so hosts the widget
  adds/removes take effect without a daemon restart.
* Per host, on that host's own `poll_seconds` cadence, one sync cycle:
    1. `dump` fetch over ssh (15s hard timeout, stdin=DEVNULL). Failure ⇒ mark
       that host's entries `remote_stale=true` (under StateLock) and skip; after
       REMOTE_DROP_HOURS (24h) of *continuous* unreachability the entries are
       dropped.
    2. clock-skew offset = midpoint(mac clock around the ssh call) − dump["now"].
    3. merge under StateLock (contract C3): upsert `"<host>::<sid>"`;
       remote-daemon-owned fields overwritten (last_activity_at / detected_at /
       handled_at skew-adjusted — never resets_at, which is server wall-clock);
       widget-owned enabled / resume_armed / force_resume preserved from local
       (local authoritative); sync-owned host / remote_id / remote_stale=false /
       remote_last_sync / last_seen stamped; local `host::` entries absent from
       the dump deleted.
    4. compute the toggle write-back delta under the SAME lock (enabled /
       resume_armed where local differs from the just-fetched remote;
       force_resume included when local is true — one-shot).
    5. push the delta OUTSIDE the lock via `apply-toggles`. Only after a
       successful push is local force_resume cleared (a second short lock
       acquisition). On push failure force_resume is kept — natural retry next
       cycle; enabled/resume_armed deltas are idempotent re-pushes anyway.
* Hourly usage lane: for `collect_usage` hosts, `dump --usage` once per hour and
  an atomic write to `usage/remote/<host>_tokens_hourly.json` (a stale copy is
  kept on failure).
* Retention relay: each successful dump reports the host's effective
  `sessions.idle_retention_minutes`; when it differs from the Mac's configured
  value, `remote_ctl.py apply-config` pushes the Mac's value (outside the
  StateLock; idempotent convergence like the toggle relay). An old remote_ctl
  without apply-config logs one redeploy hint per host per config change — see
  `_maybe_push_retention`.

Testability: the ssh transport is injected (a callable with the signature
`(ssh_target, remote_argv, stdin_data, timeout) -> (returncode, stdout, stderr)`)
so unit tests never shell out. See test_remote_sync.py.

Constraints: pure stdlib; every state.json access goes through autoresume's
flock-based StateLock; remote entries default enabled=false exactly like local
ones (opt-in only). The per-host loop is sequential — fine for the intended
1–3 hosts (a slow/blocked host delays later hosts by at most its 15s timeout,
never state correctness). Two Macs syncing the same remote host is unsupported
(both would fight over the toggle write-back).
"""

from __future__ import annotations  # `X | None` hints on system python3 (3.9)

import json
import subprocess
import time
from pathlib import Path

import autoresume          # StateLock / load_state / save_state / log / STATE_DIR
import autoresume_config   # load_config / config_mtime

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------

# Hard ceiling on any single ssh round-trip (dump or apply-toggles). ssh's own
# ConnectTimeout=5 covers connection setup; this bounds the whole call so a
# host that connects then hangs can't wedge the sync thread.
REMOTE_SSH_TIMEOUT_SECONDS = 15
# Keep a host's stale entries this long after it first becomes continuously
# unreachable, then drop them. Measured against the last *successful* sync
# (remote_last_sync), which we never advance on a failed cycle.
REMOTE_DROP_HOURS = 24
# Usage lane cadence: remote token totals feed the (per-account) budget bar,
# which only needs hourly granularity — no reason to ssh for it every poll.
USAGE_LANE_INTERVAL_SECONDS = 60 * 60
# How often the worker loop wakes to check per-host schedules. Each host still
# only actually syncs on its own poll_seconds; this is just the scheduler tick.
REMOTE_SYNC_TICK_SECONDS = 5

# state.json remote keys are "<host>::<remote_session_id>". "::" cannot collide
# with a bare UUID or a Cowork "local_<uuid>" id.
KEY_SEP = "::"

# Widget-owned fields: the Mac is authoritative, so these are preserved from the
# local entry across a merge rather than taken from the remote dump.
WIDGET_OWNED_FIELDS = ("enabled", "resume_armed", "force_resume")
# Remote-daemon-owned timestamps that must be shifted by the clock-skew offset
# at merge time. resets_at is deliberately excluded — it is a server wall-clock
# instant, meaningful on the remote's own clock, not to be skewed.
SKEW_ADJUSTED_FIELDS = ("last_activity_at", "detected_at", "handled_at")


# ---------------------------------------------------------------------------
# ssh transport (injected in tests)
# ---------------------------------------------------------------------------

def _default_transport(ssh_target, remote_argv, stdin_data=None,
                       timeout=REMOTE_SSH_TIMEOUT_SECONDS):
    """Run `ssh -o BatchMode=yes -o ConnectTimeout=5 <ssh_target> <remote_argv…>`
    and return `(returncode, stdout, stderr)`.

    BatchMode=yes guarantees ssh never blocks on a password/passphrase prompt
    (key-based auth only). For a `dump` there is no stdin (DEVNULL); for
    `apply-toggles` the JSON payload is fed on stdin. May raise
    subprocess.TimeoutExpired / OSError — callers treat any exception as
    "host unreachable this cycle".
    """
    argv = ["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=5",
            ssh_target, *remote_argv]
    if stdin_data is None:
        proc = subprocess.run(argv, stdin=subprocess.DEVNULL,
                              capture_output=True, text=True, timeout=timeout)
    else:
        proc = subprocess.run(argv, input=stdin_data,
                              capture_output=True, text=True, timeout=timeout)
    return proc.returncode, proc.stdout, proc.stderr


def _resolve_state_dir(state_dir):
    """Rewrite a leading `~`/`~/` to `$HOME`/`$HOME/` so the remote shell (not
    the local one) expands it inside the double-quoted command below. Absolute
    paths, `$VAR` forms, and anything else pass through untouched."""
    if state_dir == "~":
        return "$HOME"
    if state_dir.startswith("~/"):
        return "$HOME/" + state_dir[2:]
    return state_dir


def _remote_ctl_command(host, subcommand, *extra):
    """Compose the SINGLE remote shell command line for remote_ctl.py (contract
    C4), returned as a one-element list to hand ssh as one argument.

    It exports `AUTORESUME_STATE_DIR` (remote_ctl.py honors it) before invoking
    the script, so a non-default `state_dir` points remote_ctl at the right
    place. Every path is double-quoted so spaces in `state_dir`/`python` survive
    the remote shell's word-splitting (audit M3), and a leading `~/` is rewritten
    to `$HOME/` for remote-shell expansion.

    Note: deploy_remote.sh only ever installs to `~/.claude-autoresume`, so a
    host configured with a custom `state_dir` needs a matching manual deploy
    there — this composition just makes the runtime calls address it correctly.

    Same caveat for `host["python"]`: deploy_remote.sh installs the daemon under
    whatever `command -v python3` resolves to on the remote, but this runtime
    path invokes the interpreter named in the host's config `python` field. They
    diverge only on a hand-edited config; if you set a custom `python` it must
    point at the same (>= 3.9) interpreter deploy installed with, or these
    remote_ctl calls run under a different Python than the daemon."""
    state_dir = _resolve_state_dir(host["state_dir"])
    script = f"{state_dir}/bin/remote_ctl.py"
    python = host["python"]
    extra_str = "".join(f" {tok}" for tok in extra)
    command = (f'AUTORESUME_STATE_DIR="{state_dir}" '
               f'"{python}" "{script}" {subcommand}{extra_str}')
    return [command]


# ---------------------------------------------------------------------------
# Fetch / push primitives
# ---------------------------------------------------------------------------

def fetch_dump(host, transport, usage=False):
    """Fetch `remote_ctl.py dump [--usage]` from `host`. Returns the parsed
    dict on success, or None if the host is unreachable / the output is
    malformed (either counts as "unreachable this cycle" per C4)."""
    extra = ("--usage",) if usage else ()
    argv = _remote_ctl_command(host, "dump", *extra)
    try:
        rc, out, err = transport(host["ssh"], argv, None, REMOTE_SSH_TIMEOUT_SECONDS)
    except Exception as e:  # TimeoutExpired, OSError, anything the transport raises
        autoresume.log(f"remote-sync: {host['name']} dump transport error: {e!r}")
        return None
    if rc != 0:
        autoresume.log(f"remote-sync: {host['name']} unreachable "
                       f"(dump rc={rc}): {(err or '').strip()[:200]}")
        return None
    try:
        data = json.loads(out)
    except (ValueError, TypeError):
        autoresume.log(f"remote-sync: {host['name']} dump returned unparseable output")
        return None
    if (not isinstance(data, dict) or data.get("v") != 1
            or not isinstance(data.get("state"), dict)):
        autoresume.log(f"remote-sync: {host['name']} dump malformed (missing v/state)")
        return None
    return data


# Retention relay (config push): per-host failure memo. Maps host name ->
# {"reason": "no_field" | "push_failed", "value": <Mac retention at failure>,
#  "at": <now_fn timestamp>}. The reason matters (round-2 audit): a memo that
# only remembered the value blocked convergence after the very redeploy its
# own hint requested — nothing pushed until the value changed or the daemon
# restarted. Now:
#   - "no_field" (dump lacks retention_minutes, old remote_ctl): cleared the
#     moment a dump DOES carry the field (i.e. the redeploy happened); the
#     hint is still logged once per (host, value), not per cycle.
#   - "push_failed": skipped only while the value is unchanged AND the memo
#     is younger than RETENTION_PUSH_RETRY_SECONDS, so a transient ssh blip
#     retries after ~1h instead of never.
# Single sync thread, so no locking needed.
_RETENTION_PUSH_FAILED: dict = {}
# Age after which a failed push is retried even with an unchanged Mac value.
RETENTION_PUSH_RETRY_SECONDS = 3600


def push_config(host, retention_minutes, transport):
    """Push the Mac's sessions.idle_retention_minutes to `host` via
    `remote_ctl.py apply-config` (JSON on stdin). Returns True only when the
    remote confirms `{"ok": true}`. An old deployed remote_ctl without the
    apply-config command exits non-zero ("unknown command", rc 2) — that
    lands in the rc != 0 branch and reads as failure, which the caller turns
    into a single redeploy-hint log."""
    argv = _remote_ctl_command(host, "apply-config")
    body = json.dumps({"sessions": {"idle_retention_minutes": retention_minutes}})
    try:
        rc, out, err = transport(host["ssh"], argv, body, REMOTE_SSH_TIMEOUT_SECONDS)
    except Exception as e:
        autoresume.log(f"remote-sync: {host['name']} apply-config transport error: {e!r}")
        return False
    if rc != 0:
        autoresume.log(f"remote-sync: {host['name']} apply-config failed "
                       f"(rc={rc}): {(err or '').strip()[:200]}")
        return False
    try:
        resp = json.loads(out)
    except (ValueError, TypeError):
        autoresume.log(f"remote-sync: {host['name']} apply-config returned unparseable output")
        return False
    return bool(isinstance(resp, dict) and resp.get("ok"))


def _maybe_push_retention(host, state_dir, dump, transport, now_fn=time.time):
    """Retention relay (WS config push): after a successful dump, converge the
    remote's effective sessions.idle_retention_minutes onto the Mac's
    configured value. Idempotent convergence, exactly like the toggle relay:
    push only when the dump's reported value differs; next cycle's dump
    reflects the applied value and the delta disappears. Runs OUTSIDE the
    StateLock (pure ssh + config read, no state.json access).

    Old-remote handling: a remote_ctl predating this feature neither reports
    "retention_minutes" in its dump nor understands apply-config. Either way
    we log ONE "redeploy to update" hint per host per Mac-side config change
    (via _RETENTION_PUSH_FAILED) instead of retry-spamming every cycle — but
    the memo remembers WHY it's set (see its comment): a redeploy clears the
    no-field memo immediately, and failed pushes retry after ~1h."""
    name = host["name"]
    local = int(autoresume_config.load_config(Path(state_dir))
                ["sessions"]["idle_retention_minutes"])

    remote = dump.get("retention_minutes")
    memo = _RETENTION_PUSH_FAILED.get(name)
    if isinstance(remote, bool) or not isinstance(remote, (int, float)):
        # Old remote_ctl: no retention_minutes field in the dump.
        if not (memo and memo.get("reason") == "no_field"
                and memo.get("value") == local):
            _RETENTION_PUSH_FAILED[name] = {
                "reason": "no_field", "value": local, "at": now_fn()}
            autoresume.log(
                f"remote-sync: {name} dump has no retention_minutes (old remote_ctl) — "
                f"can't relay idle retention ({local}m); redeploy to update "
                "(deploy_remote.sh). Will retry after the next retention change.")
        return

    # The dump carries the field, so the remote_ctl is current: any "old
    # remote_ctl" memo is moot — the redeploy its hint asked for happened.
    # (Round-2 audit: keying the memo on the value alone blocked exactly
    # this convergence until the next Settings edit or daemon restart.)
    if memo and memo.get("reason") == "no_field":
        _RETENTION_PUSH_FAILED.pop(name, None)
        memo = None

    if int(remote) == local:
        _RETENTION_PUSH_FAILED.pop(name, None)  # converged — allow future pushes
        return

    if (memo and memo.get("value") == local
            and now_fn() - memo.get("at", 0) < RETENTION_PUSH_RETRY_SECONDS):
        return  # this exact value failed recently — no per-cycle spam

    if push_config(host, local, transport):
        _RETENTION_PUSH_FAILED.pop(name, None)
        autoresume.log(f"remote-sync: {name} idle retention pushed "
                       f"({int(remote)}m -> {local}m)")
    else:
        _RETENTION_PUSH_FAILED[name] = {
            "reason": "push_failed", "value": local, "at": now_fn()}
        autoresume.log(
            f"remote-sync: {name} apply-config push of idle retention ({local}m) failed — "
            "if the host runs an older remote_ctl, redeploy to update (deploy_remote.sh). "
            "Will retry within the hour, or sooner after the next retention change.")


def push_toggles(host, payload, transport):
    """Push a toggle delta via `remote_ctl.py apply-toggles` (JSON on stdin).
    Returns True only when the remote confirms `{"ok": true, …}`."""
    argv = _remote_ctl_command(host, "apply-toggles")
    body = json.dumps(payload)
    try:
        rc, out, err = transport(host["ssh"], argv, body, REMOTE_SSH_TIMEOUT_SECONDS)
    except Exception as e:
        autoresume.log(f"remote-sync: {host['name']} apply-toggles transport error: {e!r}")
        return False
    if rc != 0:
        autoresume.log(f"remote-sync: {host['name']} apply-toggles failed "
                       f"(rc={rc}): {(err or '').strip()[:200]}")
        return False
    try:
        resp = json.loads(out)
    except (ValueError, TypeError):
        autoresume.log(f"remote-sync: {host['name']} apply-toggles returned unparseable output")
        return False
    return bool(isinstance(resp, dict) and resp.get("ok"))


# ---------------------------------------------------------------------------
# Merge (contract C3) — all callers hold StateLock
# ---------------------------------------------------------------------------

def _skew(value, offset):
    """Shift a remote timestamp onto the Mac clock; pass through non-numbers
    (e.g. handled_at == None) untouched."""
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return value
    return value + offset


def _merge_host(state, host_name, dump, offset, mac_now):
    """Fold one host's dump into `state` in place. Returns the dict of remote
    entries keyed by remote sid (used to compute toggle deltas). Caller holds
    StateLock."""
    remote_state = dump.get("state") or {}
    dump_by_sid = {}

    for sid, rentry in remote_state.items():
        if not isinstance(sid, str) or not isinstance(rentry, dict):
            continue
        dump_by_sid[sid] = rentry
        key = f"{host_name}{KEY_SEP}{sid}"
        local = state.get(key) or {}

        # Start from the remote-daemon-owned view of the entry…
        entry = dict(rentry)
        # …preserve widget-owned fields from local (Mac is authoritative;
        # brand-new remote entries default off — opt-in, exactly like local).
        for field in WIDGET_OWNED_FIELDS:
            entry[field] = bool(local.get(field, False))
        # …skew-adjust the remote-clock timestamps (never resets_at).
        for field in SKEW_ADJUSTED_FIELDS:
            if field in entry:
                entry[field] = _skew(entry[field], offset)
        # …stamp sync-thread-owned bookkeeping.
        entry["host"] = host_name
        entry["remote_id"] = sid
        entry["remote_stale"] = False
        entry["remote_last_sync"] = mac_now
        entry["last_seen"] = mac_now

        state[key] = entry

    # A local entry for this host that the dump no longer lists = the session
    # ended/was deleted on the remote → drop it.
    prefix = f"{host_name}{KEY_SEP}"
    for key in [k for k in state if k.startswith(prefix) and state[k].get("host") == host_name]:
        sid = state[key].get("remote_id") or key[len(prefix):]
        if sid not in dump_by_sid:
            del state[key]

    return dump_by_sid


def _compute_toggle_deltas(state, host_name, dump_by_sid):
    """Toggle write-back delta: `{sid: {enabled?, resume_armed?, force_resume?}}`
    for the just-merged local entries whose widget-owned toggles differ from the
    freshly-fetched remote. enabled/resume_armed included on divergence
    (idempotent re-push); force_resume included whenever local is true (one-shot).
    Caller holds StateLock."""
    prefix = f"{host_name}{KEY_SEP}"
    payload = {}
    for key, entry in state.items():
        if not (key.startswith(prefix) and entry.get("host") == host_name):
            continue
        sid = entry.get("remote_id") or key[len(prefix):]
        rentry = dump_by_sid.get(sid)
        if rentry is None:
            continue
        delta = {}
        local_enabled = bool(entry.get("enabled", False))
        if local_enabled != bool(rentry.get("enabled", False)):
            delta["enabled"] = local_enabled
        local_armed = bool(entry.get("resume_armed", False))
        if local_armed != bool(rentry.get("resume_armed", False)):
            delta["resume_armed"] = local_armed
        if entry.get("force_resume"):
            delta["force_resume"] = True
        if delta:
            payload[sid] = delta
    return payload


def _mark_host_stale(state, host_name, mac_now):
    """Flag every entry for `host_name` as remote_stale (unreachable this cycle).
    remote_last_sync is intentionally NOT advanced, so the 24h drop clock keeps
    counting from the last successful sync. Caller holds StateLock."""
    prefix = f"{host_name}{KEY_SEP}"
    for key, entry in state.items():
        if key.startswith(prefix) and entry.get("host") == host_name:
            entry["remote_stale"] = True


def _drop_long_unreachable(state, host_name, mac_now):
    """Drop entries for `host_name` that have been continuously unreachable for
    more than REMOTE_DROP_HOURS (measured from the last successful sync). Caller
    holds StateLock."""
    prefix = f"{host_name}{KEY_SEP}"
    cutoff = mac_now - REMOTE_DROP_HOURS * 3600
    for key in [k for k in state if k.startswith(prefix) and state[k].get("host") == host_name]:
        last = state[key].get("remote_last_sync")
        if isinstance(last, (int, float)) and last < cutoff:
            autoresume.log(f"remote-sync: {key} unreachable >"
                           f"{REMOTE_DROP_HOURS}h — dropping from widget")
            del state[key]


def _prune_removed_hosts(state_dir, host_names):
    """Delete state entries whose host is no longer present in config at all
    (the widget removed it). Configured-but-disabled hosts keep their entries
    (frozen) so re-enabling doesn't lose them. Takes its own StateLock.

    Returns True if ANY `host::` entry still remains after the prune. The worker
    uses this to decide whether it can take the idle early-out next tick (no
    configured hosts AND nothing believed present ⇒ skip without the lock)."""
    with autoresume.StateLock():
        state = autoresume.load_state()
        removed = [k for k, e in state.items()
                   if isinstance(e, dict) and e.get("host") is not None
                   and e.get("host") not in host_names]
        for key in removed:
            autoresume.log(f"remote-sync: host removed from config — dropping {key}")
            del state[key]
        if removed:
            autoresume.save_state(state)
        return any(isinstance(e, dict) and e.get("host") is not None
                   for e in state.values())


# ---------------------------------------------------------------------------
# Per-host sync cycle
# ---------------------------------------------------------------------------

def sync_host(host, state_dir, transport, now_fn=time.time):
    """One sync cycle for a single host. Returns True if the dump was fetched
    (reachable), False if unreachable this cycle."""
    name = host["name"]

    t0 = now_fn()
    dump = fetch_dump(host, transport)
    t1 = now_fn()

    if dump is None:
        with autoresume.StateLock():
            state = autoresume.load_state()
            _mark_host_stale(state, name, t1)
            _drop_long_unreachable(state, name, t1)
            autoresume.save_state(state)
        return False

    remote_now = dump.get("now")
    midpoint = (t0 + t1) / 2.0
    offset = (midpoint - remote_now) if isinstance(remote_now, (int, float)) else 0.0

    # Merge + delta computation under one lock; the ssh write-back happens
    # outside it.
    with autoresume.StateLock():
        state = autoresume.load_state()
        dump_by_sid = _merge_host(state, name, dump, offset, t1)
        payload = _compute_toggle_deltas(state, name, dump_by_sid)
        autoresume.save_state(state)

    # Retention relay: outside the StateLock (it never touches state.json),
    # after a successful dump+merge, before/independent of the toggle push.
    _maybe_push_retention(host, state_dir, dump, transport, now_fn)

    if not payload:
        return True

    ok = push_toggles(host, payload, transport)
    if ok:
        # force_resume is one-shot: clear it locally only after a confirmed
        # push, under a second short lock. enabled/resume_armed need no clearing
        # — next cycle's dump reflects them and the delta disappears on its own.
        forced = [sid for sid, d in payload.items() if d.get("force_resume")]
        if forced:
            with autoresume.StateLock():
                state = autoresume.load_state()
                for sid in forced:
                    key = f"{name}{KEY_SEP}{sid}"
                    if key in state:
                        state[key]["force_resume"] = False
                autoresume.save_state(state)
    return True


def fetch_host_usage(host, state_dir, transport):
    """Hourly usage lane: fetch `dump --usage` and atomically write the host's
    per-hour token file. On failure the previous (stale) copy is left in place.
    Returns True on a successful write."""
    dump = fetch_dump(host, transport, usage=True)
    if dump is None:
        return False
    tokens = dump.get("tokens_hourly")
    if not isinstance(tokens, dict):
        autoresume.log(f"remote-sync: {host['name']} usage dump missing tokens_hourly")
        return False
    out_dir = Path(state_dir) / "usage" / "remote"
    try:
        out_dir.mkdir(parents=True, exist_ok=True)
        out_path = out_dir / f"{host['name']}_tokens_hourly.json"
        tmp = out_path.with_suffix(".json.tmp")
        tmp.write_text(json.dumps(tokens, indent=2))
        tmp.replace(out_path)
    except OSError as e:
        autoresume.log(f"remote-sync: {host['name']} usage write failed: {e!r}")
        return False
    return True


# ---------------------------------------------------------------------------
# Worker thread
# ---------------------------------------------------------------------------

def has_enabled_hosts(state_dir) -> bool:
    """True if config.json currently declares at least one enabled remote host.
    autoresume.main() gates the sync-thread start on this."""
    cfg = autoresume_config.load_config(Path(state_dir))
    return any(h.get("enabled") for h in cfg.get("remote_hosts", []))


class _RemoteSyncLoop:
    """Loop-carried state for the sync worker, factored out so a single tick is
    unit-testable without driving the `while True`. `tick()` runs one scheduler
    iteration (no sleep); `_remote_sync_worker` just constructs one of these and
    calls `tick()` forever."""

    def __init__(self, state_dir=None, transport=None):
        if state_dir is None:
            state_dir = autoresume.STATE_DIR
        self.state_dir = Path(state_dir)
        self.transport = transport or _default_transport
        self.next_poll: dict = {}   # host name -> next epoch to run a state sync
        self.next_usage: dict = {}  # host name -> next epoch to run a usage fetch
        self.cfg = autoresume_config.load_config(self.state_dir)
        self.last_mtime = autoresume_config.config_mtime(self.state_dir)
        # Start believing entries MAY exist so the very first tick always runs
        # the prune once — cleans up any `host::` leftovers from a config whose
        # hosts were removed while the daemon was down, then latches to False.
        self.believe_host_entries = True

    def tick(self, now_fn=time.time):
        """One scheduler iteration. Returns True if it did real work (serviced
        hosts / pruned under StateLock), or False if it took the idle early-out
        (no configured hosts AND no `host::` entry believed present) — in which
        case StateLock was never acquired."""
        mtime = autoresume_config.config_mtime(self.state_dir)
        if mtime != self.last_mtime:
            self.cfg = autoresume_config.load_config(self.state_dir)
            self.last_mtime = mtime

        hosts = self.cfg.get("remote_hosts", [])
        host_names = {h["name"] for h in hosts}

        # Finding 5: evict scheduler entries for hosts no longer in the config
        # set (runs every tick, so it covers every config reload).
        for sched in (self.next_poll, self.next_usage):
            for name in [n for n in sched if n not in host_names]:
                del sched[name]
        # Round-3 m3: retention-push failure memos likewise — a removed host's
        # memo must not suppress the first push to a later re-added host of
        # the same name.
        for name in [n for n in _RETENTION_PUSH_FAILED if n not in host_names]:
            del _RETENTION_PUSH_FAILED[name]

        # Finding 1: idle early-out. Nothing configured and nothing believed
        # present ⇒ skip the whole tick without ever taking StateLock.
        if not hosts and not self.believe_host_entries:
            return False

        now = now_fn()
        for host in hosts:
            if not host.get("enabled"):
                continue
            name = host["name"]
            if now >= self.next_poll.get(name, 0.0):
                self.next_poll[name] = now + host.get("poll_seconds", 30)
                try:
                    sync_host(host, self.state_dir, self.transport)
                except Exception as e:
                    autoresume.log(f"remote-sync: {name} sync cycle error: {e!r}")
            if host.get("collect_usage") and now >= self.next_usage.get(name, 0.0):
                self.next_usage[name] = now + USAGE_LANE_INTERVAL_SECONDS
                try:
                    fetch_host_usage(host, self.state_dir, self.transport)
                except Exception as e:
                    autoresume.log(f"remote-sync: {name} usage cycle error: {e!r}")

        self.believe_host_entries = _prune_removed_hosts(self.state_dir, host_names)
        return True


def _remote_sync_worker(state_dir=None, transport=None):
    """Daemon-thread entry point. Always started by autoresume.main() (a host
    the widget adds at runtime doesn't restart the daemon), and idle-cheap when
    no host is configured. Sequentially services each enabled remote host on its
    own poll_seconds cadence (and each collect_usage host hourly), re-reading
    config.json on mtime change so add/remove takes effect live."""
    loop = _RemoteSyncLoop(state_dir, transport)
    enabled = sum(1 for h in loop.cfg.get("remote_hosts", []) if h.get("enabled"))
    if enabled:
        autoresume.log(f"remote-sync thread started ({enabled} enabled host(s))")
    else:
        autoresume.log("remote-sync thread started (no enabled remote hosts — "
                       "idle until one is configured)")

    while True:
        try:
            loop.tick()
        except Exception as e:  # a bad cycle must never kill the thread
            autoresume.log(f"remote-sync: worker cycle error: {e!r}")
        time.sleep(REMOTE_SYNC_TICK_SECONDS)
