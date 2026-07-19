#!/usr/bin/env python3
"""
claude-autoresume daemon
=========================

Watches Claude Code (CLI) sessions on this Mac. When a session gets cut off
by your Pro/Max plan's rate limit, this daemon detects it and records it in
a shared state file — it does NOT resume anything on its own. Resuming only
happens for sessions you've explicitly opted into via the Claude Usage
Overlay widget (or that you've told it to resume right now from there).

Scope: Claude Code (CLI) sessions ONLY. Cowork sessions run server-side and
never write a local transcript, so there's nothing on disk for this daemon
to watch. Plain chat conversations aren't "sessions" in this sense — there's
nothing to relaunch, you just send your next message when the limit clears.

State file: ~/.claude-autoresume/state.json
This is shared with the ClaudeUsageOverlay app, which reads it to show you
detected sessions and lets you flip each one's "enabled" flag (default:
off) or set "force_resume" for an immediate one-off resume. Both processes
take an exclusive lock (~/.claude-autoresume/state.json.lock) around every
read-modify-write so toggles from the widget and updates from this daemon
don't clobber each other.

Per-cycle behavior:
  1. Scan ~/.claude/projects/**/*.jsonl (touched recently) for two kinds of
     sessions:
       - "active": touched in the last ACTIVE_WINDOW_MINUTES, no rate-limit
         cutoff yet. Shown in the widget so you can pre-authorize a resume
         in case it does get cut off later, without needing to come back.
       - "waiting": log ends in a rate_limit_event — already cut off, with
         a known reset time.
     New sessions are added with enabled=false, handled=false. If a session
     you've already seen transitions from active -> waiting, its enabled
     flag (and any other choice you made) is preserved, not reset.
  2. For every tracked, not-yet-handled "waiting" session: resume it now if
     either
       - force_resume is true (widget's "Resume Now" button), or
       - enabled is true AND the reported reset time has passed.
     "active" sessions are never auto-resumed (there's nothing to resume —
     they're still running). Resumed sessions run under PERMISSION_MODE,
     which defaults to "acceptEdits" (NOT bypassPermissions): the safer
     tradeoff is that an unattended resume may stall on a permission prompt
     rather than run with every prompt bypassed under full trust. Override
     with AUTORESUME_PERMISSION_MODE if you knowingly want otherwise.
  3. Prune old handled entries and stale "active" entries (gone quiet for a
     while and never got rate-limited) so state.json doesn't grow forever.

Cost/latency note: file reading, JSON parsing and work_status
classification all happen OUTSIDE StateLock (see compute_cli_records /
compute_cowork_records), producing plain records; the lock is then held only
long enough to load_state -> merge those records in -> resume/prune -> save.
A per-transcript parse cache (_PARSE_CACHE, keyed on file mtime+size) means a
transcript is only re-read+re-parsed when it actually changed, so an idle
in-window session costs a stat, not a full re-read, each poll.
"""

from __future__ import annotations  # keeps `X | None` / `list[str]` hints safe on Python 3.9 (macOS system python3)

import fcntl
import json
import os
import shutil
import subprocess
import sys
import threading
import time
from datetime import datetime
from pathlib import Path

import plan_fit        # Usage analytics: plan-fit computation + pricing refresh
import usage_collector  # Usage analytics: token collection from transcripts + snapshot compaction
import cowork_resume  # Track 1: Cowork resume automation scaffolding — see that module's
                       # docstring. Hardcoded dry-run; see DRY_RUN there.

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------

HOME = Path.home()
PROJECTS_DIR = HOME / ".claude" / "projects"
# Cowork sessions (this includes Claude Desktop's Cowork mode) each get a
# metadata file here (local_<uuid>.json: title, lastActivityAt, isArchived,
# ...) plus a sibling local_<uuid>/audit.jsonl activity log. There is no
# rate-limit/resume concept for these — Cowork manages its own lifecycle —
# so we only ever show them in the widget as "active", never "waiting".
COWORK_SESSIONS_DIR = HOME / "Library" / "Application Support" / "Claude" / "local-agent-mode-sessions"
STATE_DIR = HOME / ".claude-autoresume"
STATE_FILE = STATE_DIR / "state.json"
LOCK_FILE = STATE_DIR / "state.json.lock"
LOG_DIR = STATE_DIR / "logs"
DAEMON_LOG = STATE_DIR / "daemon.log"

