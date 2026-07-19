#!/usr/bin/env python3
"""
plan_fit — Claude plan-fit analysis
=====================================

Reads the usage stores populated by usage_collector.py
(~/.claude-autoresume/usage/tokens_hourly.json and the snapshots*.jsonl
utilization files) and turns them into a single answer to "which plan
should I be on": Pro ($20/mo), Max 5x ($100/mo), or Max 20x ($200/mo),
plus what the same usage would cost on the API directly.

This module does NOT collect data (see usage_collector.py, owned by a
sibling module) and does NOT touch Claude Code sessions (see
autoresume.py). It only reads the stores above and writes one derived
file: ~/.claude-autoresume/usage/plan_fit.json. That file is consumed by
the Swift menu-bar widget, so its shape is meant to stay flat and stable.

Utilization numbers in the snapshots stores are official, server-reported
percentages measured against whatever plan is *currently* active — i.e.
the configured account plan (config["account"]["plan"], default
CURRENT_PLAN below). "Tier rescaling" projects what those same
percentages would have been on another plan, since the caps scale
linearly with the plan's multiplier (Pro=1x, Max 5x=5x, Max 20x=20x):
observed_utilization × (current_multiplier / tier_multiplier).

Pricing layer
-------------
Token counts are priced into API-equivalent dollars using a three-tier
resolution chain, first match wins **per model**, so you can override one
model while still falling back for the rest:

  1. ~/.claude-autoresume/usage/pricing_override.json — optional,
     hand-edited. Wins over everything.
  2. ~/.claude-autoresume/usage/pricing_cache.json — populated by
     refresh_pricing(), which fetches LiteLLM's community-maintained
     pricing table over the network. Never touched by compute() or by
     the tests — only by the `refresh-pricing` CLI subcommand (intended
     to be invoked by the daemon at most once a day).
  3. Bundled defaults below (BUNDLED_RATES_TABLE / SONNET5_*) — last
     resort, frozen as of BUNDLED_PRICING_AS_OF. Includes the one
     date-conditional rule we know about (Sonnet 5's introductory
     pricing window).

compute() records which of these tiers actually got used in its
"assumptions" list and "pricing_meta" block, and warns if it's running
purely on bundled defaults that have gone stale.
"""

from __future__ import annotations  # keeps `X | None` / `list[str]` hints safe on Python 3.9 (macOS system python3)

import json
import sys
import urllib.error
import urllib.request
from datetime import date, datetime, timedelta, timezone
from pathlib import Path

from autoresume_config import load_config, load_config_with_meta  # stdlib-only sibling; account/budget config (C1)

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------

HOME = Path.home()
DEFAULT_STATE_DIR = HOME / ".claude-autoresume"

CURRENT_PLAN = "max_20x"  # default only; the live plan is config["account"]["plan"] (see autoresume_config)
TIER_MULTIPLIERS = {"pro": 1, "max_5x": 5, "max_20x": 20}
TIER_PRICE_USD = {"pro": 20, "max_5x": 100, "max_20x": 200}
TIER_ORDER = ("pro", "max_5x", "max_20x")  # cheapest first

ROLLING_WINDOW_HOURS = 5
MA_WINDOWS_DAYS = (1, 7, 30, 90)
# 30 (not the 30.44 calendar-month average) so "monthly run rate" and the
# widget Graph tab's 1mo period estimate — a literal 30-day window — quote the
# same pace against the same month definition instead of disagreeing by 1.5%.
MONTHLY_RUN_RATE_DAYS = 30.0

# Budget (API-account dollar limits) — see _budget_block / autoresume_config C1.
BUDGET_PROJECTION_MIN_ELAPSED_SECONDS = 3600  # suppress linear projection in a period's first hour

# Minimum elapsed time before a moving-average window reports a $/day value.
# Semantics chosen: SUPPRESS (value null) rather than floor the denominator —
# consistent with both the Swift Graph tab (period estimate suppressed under
# 1h of data) and the budget projection above, so all three surfaces agree
# that under an hour of elapsed data there is no rate to quote, instead of
# quoting a clamped guess. Without this, $2 spent in the first 10 minutes of
# history extrapolated to $288/day ($8,640/mo run rate), and the 1d window —
# whose span restarts at 00:00 UTC — exploded the same way every day just
# after midnight. `days_covered` is unaffected (maturity captions still work).
MA_MIN_ELAPSED_SECONDS = 3600

# Plan-change containment (see _update_plan_history): snapshot rows don't
# record which plan they were measured against, so utilization observation is
# restricted to rows at/after the most recent plan change recorded in this
# sidecar. plan_fit MAY append to this file; it still NEVER writes config.json.
PLAN_HISTORY_FILENAME = "plan_history.jsonl"

# Remote usage merge (WS-6) — remote Claude Code bills the same API account, so
# its token usage folds into the same cost/budget math. remote_sync.py writes
# each collect_usage host's hourly store to usage/remote/<host>_tokens_hourly.json
# (same schema as the local tokens_hourly.json). See load_remote_tokens /
# _merge_remote_hours below.
REMOTE_STORE_SUFFIX = "_tokens_hourly.json"
REMOTE_USAGE_STALE_SECONDS = 3 * 3600  # warn if a to-be-merged host's store is older than this
# Summable per-(hour, surface, model) usage fields — mirrors usage_collector's
# USAGE_FIELDS (plan_fit stays independent of that module; it only reads stores).
_USAGE_SUM_KEYS = ("input", "output", "cache_write", "cache_read", "web_searches", "messages")

# ---------------------------------------------------------------------------
# Pricing — resolution chain: override > fetched cache > bundled defaults
# ---------------------------------------------------------------------------

DEFAULT_CACHE_WRITE_MULTIPLIER = 2.0  # 1h-TTL cache write ~= 2x input (see assumptions)
DEFAULT_CACHE_READ_MULTIPLIER = 0.1

BUNDLED_PRICING_AS_OF = date(2026, 7, 18)
BUNDLED_STALE_WARNING_DAYS = 60
PRICING_CACHE_STALE_DAYS = 7

LITELLM_PRICING_URL = "https://raw.githubusercontent.com/BerriAI/litellm/main/model_prices_and_context_window.json"

# Bundled fallback table: prefix -> (input $/Mtok, output $/Mtok). Sonnet 5
# is handled separately below because its price depends on the bucket date
# (introductory rate through 2026-08-31).
BUNDLED_RATES_TABLE: dict[str, tuple[float, float]] = {
    "claude-fable-5": (10.0, 50.0),
    "claude-mythos-5": (10.0, 50.0),
    "claude-opus-4-8": (5.0, 25.0),
    "claude-opus-4-7": (5.0, 25.0),
    "claude-opus-4-6": (5.0, 25.0),
    "claude-opus-4-5": (5.0, 25.0),
    "claude-opus-4-1": (5.0, 25.0),
    "claude-sonnet-4-6": (3.0, 15.0),
    "claude-sonnet-4-5": (3.0, 15.0),
    "claude-haiku-4-5": (1.0, 5.0),
}

SONNET5_PREFIX = "claude-sonnet-5"
SONNET5_INTRO_CUTOFF = date(2026, 9, 1)  # standard pricing kicks in on/after this date
SONNET5_INTRO_RATES = (2.0, 10.0)
SONNET5_STANDARD_RATES = (3.0, 15.0)

# Sentinel model ids that should be skipped entirely: not priced, not
# warned about. "<synthetic>" is usage_collector's marker for a
# synthetic/haiku-generated-summary event (see its _scan_file(), which
# checks `message.get("model") == "<synthetic>"`) — not a real model call.
# "synthetic" (no brackets) is kept too in case that shape ever shows up.
SKIP_MODEL_IDS = {"", "synthetic", "<synthetic>"}


def _rate_entry(input_per_mtok: float, output_per_mtok: float,
                 cache_write_multiplier: float = DEFAULT_CACHE_WRITE_MULTIPLIER,
                 cache_read_multiplier: float = DEFAULT_CACHE_READ_MULTIPLIER) -> dict:
    return {
        "input_per_mtok": float(input_per_mtok),
        "output_per_mtok": float(output_per_mtok),
        "cache_write_multiplier": float(cache_write_multiplier),
        "cache_read_multiplier": float(cache_read_multiplier),
    }


