#!/usr/bin/env python3
"""
usage_collector.py
===================

Data-collection half of the usage-tracking feature. Standalone module, NOT
wired into autoresume.py's poll loop by this file — the architect does that
wiring separately. Runs on SYSTEM python3 (same launchd context as
autoresume.py), so this module is PURE STDLIB, no pip dependencies.

Two independently useful entry points:

  collect(state_dir)  Incremental pass: parse *new* per-message usage events
                       out of both jsonl sources below and fold them into an
                       hourly-bucketed, durable token-usage store. Idempotent
                       and cheap — safe to call every 30s, intended to run
                       roughly hourly.

  compact(state_dir)  Downsamples the widget's utilization snapshots
                       (snapshots.jsonl, appended every 2 min by the Swift
                       side — not written by this module) per the retention
                       policy in the "Snapshot compaction" section below.

Sources of usage events
------------------------
1. Claude Code CLI session transcripts: ~/.claude/projects/*/*.jsonl, plus
   their subagent transcripts at
   ~/.claude/projects/*/<session_id>/subagents/*.jsonl (subagents burn
   tokens too — see autoresume.py's latest_activity_mtime() for the same
   directory-layout assumption). Each "assistant"-type line looks like:

     {"message": {"id": "msg_...", "model": "claude-...",
                  "usage": {"input_tokens": N, "output_tokens": N,
                            "cache_creation_input_tokens": N,
                            "cache_read_input_tokens": N,
                            "server_tool_use": {"web_search_requests": N, ...},
                            ...}},
      "requestId": "req_...", "type": "assistant", "timestamp": "...Z", ...}

2. Cowork audit logs: ~/Library/Application Support/Claude/
   local-agent-mode-sessions/**/audit.jsonl (see autoresume.py's
   COWORK_SESSIONS_DIR). Same "assistant"-type usage shape, but with two
   real-world schema differences discovered by inspecting live files:
     - the request id lives at "request_id" (snake_case), not "requestId".
     - "server_tool_use" is sometimes entirely absent from usage (treated
       as all-zero, not an error).
   Cowork's "result"-type lines carry a *cumulative* usage rollup across the
   whole turn (all iterations) — deliberately NOT parsed here, since it
   would double-count usage already attributed to the individual
   "assistant" lines that make it up. Only "assistant" lines are read.

CRITICAL — dedupe
------------------
Verified against a live session transcript: a single logical assistant
turn is written as *multiple* consecutive "assistant" lines as content
streams in (one per content block — thinking, then tool_use, etc), and
EVERY one of those lines repeats the SAME message.id, the SAME requestId,
and the SAME (already-cumulative) usage payload. Summing usage per-line
would overcount by however many content blocks the message had (observed
up to 4x on a real transcript). The fix, matching the community `ccusage`
tool: dedupe by (message.id, requestId), falling back to message.id alone
when requestId is absent. Only the first occurrence of a given key is ever
folded into the totals.

Dedupe ledger bounding: a duplicate's repeat lines were only ever observed
a few lines apart (never split across unrelated messages), so we don't
need to remember every id a file has ever produced — only a small trailing
window of recently-seen ids for files still being actively appended to
("hot" files). Once a file has gone quiet for HOT_WINDOW_SECONDS, its
seen-id list is dropped; the persisted per-file byte offset alone is
sufficient from then on, since bytes before that offset are never
re-read (this also correctly handles `claude --resume` reviving an
old, cold session file after days of inactivity — new bytes land after
the saved offset, no replay, no need for the old ledger).

Persistent store: ~/.claude-autoresume/usage/tokens_hourly.json
------------------------------------------------------------------
Survives Claude Code's ~30-day transcript pruning by design — this store
*is* the durable record past that window. Hourly buckets are kept forever
(they're tiny). Written atomically (temp file + rename). This is a
collector-private file with its own lock (usage_collect.lock) — deliberately
NOT autoresume.py's state.json.lock.

Snapshot compaction: ~/.claude-autoresume/usage/snapshots*.jsonl
------------------------------------------------------------------
snapshots.jsonl (raw, 2-min rows, written by the widget — not this module)
  -> kept 24h, then downsampled into 15-min buckets in snapshots_15m.jsonl
snapshots_15m.jsonl
  -> kept 30 days, then downsampled into 1-hour buckets in snapshots_1h.jsonl
snapshots_1h.jsonl
  -> kept forever.

Bucket rows look like:
  {"ts_start": "...", "n": count,
   "five_hour": {"min":.., "max":.., "avg":.., "last":..},
   "seven_day": {"min":.., "max":.., "avg":.., "last":..}}
plus a few underscore-prefixed bookkeeping fields (_sum/_n/_last_ts) inside
each of those "five_hour"/"seven_day" dicts. Those are intentionally
persisted (not just computed transiently) because a bucket can receive
contributions across more than one compact() run (e.g. a 1-hour bucket is
fed by four 15-min buckets that may age past the 30-day mark at slightly
different times) — the bookkeeping fields are what let a later merge
recompute avg/last correctly without re-reading data that's already been
discarded from the finer-grained tier. Consumers that only care about the
documented min/max/avg/last fields can simply ignore the rest. MAX matters
most for the product (peak utilization analysis) and is preserved exactly
through every tier, never averaged away.
"""