POLL_INTERVAL_SECONDS = 10
# Usage analytics run much less often than the session poll. Collection is
# incremental (byte offsets) so an hourly cadence loses nothing; pricing
# refresh hits the network, so at most daily.
USAGE_COLLECT_INTERVAL_SECONDS = 60 * 60
PRICING_REFRESH_INTERVAL_SECONDS = 24 * 60 * 60
# Only look at session files touched in the last N minutes when scanning at
# all — no need to re-read your entire session history every cycle. Kept in
# lockstep with ACTIVE_WINDOW_MINUTES below (>=): compute_cli_records() only
# explicitly re-evaluates (and prunes) a session while its mtime is inside
# this window, so if this were smaller than ACTIVE_WINDOW_MINUTES, sessions
# idle beyond this cutoff but still inside the active window would stop
# being touched entirely and freeze in state (with a stale "active" status)
# until the much looser ACTIVE_STALE_MINUTES safety net eventually caught
# them, instead of aging out predictably at the active window's edge.
SCAN_WINDOW_MINUTES = 30
# A session touched more recently than this is considered "active" and shown
# in the widget even though it hasn't hit a rate limit (yet). This is also
# the *effective session-list lookback*: once a session goes quiet for longer
# than this, the scan (compute_cli_records -> merge_cli_records; see the
# `status is None` branch) deletes
# its state.json entry outright on the next poll cycle, so it drops out of
# the widget's Sessions list. Raised from 5 to 30 minutes so recently-idle
# sessions stay visible long enough to still be found/resumed from the
# widget.
ACTIVE_WINDOW_MINUTES = 30
# Small buffer after the reported reset time before we actually fire, to
# avoid racing the server's own clock.
RESET_BUFFER_SECONDS = 30
# Drop handled entries from state.json after this long, so the widget's
# list (and this file) stay small.
PRUNE_AFTER_HOURS = 48
# Drop "active" entries that have gone quiet (and never got rate-limited)
# after this long.
ACTIVE_STALE_MINUTES = ACTIVE_WINDOW_MINUTES * 2
# Per-session "work_status" classification (running / needs_input / idle),
# additive to the existing active/waiting `status` field (which resume logic
# depends on and which this does NOT change).
#
# Redesigned 2026-07-19 from live ground-truth sessions (one sitting on a
# permission prompt, one running a background subagent, one mid-agentic-work
# with a pending Agent tool call). Empirical findings the rules below rest on:
#
#   * There is still no "permission_request"-style event type in the jsonl.
#     BUT: the assistant `tool_use` event IS flushed to the transcript the
#     moment the call is issued — i.e. while the permission prompt is on
#     screen the file's last conversational event is that pending tool_use,
#     and the file then goes quiet (observed live: pending Bash tool_use as
#     the literal last line, file mtime frozen for minutes, prompt visible
#     in the UI the whole time).
#   * A pending tool_use is structurally IDENTICAL whether it's waiting for
#     approval or actually executing (same keys: id/name/input/caller — no
#     approval marker ever appears). The discriminators live OUTSIDE the
#     main transcript:
#       - ~/.claude/sessions/<pid>.json maps every live session process to
#         its sessionId ({"pid": ..., "sessionId": ..., ...}). This gives a
#         precise session -> process handle.
#       - While a Bash tool is EXECUTING, the session process has a child
#         shell whose command line sources ~/.claude/shell-snapshots/
#         snapshot-*.sh (observed live under the working session's pid;
#         absent under the permission-blocked session's pid). Permission
#         prompts happen BEFORE the shell is spawned, so:
#         pending Bash + no shell child  => waiting on approval.
#       - Subagent (Agent/Task tool) work is written to sibling
#         <session_id>/subagents/agent-*.jsonl files, and large streamed
#         tool output to <session_id>/tool-results/*.txt — both keep fresh
#         mtimes while the parent transcript sits on the pending Agent
#         tool_use (observed: parent quiet 15+ min, subagent file mtime
#         seconds old). Fresh sidecar => running, no matter how quiet the
#         parent file is.
#   * A cleanly finished turn is explicit in-band: the final assistant event's
#     message carries stop_reason == "end_turn" (mid-turn blocks carry
#     "tool_use"). So "idle" no longer needs a 90s quiet window — end_turn
#     with no fresh sidecar activity is idle immediately.
WORK_STATUS_RUNNING_WINDOW_SECONDS = 90
# Tools whose entire purpose is to block on the human. A pending call to one
# of these means "needs input" the moment it's issued.
USER_INPUT_TOOLS = {"AskUserQuestion", "ExitPlanMode"}
# Tools that delegate to a subagent; their liveness signal is the
# subagents/ sidecar dir, not the main transcript.
SUBAGENT_TOOLS = {"Agent", "Task"}
# In-process tools that complete in well under a second when approved — a
# pending call to one of these that is older than a few seconds can only be
# a permission prompt.
INSTANT_TOOLS = {
    "Read", "Edit", "Write", "MultiEdit", "NotebookEdit", "Glob", "Grep",
    "LS", "TodoWrite", "BashOutput", "KillShell", "TaskStop",
}
# Grace before a pending call to an INSTANT_TOOL counts as a permission
# prompt (covers the flush -> execute -> result-write race).
PENDING_INSTANT_GRACE_SECONDS = 10
# Grace for everything else we can't observe from outside (WebFetch, MCP
# tools, and Bash when no process table is available): these legitimately
# run for a while with zero on-disk footprint.
PENDING_SLOW_GRACE_SECONDS = 60

SESSIONS_DIR = HOME / ".claude" / "sessions"
# Command-line substrings that identify a tool child process actually
# executing under a session's pid (Bash tool shells source a shell-snapshot
# on startup; sandboxed variants wrap the same thing).
_TOOL_CHILD_MARKERS = (".claude/shell-snapshots/", "sandbox-exec")


def collect_runtime_snapshot() -> dict:
    """Once-per-cycle process-level signals shared by every session's
    classification: which live process owns which session (from
    ~/.claude/sessions/<pid>.json), and which of those processes currently
    have a tool child actually executing (a shell sourcing a
    ~/.claude/shell-snapshots snapshot). One ps fork + a handful of tiny
    JSON reads per cycle."""
    procs = []
    try:
        out = subprocess.run(
            ["ps", "-axo", "pid=,ppid=,command="],
            capture_output=True, text=True, timeout=5,
        ).stdout
    except (OSError, subprocess.SubprocessError):
        out = ""
    for line in out.splitlines():
        parts = line.strip().split(None, 2)
        if len(parts) < 2:
            continue
        try:
            pid, ppid = int(parts[0]), int(parts[1])
        except ValueError:
            continue
        procs.append((pid, ppid, parts[2] if len(parts) > 2 else ""))

    alive = {pid for pid, _, _ in procs}
    parent_of = {pid: ppid for pid, ppid, _ in procs}
    busy_pids = set()
    for pid, ppid, cmd in procs:
        if any(marker in cmd for marker in _TOOL_CHILD_MARKERS):
            # Credit the executing shell to its ancestors (the session
            # process is usually the direct parent; walk a couple levels to
            # cover wrapper processes).
            ancestor = ppid
            for _ in range(3):
                if ancestor in (0, 1):
                    break
                busy_pids.add(ancestor)
                ancestor = parent_of.get(ancestor, 0)

    session_pids = {}
    if SESSIONS_DIR.is_dir():
        for f in SESSIONS_DIR.glob("*.json"):
            try:
                info = json.loads(f.read_text())
            except (OSError, ValueError):
                continue
            pid, sid = info.get("pid"), info.get("sessionId")
            if isinstance(pid, int) and isinstance(sid, str) and pid in alive:
                session_pids[sid] = pid

    return {
        "session_pids": session_pids,
        "busy_pids": busy_pids,
        "have_ps": bool(procs),
    }


def sidecar_activity_mtime(jsonl_path: Path) -> float:
    """Most recent write to the session's sidecar activity files: subagent
    transcripts (<session_id>/subagents/*.jsonl) and streamed big tool
    outputs (<session_id>/tool-results/*). Fresh writes here mean work is
    happening even while the main transcript is quiet."""
    latest = 0.0
    base = jsonl_path.parent / jsonl_path.stem
    for sub in ("subagents", "tool-results"):
        d = base / sub
        if d.is_dir():
            try:
                for p in d.iterdir():
                    try:
                        latest = max(latest, p.stat().st_mtime)
                    except OSError:
                        continue
            except OSError:
                continue
    return latest


def _parse_event_time(obj: dict) -> float | None:
    ts = obj.get("timestamp")
    if isinstance(ts, str):
        try:
            return datetime.fromisoformat(ts.replace("Z", "+00:00")).timestamp()
        except ValueError:
            return None
    return None