def _parse_rate_table(raw: dict) -> dict[str, dict]:
    """Shared parser for the override file and the fetched-cache "models"
    block — both use {"<prefix>": {"input_per_mtok", "output_per_mtok",
    "cache_write_multiplier"?, "cache_read_multiplier"?}}. Skips entries
    that don't at least have valid input/output rates."""
    result: dict[str, dict] = {}
    if not isinstance(raw, dict):
        return result
    for prefix, entry in raw.items():
        if not isinstance(prefix, str) or not isinstance(entry, dict):
            continue
        try:
            inp = float(entry["input_per_mtok"])
            out = float(entry["output_per_mtok"])
        except (KeyError, TypeError, ValueError):
            continue
        cw = entry.get("cache_write_multiplier", DEFAULT_CACHE_WRITE_MULTIPLIER)
        cr = entry.get("cache_read_multiplier", DEFAULT_CACHE_READ_MULTIPLIER)
        try:
            cw = float(cw)
        except (TypeError, ValueError):
            cw = DEFAULT_CACHE_WRITE_MULTIPLIER
        try:
            cr = float(cr)
        except (TypeError, ValueError):
            cr = DEFAULT_CACHE_READ_MULTIPLIER
        result[prefix] = _rate_entry(inp, out, cw, cr)
    return result


def load_pricing_override(usage_dir: Path) -> dict[str, dict]:
    """~/.claude-autoresume/usage/pricing_override.json — optional,
    hand-edited. Missing or malformed -> empty (falls through the chain)."""
    path = usage_dir / "pricing_override.json"
    if not path.exists():
        return {}
    try:
        raw = json.loads(path.read_text())
    except (OSError, json.JSONDecodeError):
        return {}
    return _parse_rate_table(raw)


def load_pricing_cache(usage_dir: Path) -> dict | None:
    """~/.claude-autoresume/usage/pricing_cache.json — written by
    refresh_pricing(). Returns None if missing, malformed, or empty so
    callers fall through to bundled defaults. Never fetched from here."""
    path = usage_dir / "pricing_cache.json"
    if not path.exists():
        return None
    try:
        raw = json.loads(path.read_text())
    except (OSError, json.JSONDecodeError):
        return None
    if not isinstance(raw, dict):
        return None
    models = _parse_rate_table(raw.get("models"))
    if not models:
        return None
    return {
        "fetched_at": raw.get("fetched_at"),
        "source": raw.get("source"),
        "models": models,
    }


def _find_prefix_match(model_id: str, table: dict[str, dict]) -> tuple[str, dict] | None:
    """Longest-prefix match against model_id (ids may carry date suffixes,
    e.g. "claude-opus-4-5-20260301")."""
    best_prefix = None
    for prefix in table:
        if model_id.startswith(prefix) and (best_prefix is None or len(prefix) > len(best_prefix)):
            best_prefix = prefix
    if best_prefix is None:
        return None
    return best_prefix, table[best_prefix]


def _bundled_rate(model_id: str, bucket_date: date) -> tuple[dict, bool]:
    """Last-resort pricing. Returns (rate_entry, unknown_flag)."""
    if model_id.startswith(SONNET5_PREFIX):
        inp, out = SONNET5_INTRO_RATES if bucket_date < SONNET5_INTRO_CUTOFF else SONNET5_STANDARD_RATES
        return _rate_entry(inp, out), False
    match = _find_prefix_match(model_id, {p: v for p, v in BUNDLED_RATES_TABLE.items()})
    if match:
        _, (inp, out) = match
        return _rate_entry(inp, out), False
    # Unknown model -> price at Sonnet 5 standard rates and flag it.
    inp, out = SONNET5_STANDARD_RATES
    return _rate_entry(inp, out), True


def resolve_model_pricing(model_id: str, bucket_date: date, override: dict[str, dict],
                           cache_models: dict[str, dict]) -> tuple[dict, str, bool]:
    """First match wins, per model: override -> fetched cache -> bundled.
    Returns (rate_entry, source_label, unknown_flag). unknown_flag is only
    ever True for the bundled tier (override/cache entries are trusted)."""
    match = _find_prefix_match(model_id, override)
    if match:
        return match[1], "override", False
    if cache_models:
        match = _find_prefix_match(model_id, cache_models)
        if match:
            return match[1], "litellm_cache", False
    rate, unknown = _bundled_rate(model_id, bucket_date)
    return rate, "bundled_defaults", unknown


def _rate_cost(rate: dict, input_tok: float, output_tok: float,
               cache_write_tok: float, cache_read_tok: float) -> float:
    inp = rate["input_per_mtok"]
    out = rate["output_per_mtok"]
    cw = inp * rate["cache_write_multiplier"]
    cr = inp * rate["cache_read_multiplier"]
    return (input_tok * inp + output_tok * out + cache_write_tok * cw + cache_read_tok * cr) / 1_000_000.0


def _litellm_entry_to_rate(entry: dict) -> dict | None:
    """Converts one LiteLLM model_prices_and_context_window.json entry
    (per-TOKEN costs) into our per-MTok rate_entry shape. Pure function,
    no network — this is what refresh_pricing() calls per model, and what
    the tests exercise directly with fixture dicts."""
    try:
        input_cost = float(entry.get("input_cost_per_token"))
        output_cost = float(entry.get("output_cost_per_token"))
    except (TypeError, ValueError):
        return None
    if input_cost < 0 or output_cost < 0 or (input_cost == 0 and output_cost == 0):
        return None

    cache_write_mult = DEFAULT_CACHE_WRITE_MULTIPLIER
    cw_cost = entry.get("cache_creation_input_token_cost")
    if cw_cost is not None and input_cost > 0:
        try:
            cache_write_mult = float(cw_cost) / input_cost
        except (TypeError, ValueError):
            pass

    cache_read_mult = DEFAULT_CACHE_READ_MULTIPLIER
    cr_cost = entry.get("cache_read_input_token_cost")
    if cr_cost is not None and input_cost > 0:
        try:
            cache_read_mult = float(cr_cost) / input_cost
        except (TypeError, ValueError):
            pass

    return _rate_entry(input_cost * 1_000_000.0, output_cost * 1_000_000.0, cache_write_mult, cache_read_mult)


def refresh_pricing(state_dir: Path = DEFAULT_STATE_DIR) -> dict:
    """Fetches LiteLLM's community-maintained pricing table and writes
    ~/.claude-autoresume/usage/pricing_cache.json. Separate entrypoint —
    never called from compute() or from tests. Meant to be invoked by the
    daemon (or `python3 plan_fit.py refresh-pricing`) at most once a day.
    Swallows all network/parse errors and leaves any existing cache file
    untouched on failure."""
    usage_dir = state_dir / "usage"
    try:
        req = urllib.request.Request(
            LITELLM_PRICING_URL,
            headers={"User-Agent": "claude-autoresume-plan-fit/1.0"},
        )
        with urllib.request.urlopen(req, timeout=10) as resp:
            raw = json.loads(resp.read().decode("utf-8"))
    except (urllib.error.URLError, TimeoutError, json.JSONDecodeError, OSError, ValueError) as e:
        return {"ok": False, "error": f"{type(e).__name__}: {e}"}

    if not isinstance(raw, dict):
        return {"ok": False, "error": "unexpected response shape (not a JSON object)"}

    models: dict[str, dict] = {}
    for key, entry in raw.items():
        if not isinstance(entry, dict):
            continue
        provider = str(entry.get("litellm_provider", ""))
        if "anthropic" not in provider.lower() and "claude" not in key.lower():
            continue
        rate = _litellm_entry_to_rate(entry)
        if rate is None:
            continue
        prefix = key.split("/")[-1]  # strip an "anthropic/" namespace if present
        models[prefix] = rate

    if not models:
        return {"ok": False, "error": "no anthropic/claude models found in fetched pricing data"}

    fetched_at = datetime.now(timezone.utc).isoformat()
    payload = {"fetched_at": fetched_at, "source": LITELLM_PRICING_URL, "models": models}
    try:
        usage_dir.mkdir(parents=True, exist_ok=True)
        tmp = usage_dir / "pricing_cache.json.tmp"
        tmp.write_text(json.dumps(payload, indent=2))
        tmp.replace(usage_dir / "pricing_cache.json")
    except OSError as e:
        return {"ok": False, "error": f"fetched OK but failed to write cache: {e}"}

    return {"ok": True, "fetched_at": fetched_at, "model_count": len(models)}


# ---------------------------------------------------------------------------
# Store loading helpers
# ---------------------------------------------------------------------------

def _ensure_utc(dt: datetime) -> datetime:
    return dt.replace(tzinfo=timezone.utc) if dt.tzinfo is None else dt.astimezone(timezone.utc)


def _parse_iso(value) -> datetime | None:
    if not isinstance(value, str) or not value:
        return None
    try:
        return _ensure_utc(datetime.fromisoformat(value.replace("Z", "+00:00")))
    except ValueError:
        return None