from __future__ import annotations

import argparse
import fcntl
import json
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

# ---------------------------------------------------------------------------
# Config (mirrors autoresume.py's constants where the source is the same)
# ---------------------------------------------------------------------------

HOME = Path.home()
PROJECTS_DIR = HOME / ".claude" / "projects"
COWORK_SESSIONS_DIR = HOME / "Library" / "Application Support" / "Claude" / "local-agent-mode-sessions"

DEFAULT_STATE_DIR = HOME / ".claude-autoresume"
USAGE_SUBDIR = "usage"
TOKENS_FILENAME = "tokens_hourly.json"
COLLECT_LOCK_FILENAME = "usage_collect.lock"
SNAPSHOTS_RAW_FILENAME = "snapshots.jsonl"
SNAPSHOTS_15M_FILENAME = "snapshots_15m.jsonl"
SNAPSHOTS_1H_FILENAME = "snapshots_1h.jsonl"

STORE_VERSION = 1

SOURCE_CODE_CLI = "code_cli"
SOURCE_COWORK = "cowork"

USAGE_FIELDS = ("input", "output", "cache_write", "cache_read", "web_searches", "messages")

# A source file that hasn't been modified in this long is considered "cold":
# safe to drop its recent-dedupe-id ledger (see module docstring). Generous
# relative to both the 30s daemon poll cadence and an hourly collect() cadence.
HOT_WINDOW_SECONDS = 15 * 60
# Hard cap on how many recent dedupe keys we retain per hot file. Duplicate
# emissions have only ever been observed within a handful of adjacent lines
# of each other, so this is a wide safety margin, not a tuned-to-the-wire limit.
MAX_SEEN_IDS_PER_FILE = 200

# Snapshot compaction retention/bucket policy.
RAW_RETENTION_SECONDS = 24 * 3600
FIFTEEN_MIN_RETENTION_SECONDS = 30 * 24 * 3600
BUCKET_15M_SECONDS = 15 * 60
BUCKET_1H_SECONDS = 3600


def _log(msg: str) -> None:
    print(f"[{datetime.now().isoformat(timespec='seconds')}] usage_collector: {msg}", flush=True)


# ---------------------------------------------------------------------------
# Paths / atomic IO
# ---------------------------------------------------------------------------

def usage_dir(state_dir: Path) -> Path:
    d = state_dir / USAGE_SUBDIR
    d.mkdir(parents=True, exist_ok=True)
    return d


def tokens_path(state_dir: Path) -> Path:
    return usage_dir(state_dir) / TOKENS_FILENAME


def snapshots_raw_path(state_dir: Path) -> Path:
    return usage_dir(state_dir) / SNAPSHOTS_RAW_FILENAME


def snapshots_15m_path(state_dir: Path) -> Path:
    return usage_dir(state_dir) / SNAPSHOTS_15M_FILENAME


def snapshots_1h_path(state_dir: Path) -> Path:
    return usage_dir(state_dir) / SNAPSHOTS_1H_FILENAME


def _atomic_write_json(path: Path, data: dict) -> None:
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(json.dumps(data, indent=2, sort_keys=True))
    tmp.replace(path)


def _atomic_write_text(path: Path, text: str) -> None:
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(text)
    tmp.replace(path)