def classify_work_status(
    objs: list[dict],
    mtime: float,
    now: float,
    jsonl_path: Path | None = None,
    session_id: str | None = None,
    runtime: dict | None = None,
) -> str:
    """Classifies a session as "running", "needs_input", or "idle" for the
    widget's per-row status dot. See the big comment above the constants for
    the on-disk evidence each rule keys off.

    Rules, in order:
      1. Pending call to a USER_INPUT_TOOL (AskUserQuestion / ExitPlanMode)
         -> needs_input immediately.
      2. Session process has an executing tool child (shell-snapshot shell)
         -> running (covers long Bash commands, including ones a subagent
         is running — they spawn under the same session pid).
      3. Fresh subagents/ or tool-results/ sidecar writes -> running
         (background/parallel subagents keep working after the parent's
         turn even ends).
      4. Pending ordinary tool_use, none of the above: it's a permission
         prompt once it outlives its grace — 0s for Bash when we can see
         the process table (an executing Bash ALWAYS has a shell child, so
         its absence is decisive within one poll cycle), ~10s for
         in-process instant tools (Edit/Write/Read...), ~60s for
         tools that run remotely/invisibly (WebFetch, MCP).
      5. No pending call and the last assistant event says
         stop_reason == "end_turn": the turn finished. If its closing text
         ends with a question mark, Claude is (informally) asking the human
         something -> needs_input; otherwise idle right away — no quiet
         window needed.
      6. Otherwise (mid-turn shapes: fresh human prompt, tool_result just
         landed, streaming blocks): running while the transcript was
         touched inside WORK_STATUS_RUNNING_WINDOW_SECONDS, else idle
         (stalled/killed mid-turn, or streaming silently longer than the
         window — accepted residual).

    Text-question policy (rule 5): a turn that ends with "...?" reads as a
    question to the human, so it gets the needs_input dot; anything else
    that ended cleanly is idle. AskUserQuestion/plan-approval — the common,
    structured ways Claude blocks on the human — are already caught by
    rule 1, so this only affects informal trailing questions.
    """
    runtime = runtime or {}
    session_pids = runtime.get("session_pids") or {}
    busy_pids = runtime.get("busy_pids") or set()
    have_ps = bool(runtime.get("have_ps"))
    pid = session_pids.get(session_id) if session_id else None
    executing = pid is not None and pid in busy_pids

    # --- walk the current turn backwards: newest conversational event and
    # any tool_use calls not yet answered by a tool_result. tool_results
    # always land after their tool_use, so scanning backwards we meet
    # results before uses. The turn is bounded by a non-tool_result user
    # event (a human/injected prompt) or a previous turn's end_turn.
    result_ids = set()
    pending = []  # (tool_name, event_time or None)
    last_conv = None
    for obj in reversed(objs[-400:]):
        obj_type = obj.get("type")
        if obj_type not in ("assistant", "user"):
            continue  # queue-operation / attachment / system / ai-title ...
        message = obj.get("message") if isinstance(obj.get("message"), dict) else {}
        content = message.get("content")
        if last_conv is None:
            last_conv = obj
        if obj_type == "user":
            saw_result = False
            if isinstance(content, list):
                for block in content:
                    if isinstance(block, dict) and block.get("type") == "tool_result":
                        result_ids.add(block.get("tool_use_id"))
                        saw_result = True
            if not saw_result:
                break  # human prompt: start of the current turn
        else:
            if isinstance(content, list):
                for block in content:
                    if (
                        isinstance(block, dict)
                        and block.get("type") == "tool_use"
                        and block.get("id") not in result_ids
                    ):
                        pending.append((block.get("name") or "", _parse_event_time(obj)))
            if obj is not last_conv and message.get("stop_reason") == "end_turn":
                break  # previous turn's clean ending

    # Rule 1: tools that exist to block on the human.
    if any(name in USER_INPUT_TOOLS for name, _ in pending):
        return "needs_input"

    # Rule 2: a tool child is executing right now under this session's pid.
    if executing:
        return "running"

    # Rule 3: subagent / streamed-output sidecars are being written.
    sidecar_ts = sidecar_activity_mtime(jsonl_path) if jsonl_path else 0.0
    sidecar_fresh = sidecar_ts > 0 and (now - sidecar_ts) <= WORK_STATUS_RUNNING_WINDOW_SECONDS
    if sidecar_fresh:
        return "running"

    # Rule 4: an unresolved ordinary tool call with no observable execution.
    if pending:
        ages = [now - ts for _, ts in pending if ts is not None]
        age = min(ages) if ages else (now - mtime)
        grace = 0.0
        for name, _ in pending:
            if name == "Bash" and have_ps and pid is not None:
                tool_grace = 0.0  # executing Bash always has a shell child
            elif name in SUBAGENT_TOOLS:
                # Bug fix: SUBAGENT_TOOLS was defined (see its doc comment —
                # liveness is the subagents/ sidecar dir, not this age check)
                # but never actually consulted here, so a pending Agent/Task
                # call fell into the `else` bucket below and got only
                # PENDING_SLOW_GRACE_SECONDS (60s) — the grace meant for
                # WebFetch/MCP calls that really do resolve in tens of
                # seconds. Subagent delegation routinely runs far longer
                # than that between sidecar writes (a long "thinking" burst,
                # a slow nested tool call), and a pending Agent/Task call has
                # no permission-prompt semantics at all — any human-facing
                # approval happens inside the SUBAGENT's own transcript, not
                # as a blocking state on this one — so there is no reading
                # of "stale" here that means needs_input. Rule 3 above
                # already returns "running" whenever the sidecar looks
                # fresh; if we get here the sidecar merely looks quiet
                # *right now*, which just means still-running, so this never
                # times out.
                tool_grace = float("inf")
            elif name in INSTANT_TOOLS:
                tool_grace = float(PENDING_INSTANT_GRACE_SECONDS)
            else:
                tool_grace = float(PENDING_SLOW_GRACE_SECONDS)
            grace = max(grace, tool_grace)
        return "running" if age <= grace else "needs_input"

    # Rule 5: turn finished cleanly (explicit end_turn) — idle immediately,
    # or needs_input if the closing text is an informal question.
    if last_conv is not None and last_conv.get("type") == "assistant":
        message = last_conv.get("message") if isinstance(last_conv.get("message"), dict) else {}
        if message.get("stop_reason") == "end_turn":
            closing_text = ""
            content = message.get("content")
            if isinstance(content, list):
                for block in content:
                    if isinstance(block, dict) and block.get("type") == "text":
                        closing_text = block.get("text") or ""
            if closing_text.rstrip().rstrip("*_`").endswith("?"):
                return "needs_input"
            return "idle"

    # Rule 6: mid-turn (streaming, human prompt just sent, tool_result just
    # landed) — running while recently touched.
    #
    # Deleted-session fix: "recently touched" is judged by the last
    # conversational event's OWN embedded timestamp when it has one, not the
    # file's mtime. Deleting a session's imported copy in Claude Desktop's
    # GUI touches the underlying CLI transcript (observed live: Desktop
    # metadata events — ai-title/custom-title/last-prompt — appended at the
    # tail, +343 bytes), which refreshes mtime without any new conversation
    # having happened. Under the old
    # mtime-only check that rewrite read as "fresh human prompt, Claude is
    # about to respond" -> a false ~90s "running" flicker right after the
    # user deleted the session. The tail event's own timestamp is immune to
    # metadata-only touches (every real conversational event — streamed
    # blocks, prompts, tool_results — carries a fresh one), so it's strictly
    # the better signal; mtime stays as the fallback for events without a
    # parseable timestamp.
    last_conv_ts = _parse_event_time(last_conv) if last_conv is not None else None
    reference_ts = last_conv_ts if last_conv_ts is not None else mtime
    if (now - reference_ts) <= WORK_STATUS_RUNNING_WINDOW_SECONDS:
        return "running"
    return "idle"