def _parse_hour_key(key: str) -> datetime | None:
    try:
        return datetime.strptime(key, "%Y-%m-%dT%H").replace(tzinfo=timezone.utc)
    except (ValueError, TypeError):
        return None


def load_tokens_hourly(usage_dir: Path) -> dict:
    path = usage_dir / "tokens_hourly.json"
    if not path.exists():
        return {}
    try:
        raw = json.loads(path.read_text())
    except (OSError, json.JSONDecodeError):
        return {}
    if not isinstance(raw, dict):
        return {}
    hours = raw.get("hours")
    return hours if isinstance(hours, dict) else {}


def load_remote_tokens(usage_dir: Path) -> dict[str, dict]:
    """Reads every usage/remote/<host>_tokens_hourly.json store (written by
    remote_sync.fetch_host_usage, same schema as the local tokens_hourly.json).

    Returns {host_name: {"hours": {...}, "mtime": float}} for each parseable
    file, host_name derived from the filename by stripping the store suffix.
    Missing remote/ dir, unreadable/malformed files, and files without an
    "hours" dict are silently skipped — no config gating happens here; the
    caller (compute) decides which hosts to actually merge vs. treat as orphans.
    """
    remote_dir = usage_dir / "remote"
    result: dict[str, dict] = {}
    if not remote_dir.is_dir():
        return result
    for path in sorted(remote_dir.glob("*" + REMOTE_STORE_SUFFIX)):
        name = path.name[: -len(REMOTE_STORE_SUFFIX)]
        if not name:
            continue
        try:
            mtime = path.stat().st_mtime
            raw = json.loads(path.read_text())
        except (OSError, json.JSONDecodeError):
            continue
        if not isinstance(raw, dict):
            continue
        hours = raw.get("hours")
        if not isinstance(hours, dict):
            continue
        result[name] = {"hours": hours, "mtime": mtime}
    return result


def _add_usage(dst: dict, src: dict) -> None:
    """Sum the numeric usage fields of `src` into `dst` in place."""
    for k in _USAGE_SUM_KEYS:
        v = src.get(k)
        if isinstance(v, (int, float)):
            dst[k] = dst.get(k, 0) + v


def _copy_hours(hours: dict) -> dict:
    """Deep copy of an hours store's {hour: {surface: {model: usage}}} shape,
    keeping only well-formed nested dicts and fresh (summable) usage dicts."""
    out: dict = {}
    for hour_key, surfaces in hours.items():
        if not isinstance(surfaces, dict):
            continue
        out_surfaces: dict = {}
        for surface, models in surfaces.items():
            if not isinstance(models, dict):
                continue
            out_models: dict = {}
            for model_id, usage in models.items():
                if isinstance(usage, dict):
                    fresh: dict = {}
                    _add_usage(fresh, usage)
                    out_models[model_id] = fresh
            out_surfaces[surface] = out_models
        out[hour_key] = out_surfaces
    return out


def _merge_remote_hours(local_hours: dict, remote_by_host: dict[str, dict]) -> dict:
    """Fold each remote host's token hours into a fresh copy of `local_hours`.

    Every remote surface is renamed "<surface>@<host>" (e.g. "code_cli@devbox",
    or "cowork@devbox" if a remote Mac ever carries Cowork usage), so per-host
    attribution stays visible in the merged hours dict and there is zero
    double-count risk — different machines' transcripts never share a surface
    label. Usage fields are summed per (hour, surface, model); after the rename
    the sum is only ever exercised if a single host store repeats a bucket.
    Inputs are not mutated.
    """
    merged = _copy_hours(local_hours)
    for host_name, store in remote_by_host.items():
        remote_hours = store.get("hours")
        if not isinstance(remote_hours, dict):
            continue
        for hour_key, surfaces in remote_hours.items():
            if not isinstance(surfaces, dict):
                continue
            dst_surfaces = merged.setdefault(hour_key, {})
            for surface, models in surfaces.items():
                if not isinstance(models, dict):
                    continue
                labelled = f"{surface}@{host_name}"
                dst_models = dst_surfaces.setdefault(labelled, {})
                for model_id, usage in models.items():
                    if not isinstance(usage, dict):
                        continue
                    _add_usage(dst_models.setdefault(model_id, {}), usage)
    return merged


def _merge_remote_usage(usage_dir: Path, config: dict, local_hours: dict,
                        now: datetime, warnings: list, assumptions: list) -> tuple[dict, bool]:
    """Config-gated remote-usage merge orchestrator (WS-6).

    Merge gating (documented decision): only hosts *currently* configured with
    both `enabled` and `collect_usage` (default True) are folded in. A leftover
    store file for a host that is disabled, has collect_usage off, or is no
    longer in config at all is an *orphan* — never merged (so a stale file from
    a removed/disabled host can't silently distort spend), and flagged with a
    warning. A configured-to-merge host whose store is missing, or older than
    REMOTE_USAGE_STALE_SECONDS, also warns (the stale store is still merged as
    the best available data). Each merged host contributes an assumptions line
    naming it and its store's last-fetch time.

    Returns (merged_hours, includes_remote). includes_remote is True iff at
    least one remote store was actually merged. When nothing merges, returns the
    original local_hours unchanged so default-config output stays byte-compatible.
    """
    stores = load_remote_tokens(usage_dir)  # {host: {"hours","mtime"}}

    merge_names: list[str] = []
    for h in config.get("remote_hosts", []) or []:
        if not isinstance(h, dict):
            continue
        name = h.get("name")
        if not isinstance(name, str) or not name:
            continue
        if not h.get("enabled"):
            continue
        if not h.get("collect_usage", True):
            continue
        merge_names.append(name)

    merge_set = set(merge_names)
    to_merge: dict[str, dict] = {}
    now_epoch = now.timestamp()

    for name in merge_names:
        store = stores.get(name)
        if store is None:
            warnings.append(
                f"Remote host {name!r} has collect_usage enabled but no usage store "
                f"({name}{REMOTE_STORE_SUFFIX} under usage/remote/) has synced yet — "
                "its spend is not included in cost/budget figures."
            )
            continue
        to_merge[name] = store
        age = now_epoch - store["mtime"]
        if age > REMOTE_USAGE_STALE_SECONDS:
            fetched = datetime.fromtimestamp(store["mtime"], tz=timezone.utc).isoformat()
            warnings.append(
                f"Remote host {name!r} usage store is stale (last fetched {fetched}, "
                f"{age / 3600.0:.1f}h ago); its spend may be undercounted."
            )

    # Orphan store files: on disk but not a currently-merged host.
    for name in sorted(stores):
        if name not in merge_set:
            warnings.append(
                f"Ignoring orphan remote usage store {name}{REMOTE_STORE_SUFFIX} — "
                f"host {name!r} is not a currently enabled collect_usage remote host; "
                "its spend is excluded from cost/budget figures."
            )

    if not to_merge:
        return local_hours, False

    for name in sorted(to_merge):
        fetched = datetime.fromtimestamp(to_merge[name]["mtime"], tz=timezone.utc).isoformat()
        assumptions.append(
            f"Remote host {name} usage last fetched {fetched}, folded into cost/budget "
            f"as surface code_cli@{name} (per-host attribution; no cross-machine double-count)."
        )

    return _merge_remote_hours(local_hours, to_merge), True


def load_jsonl(path: Path) -> list[dict]:
    """Reads a .jsonl store, silently skipping malformed lines and
    tolerating a missing file entirely."""
    if not path.exists():
        return []
    rows = []
    try:
        with open(path, "r", errors="ignore") as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    obj = json.loads(line)
                except json.JSONDecodeError:
                    continue
                if isinstance(obj, dict):
                    rows.append(obj)
    except OSError:
        return []
    return rows


# ---------------------------------------------------------------------------
# Cost aggregation
# ---------------------------------------------------------------------------

def _iter_model_usage(hours: dict):
    """Yields (hour_dt, model_id, usage_dict) for every priceable model
    entry across every surface (code_cli, cowork, any future surface) in
    every hour bucket. Skips unparseable hour keys and sentinel model ids."""
    for hour_key, surfaces in hours.items():
        hour_dt = _parse_hour_key(hour_key)
        if hour_dt is None or not isinstance(surfaces, dict):
            continue
        for _surface_name, models in surfaces.items():
            if not isinstance(models, dict):
                continue
            for model_id, usage in models.items():
                if model_id in SKIP_MODEL_IDS or not isinstance(usage, dict):
                    continue
                yield hour_dt, model_id, usage