class _CollectLock:
    """Exclusive lock private to this collector. collect() must tolerate
    concurrent invocation (e.g. a daemon poll and a manual CLI run
    overlapping) without corrupting tokens_hourly.json — but this
    deliberately does NOT touch autoresume.py's state.json.lock; that lock
    is for the shared session state file, this store is collector-private."""

    def __init__(self, state_dir: Path):
        self._path = usage_dir(state_dir) / COLLECT_LOCK_FILENAME
        self._fh = None

    def __enter__(self):
        self._fh = open(self._path, "w")
        fcntl.flock(self._fh, fcntl.LOCK_EX)
        return self

    def __exit__(self, *exc):
        fcntl.flock(self._fh, fcntl.LOCK_UN)
        self._fh.close()


# ---------------------------------------------------------------------------
# tokens_hourly.json store
# ---------------------------------------------------------------------------

def _empty_store() -> dict:
    return {"version": STORE_VERSION, "hours": {}, "progress": {}}


def load_store(state_dir: Path) -> dict:
    path = tokens_path(state_dir)
    if path.exists():
        try:
            data = json.loads(path.read_text())
            if isinstance(data, dict) and "hours" in data and "progress" in data:
                data.setdefault("version", STORE_VERSION)
                return data
        except (json.JSONDecodeError, OSError):
            _log(f"WARNING: could not parse {path}, starting fresh")
    return _empty_store()


def save_store(state_dir: Path, store: dict) -> None:
    _atomic_write_json(tokens_path(state_dir), store)


def _zero_usage() -> dict:
    return {k: 0 for k in USAGE_FIELDS}


def _hour_key(ts: str | None, fallback_epoch: float) -> str:
    """UTC hour bucket key, e.g. '2026-07-18T14'."""
    if isinstance(ts, str):
        try:
            dt = datetime.fromisoformat(ts.replace("Z", "+00:00")).astimezone(timezone.utc)
            return dt.strftime("%Y-%m-%dT%H")
        except ValueError:
            pass
    return datetime.fromtimestamp(fallback_epoch, tz=timezone.utc).strftime("%Y-%m-%dT%H")


def _dedupe_key(msg_id: str | None, request_id: str | None) -> str | None:
    if not msg_id:
        return None
    return f"{msg_id}|{request_id or ''}"


# ---------------------------------------------------------------------------
# Source file discovery
# ---------------------------------------------------------------------------

def _iter_code_cli_files(projects_dir: Path):
    """Top-level Code CLI session transcripts plus their subagent
    transcripts, mirroring autoresume.py's latest_activity_mtime() layout
    assumption: <project>/<session_id>.jsonl and
    <project>/<session_id>/subagents/*.jsonl."""
    if not projects_dir.is_dir():
        return
    for project_folder in sorted(projects_dir.iterdir()):
        if not project_folder.is_dir():
            continue
        for jsonl_path in sorted(project_folder.glob("*.jsonl")):
            yield jsonl_path
            subagents_dir = jsonl_path.parent / jsonl_path.stem / "subagents"
            if subagents_dir.is_dir():
                for sub_path in sorted(subagents_dir.glob("*.jsonl")):
                    yield sub_path


def _iter_cowork_files(cowork_dir: Path):
    if not cowork_dir.is_dir():
        return
    yield from sorted(cowork_dir.rglob("audit.jsonl"))


# ---------------------------------------------------------------------------
# Incremental per-file scan
# ---------------------------------------------------------------------------