CLAUDE_BIN = os.environ.get("CLAUDE_BIN", "claude")
RESUME_PROMPT = os.environ.get("AUTORESUME_PROMPT", "continue")
# Permission mode for an auto-resumed session. Default "acceptEdits", NOT
# "bypassPermissions": a resume fires unattended, and bypassPermissions runs
# it with EVERY permission prompt suppressed under full trust — an unattended
# session with no human watching is the worst place to grant that. acceptEdits
# auto-accepts file edits (the common case for "continue") but still stops on
# anything that would otherwise prompt (running commands, network, deletes),
# so the failure mode is a resume that stalls waiting for approval rather than
# one that barrels ahead with full trust — the safer default. Override via
# AUTORESUME_PERMISSION_MODE if you knowingly want a different tradeoff.
# See README's "Known rough edges" section — verify with `claude --help` if
# resume attempts fail immediately.
PERMISSION_MODE = os.environ.get("AUTORESUME_PERMISSION_MODE", "acceptEdits")


# Rotate daemon.log once it crosses this size. Single generation (.1),
# overwritten each roll — bounded, never accumulates.
LOG_MAX_BYTES = 5 * 1024 * 1024


def log(msg: str) -> None:
    line = f"[{datetime.now().isoformat(timespec='seconds')}] {msg}"
    # Only echo to stdout on an interactive TTY. Under launchd, stdout is
    # redirected to launchd.out.log — print()ing there would store every line
    # twice (once in launchd.out.log, once in daemon.log below), forever.
    if sys.stdout.isatty():
        print(line, flush=True)
    try:
        DAEMON_LOG.parent.mkdir(parents=True, exist_ok=True)
        try:
            if DAEMON_LOG.exists() and DAEMON_LOG.stat().st_size > LOG_MAX_BYTES:
                # .replace() atomically overwrites any previous .1 generation.
                DAEMON_LOG.replace(DAEMON_LOG.with_name(DAEMON_LOG.name + ".1"))
        except OSError:
            pass
        with open(DAEMON_LOG, "a") as f:
            f.write(line + "\n")
    except OSError:
        pass


# ---------------------------------------------------------------------------
# Locked state read/modify/write
# ---------------------------------------------------------------------------

class StateLock:
    """Exclusive file lock shared with the Swift widget, so a toggle click
    and a daemon poll cycle can never interleave and lose an update."""

    def __enter__(self):
        STATE_DIR.mkdir(parents=True, exist_ok=True)
        self._fh = open(LOCK_FILE, "w")
        fcntl.flock(self._fh, fcntl.LOCK_EX)
        return self

    def __exit__(self, *exc):
        fcntl.flock(self._fh, fcntl.LOCK_UN)
        self._fh.close()


def load_state() -> dict:
    if STATE_FILE.exists():
        try:
            return json.loads(STATE_FILE.read_text())
        except (json.JSONDecodeError, OSError) as e:
            # Starting fresh here silently discards EVERY user toggle
            # (enabled / resume_armed / force_resume) — the whole point of
            # this file. Preserve the corrupt copy for post-mortem first, and
            # log loudly that toggles were lost. Single backup, overwritten
            # each time, so a persistently-corrupt file can't accumulate.
            backup = STATE_FILE.parent / (STATE_FILE.name + ".corrupt")
            try:
                shutil.copy2(STATE_FILE, backup)
                log(f"ERROR: {STATE_FILE} is corrupt ({e!r}); copied to {backup} "
                    f"and starting fresh — all user auto-resume toggles were lost.")
            except OSError as copy_err:
                log(f"ERROR: {STATE_FILE} is corrupt ({e!r}) and could not be backed up "
                    f"({copy_err!r}); starting fresh — all user auto-resume toggles were lost.")
    return {}


def save_state(state: dict) -> None:
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    tmp = STATE_FILE.with_suffix(".json.tmp")
    tmp.write_text(json.dumps(state, indent=2))
    tmp.replace(STATE_FILE)


# ---------------------------------------------------------------------------
# Session log parsing
# ---------------------------------------------------------------------------

def parse_reset_timestamp(value) -> float | None:
    """rate_limit_event reset fields have shown up as either unix seconds
    or ISO-8601 strings in the wild; handle both."""
    if value is None:
        return None
    if isinstance(value, (int, float)):
        return value / 1000.0 if value > 10**12 else float(value)
    if isinstance(value, str):
        try:
            num = float(value)
        except ValueError:
            num = None
        if num is not None:
            # Route a stringified epoch through the SAME ms->s normalization
            # as the numeric branch above. Without this, "1752900000000"
            # (epoch-milliseconds as a string) returned raw as ~year 57000,
            # so `due = now >= resets_at` never became true and the session
            # never resumed. Epoch-seconds strings ("1752900000") are < 10**12
            # and pass through untouched.
            return num / 1000.0 if num > 10**12 else num
        try:
            return datetime.fromisoformat(value.replace("Z", "+00:00")).timestamp()
        except ValueError:
            log(f"WARNING: could not parse reset timestamp {value!r}")
            return None
    return None


def find_cwd_in_lines(objs: list[dict]) -> str | None:
    # Iterate newest-first: if the session cd'd partway through, the most
    # recent cwd is where a resume should land, not the directory it started
    # in. (The old first-match scan resumed a moved session in its original
    # directory.)
    for obj in reversed(objs):
        for key in ("cwd", "cwdPath", "workingDirectory"):
            val = obj.get(key)
            if isinstance(val, str):
                return val
    return None


def find_prompt_preview(objs: list[dict]) -> str:
    for obj in objs:
        if obj.get("type") == "user":
            message = obj.get("message")
            content = None
            if isinstance(message, dict):
                content = message.get("content")
            elif isinstance(message, str):
                content = message
            if isinstance(content, list):
                for block in content:
                    if isinstance(block, dict) and block.get("type") == "text":
                        content = block.get("text")
                        break
            if isinstance(content, str) and content.strip():
                text = content.strip().replace("\n", " ")
                return text[:100] + ("…" if len(text) > 100 else "")
    return "(no preview available)"


def find_session_title(objs: list[dict]) -> str | None:
    """Claude Code stamps each session with a couple of standalone
    bookkeeping events as the conversation goes: "ai-title" (an
    auto-generated summary) and "custom-title" (set if you or the app
    renamed it). Both can appear multiple times as the conversation
    evolves — later ones supersede earlier ones — and a custom title (if
    ever set) should win over the auto-generated one. This is what lets
    the widget show something like "Test session do nothing" instead of
    just the project folder name, which is all we had before and wasn't
    enough to tell sessions in the same repo apart."""
    ai_title = None
    custom_title = None
    for obj in objs:
        obj_type = obj.get("type")
        if obj_type == "ai-title" and obj.get("aiTitle"):
            ai_title = obj["aiTitle"]
        elif obj_type == "custom-title" and obj.get("customTitle"):
            custom_title = obj["customTitle"]
    return custom_title or ai_title