def _num(usage: dict, key: str) -> float:
    val = usage.get(key, 0)
    return float(val) if isinstance(val, (int, float)) else 0.0


def _build_cost_series(hours: dict, override: dict, cache_models: dict, warnings: list,
                        pricing_sources_used: set, unknown_models: set):
    """Returns (hourly_cost: {hour_dt: cost}, daily_cost: {date: cost},
    days_with_data: set[date], totals_by_model: dict)."""
    hourly_cost: dict[datetime, float] = {}
    daily_cost: dict[date, float] = {}
    days_with_data: set[date] = set()
    totals_by_model: dict[str, dict] = {}

    for hour_dt, model_id, usage in _iter_model_usage(hours):
        bucket_date = hour_dt.date()
        days_with_data.add(bucket_date)

        rate, source, unknown = resolve_model_pricing(model_id, bucket_date, override, cache_models)
        pricing_sources_used.add(source)
        if unknown:
            unknown_models.add(model_id)

        input_tok = _num(usage, "input")
        output_tok = _num(usage, "output")
        cache_write_tok = _num(usage, "cache_write")
        cache_read_tok = _num(usage, "cache_read")
        web_searches = _num(usage, "web_searches")
        messages = _num(usage, "messages")

        cost = _rate_cost(rate, input_tok, output_tok, cache_write_tok, cache_read_tok)

        hourly_cost[hour_dt] = hourly_cost.get(hour_dt, 0.0) + cost
        daily_cost[bucket_date] = daily_cost.get(bucket_date, 0.0) + cost

        t = totals_by_model.setdefault(model_id, {
            "input": 0.0, "output": 0.0, "cache_write": 0.0, "cache_read": 0.0,
            "web_searches": 0.0, "messages": 0.0, "cost_usd": 0.0, "pricing_sources": set(),
        })
        t["input"] += input_tok
        t["output"] += output_tok
        t["cache_write"] += cache_write_tok
        t["cache_read"] += cache_read_tok
        t["web_searches"] += web_searches
        t["messages"] += messages
        t["cost_usd"] += cost
        t["pricing_sources"].add(source)

    return hourly_cost, daily_cost, days_with_data, totals_by_model


def _moving_averages(daily_cost: dict, days_with_data: set, now: datetime,
                     earliest_data: datetime | None = None) -> dict:
    """$/day per window, where the denominator is the REAL elapsed time the
    data could have covered — fractional days from max(window start, first
    data point) to `now` — not the count of calendar days touched.

    Day-counting quantized 1.33 days of history up to 2 "covered days" and
    deflated the rate ~35% (and, symmetrically, treated a genuinely idle day
    with no store entry as nonexistent time, inflating it). The fractional
    denominator matches the Graph tab's period-total estimate, so the two no
    longer disagree about what "your pace" is. `days_covered` stays the
    integer calendar-day count for the maturity captions ("2/7 days
    collected"). Falls back to day-counting if `earliest_data` is absent or
    inconsistent with `now` (clock skew).

    Minimum-elapsed floor: with less than MA_MIN_ELAPSED_SECONDS (1h) elapsed
    since the window's span start, the value is SUPPRESSED (None) rather than
    extrapolated — the same "no estimate in the first hour" semantics as the
    Swift Graph tab and the budget projection. This kills the fresh-store
    explosion ($2 in 10 minutes reading as $288/day) and the 1d window's
    daily just-after-00:00-UTC spike. days_covered still counts, so maturity
    captions keep working while the value is suppressed.
    """
    today = now.date()
    result = {}
    for window_days in MA_WINDOWS_DAYS:
        window_start = today - timedelta(days=window_days - 1)
        window_dates = {window_start + timedelta(days=i) for i in range(window_days)}
        covered = window_dates & days_with_data
        days_covered = len(covered)
        if days_covered == 0:
            value = None
        else:
            total = sum(daily_cost.get(d, 0.0) for d in covered)
            span_start = datetime(window_start.year, window_start.month,
                                  window_start.day, tzinfo=timezone.utc)
            if earliest_data is not None and earliest_data > span_start:
                span_start = earliest_data
            elapsed_seconds = (now - span_start).total_seconds()
            if elapsed_seconds <= 0:
                value = total / days_covered  # clock-skew fallback (unchanged)
            elif elapsed_seconds < MA_MIN_ELAPSED_SECONDS:
                value = None  # <1h elapsed: suppress, don't extrapolate
            else:
                value = total / (elapsed_seconds / 86400.0)
        result[f"{window_days}d"] = {
            "value_usd_per_day": round(value, 2) if value is not None else None,
            "days_covered": days_covered,
            "window_days": window_days,
        }
    return result


def _monthly_run_rate(moving_averages: dict) -> dict:
    basis = None
    if moving_averages["7d"]["value_usd_per_day"] is not None:
        basis = "7d"
    else:
        for w in ("90d", "30d", "1d"):
            if moving_averages[w]["value_usd_per_day"] is not None:
                basis = w
                break
    if basis is None:
        return {"value_usd_per_month": None, "basis": None}
    per_day = moving_averages[basis]["value_usd_per_day"]
    return {
        "value_usd_per_month": round(per_day * MONTHLY_RUN_RATE_DAYS, 2),
        "basis": basis,
    }


def _cost_peaks(hourly_cost: dict) -> dict:
    if not hourly_cost:
        return {
            "one_hour": {"value_usd": None, "at": None},
            "rolling_five_hour": {"value_usd": None, "at": None},
        }

    peak_1h_ts = max(hourly_cost, key=lambda h: hourly_cost[h])
    peak_1h_val = hourly_cost[peak_1h_ts]

    min_h, max_h = min(hourly_cost), max(hourly_cost)
    peak_5h_val = None
    peak_5h_ts = None
    h = min_h
    one_hour = timedelta(hours=1)
    while h <= max_h:
        window_sum = sum(hourly_cost.get(h - i * one_hour, 0.0) for i in range(ROLLING_WINDOW_HOURS))
        if peak_5h_val is None or window_sum > peak_5h_val:
            peak_5h_val = window_sum
            peak_5h_ts = h
        h += one_hour

    return {
        "one_hour": {"value_usd": round(peak_1h_val, 2), "at": peak_1h_ts.isoformat()},
        "rolling_five_hour": {"value_usd": round(peak_5h_val, 2), "at": peak_5h_ts.isoformat()},
    }


# ---------------------------------------------------------------------------
# Utilization series (snapshots.jsonl / snapshots_15m.jsonl / snapshots_1h.jsonl)
# ---------------------------------------------------------------------------

def _merge_utilization_points(raw_rows: list, bucket15_rows: list, bucket1h_rows: list) -> list[dict]:
    """Merges the three snapshot stores into one series, preferring the
    finest-grained source available for each stretch of time: raw (2-min,
    last 24h) for its own covered range, then 15m buckets for anything
    older than that, then 1h buckets for anything older still. Each
    returned point is either {"kind": "raw", "ts": dt, "five_hour": val|None,
    "seven_day": val|None} or {"kind": "bucket", "ts_start": dt, "n": int,
    "five_hour": {...}|None, "seven_day": {...}|None}."""
    points: list[dict] = []
    covered_start: datetime | None = None

    raw_points = []
    for row in raw_rows:
        ts = _parse_iso(row.get("ts"))
        if ts is None:
            continue
        fh = row.get("five_hour", {})
        sd = row.get("seven_day", {})
        fh_val = fh.get("utilization") if isinstance(fh, dict) else None
        sd_val = sd.get("utilization") if isinstance(sd, dict) else None
        raw_points.append({"kind": "raw", "ts": ts,
                            "five_hour": fh_val if isinstance(fh_val, (int, float)) else None,
                            "seven_day": sd_val if isinstance(sd_val, (int, float)) else None})
    if raw_points:
        points.extend(raw_points)
        covered_start = min(p["ts"] for p in raw_points)

    def _bucket_points(rows):
        parsed = []
        for row in rows:
            ts_start = _parse_iso(row.get("ts_start"))
            if ts_start is None:
                continue
            n = row.get("n", 1)
            n = n if isinstance(n, (int, float)) and n > 0 else 1
            fh = row.get("five_hour") if isinstance(row.get("five_hour"), dict) else None
            sd = row.get("seven_day") if isinstance(row.get("seven_day"), dict) else None
            parsed.append({"kind": "bucket", "ts_start": ts_start, "n": n, "five_hour": fh, "seven_day": sd})
        return parsed

    kept_15m = [p for p in _bucket_points(bucket15_rows) if covered_start is None or p["ts_start"] < covered_start]
    if kept_15m:
        points.extend(kept_15m)
        oldest_15m = min(p["ts_start"] for p in kept_15m)
        covered_start = oldest_15m if covered_start is None else min(covered_start, oldest_15m)

    kept_1h = [p for p in _bucket_points(bucket1h_rows) if covered_start is None or p["ts_start"] < covered_start]
    points.extend(kept_1h)

    return points