def _scan_file(path: Path, progress: dict, hours: dict, source: str, now: float) -> tuple[int, int]:
    """Reads only the bytes appended to `path` since the last collect()
    pass, parses complete JSON lines, and folds any not-yet-seen assistant
    usage event into `hours`. Returns (events_added, malformed_lines)."""
    key = str(path)
    try:
        st = path.stat()
    except OSError:
        return (0, 0)

    entry = progress.get(key) or {"offset": 0, "size": 0, "mtime": 0.0, "seen_ids": []}

    if st.st_size < entry["offset"]:
        # File shrank or was replaced outright -- our offset bookkeeping is
        # no longer trustworthy. Rescanning from scratch risks a one-time
        # recount, but that's far safer than silently missing a rewritten
        # file forever.
        _log(f"WARNING: {path} shrank from {entry['offset']} to {st.st_size} bytes; rescanning from start")
        entry = {"offset": 0, "size": 0, "mtime": 0.0, "seen_ids": []}

    if st.st_size == entry["offset"]:
        # Nothing new to read. Still worth aging out the dedupe ledger if
        # the file has gone cold, so the store doesn't grow forever.
        if entry["seen_ids"] and (now - st.st_mtime) > HOT_WINDOW_SECONDS:
            entry = dict(entry, seen_ids=[])
        entry["mtime"] = st.st_mtime
        entry["size"] = st.st_size
        progress[key] = entry
        return (0, 0)

    seen_order = list(entry.get("seen_ids") or [])
    seen_set = set(seen_order)
    added = 0
    malformed = 0

    with open(path, "rb") as f:
        f.seek(entry["offset"])
        chunk = f.read()

    # Only consume complete (newline-terminated) lines; a trailing partial
    # line -- the file is still mid-write -- is left for the next pass.
    consumed = 0
    for raw in chunk.split(b"\n"):
        line_len = len(raw) + 1  # +1 for the '\n' this piece was split on
        if consumed + line_len > len(chunk):
            break  # trailing partial line (no terminating '\n' yet)
        consumed += line_len
        text = raw.strip()
        if not text:
            continue
        try:
            obj = json.loads(text)
        except json.JSONDecodeError:
            malformed += 1
            continue
        if obj.get("type") != "assistant":
            continue
        if obj.get("isApiErrorMessage"):
            # Claude Code locally synthesizes an "assistant" line to display
            # things like a rate-limit notice inline in the transcript --
            # e.g. model: "<synthetic>", all-zero usage, "error": "rate_limit".
            # Never hit a real model, so it must not be counted as a message.
            continue
        message = obj.get("message")
        if not isinstance(message, dict):
            continue
        if message.get("model") == "<synthetic>":
            continue
        usage = message.get("usage")
        if not isinstance(usage, dict):
            continue

        msg_id = message.get("id")
        request_id = obj.get("requestId") or obj.get("request_id")
        dkey = _dedupe_key(msg_id, request_id)
        if dkey is None or dkey in seen_set:
            continue
        seen_set.add(dkey)
        seen_order.append(dkey)

        model = message.get("model") or "unknown"
        hour = _hour_key(obj.get("timestamp"), now)
        stu = usage.get("server_tool_use") or {}

        bucket = hours.setdefault(hour, {}).setdefault(source, {}).setdefault(model, _zero_usage())
        bucket["input"] += int(usage.get("input_tokens") or 0)
        bucket["output"] += int(usage.get("output_tokens") or 0)
        bucket["cache_write"] += int(usage.get("cache_creation_input_tokens") or 0)
        bucket["cache_read"] += int(usage.get("cache_read_input_tokens") or 0)
        bucket["web_searches"] += int(stu.get("web_search_requests") or 0)
        bucket["messages"] += 1
        added += 1

    new_offset = entry["offset"] + consumed
    is_hot = (now - st.st_mtime) <= HOT_WINDOW_SECONDS
    seen_list = seen_order[-MAX_SEEN_IDS_PER_FILE:] if is_hot else []

    progress[key] = {
        "offset": new_offset,
        "size": st.st_size,
        "mtime": st.st_mtime,
        "seen_ids": seen_list,
    }
    return (added, malformed)


# ---------------------------------------------------------------------------
# collect()
# ---------------------------------------------------------------------------