def guess_project_dir_from_folder(folder_name: str) -> str | None:
    """Best-effort fallback: Claude Code encodes the project's absolute path
    into the folder name (roughly: '/' -> '-'). Not guaranteed reversible if
    the original path itself contained dashes, hence "best-effort"."""
    if folder_name.startswith("-"):
        candidate = "/" + folder_name[1:].replace("-", "/")
        if Path(candidate).is_dir():
            return candidate
    return None


def latest_activity_mtime(jsonl_path: Path) -> float:
    """A session's own top-level transcript file goes quiet the moment work
    gets delegated to a subagent (Task tool) — the subagent's own writes
    land in a sibling <session_id>/subagents/*.jsonl file instead, not in
    the top-level file. Using only the top-level file's mtime made
    long-running sessions with a subagent doing the actual work look idle
    (and eventually age out of the active window entirely) even while
    they were actively running. This returns the most recent mtime across
    the session's own file and any of its subagent transcripts, so
    delegated work counts as activity too."""
    return max(jsonl_path.stat().st_mtime, sidecar_activity_mtime(jsonl_path))


# In-memory parse cache, keyed by transcript path. This daemon is a
# long-lived process, so an in-window transcript that hasn't changed since
# last poll (same file mtime+size) does NOT need re-reading + re-parsing —
# everything cached below is a pure function of file *content*. Memory is
# bounded: compute_cli_records() only ever caches files currently inside the
# scan window and evicts entries whose path has left it. work_status is
# deliberately NOT cached (it depends on `now`, the per-cycle process-table
# snapshot, and live sidecar mtimes), so it's recomputed each cycle from the
# cheap cached objs tail.
_PARSE_CACHE: dict = {}


def _parse_cli_transcript(jsonl_path: Path, file_stat, project_folder: Path) -> dict | None:
    """Read + parse ONE transcript and return the content-derived fields the
    scan needs, or None if the file is unreadable. Everything here is a pure
    function of file content, so the result is valid until the file's
    (mtime, size) changes — that's what makes it cacheable in _PARSE_CACHE."""
    try:
        raw_lines = jsonl_path.read_text(errors="ignore").splitlines()
    except OSError:
        return None

    objs = []
    for raw in raw_lines:
        try:
            objs.append(json.loads(raw))
        except json.JSONDecodeError:
            continue

    # Claude/Claude Code spawn short-lived internal sessions for things like
    # the bash-command permission classifier — each one gets its own session
    # file in the same project directory, sharing entrypoint/promptSource/
    # isSidechain with real sessions. We previously tried to distinguish them
    # by model (internal calls run on Haiku) but that broke: trivial real
    # prompts (e.g. a one-line "test" message) can *also* get routed to Haiku,
    # so that heuristic hid genuine short conversations. The actual reliable
    # signal is the "origin" field Claude Code itself stamps on every "user"
    # event: a message the human actually typed carries origin.kind ==
    # "human". Internal/synthetic prompts (the classifier's "Classify this
    # shell command..." calls, task-notifications, etc.) never have it. A
    # session is "real" if at least one of its user turns is human-originated.
    has_human_message = any(
        obj.get("type") == "user"
        and isinstance(obj.get("origin"), dict)
        and obj["origin"].get("kind") == "human"
        for obj in objs
    )

    # A rate_limit event only reflects the CURRENT state of the session if it
    # is still the effective TAIL of the transcript. A session that hit a
    # limit hours ago and was then manually resumed keeps appending ordinary
    # conversation past that event — the old scan only stopped at
    # "result"/"session_end" (which interactive transcripts rarely contain),
    # so it kept classifying such a live session as "waiting" with a long-past
    # reset time. If the user had pre-enabled auto-resume, resume_due_sessions
    # would then fire a *second* `claude --resume` straight into the session
    # they're actively using. So: walk backwards and stop the moment we meet
    # an ordinary conversational event (a real "user" or "assistant" turn)
    # before finding a rate_limit event — that event is newer than any limit,
    # meaning the session moved on. Non-conversational bookkeeping appended
    # after the limit (ai-title / custom-title / attachments / queue-operation
    # / ...) is skipped so it can't mask a rate_limit that IS still the tail,
    # and the limit's own inline synthetic notice line (model "<synthetic>" /
    # isApiErrorMessage) is skipped for the same reason.
    rate_limit_obj = None
    for obj in reversed(objs):
        obj_type = obj.get("type", "")
        if "rate_limit" in obj_type.lower():
            rate_limit_obj = obj
            break
        if obj_type in ("result", "session_end"):
            break  # session ended normally
        if obj_type in ("user", "assistant"):
            message = obj.get("message") if isinstance(obj.get("message"), dict) else {}
            if obj.get("isApiErrorMessage") or message.get("model") == "<synthetic>":
                continue  # the limit's own inline notice, not a resumption
            break  # a genuine turn newer than any limit — session moved on

    waiting_resets_at = None
    if rate_limit_obj is not None and has_human_message:
        info = (
            rate_limit_obj.get("rateLimitInfo")
            or rate_limit_obj.get("rate_limit_info")
            or rate_limit_obj
        )
        resets_raw = None
        for key in ("resetsAt", "resets_at", "reset_at", "resetAt"):
            if isinstance(info, dict) and key in info:
                resets_raw = info[key]
                break
        waiting_resets_at = parse_reset_timestamp(resets_raw)
        if waiting_resets_at is None:
            log(f"Found rate_limit_event in {jsonl_path} but couldn't read a reset time")

    project_dir = find_cwd_in_lines(objs) or guess_project_dir_from_folder(project_folder.name)
    if not project_dir:
        log(f"Found session {jsonl_path.stem} but couldn't determine its project directory; skipping")

    return {
        "mtime": file_stat.st_mtime,       # cache-validity key (file content)
        "size": file_stat.st_size,
        "has_human_message": has_human_message,
        "waiting_resets_at": waiting_resets_at,
        "project_dir": project_dir or None,
        "session_title": find_session_title(objs),
        "prompt_preview": find_prompt_preview(objs),
        # classify_work_status only ever reads reversed(objs[-400:]); caching
        # just that tail keeps the cache bounded even for enormous transcripts.
        "objs_tail": objs[-400:],
    }