def _utilization_observed(points: list[dict]) -> dict:
    """Peak + weighted-average utilization for five_hour and seven_day,
    over whatever history the merged series covers."""
    result = {}
    for dim in ("five_hour", "seven_day"):
        peak_val = None
        peak_ts = None
        weighted_sum = 0.0
        weight_total = 0.0
        for p in points:
            if p["kind"] == "raw":
                val = p[dim]
                if val is None:
                    continue
                if peak_val is None or val > peak_val:
                    peak_val, peak_ts = val, p["ts"]
                weighted_sum += val
                weight_total += 1.0
            else:
                d = p[dim]
                if not d:
                    continue
                mx = d.get("max")
                avg = d.get("avg")
                if isinstance(mx, (int, float)) and (peak_val is None or mx > peak_val):
                    peak_val, peak_ts = mx, p["ts_start"]
                if isinstance(avg, (int, float)):
                    weighted_sum += avg * p["n"]
                    weight_total += p["n"]
        avg_val = (weighted_sum / weight_total) if weight_total > 0 else None
        result[dim] = {
            "peak_pct": round(float(peak_val), 1) if peak_val is not None else None,
            "peak_at": peak_ts.isoformat() if peak_ts is not None else None,
            "avg_pct": round(avg_val, 1) if avg_val is not None else None,
        }
    return result


# ---------------------------------------------------------------------------
# Plan-change containment (usage/plan_history.jsonl sidecar)
# ---------------------------------------------------------------------------
#
# Snapshot rows carry server-reported utilization percentages measured against
# whatever plan was active WHEN THE ROW WAS WRITTEN, but the rows themselves
# don't record that plan (per-row stamping would need the Swift snapshot
# writer). Without containment, changing config.json's account.plan silently
# rebases ALL history: an 80%-of-Max20x historical peak reread under a Pro
# setting projects as 80%-of-Pro, letting _verdict declare Pro viable when the
# true Pro-relative peak was 1600%. The containment fix: plan_fit appends a
# {"ts", "plan"} line to usage/plan_history.jsonl whenever the configured plan
# differs from the last recorded one, and the utilization peak/avg scan only
# uses snapshot rows at/after the most recent recorded plan change.
#
# First run (no history file): the file is seeded with the CURRENT plan
# stamped at the epoch of the earliest snapshot data — i.e. pre-existing
# history is presumed to have been measured under the currently-configured
# plan. Documented assumption: that matches reality here (the owner has been
# on max_20x throughout); anyone who changed plans BEFORE first running this
# version has no record of it, and the old rebasing behavior applies to that
# pre-history once.
#
# Seed rows (round-2 audit): the seed timestamp is FLOORED to the hour
# boundary and the row is tagged {"seed": true}. Rationale: usage_collector's
# compaction re-floors raw snapshot rows into 15m/1h buckets whose ts_start
# can precede the earliest raw timestamp (10:07 raw -> 10:00 bucket); an
# unfloored seed cutoff then excluded the first bucket whole, forever, with a
# permanent spurious "Plan changed" warning. Migration: a history file
# written before the tag existed carries an untagged first row that IS the
# seed (a file is only ever created by the seed append), so _load_plan_history
# treats the first valid row as the seed and the cutoff is re-floored on
# read — no file rewrite needed.
#
# Degraded config reads (round-2 audit): load_config silently defaults
# account.plan on an unreadable/malformed config, and recording that default
# as a real plan change permanently truncated history on a transient glitch.
# _update_plan_history therefore never appends when the plan value came from
# a degraded read (load_config_with_meta's plan_from_file=False), and a
# genuine change must be seen on TWO consecutive computes before it is
# recorded (_PENDING_PLAN_CHANGE). Accepted trade-off: a genuine plan change
# takes effect one compute late (the on-config-change trigger fires the
# first, the next scheduled compute confirms).
#
# plan_fit MAY write this one sidecar; it must still NEVER write config.json.

def _point_ts(point: dict) -> datetime:
    """Timestamp of a merged utilization point (raw or bucket)."""
    return point["ts"] if point["kind"] == "raw" else point["ts_start"]


def _floor_hour(ts: datetime) -> datetime:
    """Floor to the hour boundary — the coarsest compaction bucket size, so a
    seed cutoff can never exclude a bucket that contains the seed's data."""
    return ts.replace(minute=0, second=0, microsecond=0)


def _load_plan_history(usage_dir: Path) -> list[tuple[datetime, str, bool]]:
    """Valid (ts, plan, is_seed) rows of plan_history.jsonl in file (append)
    order. Missing/malformed file or rows -> skipped, never raises.

    Migration shim: the first valid row always counts as the seed even
    without a {"seed": true} tag — files predate the tag, and a history file
    is only ever created by the seed append, so the first row IS the seed by
    construction."""
    entries: list[tuple[datetime, str, bool]] = []
    for row in load_jsonl(usage_dir / PLAN_HISTORY_FILENAME):
        ts = _parse_iso(row.get("ts"))
        plan = row.get("plan")
        if ts is not None and isinstance(plan, str) and plan:
            entries.append((ts, plan, bool(row.get("seed"))))
    if entries:
        ts0, plan0, _ = entries[0]
        entries[0] = (ts0, plan0, True)
    return entries


def _append_plan_history(usage_dir: Path, ts: datetime, plan: str,
                         seed: bool = False) -> None:
    """Append one {"ts","plan"[,"seed"]} line. Write failures are swallowed —
    the caller already holds the correct cutoff in memory for this run, and
    the next run simply retries the append.

    Torn-tail guard: if a crash mid-append left the file without a trailing
    newline, a naive append would merge with the torn line and corrupt BOTH
    rows. Check the last byte and prefix a newline when needed (the torn
    fragment stays as one unparseable line that _load_plan_history skips)."""
    try:
        usage_dir.mkdir(parents=True, exist_ok=True)
        path = usage_dir / PLAN_HISTORY_FILENAME
        prefix = ""
        try:
            with open(path, "rb") as f:
                f.seek(-1, 2)  # last byte (whence=2: from end)
                if f.read(1) != b"\n":
                    prefix = "\n"
        except (OSError, ValueError):
            pass  # missing or empty file: nothing to guard against
        row: dict = {"ts": ts.isoformat(), "plan": plan}
        if seed:
            row["seed"] = True
        with open(path, "a") as f:
            f.write(prefix + json.dumps(row) + "\n")
    except OSError:
        pass


# Two-compute confirmation for genuine plan changes (round-2 audit): maps
# str(usage_dir) -> the not-yet-recorded new plan seen on the previous
# compute. Only recorded once the SAME new plan is seen twice in a row, so a
# one-cycle glitch (or a mid-edit read) can't truncate history. In-process
# only — a daemon restart just adds one more compute of lag.
_PENDING_PLAN_CHANGE: dict = {}


def _update_plan_history(usage_dir: Path, current_plan: str, now: datetime,
                         earliest_data: datetime | None,
                         plan_defaulted: bool = False) -> tuple[datetime, bool]:
    """Maintain the plan-history sidecar and return (cutoff, cutoff_is_seed):
    the UTC instant since which snapshot rows are known to have been measured
    against `current_plan`, and whether that cutoff is the first-run seed
    (callers suppress the "Plan changed" truncation warning for seeds — a
    seed is an assumption marker, not a recorded change).

    `plan_defaulted` means account.plan came from a degraded config read
    (missing/unreadable file, non-canonical value) — never append anything on
    such a read; report the cutoff from the existing file as-is.

    - No usable history yet: seed with the current plan, tagged and stamped
      at the HOUR FLOOR of the earliest snapshot data (or `now` if none) —
      see the seed rationale in the block comment above. Cutoff = that seed.
    - Last recorded plan != current (genuinely read) plan: record the change
      at `now` only after the same new plan is seen on two consecutive
      computes; until confirmed, cutoff stays at the last recorded entry.
    - Otherwise: cutoff = the last recorded entry's ts (re-floored when that
      entry is the seed, covering pre-tag files with unfloored seeds).
    """
    entries = _load_plan_history(usage_dir)
    key = str(usage_dir)
    if not entries:
        seed_ts = _floor_hour(earliest_data if earliest_data is not None else now)
        if not plan_defaulted:
            _append_plan_history(usage_dir, seed_ts, current_plan, seed=True)
        return seed_ts, True
    last_ts, last_plan, last_is_seed = entries[-1]
    if last_plan != current_plan and not plan_defaulted:
        if _PENDING_PLAN_CHANGE.get(key) == current_plan:
            del _PENDING_PLAN_CHANGE[key]
            _append_plan_history(usage_dir, now, current_plan)
            return now, False
        _PENDING_PLAN_CHANGE[key] = current_plan
        # Unconfirmed first sighting: fall through to the recorded cutoff.
    elif last_plan == current_plan:
        _PENDING_PLAN_CHANGE.pop(key, None)  # settled back — cancel pending
    if last_is_seed:
        return _floor_hour(last_ts), True
    return last_ts, False