def collect(
    state_dir: Path,
    now: float | None = None,
    projects_dir: Path | None = None,
    cowork_dir: Path | None = None,
    quiet: bool = False,
) -> None:
    """Incremental collection pass. Safe to call every 30s; cheap enough to
    run hourly. `now`/`projects_dir`/`cowork_dir` are injectable for tests;
    real callers should just pass state_dir."""
    now = time.time() if now is None else now
    projects_dir = PROJECTS_DIR if projects_dir is None else projects_dir
    cowork_dir = COWORK_SESSIONS_DIR if cowork_dir is None else cowork_dir

    with _CollectLock(state_dir):
        store = load_store(state_dir)
        hours = store["hours"]
        progress = store["progress"]

        files_seen = 0
        total_added = 0
        total_malformed = 0

        for path in _iter_code_cli_files(projects_dir):
            files_seen += 1
            added, malformed = _scan_file(path, progress, hours, SOURCE_CODE_CLI, now)
            total_added += added
            total_malformed += malformed

        for path in _iter_cowork_files(cowork_dir):
            files_seen += 1
            added, malformed = _scan_file(path, progress, hours, SOURCE_COWORK, now)
            total_added += added
            total_malformed += malformed

        # Drop bookkeeping for files that no longer exist (Claude Code prunes
        # transcripts after ~30 days) -- their contribution to `hours` is
        # already durably folded in, which is the entire point of this store
        # outliving the transcript retention window.
        for k in list(progress.keys()):
            if not Path(k).exists():
                del progress[k]

        save_store(state_dir, store)

    if not quiet:
        msg = f"collect: scanned {files_seen} files, {total_added} new usage events"
        if total_malformed:
            msg += f", {total_malformed} malformed lines skipped"
        _log(msg)


# ---------------------------------------------------------------------------
# Snapshot compaction
# ---------------------------------------------------------------------------

def _read_jsonl_rows(path: Path) -> tuple[list[dict], int]:
    """Tolerates a missing file (returns no rows, no error) and malformed
    lines (skipped, counted, never crash the pass)."""
    if not path.exists():
        return [], 0
    rows: list[dict] = []
    malformed = 0
    try:
        text = path.read_text(errors="ignore")
    except OSError:
        return [], 0
    for line in text.splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            obj = json.loads(line)
        except json.JSONDecodeError:
            malformed += 1
            continue
        if isinstance(obj, dict):
            rows.append(obj)
        else:
            malformed += 1
    return rows, malformed


def _write_jsonl_rows(path: Path, rows: list[dict]) -> None:
    text = "".join(json.dumps(r, sort_keys=True) + "\n" for r in rows)
    _atomic_write_text(path, text)


def _parse_ts(ts) -> float | None:
    if not isinstance(ts, str):
        return None
    try:
        return datetime.fromisoformat(ts.replace("Z", "+00:00")).astimezone(timezone.utc).timestamp()
    except ValueError:
        return None