def compute_cli_records(now: float, runtime: dict, cache: dict) -> dict:
    """OUTSIDE StateLock: scan recent CLI transcripts and return
    {session_id: record}. This does NOT read or mutate state.json — it only
    computes what the files say; merge_cli_records() applies that to state
    while the lock is held. Keeping all the file I/O + parsing + work_status
    classification out here is the whole point (the lock was previously held
    across a full re-read of every in-window transcript, every 10s).

    A record's "status" is "active", "waiting", or None. None is meaningful:
    the file is in-window but is not a trackable session right now (no human
    message, or gone quiet, or no current rate limit) — merge will drop any
    existing UNHANDLED entry for it, exactly as the old scan's `status is
    None` branch did. A trackable session whose project dir can't be resolved
    yields no record at all (same as the old skip)."""
    records: dict = {}
    if not PROJECTS_DIR.is_dir():
        return records

    scan_cutoff = now - SCAN_WINDOW_MINUTES * 60
    active_window_seconds = ACTIVE_WINDOW_MINUTES * 60
    in_window_paths = set()

    for project_folder in PROJECTS_DIR.iterdir():
        if not project_folder.is_dir():
            continue
        for jsonl_path in project_folder.glob("*.jsonl"):
            try:
                # latest_activity_mtime() also covers subagent transcripts, so
                # a session whose work is delegated to a subagent still counts
                # as in-window; file_stat is the raw file's own stat, used as
                # the parse-cache validity key.
                activity_mtime = latest_activity_mtime(jsonl_path)
                file_stat = jsonl_path.stat()
            except OSError:
                continue
            if activity_mtime < scan_cutoff:
                continue

            key = str(jsonl_path)
            in_window_paths.add(key)
            session_id = jsonl_path.stem

            cached = cache.get(key)
            if (cached is not None
                    and cached["mtime"] == file_stat.st_mtime
                    and cached["size"] == file_stat.st_size):
                derived = cached
            else:
                derived = _parse_cli_transcript(jsonl_path, file_stat, project_folder)
                if derived is None:
                    continue
                cache[key] = derived

            # Per-cycle status: cheap, depends on now/activity_mtime, not on
            # file content, so it's recomputed here rather than cached.
            if derived["waiting_resets_at"] is not None:
                status = "waiting"
                resets_at = derived["waiting_resets_at"]
            elif derived["has_human_message"] and (now - activity_mtime) <= active_window_seconds:
                status = "active"
                resets_at = None
            else:
                records[session_id] = {"status": None}
                continue

            if derived["project_dir"] is None:
                continue  # couldn't resolve project dir — skip (as old code did)

            work_status = classify_work_status(
                derived["objs_tail"], activity_mtime, now,
                jsonl_path=jsonl_path, session_id=session_id, runtime=runtime,
            )
            records[session_id] = {
                "kind": "cli",
                "status": status,
                "resets_at": resets_at,
                "project_dir": derived["project_dir"],
                "project_name": Path(derived["project_dir"]).name,
                "session_title": derived["session_title"],
                "prompt_preview": derived["prompt_preview"],
                "last_activity_at": activity_mtime,
                "work_status": work_status,
            }

    # Bound memory: forget any cached file that has left the scan window.
    for stale_key in [k for k in cache if k not in in_window_paths]:
        del cache[stale_key]

    return records


def merge_cli_records(state: dict, records: dict, now: float) -> None:
    """INSIDE StateLock: fold computed CLI records into state, preserving
    every widget-owned field (enabled / force_resume / handled / handled_at)
    exactly as the old in-place scan did. New sessions default enabled=False;
    existing ones keep their user toggles across an active -> waiting
    transition. Because state is loaded fresh under the lock, a session the
    widget deleted since the records were computed is simply not present and
    gets re-added as a fresh disabled entry (same as the old scan); a record
    that says None drops an existing unhandled entry."""
    for session_id, rec in records.items():
        existing = state.get(session_id)
        if existing and existing.get("handled"):
            continue  # already resumed/failed once — don't resurrect it

        if rec["status"] is None:
            if existing:
                del state[session_id]  # gone quiet / no rate limit — drop it
            continue

        if existing:
            was_active = existing.get("status") == "active"
            existing["kind"] = "cli"
            existing["project_dir"] = rec["project_dir"]
            existing["project_name"] = rec["project_name"]
            existing["session_title"] = rec["session_title"]
            existing["prompt_preview"] = rec["prompt_preview"]
            existing["status"] = rec["status"]
            existing["resets_at"] = rec["resets_at"]
            existing["last_seen"] = now
            # `last_seen` is poll-cycle bookkeeping (bumped every ~10s while
            # in-window, regardless of real activity), so it's useless as an
            # "activity age" signal. `last_activity_at` (from
            # latest_activity_mtime, which covers subagent transcripts) is the
            # real last-write time the widget shows as "<1m" / "17m" / etc.
            existing["last_activity_at"] = rec["last_activity_at"]
            existing["work_status"] = rec["work_status"]
            if was_active and rec["status"] == "waiting":
                log(f"Session {session_id} in {rec['project_dir']} transitioned active -> rate-limited "
                    f"(enabled={existing.get('enabled', False)} preserved), "
                    f"resets at {datetime.fromtimestamp(rec['resets_at'])}")
        else:
            log(f"Detected {rec['status']} session {session_id} ({rec['session_title']!r}) in {rec['project_dir']}"
                + (f", resets at {datetime.fromtimestamp(rec['resets_at'])}" if rec["resets_at"] else "")
                + " — added to widget, NOT auto-resuming")
            state[session_id] = {
                "kind": "cli",          # explicit type sentinel (see prune_deleted_sessions)
                "project_dir": rec["project_dir"],
                "project_name": rec["project_name"],
                "session_title": rec["session_title"],
                "prompt_preview": rec["prompt_preview"],
                "resets_at": rec["resets_at"],
                "last_activity_at": rec["last_activity_at"],
                "detected_at": now,
                "last_seen": now,
                "enabled": False,       # <-- default OFF; only the widget can flip this
                "force_resume": False,
                "handled": False,
                "handled_at": None,
                "status": rec["status"],
                # Widget-owned display field, daemon-computed each cycle (never
                # user-toggled): "running" / "needs_input" / "idle". See
                # classify_work_status's docstring.
                "work_status": rec["work_status"],
            }


def read_last_jsonl_object(path: Path, initial_chunk: int = 8192) -> dict | None:
    """Returns the last parseable JSON object in a .jsonl file without
    reading the whole thing — audit.jsonl files carry full message content
    and can get large. Seeks backward from the end, growing the read
    window only if the tail chunk doesn't contain a full line yet."""
    try:
        size = path.stat().st_size
        if size == 0:
            return None
        read_size = min(initial_chunk, size)
        with open(path, "rb") as f:
            while True:
                f.seek(size - read_size)
                chunk = f.read(read_size)
                lines = [ln for ln in chunk.split(b"\n") if ln.strip()]
                # Drop a possibly-truncated first line unless we've already
                # read the whole file.
                if read_size < size and len(lines) > 1:
                    lines = lines[1:]
                for raw in reversed(lines):
                    try:
                        return json.loads(raw)
                    except json.JSONDecodeError:
                        continue
                if read_size >= size:
                    return None
                read_size = min(read_size * 4, size)
    except OSError:
        return None


def _truthy(value) -> bool:
    """isArchived and similar fields have shown up as both native JSON
    booleans and stringified "True"/"False" — normalize either way."""
    if isinstance(value, bool):
        return value
    if isinstance(value, str):
        return value.strip().lower() == "true"
    return bool(value)