# ---------------------------------------------------------------------------
# Tier rescaling + verdict
# ---------------------------------------------------------------------------

def _tier_projection(observed: dict, current_plan: str = CURRENT_PLAN) -> dict:
    """Rescale observed utilization onto every tier.

    The observed percentages are measured against the *current* plan's caps
    (the usage endpoint reports utilization of whatever plan the account
    actually has), so the baseline multiplier must be the configured plan's —
    a hardcoded 20.0 here silently assumed Max 20x and produced projections
    off by current/20x for anyone on Pro or Max 5x once the plan became
    user-configurable. Unknown plan strings fall back to the Max-20x baseline
    rather than crashing the analytics thread.
    """
    current_mult = float(TIER_MULTIPLIERS.get(current_plan, TIER_MULTIPLIERS[CURRENT_PLAN]))
    projection = {}
    for tier, mult in TIER_MULTIPLIERS.items():
        factor = current_mult / mult
        peak_5h = observed["five_hour"]["peak_pct"]
        peak_7d = observed["seven_day"]["peak_pct"]
        avg_5h = observed["five_hour"]["avg_pct"]
        avg_7d = observed["seven_day"]["avg_pct"]

        p5h = round(peak_5h * factor, 1) if peak_5h is not None else None
        p7d = round(peak_7d * factor, 1) if peak_7d is not None else None
        a5h = round(avg_5h * factor, 1) if avg_5h is not None else None
        a7d = round(avg_7d * factor, 1) if avg_7d is not None else None

        would_hit_cap = (p5h is not None and p5h > 100) or (p7d is not None and p7d > 100)

        projection[tier] = {
            "peak_five_hour_pct": p5h,
            "peak_seven_day_pct": p7d,
            "avg_five_hour_pct": a5h,
            "avg_seven_day_pct": a7d,
            "would_hit_cap": would_hit_cap,
        }
    return projection


def _verdict(tier_projection: dict, run_rate: dict, days_covered_widest: int, widest_window: int,
             current_plan: str = CURRENT_PLAN,
             truncated_by_plan_change: bool = False) -> dict:
    plans = {}
    run_rate_value = run_rate.get("value_usd_per_month")
    for tier in TIER_ORDER:
        price = TIER_PRICE_USD[tier]
        proj = tier_projection[tier]
        ratio = round(run_rate_value / price, 2) if run_rate_value is not None else None
        peak_5h = proj["peak_five_hour_pct"]
        peak_7d = proj["peak_seven_day_pct"]
        has_peak_data = peak_5h is not None or peak_7d is not None
        viable = True
        if peak_5h is not None and peak_5h > 100:
            viable = False
        if peak_7d is not None and peak_7d > 100:
            viable = False
        plans[tier] = {
            "price_usd": price,
            "api_equiv_ratio": ratio,
            "projected_peak_7d_util": peak_7d,
            "projected_peak_5h_util": peak_5h,
            "viable": viable,
            "has_peak_data": has_peak_data,
        }

    if days_covered_widest == 0:
        data_maturity = f"0/{widest_window} days collected — no usage data yet; all projections are unavailable"
    elif days_covered_widest < 7:
        data_maturity = f"{days_covered_widest}/{widest_window} days collected — treat as preliminary"
    else:
        data_maturity = f"{days_covered_widest}/{widest_window} days collected"

    viable_tiers = [t for t in TIER_ORDER if plans[t]["viable"]]
    any_peak_data = any(plans[t]["has_peak_data"] for t in TIER_ORDER)
    preliminary = days_covered_widest < 7

    tier_label = {"pro": "Pro ($20/mo)", "max_5x": "Max 5x ($100/mo)", "max_20x": "Max 20x ($200/mo)"}

    if not any_peak_data:
        if truncated_by_plan_change:
            # There IS utilization history, but it all predates the recorded
            # plan change, so none of it was measured against the current
            # plan. (Snapshots are written by the widget, not usage_collector
            # — don't send the user to the wrong component.)
            recommendation = (
                f"Utilization history exists but predates the plan change to "
                f"{tier_label.get(current_plan, current_plan)}, so it can't ground a "
                "recommendation — projections resume as the widget collects new "
                "snapshots under the current plan."
            )
        else:
            recommendation = (
                "No utilization history yet, so this can't recommend a plan — "
                "check back once usage_collector has run for a few days."
            )
    elif viable_tiers:
        cheapest = viable_tiers[0]
        qualifier = " (based on limited, preliminary data — recheck once more history is collected)" if preliminary else ""
        if cheapest == current_plan:
            recommendation = (
                f"Your current plan, {tier_label[cheapest]}, matches your usage — "
                f"projected peak utilization stays under the cap{qualifier}."
            )
        else:
            recommendation = (
                f"{tier_label[cheapest]} looks sufficient — projected peak utilization stays "
                f"under the cap even during your busiest observed windows{qualifier}."
            )
    else:
        recommendation = (
            "Even Max 20x would have been pushed over its cap during your peak usage window — "
            "peaks matter more than the average here, since they're what actually interrupt work. "
            "Consider spreading usage out, or budgeting for API overage during spikes."
        )

    return {
        "plans": plans,
        "recommendation": recommendation,
        "data_maturity": data_maturity,
    }


# ---------------------------------------------------------------------------
# Budget windows (API-account dollar limits, config-driven)
# ---------------------------------------------------------------------------

def _budget_period_bounds(now: datetime, kind: str, week_start: str, tzname: str) -> tuple[datetime, datetime]:
    """Calendar-period bounds for the budget window containing `now`,
    returned as UTC-aware datetimes.

    `kind` is "monthly" (calendar month) or "weekly" (calendar week starting
    `week_start`, "monday" or "sunday" — deliberately NOT the Max rolling-7d
    window). `tzname` is "local" (system tz) or "utc".

    DST-safe: for the "local" case each boundary's wall-clock midnight is
    localized on its own date via stdlib naive-datetime `.astimezone()` (a
    naive datetime is presumed to be system-local time, converted with the
    correct offset for that specific date), so a period spanning a DST
    transition still resolves to true local midnight at both ends. Pure
    stdlib — no zoneinfo key lookup required.
    """
    now = _ensure_utc(now)
    if tzname == "utc":
        ref = now  # already UTC-aware
        def to_utc(y: int, m: int, d: int) -> datetime:
            return datetime(y, m, d, tzinfo=timezone.utc)
    else:  # "local"
        ref = now.astimezone()  # aware datetime in the system-local tz
        def to_utc(y: int, m: int, d: int) -> datetime:
            # naive -> presumed local, localized on its own date (DST-correct)
            return datetime(y, m, d).astimezone(timezone.utc)

    if kind == "monthly":
        start = to_utc(ref.year, ref.month, 1)
        if ref.month == 12:
            end = to_utc(ref.year + 1, 1, 1)
        else:
            end = to_utc(ref.year, ref.month + 1, 1)
    else:  # "weekly"
        start_weekday = 6 if week_start == "sunday" else 0  # Python weekday(): Mon=0 .. Sun=6
        ref_date = ref.date()
        days_back = (ref_date.weekday() - start_weekday) % 7
        start_date = ref_date - timedelta(days=days_back)
        end_date = start_date + timedelta(days=7)
        start = to_utc(start_date.year, start_date.month, start_date.day)
        end = to_utc(end_date.year, end_date.month, end_date.day)

    return start, end


