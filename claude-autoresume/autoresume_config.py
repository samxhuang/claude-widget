"""Shared config for the daemon, plan_fit, and (via direct JSON writes) the widget.

`~/.claude-autoresume/config.json` is the single source of truth for account
type, budget limits, and remote SSH hosts. On the Mac, the widget's Settings
window is the only writer (read-modify-write under `config.json.lock`,
tmp+rename, unknown keys preserved); the Python side only ever reads. On a
REMOTE host, `remote_ctl.py apply-config` may additionally write the file —
solely as a relay of the widget's settings (sessions.idle_retention_minutes),
same lock + tmp+rename discipline; the daemon itself never writes config.json
on any host. A missing or malformed file
yields the full default config below, which reproduces pre-config behavior
exactly (Max account, no budget, no remote hosts) — the file is optional.

Pure stdlib; imported by the daemon at runtime (hard constraint: no pip deps).

Schema (version 1):

    {
      "version": 1,
      "account": { "type": "max" | "api", "plan": "max_20x" },
      "budget": {
        "weekly_usd":  <number|null>,   # null = no weekly budget bar
        "monthly_usd": <number|null>,   # null = no monthly budget bar
        "week_start":  "monday" | "sunday",
        "timezone":    "local" | "utc"  # budget period boundary computation
      },
      "remote_hosts": [
        {
          "name": "<unique, no ':'>",   # state.json key prefix "<name>::<sid>"
          "ssh": "<user@host or ~/.ssh/config alias>",
          "enabled": true,
          "python": "python3",
          "state_dir": "~/.claude-autoresume",
          "poll_seconds": 30,
          "collect_usage": true,
          "deployed_at": <ISO str|null>,      # widget-recorded, informational
          "deployed_version": <str|null>
        }, ...
      ]
    }
"""

from __future__ import annotations

import json
from pathlib import Path
from typing import Any, Optional

CONFIG_FILENAME = "config.json"

VALID_ACCOUNT_TYPES = {"max", "api"}
VALID_WEEK_STARTS = {"monday", "sunday"}
VALID_TIMEZONES = {"local", "utc"}

# Canonical plan keys. Mirrors plan_fit.TIER_MULTIPLIERS' key set — kept as a
# duplicate on purpose: this module must not import plan_fit (it is imported
# by the daemon and deployed standalone to remote hosts). If a tier is ever
# added there, add it here too. Anything else in config.json falls back to
# DEFAULT_PLAN instead of flowing downstream as an unknown plan string.
VALID_PLANS = {"pro", "max_5x", "max_20x"}

DEFAULT_PLAN = "max_20x"
DEFAULT_HOST_POLL_SECONDS = 30
MIN_HOST_POLL_SECONDS = 10

# How long an idle (never-rate-limited) session stays in the widget's
# Sessions list before the daemon drops it. Default matches the historical
# hardcoded ACTIVE_WINDOW_MINUTES = 30.
DEFAULT_IDLE_RETENTION_MINUTES = 30
MIN_IDLE_RETENTION_MINUTES = 5
MAX_IDLE_RETENTION_MINUTES = 24 * 60


def _default_config() -> dict:
    return {
        "version": 1,
        "account": {"type": "max", "plan": DEFAULT_PLAN},
        "budget": {
            "weekly_usd": None,
            "monthly_usd": None,
            "week_start": "monday",
            "timezone": "local",
        },
        "remote_hosts": [],
        "sessions": {"idle_retention_minutes": DEFAULT_IDLE_RETENTION_MINUTES},
    }


def _positive_number(value: Any) -> Optional[float]:
    """A strictly-positive finite number, else None (treated as unset)."""
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return None
    value = float(value)
    if value <= 0 or value != value or value in (float("inf"), float("-inf")):
        return None
    return value


def _clean_host(raw: Any, seen_names: set) -> Optional[dict]:
    """Validate one remote_hosts entry; None drops it (never raises)."""
    if not isinstance(raw, dict):
        return None
    name = raw.get("name")
    ssh = raw.get("ssh")
    if not isinstance(name, str) or not name.strip() or ":" in name:
        return None
    if not isinstance(ssh, str) or not ssh.strip():
        return None
    name = name.strip()
    if name in seen_names:
        return None
    seen_names.add(name)

    poll = raw.get("poll_seconds")
    if isinstance(poll, bool) or not isinstance(poll, (int, float)) or poll < MIN_HOST_POLL_SECONDS:
        poll = DEFAULT_HOST_POLL_SECONDS

    python = raw.get("python")
    state_dir = raw.get("state_dir")
    return {
        "name": name,
        "ssh": ssh.strip(),
        "enabled": bool(raw.get("enabled", True)),
        "python": python if isinstance(python, str) and python.strip() else "python3",
        "state_dir": state_dir if isinstance(state_dir, str) and state_dir.strip() else "~/.claude-autoresume",
        "poll_seconds": int(poll),
        "collect_usage": bool(raw.get("collect_usage", True)),
        "deployed_at": raw.get("deployed_at") if isinstance(raw.get("deployed_at"), str) else None,
        "deployed_version": raw.get("deployed_version") if isinstance(raw.get("deployed_version"), str) else None,
    }


def config_path(state_dir: Path) -> Path:
    return Path(state_dir) / CONFIG_FILENAME


def config_mtime(state_dir: Path) -> Optional[float]:
    """mtime of config.json, or None if absent. Cheap change-detection hook."""
    try:
        return config_path(state_dir).stat().st_mtime
    except OSError:
        return None


def load_config(state_dir: Path) -> dict:
    """Read config.json into the fully-defaulted schema. Never raises.

    Every field is validated independently; anything missing or malformed
    falls back to its default rather than poisoning the rest of the file.
    """
    cfg = _default_config()
    try:
        raw = json.loads(config_path(state_dir).read_text())
    except (OSError, ValueError):
        return cfg
    if not isinstance(raw, dict):
        return cfg

    account = raw.get("account")
    if isinstance(account, dict):
        acct_type = account.get("type")
        if isinstance(acct_type, str) and acct_type in VALID_ACCOUNT_TYPES:
            cfg["account"]["type"] = acct_type
        plan = account.get("plan")
        if isinstance(plan, str) and plan.strip() in VALID_PLANS:
            cfg["account"]["plan"] = plan.strip()
        # invalid/unknown plan string -> keep DEFAULT_PLAN (canonical keys only)

    budget = raw.get("budget")
    if isinstance(budget, dict):
        cfg["budget"]["weekly_usd"] = _positive_number(budget.get("weekly_usd"))
        cfg["budget"]["monthly_usd"] = _positive_number(budget.get("monthly_usd"))
        week_start = budget.get("week_start")
        if isinstance(week_start, str) and week_start in VALID_WEEK_STARTS:
            cfg["budget"]["week_start"] = week_start
        timezone = budget.get("timezone")
        if isinstance(timezone, str) and timezone in VALID_TIMEZONES:
            cfg["budget"]["timezone"] = timezone

    hosts = raw.get("remote_hosts")
    if isinstance(hosts, list):
        seen: set = set()
        cfg["remote_hosts"] = [h for h in (_clean_host(r, seen) for r in hosts) if h is not None]

    sessions = raw.get("sessions")
    if isinstance(sessions, dict):
        retention = sessions.get("idle_retention_minutes")
        if not isinstance(retention, bool) and isinstance(retention, (int, float)):
            cfg["sessions"]["idle_retention_minutes"] = int(
                min(MAX_IDLE_RETENTION_MINUTES,
                    max(MIN_IDLE_RETENTION_MINUTES, retention)))

    return cfg