def compute_cowork_records(now: float) -> dict:
    """OUTSIDE StateLock: scan Cowork sessions (including Claude Desktop's
    Cowork mode) and return {session_id: record}. Cowork sessions don't write
    into ~/.claude/projects — they get their own metadata file plus an
    audit.jsonl activity log under COWORK_SESSIONS_DIR — and have no
    rate-limit/resume cycle: Cowork manages its own retries, so these are only
    ever tracked as "active". A record's "status" is "active", or None meaning
    "drop any existing unhandled entry" (archived, gone quiet, or last audit
    event shows the turn finished). No state.json access here; the audit-tail
    read is already cheap (read_last_jsonl_object seeks from the end), so no
    parse cache is needed for these."""
    records: dict = {}
    if not COWORK_SESSIONS_DIR.is_dir():
        return records

    scan_cutoff_ms = (now - SCAN_WINDOW_MINUTES * 60) * 1000

    for meta_path in COWORK_SESSIONS_DIR.rglob("local_*.json"):
        # Sibling directory of the same name holds audit.jsonl; if it's not
        # there this isn't a session metadata file (or the session was
        # cleaned up already).
        session_dir = meta_path.with_suffix("")
        audit_path = session_dir / "audit.jsonl"
        if not session_dir.is_dir() or not audit_path.exists():
            continue

        try:
            meta = json.loads(meta_path.read_text(errors="ignore"))
        except (OSError, json.JSONDecodeError):
            continue

        if _truthy(meta.get("isArchived")):
            continue

        session_id = meta.get("sessionId") or meta_path.stem

        try:
            last_activity_ms = float(meta.get("lastActivityAt", 0))
        except (TypeError, ValueError):
            last_activity_ms = 0
        if last_activity_ms and last_activity_ms < scan_cutoff_ms:
            records[session_id] = {"status": None}  # gone quiet — drop if tracked
            continue

        last_event = read_last_jsonl_object(audit_path)
        # A finished turn ends in a "result" event. Anything else at the tail
        # (assistant/user/tool events, or a "system" event mid-request) means
        # the session is still actively working.
        is_running = bool(last_event) and last_event.get("type") != "result"
        if not is_running:
            records[session_id] = {"status": None}
            continue

        # meta's lastActivityAt is epoch milliseconds; convert to seconds to
        # match every other timestamp field in state.json. Fall back to `now`
        # if the field was missing/unparsable, rather than storing an epoch-0
        # timestamp that would render as a nonsensical decades-old age.
        last_activity_at = (last_activity_ms / 1000.0) if last_activity_ms else now
        records[session_id] = {
            "kind": "cowork",
            "status": "active",
            "project_dir": str(session_dir),
            "session_title": meta.get("title") or "Cowork session",
            "last_activity_at": last_activity_at,
        }

    return records


def merge_cowork_records(state: dict, records: dict, now: float) -> None:
    """INSIDE StateLock: fold computed Cowork records into state. Same
    contract as merge_cli_records — preserve widget-owned fields
    (resume_armed / needs_attention / enabled / handled), default new entries
    off. A None-status record drops an existing unhandled entry."""
    for session_id, rec in records.items():
        existing = state.get(session_id)
        if existing and existing.get("handled"):
            continue

        if rec["status"] is None:
            if existing:
                del state[session_id]
            continue

        if existing:
            existing["kind"] = "cowork"
            existing["project_dir"] = rec["project_dir"]
            existing["project_name"] = "Cowork"
            existing["session_title"] = rec["session_title"]
            existing["prompt_preview"] = ""
            existing["status"] = "active"
            existing["resets_at"] = None
            existing["last_seen"] = now
            existing["last_activity_at"] = rec["last_activity_at"]
            # Cowork entries only survive in state while still running (a
            # finished turn yields a None record above and gets dropped this
            # very cycle), so by construction every surviving entry is
            # "running". There's no local signal yet to distinguish "actively
            # computing" from "blocked on a permission prompt" for Cowork.
            existing["work_status"] = "running"
        else:
            log(f"Detected active Cowork session {session_id} ({rec['session_title']!r}) — added to widget")
            state[session_id] = {
                "kind": "cowork",       # explicit type sentinel (see prune_deleted_sessions)
                "project_dir": rec["project_dir"],
                "project_name": "Cowork",
                "session_title": rec["session_title"],
                "prompt_preview": "",
                "resets_at": None,
                "detected_at": now,
                "last_seen": now,
                "last_activity_at": rec["last_activity_at"],
                "enabled": False,
                "force_resume": False,
                "handled": False,
                "handled_at": None,
                "status": "active",
                "work_status": "running",
                # Widget-owned, additive fields (Track 1: Cowork auto-resume
                # via UI automation — see cowork_resume.py). Same pattern as
                # enabled/force_resume: default off, only the widget flips
                # resume_armed, only cowork_resume.py flips needs_attention.
                # The `existing` branch above never touches these keys, so they
                # survive every cycle once set, exactly like enabled does.
                "resume_armed": False,
                "needs_attention": False,
            }


def resume_due_sessions(state: dict) -> None:
    now = time.time()
    for session_id, entry in state.items():
        if entry.get("handled"):
            continue
        if entry.get("status") != "waiting" or entry.get("resets_at") is None:
            continue  # "active" sessions have nothing to resume yet

        force = entry.get("force_resume", False)
        enabled = entry.get("enabled", False)
        due = now >= entry["resets_at"] + RESET_BUFFER_SECONDS

        if not (force or (enabled and due)):
            continue

        project_dir = entry["project_dir"]
        reason = "forced from widget" if force else "enabled + reset time reached"
        log(f"Resuming session {session_id} ({project_dir}) — {reason}")

        LOG_DIR.mkdir(parents=True, exist_ok=True)
        session_log = LOG_DIR / f"{session_id}.log"

        cmd = [
            CLAUDE_BIN,
            "--resume", session_id,
            "--print", RESUME_PROMPT,
            "--output-format", "json",
            "--permission-mode", PERMISSION_MODE,
        ]

        try:
            with open(session_log, "a") as f:
                f.write(f"\n--- auto-resume attempt at {datetime.now().isoformat()} ({reason}) ---\n")
                f.write(f"cmd: {' '.join(cmd)}\n\n")
                f.flush()
                subprocess.Popen(cmd, cwd=project_dir, stdout=f, stderr=subprocess.STDOUT)
            log(f"Launched resume for {session_id}, output logging to {session_log}")
            entry["status"] = "resumed"
        except FileNotFoundError:
            log(f"ERROR: could not find '{CLAUDE_BIN}' executable. Set CLAUDE_BIN in the launchd plist's environment.")
            entry["status"] = "failed"
        except OSError as e:
            log(f"ERROR launching resume for {session_id}: {e}")
            entry["status"] = "failed"

        entry["handled"] = True
        entry["handled_at"] = now
        entry["force_resume"] = False