def _budget_window(hourly_cost: dict, now: datetime, limit_usd, kind: str,
                   week_start: str, tzname: str, includes_remote: bool = False) -> dict | None:
    """One budget window (C2) or None when its limit is unconfigured.

    Spend = sum of the already-priced `hourly_cost` UTC hour buckets falling
    within the current calendar period (downstream of the pricing chain — this
    never re-resolves rates). Projection is linear (spent / elapsed fraction),
    suppressed in the period's first hour where too little has elapsed to
    extrapolate. `includes_remote` is True when at least one remote host's usage
    store was folded into the cost series (WS-6), False otherwise.
    """
    if limit_usd is None:
        return None
    now = _ensure_utc(now)
    limit = float(limit_usd)
    period_start, period_end = _budget_period_bounds(now, kind, week_start, tzname)

    spent = float(sum(c for h, c in hourly_cost.items() if period_start <= h < period_end))
    pct = round(spent / limit * 100.0, 1) if limit > 0 else None

    projected_usd = None
    projected_pct = None
    elapsed = (now - period_start).total_seconds()
    total = (period_end - period_start).total_seconds()
    if elapsed >= BUDGET_PROJECTION_MIN_ELAPSED_SECONDS and total > 0:
        elapsed_fraction = elapsed / total
        if elapsed_fraction > 0:
            projected = spent / elapsed_fraction
            projected_usd = round(projected, 2)
            projected_pct = round(projected / limit * 100.0, 1) if limit > 0 else None

    return {
        "limit_usd": round(limit, 2),
        "spent_usd": round(spent, 2),
        "pct": pct,
        "projected_usd": projected_usd,
        "projected_pct": projected_pct,
        "period_start": period_start.isoformat(),
        "period_end": period_end.isoformat(),
        "includes_remote": bool(includes_remote),
    }


def _budget_block(hourly_cost: dict, now: datetime, config: dict,
                  includes_remote: bool = False) -> dict:
    """The `budget` top-level block (C2): weekly/monthly windows, each null
    when its limit is unconfigured. Emitted for every account type (the widget
    decides whether to surface it). `includes_remote` flags whether the
    `hourly_cost` it sums already folds in remote hosts' usage (WS-6)."""
    budget = config.get("budget", {}) or {}
    week_start = budget.get("week_start", "monday")
    tzname = budget.get("timezone", "local")
    return {
        "weekly": _budget_window(hourly_cost, now, budget.get("weekly_usd"),
                                 "weekly", week_start, tzname, includes_remote),
        "monthly": _budget_window(hourly_cost, now, budget.get("monthly_usd"),
                                  "monthly", week_start, tzname, includes_remote),
    }


# ---------------------------------------------------------------------------
# Top-level compute()
# ---------------------------------------------------------------------------

def compute(state_dir: Path, now: datetime) -> dict:
    """Reads the usage stores under state_dir/usage and returns the full
    plan-fit result as a dict. Never touches the network. Tolerates
    missing/malformed store files — worst case, everything comes back
    null/empty with a warning rather than raising."""
    now = _ensure_utc(now)
    usage_dir = state_dir / "usage"

    # Account/budget config (C1) — re-read each compute(); missing/malformed
    # yields full defaults (Max, plan max_20x, no budget) = pre-config behavior.
    # The meta flag distinguishes a plan actually read from config.json from a
    # degraded-read default, so a transient config glitch is never recorded as
    # a real plan change (see _update_plan_history).
    config, config_meta = load_config_with_meta(state_dir)
    current_plan = config["account"]["plan"]
    plan_defaulted = not config_meta.get("plan_from_file", False)

    warnings: list[str] = []
    assumptions: list[str] = [
        "Cache writes are priced at 2x the input rate (1-hour-TTL assumption) because the "
        "store doesn't record cache TTL, and Claude Code predominantly uses 1h-TTL caching.",
        "Cache reads are priced at 0.1x the input rate.",
        "Claude Sonnet 5 is priced at introductory $2/$10 per Mtok for usage before "
        f"{SONNET5_INTRO_CUTOFF.isoformat()}, standard $3/$15 per Mtok on/after.",
        "web_searches are counted per model but not priced (no published per-search rate).",
        "Rolling 5-hour cost peak uses a sliding window over contiguous UTC hour buckets; "
        "hours with no recorded usage are treated as $0, not as missing data.",
        "The utilization series merges raw 2-minute snapshots (last 24h) with 15m/1h bucket "
        "aggregates for older history, preferring the finest-grained source for each time range.",
    ]

    hours = load_tokens_hourly(usage_dir)
    if not hours:
        warnings.append("tokens_hourly.json is missing, empty, or unreadable — cost figures are unavailable.")

    # Remote usage merge (WS-6): fold each enabled+collect_usage host's token
    # store into the hourly totals so cost/budget math covers the whole (shared)
    # API account. Surfaces are renamed code_cli@<host> during the merge, so the
    # per-host cost stays attributable and there is no cross-machine double-count.
    hours, includes_remote = _merge_remote_usage(usage_dir, config, hours, now, warnings, assumptions)

    override = load_pricing_override(usage_dir)
    cache = load_pricing_cache(usage_dir)
    cache_models = cache["models"] if cache else {}

    pricing_sources_used: set = set()
    unknown_models: set = set()

    hourly_cost, daily_cost, days_with_data, totals_by_model = _build_cost_series(
        hours, override, cache_models, warnings, pricing_sources_used, unknown_models,
    )

    for m in sorted(unknown_models):
        warnings.append(f"Unknown model id {m!r}; priced at Sonnet 5 standard bundled rates.")

    # Pricing provenance
    pricing_parts = []
    if "override" in pricing_sources_used:
        pricing_parts.append("user override file (pricing_override.json)")
    if "litellm_cache" in pricing_sources_used:
        fetched_at = cache.get("fetched_at") if cache else None
        pricing_parts.append(f"LiteLLM pricing cache (fetched {fetched_at})" if fetched_at else "LiteLLM pricing cache")
    if "bundled_defaults" in pricing_sources_used or not pricing_sources_used:
        pricing_parts.append(f"bundled defaults (as of {BUNDLED_PRICING_AS_OF.isoformat()})")
    pricing_source_desc = " + ".join(pricing_parts)
    assumptions.append(f"Pricing source: {pricing_source_desc}.")

    purely_bundled = pricing_sources_used <= {"bundled_defaults"}
    bundled_age_days = (now.date() - BUNDLED_PRICING_AS_OF).days
    if purely_bundled and bundled_age_days > BUNDLED_STALE_WARNING_DAYS:
        warnings.append(
            f"Pricing is running purely on bundled defaults last updated {BUNDLED_PRICING_AS_OF.isoformat()} "
            f"({bundled_age_days} days old). Run `python3 plan_fit.py refresh-pricing` to fetch current rates, "
            "or supply ~/.claude-autoresume/usage/pricing_override.json."
        )

    cache_stale = None
    if cache is not None:
        fetched_dt = _parse_iso(cache.get("fetched_at"))
        if fetched_dt is not None:
            cache_age_days = (now.date() - fetched_dt.date()).days
            cache_stale = cache_age_days > PRICING_CACHE_STALE_DAYS
            if cache_stale and "litellm_cache" in pricing_sources_used:
                warnings.append(
                    f"LiteLLM pricing cache is {cache_age_days} days old (fetched {cache['fetched_at']}); "
                    "still being used, but a refresh is recommended."
                )

    earliest_data = min(hourly_cost) if hourly_cost else None
    moving_averages = _moving_averages(daily_cost, days_with_data, now, earliest_data)
    run_rate = _monthly_run_rate(moving_averages)
    cost_peaks = _cost_peaks(hourly_cost)

    raw_rows = load_jsonl(usage_dir / "snapshots.jsonl")
    bucket15_rows = load_jsonl(usage_dir / "snapshots_15m.jsonl")
    bucket1h_rows = load_jsonl(usage_dir / "snapshots_1h.jsonl")
    if not raw_rows and not bucket15_rows and not bucket1h_rows:
        warnings.append("No utilization snapshots found — peak utilization and tier projections are unavailable.")

    merged_points = _merge_utilization_points(raw_rows, bucket15_rows, bucket1h_rows)

    # Plan-change containment: restrict the peak/avg scan to rows measured
    # under the currently-configured plan (at/after the most recent recorded
    # plan change). A bucket point straddling the change is excluded whole
    # (its ts_start predates the change), which is the conservative side.
    earliest_point = min((_point_ts(p) for p in merged_points), default=None)
    plan_since, cutoff_is_seed = _update_plan_history(
        usage_dir, current_plan, now, earliest_point, plan_defaulted)
    observed_points = [p for p in merged_points if _point_ts(p) >= plan_since]
    truncated = len(merged_points) - len(observed_points)
    truncated_by_plan_change = truncated > 0 and not cutoff_is_seed
    if truncated_by_plan_change:
        # Suppressed for seed cutoffs: a seed is a first-run assumption
        # marker, not a plan change — warning there was the round-2 audit's
        # false "Plan changed" after compaction re-floored the seed's data.
        warnings.append(
            f"Plan changed to {current_plan!r}: peak/avg utilization only uses snapshots "
            f"since {plan_since.isoformat()} ({truncated} earlier snapshot row(s) were "
            "measured against a different plan and are excluded)."
        )

    utilization_observed = _utilization_observed(observed_points)

    tier_projection = _tier_projection(utilization_observed, current_plan)

    widest_window = MA_WINDOWS_DAYS[-1]
    days_covered_widest = moving_averages[f"{widest_window}d"]["days_covered"]
    verdict = _verdict(tier_projection, run_rate, days_covered_widest, widest_window,
                       current_plan, truncated_by_plan_change=truncated_by_plan_change)

    # Graph-ready cost series for the widget's usage-over-time view. Hourly
    # covers the widget's 24h/7d/1mo ranges; daily keeps the 3mo view compact.
    # Keys are ISO timestamps so Swift can parse without knowing bucket rules.
    hourly_cutoff = _ensure_utc(now) - timedelta(days=35)
    hourly_series = {
        h.isoformat(): round(c, 4)
        for h, c in sorted(hourly_cost.items())
        if h >= hourly_cutoff
    }
    daily_series = {d.isoformat(): round(c, 2) for d, c in sorted(daily_cost.items())}

    totals_out = {}
    for model_id, t in sorted(totals_by_model.items()):
        totals_out[model_id] = {
            "input": int(t["input"]),
            "output": int(t["output"]),
            "cache_write": int(t["cache_write"]),
            "cache_read": int(t["cache_read"]),
            "web_searches": int(t["web_searches"]),
            "messages": int(t["messages"]),
            "cost_usd": round(t["cost_usd"], 2),
            "pricing_sources": sorted(t["pricing_sources"]),
        }
    all_models_cost_usd = round(sum(t["cost_usd"] for t in totals_by_model.values()), 2)

    budget = _budget_block(hourly_cost, now, config, includes_remote)
    # Only extend assumptions when a budget is actually configured, so the
    # default-config output stays byte-compatible with the pre-budget file.
    if budget["weekly"] is not None or budget["monthly"] is not None:
        assumptions.append(
            "Budget spend sums the API-equivalent cost of hourly usage buckets within the current "
            "calendar period; a bucket straddling a period boundary can misattribute up to 1 hour of cost."
        )
        assumptions.append(
            "Budget spend can undercount usage from before 2026-07-18, when hourly cost collection began."
        )

    return {
        "generated_at": now.isoformat(),
        "current_plan": current_plan,
        "account": {"type": config["account"]["type"], "plan": config["account"]["plan"]},
        "budget": budget,
        "cost_series": {"hourly": hourly_series, "daily": daily_series},
        "moving_averages": moving_averages,
        "monthly_run_rate": run_rate,
        "cost_peaks": cost_peaks,
        "utilization_observed": utilization_observed,
        "tier_projection": tier_projection,
        "verdict": verdict,
        "totals": {
            "by_model": totals_out,
            "all_models_cost_usd": all_models_cost_usd,
        },
        "pricing_meta": {
            "override_active": bool(override),
            "cache_present": cache is not None,
            "cache_fetched_at": cache.get("fetched_at") if cache else None,
            "cache_stale": cache_stale,
            "bundled_as_of": BUNDLED_PRICING_AS_OF.isoformat(),
            "sources_used": sorted(pricing_sources_used),
        },
        "assumptions": assumptions,
        "warnings": warnings,
    }