def _bucket_ts_start(epoch: float, bucket_seconds: int) -> str:
    floored = (int(epoch) // bucket_seconds) * bucket_seconds
    return datetime.fromtimestamp(floored, tz=timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _extract_util(row: dict, field: str) -> float | None:
    """Reads a utilization value out of either a raw snapshot row
    ({"utilization": N}) or an already-bucketed row ({"max": N, ...}),
    whichever this row happens to be."""
    sub = row.get(field)
    if not isinstance(sub, dict):
        return None
    for key in ("utilization", "max"):
        v = sub.get(key)
        if isinstance(v, (int, float)):
            return float(v)
    return None


def _new_field_stat() -> dict:
    return {"min": None, "max": None, "avg": None, "last": None, "_sum": 0.0, "_n": 0, "_last_ts": None}


def _update_field_stat_from_raw(field: dict, value: float, ts_epoch: float) -> None:
    field["min"] = value if field["min"] is None else min(field["min"], value)
    field["max"] = value if field["max"] is None else max(field["max"], value)
    field["_sum"] = field.get("_sum", 0.0) + value
    field["_n"] = field.get("_n", 0) + 1
    field["avg"] = field["_sum"] / field["_n"]
    if field.get("_last_ts") is None or ts_epoch >= field["_last_ts"]:
        field["last"] = value
        field["_last_ts"] = ts_epoch


def _merge_field_stat(target: dict, source: dict) -> None:
    """Folds an already-aggregated field stat (e.g. a 15-min bucket's
    "five_hour") into a coarser bucket's field stat. Safe to call multiple
    times across separate compact() runs -- see module docstring."""
    s_n = source.get("_n", 0) or 0
    if s_n == 0:
        return
    if source.get("min") is not None:
        target["min"] = source["min"] if target["min"] is None else min(target["min"], source["min"])
    if source.get("max") is not None:
        target["max"] = source["max"] if target["max"] is None else max(target["max"], source["max"])
    target["_sum"] = target.get("_sum", 0.0) + source.get("_sum", 0.0)
    target["_n"] = target.get("_n", 0) + s_n
    target["avg"] = target["_sum"] / target["_n"] if target["_n"] else None
    s_last_ts = source.get("_last_ts")
    if s_last_ts is not None and (target.get("_last_ts") is None or s_last_ts >= target["_last_ts"]):
        target["last"] = source.get("last")
        target["_last_ts"] = s_last_ts


def _new_bucket(ts_start: str) -> dict:
    return {"ts_start": ts_start, "n": 0, "five_hour": _new_field_stat(), "seven_day": _new_field_stat()}


def _load_bucket_map(rows: list[dict]) -> dict:
    m: dict[str, dict] = {}
    for row in rows:
        ts_start = row.get("ts_start")
        if isinstance(ts_start, str):
            m[ts_start] = row
    return m


def _bucket_raw_rows(bucket_map: dict, epoch_rows: list[tuple[float, dict]], bucket_seconds: int) -> None:
    """raw snapshot rows -> bucket_map (used for raw -> 15m)."""
    for epoch, row in epoch_rows:
        ts_start = _bucket_ts_start(epoch, bucket_seconds)
        bucket = bucket_map.setdefault(ts_start, _new_bucket(ts_start))
        bucket["n"] += 1
        for field_name in ("five_hour", "seven_day"):
            val = _extract_util(row, field_name)
            if val is not None:
                _update_field_stat_from_raw(bucket[field_name], val, epoch)


def _bucket_agg_rows(bucket_map: dict, epoch_rows: list[tuple[float, dict]], bucket_seconds: int) -> None:
    """already-bucketed rows -> coarser bucket_map (used for 15m -> 1h)."""
    for epoch, row in epoch_rows:
        ts_start = _bucket_ts_start(epoch, bucket_seconds)
        bucket = bucket_map.setdefault(ts_start, _new_bucket(ts_start))
        bucket["n"] += row.get("n", 0) or 0
        for field_name in ("five_hour", "seven_day"):
            src = row.get(field_name)
            if isinstance(src, dict):
                _merge_field_stat(bucket[field_name], src)


def compact(state_dir: Path, now: float | None = None, quiet: bool = False) -> None:
    """Downsamples snapshot files per the retention policy (module
    docstring). Tolerates the files not existing yet and malformed lines
    (skipped + counted). `now` is injectable for tests."""
    now = time.time() if now is None else now

    raw_path = snapshots_raw_path(state_dir)
    m15_path = snapshots_15m_path(state_dir)
    h1_path = snapshots_1h_path(state_dir)

    raw_cutoff = now - RAW_RETENTION_SECONDS
    m15_cutoff = now - FIFTEEN_MIN_RETENTION_SECONDS

    total_malformed = 0

    # --- Stage 1: raw (snapshots.jsonl) -> 15-min buckets -----------------
    raw_rows, malformed = _read_jsonl_rows(raw_path)
    total_malformed += malformed

    keep_raw: list[dict] = []
    to_15m: list[tuple[float, dict]] = []
    for row in raw_rows:
        epoch = _parse_ts(row.get("ts"))
        if epoch is None:
            total_malformed += 1  # can't place it in time -- drop, counted
            continue
        if epoch >= raw_cutoff:
            keep_raw.append(row)
        else:
            to_15m.append((epoch, row))

    if to_15m:
        existing_15m, malformed = _read_jsonl_rows(m15_path)
        total_malformed += malformed
        bucket_map = _load_bucket_map(existing_15m)
        _bucket_raw_rows(bucket_map, to_15m, BUCKET_15M_SECONDS)
        _write_jsonl_rows(m15_path, [bucket_map[k] for k in sorted(bucket_map)])

    if raw_path.exists():
        _write_jsonl_rows(raw_path, keep_raw)

    # --- Stage 2: 15-min buckets -> 1-hour buckets -------------------------
    rows_15m, malformed = _read_jsonl_rows(m15_path)
    total_malformed += malformed

    keep_15m: list[dict] = []
    to_1h: list[tuple[float, dict]] = []
    for row in rows_15m:
        epoch = _parse_ts(row.get("ts_start"))
        if epoch is None:
            total_malformed += 1
            continue
        if epoch >= m15_cutoff:
            keep_15m.append(row)
        else:
            to_1h.append((epoch, row))

    if to_1h:
        existing_1h, malformed = _read_jsonl_rows(h1_path)
        total_malformed += malformed
        bucket_map_1h = _load_bucket_map(existing_1h)
        _bucket_agg_rows(bucket_map_1h, to_1h, BUCKET_1H_SECONDS)
        _write_jsonl_rows(h1_path, [bucket_map_1h[k] for k in sorted(bucket_map_1h)])

    if m15_path.exists():
        _write_jsonl_rows(m15_path, keep_15m)

    if not quiet:
        _log(
            f"compact: raw kept={len(keep_raw)} moved_to_15m={len(to_15m)}; "
            f"15m kept={len(keep_15m)} moved_to_1h={len(to_1h)}; "
            f"malformed_lines_skipped={total_malformed}"
        )


# ---------------------------------------------------------------------------
# report
# ---------------------------------------------------------------------------

def _peak_from_rows(rows: list[dict], field: str) -> float | None:
    vals = [v for v in (_extract_util(r, field) for r in rows) if v is not None]
    return max(vals) if vals else None


def build_report(state_dir: Path) -> str:
    store = load_store(state_dir)
    hours = store.get("hours", {})
    lines = [f"claude-autoresume usage report (store version {store.get('version')})"]

    if not hours:
        lines.append("  no usage data collected yet")
    else:
        hour_keys = sorted(hours.keys())
        lines.append(f"  hours tracked: {len(hour_keys)} ({hour_keys[0]}..{hour_keys[-1]} UTC)")

        totals: dict[str, dict[str, dict]] = {}
        for sources in hours.values():
            for source, models in sources.items():
                for model, usage in models.items():
                    dest = totals.setdefault(source, {}).setdefault(model, _zero_usage())
                    for k in USAGE_FIELDS:
                        dest[k] += usage.get(k, 0)

        for source in sorted(totals):
            lines.append(f"  [{source}]")
            grand = _zero_usage()
            for model in sorted(totals[source]):
                u = totals[source][model]
                for k in USAGE_FIELDS:
                    grand[k] += u[k]
                lines.append(
                    f"    {model:35s} in={u['input']:>10,} out={u['output']:>10,} "
                    f"cache_w={u['cache_write']:>10,} cache_r={u['cache_read']:>12,} "
                    f"web={u['web_searches']:>4,} msgs={u['messages']:>6,}"
                )
            lines.append(
                f"    {'TOTAL':35s} in={grand['input']:>10,} out={grand['output']:>10,} "
                f"cache_w={grand['cache_write']:>10,} cache_r={grand['cache_read']:>12,} "
                f"web={grand['web_searches']:>4,} msgs={grand['messages']:>6,}"
            )

    progress = store.get("progress", {})
    lines.append(f"  tracked source files: {len(progress)}")

    lines.append("")
    lines.append("snapshots:")
    for label, path_fn in (
        ("raw (2min, <24h)", snapshots_raw_path),
        ("15-min (<30d)", snapshots_15m_path),
        ("1-hour (forever)", snapshots_1h_path),
    ):
        path = path_fn(state_dir)
        rows, malformed = _read_jsonl_rows(path)
        peak5h = _peak_from_rows(rows, "five_hour")
        peak7d = _peak_from_rows(rows, "seven_day")
        lines.append(
            f"  {label:20s} file={path.name:20s} exists={path.exists()!s:5s} rows={len(rows):>6,} "
            f"malformed_skipped={malformed} peak_5h={peak5h} peak_7d={peak7d}"
        )

    return "\n".join(lines)


def report(state_dir: Path) -> None:
    print(build_report(state_dir))


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="usage_collector", description="Claude usage token collector")
    parser.add_argument(
        "--state-dir", type=Path, default=DEFAULT_STATE_DIR,
        help="Base state dir shared with autoresume.py (default: ~/.claude-autoresume)",
    )
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("collect", help="Run an incremental usage-collection pass")
    sub.add_parser("compact", help="Downsample snapshot files per the retention policy")
    sub.add_parser("report", help="Print a human-readable summary of the store")

    args = parser.parse_args(argv)
    if args.command == "collect":
        collect(args.state_dir)
    elif args.command == "compact":
        compact(args.state_dir)
    elif args.command == "report":
        report(args.state_dir)
    return 0


if __name__ == "__main__":
    sys.exit(main())