def prune_deleted_sessions(state: dict) -> None:
    """Immediate cleanup for sessions removed via Claude Desktop's own GUI
    (its "Delete" action archives — sets isArchived: true on the metadata —
    rather than touching files on disk; confirmed by reading
    AutoArchiveEngine in Claude.app's own app.asar, which treats isArchived
    as the terminal state for a session).

    Without this, a deleted session lingers: the scan/merge path only ever
    cleans up an entry when it *revisits* the backing file/metadata and finds
    it stale — but compute_cowork_records skips archived entries entirely
    (they never produce a record), and compute_cli_records never revisits a
    jsonl file that no longer exists at all. Either way the entry just sits in
    state.json,
    frozen, until prune_old_entries' much looser ACTIVE_STALE_MINUTES
    (60 min) safety net eventually catches it — that's the delay reported as
    "deleted sessions keep showing up in the widget".

    This checks existence/archived-state directly (independent of any
    mtime/scan-window cutoff) so a deletion is reflected on the very next
    poll cycle instead. Only touches un-`handled` entries — handled ones
    (already resumed or failed) are prune_old_entries' business, not this
    one's.

    Note: this only catches sessions whose *backing file is actually gone or
    archived*. A CLI/Code session's raw ~/.claude/projects transcript isn't
    necessarily touched by deleting Desktop's own imported copy of it (that
    copy is a separate `local_<id>` wrapper — see OverlayView.openLocalSession
    in the widget) — if the underlying transcript still exists, the widget
    is correctly reflecting a CLI session that's still genuinely there.
    """
    if not state:
        return

    existing_jsonl_stems = set()
    if PROJECTS_DIR.is_dir():
        for project_folder in PROJECTS_DIR.iterdir():
            if project_folder.is_dir():
                existing_jsonl_stems.update(p.stem for p in project_folder.glob("*.jsonl"))

    live_cowork_ids = set()
    if COWORK_SESSIONS_DIR.is_dir():
        for meta_path in COWORK_SESSIONS_DIR.rglob("local_*.json"):
            session_dir = meta_path.with_suffix("")
            if not session_dir.is_dir() or not (session_dir / "audit.jsonl").exists():
                continue
            try:
                meta = json.loads(meta_path.read_text(errors="ignore"))
            except (OSError, json.JSONDecodeError):
                continue
            if _truthy(meta.get("isArchived")):
                continue
            live_cowork_ids.add(meta.get("sessionId") or meta_path.stem)

    stale = []
    for session_id, entry in state.items():
        if entry.get("handled"):
            continue
        # Prefer the explicit "kind" sentinel the daemon now writes on every
        # entry; fall back to the old project_name == "Cowork" check only for
        # entries written by an older daemon (no "kind" yet). This is why kind
        # exists: a CLI project directory literally named "Cowork" used to make
        # its sessions take the Cowork branch here and get deleted every cycle
        # (never live in live_cowork_ids), so they could never appear.
        kind = entry.get("kind")
        is_cowork = (kind == "cowork") if kind is not None else (entry.get("project_name") == "Cowork")
        if is_cowork:
            if session_id not in live_cowork_ids:
                stale.append(session_id)
        elif session_id not in existing_jsonl_stems:
            stale.append(session_id)

    for session_id in stale:
        log(f"Session {session_id} deleted/archived on disk — removing from widget immediately")
        del state[session_id]


def prune_old_entries(state: dict) -> None:
    now = time.time()
    handled_cutoff = now - PRUNE_AFTER_HOURS * 3600
    active_cutoff = now - ACTIVE_STALE_MINUTES * 60

    stale = []
    for sid, e in state.items():
        if e.get("handled") and (e.get("handled_at") or 0) < handled_cutoff:
            stale.append(sid)
            continue
        if e.get("status") == "active" and not e.get("handled"):
            last_seen = e.get("last_seen", e.get("detected_at", 0))
            if last_seen < active_cutoff:
                stale.append(sid)  # went quiet and never got rate-limited

    for sid in stale:
        del state[sid]


def _usage_analytics_worker() -> None:
    """Usage analytics (hourly collect/compact/plan_fit + daily pricing
    refresh) on its OWN daemon thread, off the poll thread. These passes can
    be slow (network fetch, whole-store rewrites); running them inline in the
    poll loop meant a slow pass delayed rate-limit detection by however long
    it took. Passes run sequentially in this single loop, so there's never an
    overlapping run to guard against. Everything here touches only
    STATE_DIR/usage/* (never state.json), and collect()/compact() take their
    own file locks, so cross-process/-thread safety is unchanged."""
    # 0 = run on the first iteration, so a fresh deploy bootstraps the usage
    # store immediately instead of waiting a full interval.
    last_usage_run = 0.0
    last_pricing_run = 0.0
    while True:
        try:
            now_mono = time.time()
            if now_mono - last_pricing_run >= PRICING_REFRESH_INTERVAL_SECONDS:
                last_pricing_run = now_mono
                plan_fit.refresh_pricing(STATE_DIR)
            if now_mono - last_usage_run >= USAGE_COLLECT_INTERVAL_SECONDS:
                last_usage_run = now_mono
                usage_collector.collect(STATE_DIR, quiet=True)
                usage_collector.compact(STATE_DIR, quiet=True)
                plan_fit.write_plan_fit(STATE_DIR, datetime.now().astimezone())
                log("usage analytics: collected, compacted, plan_fit.json refreshed")
        except Exception as e:
            log(f"ERROR in usage analytics cycle: {e!r}")
        time.sleep(POLL_INTERVAL_SECONDS)


def main() -> None:
    log(f"claude-autoresume daemon starting (poll every {POLL_INTERVAL_SECONDS}s). "
        f"Default is OFF for every detected session — resumes only happen via the widget.")
    log(f"Watching {PROJECTS_DIR} and {COWORK_SESSIONS_DIR}")

    # Usage analytics runs on its own daemon thread so a slow analytics pass
    # can't stall the session poll below (P6). daemon=True so it dies with the
    # process; it holds no state.json lock, so nothing to clean up on exit.
    threading.Thread(target=_usage_analytics_worker, name="usage-analytics", daemon=True).start()

    while True:
        try:
            # File reading, JSON parsing and work_status classification all
            # happen OUT here, before the lock, producing plain records. The
            # StateLock is then held only long enough to load fresh state,
            # merge the records in (preserving widget-owned toggles), run the
            # resume/prune steps, and save — not across a full re-read of every
            # in-window transcript, every 10s, as it used to be.
            now = time.time()
            runtime = collect_runtime_snapshot()
            cli_records = compute_cli_records(now, runtime, _PARSE_CACHE)
            cowork_records = compute_cowork_records(now)
            with StateLock():
                state = load_state()
                merge_cli_records(state, cli_records, now)
                merge_cowork_records(state, cowork_records, now)
                resume_due_sessions(state)
                # Track 1 scaffolding: dry-run only (see cowork_resume.DRY_RUN).
                # Only touches Cowork sessions the widget has explicitly armed
                # via resume_armed; logs intended actions to daemon.log instead
                # of performing any live UI automation.
                cowork_resume.process_armed_sessions(state, log)
                prune_deleted_sessions(state)
                prune_old_entries(state)
                save_state(state)
        except Exception as e:  # daemon must never die from a single bad cycle
            log(f"ERROR in poll cycle: {e!r}")
        time.sleep(POLL_INTERVAL_SECONDS)


if __name__ == "__main__":
    sys.exit(main())