def write_plan_fit(state_dir: Path, now: datetime) -> None:
    """Computes the plan-fit result and atomically writes it to
    state_dir/usage/plan_fit.json (write-tmp-then-replace, same pattern
    autoresume.py uses for state.json)."""
    result = compute(state_dir, now)
    usage_dir = state_dir / "usage"
    usage_dir.mkdir(parents=True, exist_ok=True)
    tmp = usage_dir / "plan_fit.json.tmp"
    tmp.write_text(json.dumps(result, indent=2))
    tmp.replace(usage_dir / "plan_fit.json")


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def _format_usd(value) -> str:
    return "n/a" if value is None else f"${value:,.2f}"


def _format_pct(value) -> str:
    return "n/a" if value is None else f"{value:.1f}%"


def _print_report(result: dict) -> None:
    print(f"plan_fit — generated {result['generated_at']} (current plan: {result['current_plan']})")
    print()

    print("Moving average daily cost:")
    for window, ma in result["moving_averages"].items():
        print(f"  {window:>4}: {_format_usd(ma['value_usd_per_day'])}/day "
              f"(collecting: {ma['days_covered']}/{ma['window_days']} days)")
    rr = result["monthly_run_rate"]
    basis = rr["basis"] or "n/a"
    print(f"  Monthly run-rate: {_format_usd(rr['value_usd_per_month'])} (basis: {basis})")
    print()

    cp = result["cost_peaks"]
    print("Cost peaks:")
    print(f"  Max 1-hour:          {_format_usd(cp['one_hour']['value_usd'])} at {cp['one_hour']['at'] or 'n/a'}")
    print(f"  Max rolling 5-hour:  {_format_usd(cp['rolling_five_hour']['value_usd'])} at {cp['rolling_five_hour']['at'] or 'n/a'}")
    print()

    uo = result["utilization_observed"]
    print("Observed utilization (against current plan, Max 20x):")
    for dim, label in (("five_hour", "5-hour"), ("seven_day", "7-day")):
        d = uo[dim]
        print(f"  {label:>6}: peak {_format_pct(d['peak_pct'])} at {d['peak_at'] or 'n/a'}, avg {_format_pct(d['avg_pct'])}")
    print()

    print("Tier projection (rescaled from observed utilization):")
    for tier in TIER_ORDER:
        tp = result["tier_projection"][tier]
        cap_flag = " *** WOULD HIT CAP ***" if tp["would_hit_cap"] else ""
        print(f"  {tier:>8}: peak 5h {_format_pct(tp['peak_five_hour_pct'])}, peak 7d {_format_pct(tp['peak_seven_day_pct'])}, "
              f"avg 5h {_format_pct(tp['avg_five_hour_pct'])}, avg 7d {_format_pct(tp['avg_seven_day_pct'])}{cap_flag}")
    print()

    v = result["verdict"]
    print("Verdict:")
    for tier in TIER_ORDER:
        p = v["plans"][tier]
        ratio = "n/a" if p["api_equiv_ratio"] is None else f"{p['api_equiv_ratio']:.2f}x"
        print(f"  {tier:>8} (${p['price_usd']}/mo): viable={p['viable']}, api-equiv ratio={ratio}, "
              f"projected peak 7d={_format_pct(p['projected_peak_7d_util'])}, 5h={_format_pct(p['projected_peak_5h_util'])}")
    print(f"  Data maturity: {v['data_maturity']}")
    print(f"  Recommendation: {v['recommendation']}")
    print()

    print(f"All-time API-equivalent cost: {_format_usd(result['totals']['all_models_cost_usd'])}")
    for model_id, t in result["totals"]["by_model"].items():
        print(f"  {model_id}: {_format_usd(t['cost_usd'])} "
              f"(in={t['input']:,} out={t['output']:,} cache_w={t['cache_write']:,} cache_r={t['cache_read']:,}, "
              f"source={'/'.join(t['pricing_sources'])})")
    print()

    pm = result["pricing_meta"]
    print(f"Pricing: sources_used={pm['sources_used']}, override_active={pm['override_active']}, "
          f"cache_present={pm['cache_present']}, cache_stale={pm['cache_stale']}, bundled_as_of={pm['bundled_as_of']}")

    if result["warnings"]:
        print()
        print("Warnings:")
        for w in result["warnings"]:
            print(f"  - {w}")


def main(argv: list[str]) -> int:
    state_dir = DEFAULT_STATE_DIR

    if len(argv) > 1 and argv[1] == "refresh-pricing":
        status = refresh_pricing(state_dir)
        print(json.dumps(status, indent=2))
        return 0 if status.get("ok") else 1

    now = datetime.now(timezone.utc)
    result = compute(state_dir, now)
    _print_report(result)

    usage_dir = state_dir / "usage"
    usage_dir.mkdir(parents=True, exist_ok=True)
    tmp = usage_dir / "plan_fit.json.tmp"
    tmp.write_text(json.dumps(result, indent=2))
    tmp.replace(usage_dir / "plan_fit.json")
    print(f"\nWrote {usage_dir / 'plan_fit.json'}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
