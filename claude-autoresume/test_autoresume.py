#!/usr/bin/env python3
"""
Unit tests for autoresume.py's audit fixes. Stdlib unittest only (no pip
deps, to match the daemon's SYSTEM python3 constraint). Run with:

    python3 test_autoresume.py            # or: python3 -m unittest test_autoresume -v

All module-level path constants are monkeypatched onto tmp dirs in setUp, so
nothing here reads or writes the real ~/.claude or ~/.claude-autoresume.
Timestamps are injected via the `now=` parameters where the code takes one.
"""

from __future__ import annotations

import json
import os
import tempfile
import unittest
from datetime import datetime, timezone
from pathlib import Path

import autoresume as ar


# ---------------------------------------------------------------------------
# transcript event builders (minimal shapes the daemon keys off)
# ---------------------------------------------------------------------------

def human_user(text="hi", cwd=None, ts="2026-07-18T14:00:00.000Z") -> dict:
    e = {
        "type": "user",
        "origin": {"kind": "human"},
        "message": {"role": "user", "content": [{"type": "text", "text": text}]},
        "timestamp": ts,
    }
    if cwd is not None:
        e["cwd"] = cwd
    return e


def assistant_text(text="done", stop_reason="end_turn", ts="2026-07-18T14:05:00.000Z") -> dict:
    return {
        "type": "assistant",
        "message": {
            "role": "assistant",
            "content": [{"type": "text", "text": text}],
            "stop_reason": stop_reason,
        },
        "timestamp": ts,
    }


def rate_limit(resets, ts="2026-07-18T14:02:00.000Z") -> dict:
    return {"type": "rate_limit_event", "resetsAt": resets, "timestamp": ts}


def ai_title(title="A title") -> dict:
    return {"type": "ai-title", "aiTitle": title}


def custom_title(title="Renamed") -> dict:
    return {"type": "custom-title", "customTitle": title}


class TempEnvMixin:
    """Redirects every module-level path constant onto a throwaway tmp dir and
    restores them on teardown, so a test can never touch real state."""

    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.tmp = Path(self._tmp.name)
        self.projects_dir = self.tmp / "projects"
        self.cowork_dir = self.tmp / "cowork"
        self.state_dir = self.tmp / "state"
        self.projects_dir.mkdir()
        self.cowork_dir.mkdir()
        self.state_dir.mkdir()

        self._saved = {
            "PROJECTS_DIR": ar.PROJECTS_DIR,
            "COWORK_SESSIONS_DIR": ar.COWORK_SESSIONS_DIR,
            "STATE_DIR": ar.STATE_DIR,
            "STATE_FILE": ar.STATE_FILE,
            "LOCK_FILE": ar.LOCK_FILE,
            "DAEMON_LOG": ar.DAEMON_LOG,
            "SESSIONS_DIR": ar.SESSIONS_DIR,
        }
        ar.PROJECTS_DIR = self.projects_dir
        ar.COWORK_SESSIONS_DIR = self.cowork_dir
        ar.STATE_DIR = self.state_dir
        ar.STATE_FILE = self.state_dir / "state.json"
        ar.LOCK_FILE = self.state_dir / "state.json.lock"
        ar.DAEMON_LOG = self.state_dir / "daemon.log"
        ar.SESSIONS_DIR = self.tmp / "sessions"  # nonexistent -> no live procs
        ar._PARSE_CACHE.clear()

    def tearDown(self):
        for k, v in self._saved.items():
            setattr(ar, k, v)
        ar._PARSE_CACHE.clear()
        self._tmp.cleanup()

    def write_cli_transcript(self, session_id, rows, project="proj1", mtime=None):
        folder = self.projects_dir / project
        folder.mkdir(parents=True, exist_ok=True)
        path = folder / f"{session_id}.jsonl"
        with open(path, "w") as f:
            for row in rows:
                f.write(json.dumps(row) + "\n")
        if mtime is not None:
            os.utime(path, (mtime, mtime))
        return path


# ---------------------------------------------------------------------------
# P1: stale rate-limit must not classify a live session as "waiting"
# ---------------------------------------------------------------------------

class TestP1StaleRateLimit(TempEnvMixin, unittest.TestCase):
    def _status(self, session_id, rows):
        self.write_cli_transcript(session_id, rows)
        now = ar.time.time()
        records = ar.compute_cli_records(now, {}, ar._PARSE_CACHE)
        self.assertIn(session_id, records)
        return records[session_id]

    def test_rate_limit_followed_by_real_conversation_is_not_waiting(self):
        """The bug: a rate limit hit hours ago, then the user manually resumed
        and kept working. A real user/assistant turn newer than the limit
        means it's live again -- must NOT be "waiting" (which would trigger a
        spurious second --resume into the live session)."""
        rec = self._status("sess_stale", [
            human_user(cwd=str(self.tmp)),
            rate_limit(1_800_000_000),
            assistant_text("picked back up after the limit cleared"),
            human_user("another turn", cwd=str(self.tmp), ts="2026-07-18T15:00:00.000Z"),
        ])
        self.assertEqual(rec["status"], "active")
        self.assertIsNone(rec["resets_at"])

    def test_rate_limit_at_tail_is_waiting(self):
        rec = self._status("sess_tail", [
            human_user(cwd=str(self.tmp)),
            rate_limit(1_800_000_000),
        ])
        self.assertEqual(rec["status"], "waiting")
        self.assertEqual(rec["resets_at"], 1_800_000_000)

    def test_rate_limit_followed_only_by_metadata_is_still_waiting(self):
        """Bookkeeping events (ai-title/custom-title/...) appended after the
        limit are Desktop metadata, not a resumption -- they must not mask a
        rate_limit that is still the effective tail."""
        rec = self._status("sess_meta", [
            human_user(cwd=str(self.tmp)),
            rate_limit(1_800_000_000),
            ai_title("Auto title"),
            custom_title("Renamed by user"),
        ])
        self.assertEqual(rec["status"], "waiting")
        self.assertEqual(rec["resets_at"], 1_800_000_000)

    def test_synthetic_rate_limit_notice_line_does_not_mask_the_event(self):
        """Claude Code writes an inline synthetic '<synthetic>' assistant
        notice right after the limit. That echo must be skipped (not treated
        as a real turn), so the rate_limit just before it is still found."""
        rec = self._status("sess_synth", [
            human_user(cwd=str(self.tmp)),
            rate_limit(1_800_000_000),
            {"type": "assistant", "isApiErrorMessage": True,
             "message": {"model": "<synthetic>",
                         "content": [{"type": "text", "text": "You've hit your limit"}]},
             "timestamp": "2026-07-18T14:02:30.000Z"},
        ])
        self.assertEqual(rec["status"], "waiting")


# ---------------------------------------------------------------------------
# P2: parse_reset_timestamp stringified-epoch handling
# ---------------------------------------------------------------------------

class TestP2ParseResetTimestamp(unittest.TestCase):
    def test_string_milliseconds_normalized_to_seconds(self):
        # The exact bug from the finding: "1752900000000" must become ~1.75e9,
        # not be returned raw (~year 57000).
        self.assertEqual(ar.parse_reset_timestamp("1752900000000"), 1752900000.0)

    def test_string_seconds_pass_through(self):
        self.assertEqual(ar.parse_reset_timestamp("1752900000"), 1752900000.0)

    def test_numeric_milliseconds_normalized(self):
        self.assertEqual(ar.parse_reset_timestamp(1752900000000), 1752900000.0)

    def test_numeric_seconds_pass_through(self):
        self.assertEqual(ar.parse_reset_timestamp(1752900000), 1752900000.0)

    def test_iso_string(self):
        expected = datetime(2026, 7, 18, 14, 0, 0, tzinfo=timezone.utc).timestamp()
        self.assertEqual(ar.parse_reset_timestamp("2026-07-18T14:00:00Z"), expected)

    def test_garbage_string_is_none(self):
        self.assertIsNone(ar.parse_reset_timestamp("not-a-time"))


# ---------------------------------------------------------------------------
# P7: explicit "kind" sentinel; a CLI project named "Cowork" survives pruning
# ---------------------------------------------------------------------------

class TestP7KindField(TempEnvMixin, unittest.TestCase):
    def test_merge_writes_kind_cli(self):
        state = {}
        rec = {
            "kind": "cli", "status": "active", "resets_at": None,
            "project_dir": "/x", "project_name": "x", "session_title": "t",
            "prompt_preview": "p", "last_activity_at": 1.0, "work_status": "running",
        }
        ar.merge_cli_records(state, {"sid": rec}, now=1.0)
        self.assertEqual(state["sid"]["kind"], "cli")

    def test_merge_writes_kind_cowork(self):
        state = {}
        rec = {
            "kind": "cowork", "status": "active", "project_dir": "/x",
            "session_title": "t", "last_activity_at": 1.0,
        }
        ar.merge_cowork_records(state, {"cw": rec}, now=1.0)
        self.assertEqual(state["cw"]["kind"], "cowork")

    def test_compute_cli_records_stamps_kind(self):
        self.write_cli_transcript("sess_k", [human_user(cwd=str(self.tmp))])
        records = ar.compute_cli_records(ar.time.time(), {}, ar._PARSE_CACHE)
        self.assertEqual(records["sess_k"]["kind"], "cli")

    def test_cli_session_named_cowork_not_pruned(self):
        """A CLI session whose project_dir basename is literally "Cowork" used
        to be treated as a Cowork entry by prune_deleted_sessions and deleted
        every cycle (never in live_cowork_ids). With kind="cli" it's kept as
        long as its transcript exists on disk."""
        self.write_cli_transcript("sess_cowork_named", [human_user(cwd=str(self.tmp))])
        state = {
            "sess_cowork_named": {
                "kind": "cli", "project_name": "Cowork", "status": "active",
                "handled": False,
            }
        }
        ar.prune_deleted_sessions(state)
        self.assertIn("sess_cowork_named", state)

    def test_legacy_entry_without_kind_falls_back_to_project_name(self):
        """Back-compat: an entry from an older daemon (no "kind") named
        "Cowork" with no matching live Cowork session is still pruned."""
        state = {
            "ghost": {"project_name": "Cowork", "status": "active", "handled": False}
        }
        ar.prune_deleted_sessions(state)
        self.assertNotIn("ghost", state)


# ---------------------------------------------------------------------------
# P8: corrupt state.json is backed up, not silently discarded
# ---------------------------------------------------------------------------

class TestP8CorruptStateBackup(TempEnvMixin, unittest.TestCase):
    def test_corrupt_state_copied_before_fresh_start(self):
        ar.STATE_FILE.write_text("{ this is not valid json ")
        result = ar.load_state()
        self.assertEqual(result, {})
        backup = ar.STATE_FILE.parent / (ar.STATE_FILE.name + ".corrupt")
        self.assertTrue(backup.exists())
        self.assertEqual(backup.read_text(), "{ this is not valid json ")

    def test_valid_state_loads_normally(self):
        ar.STATE_FILE.write_text(json.dumps({"sid": {"enabled": True}}))
        self.assertEqual(ar.load_state(), {"sid": {"enabled": True}})


# ---------------------------------------------------------------------------
# P9: find_cwd_in_lines returns the most recent cwd
# ---------------------------------------------------------------------------

class TestP9LatestCwd(unittest.TestCase):
    def test_last_cwd_wins(self):
        objs = [{"cwd": "/first"}, {"type": "user"}, {"cwd": "/second/moved"}]
        self.assertEqual(ar.find_cwd_in_lines(objs), "/second/moved")

    def test_single_cwd(self):
        self.assertEqual(ar.find_cwd_in_lines([{"cwd": "/only"}]), "/only")

    def test_no_cwd(self):
        self.assertIsNone(ar.find_cwd_in_lines([{"type": "user"}]))


# ---------------------------------------------------------------------------
# P5b: merge preserves widget-owned fields across a scan merge
# ---------------------------------------------------------------------------

class TestP5MergeSemantics(TempEnvMixin, unittest.TestCase):
    def _waiting_record(self):
        return {
            "kind": "cli", "status": "waiting", "resets_at": 1_800_000_000,
            "project_dir": "/repo", "project_name": "repo", "session_title": "t",
            "prompt_preview": "p", "last_activity_at": 123.0, "work_status": "idle",
        }

    def test_user_toggles_preserved_across_active_to_waiting(self):
        state = {
            "sid": {
                "kind": "cli", "status": "active", "enabled": True,
                "force_resume": True, "handled": False, "handled_at": None,
                "detected_at": 1.0, "project_name": "repo",
            }
        }
        ar.merge_cli_records(state, {"sid": self._waiting_record()}, now=999.0)
        e = state["sid"]
        self.assertTrue(e["enabled"])          # user toggle survives
        self.assertTrue(e["force_resume"])     # widget-owned survives
        self.assertEqual(e["status"], "waiting")   # display refreshed
        self.assertEqual(e["resets_at"], 1_800_000_000)
        self.assertEqual(e["detected_at"], 1.0)    # not clobbered
        self.assertEqual(e["kind"], "cli")

    def test_handled_entry_not_resurrected(self):
        state = {"sid": {"status": "resumed", "handled": True, "enabled": True}}
        ar.merge_cli_records(state, {"sid": self._waiting_record()}, now=999.0)
        self.assertEqual(state["sid"]["status"], "resumed")  # untouched

    def test_none_status_drops_unhandled_entry(self):
        state = {"sid": {"status": "active", "handled": False}}
        ar.merge_cli_records(state, {"sid": {"status": None}}, now=999.0)
        self.assertNotIn("sid", state)

    def test_none_status_keeps_handled_entry(self):
        state = {"sid": {"status": "resumed", "handled": True}}
        ar.merge_cli_records(state, {"sid": {"status": None}}, now=999.0)
        self.assertIn("sid", state)

    def test_new_session_defaults_disabled(self):
        state = {}
        ar.merge_cli_records(state, {"sid": self._waiting_record()}, now=999.0)
        self.assertFalse(state["sid"]["enabled"])
        self.assertFalse(state["sid"]["force_resume"])
        self.assertFalse(state["sid"]["handled"])

    def test_cowork_widget_fields_preserved(self):
        state = {
            "cw": {
                "kind": "cowork", "status": "active", "resume_armed": True,
                "needs_attention": True, "enabled": True, "handled": False,
                "detected_at": 5.0,
            }
        }
        rec = {"kind": "cowork", "status": "active", "project_dir": "/c",
               "session_title": "cw title", "last_activity_at": 9.0}
        ar.merge_cowork_records(state, {"cw": rec}, now=999.0)
        self.assertTrue(state["cw"]["resume_armed"])
        self.assertTrue(state["cw"]["needs_attention"])
        self.assertTrue(state["cw"]["enabled"])
        self.assertEqual(state["cw"]["session_title"], "cw title")


# ---------------------------------------------------------------------------
# Parse cache: an unchanged file is not re-parsed; a changed one is
# ---------------------------------------------------------------------------

class TestParseCache(TempEnvMixin, unittest.TestCase):
    def test_unchanged_file_reuses_cache_entry(self):
        path = self.write_cli_transcript("sess_c", [human_user(cwd=str(self.tmp))])
        cache = {}
        ar.compute_cli_records(ar.time.time(), {}, cache)
        cached_obj = cache[str(path)]
        # Second pass with no file change must reuse the very same cached dict.
        ar.compute_cli_records(ar.time.time(), {}, cache)
        self.assertIs(cache[str(path)], cached_obj)

    def test_out_of_window_file_evicted_from_cache(self):
        path = self.write_cli_transcript("sess_old", [human_user(cwd=str(self.tmp))])
        cache = {}
        ar.compute_cli_records(ar.time.time(), {}, cache)
        self.assertIn(str(path), cache)
        # Age the file well past the scan window; next pass should evict it.
        old = ar.time.time() - (ar.SCAN_WINDOW_MINUTES + 10) * 60
        os.utime(path, (old, old))
        ar.compute_cli_records(ar.time.time(), {}, cache)
        self.assertNotIn(str(path), cache)


class TestPlanFitOnConfigChange(TempEnvMixin, unittest.TestCase):
    """Finding 2: a config.json edit refreshes plan_fit.json on the next poll,
    not an hour later."""

    class _FakePlanFit:
        def __init__(self):
            self.calls = 0

        def write_plan_fit(self, state_dir, when):
            self.calls += 1

    def setUp(self):
        super().setUp()
        self._real_plan_fit = ar.plan_fit
        self.fake = self._FakePlanFit()
        ar.plan_fit = self.fake
        self.cfg = self.state_dir / "config.json"

    def tearDown(self):
        ar.plan_fit = self._real_plan_fit
        super().tearDown()

    def _write_cfg(self, mtime, content=None):
        self.cfg.write_text(json.dumps(content if content is not None else {"version": 1}))
        os.utime(self.cfg, (mtime, mtime))

    def _inputs(self):
        import autoresume_config as acfg
        return ar._plan_fit_config_inputs(acfg.load_config(self.state_dir))

    def test_no_change_no_write(self):
        self._write_cfg(1000.0)
        import autoresume_config as acfg
        last = acfg.config_mtime(self.state_dir)
        new_mtime, inputs = ar._maybe_write_plan_fit_on_config_change(
            self.state_dir, last, False, self._inputs())
        self.assertEqual(new_mtime, last)
        self.assertEqual(self.fake.calls, 0)

    def test_change_triggers_single_write_and_advances_mtime(self):
        self._write_cfg(1000.0)
        last = 1000.0
        last_inputs = self._inputs()
        # user edited Settings → new mtime AND a plan-fit-relevant change
        self._write_cfg(2000.0, {"version": 1, "account": {"type": "api", "plan": "pro"}})
        new_mtime, new_inputs = ar._maybe_write_plan_fit_on_config_change(
            self.state_dir, last, False, last_inputs)
        self.assertEqual(self.fake.calls, 1, "one plan_fit write on account change")
        self.assertEqual(new_mtime, 2000.0, "returns the new mtime so it won't re-fire")
        # A follow-up with the returned values must not write again.
        again_mtime, again_inputs = ar._maybe_write_plan_fit_on_config_change(
            self.state_dir, new_mtime, False, new_inputs)
        self.assertEqual(self.fake.calls, 1)
        self.assertEqual(again_mtime, new_mtime)
        self.assertEqual(again_inputs, new_inputs)

    def test_retention_only_change_skips_write(self):
        # Audit MINOR #6: an edit that only touches retention (or hosts) bumps
        # the mtime but doesn't affect plan-fit's inputs — no rewrite, but the
        # mtime is remembered so the detector doesn't re-load every poll.
        self._write_cfg(1000.0)
        last_inputs = self._inputs()
        self._write_cfg(2000.0, {"version": 1,
                                 "sessions": {"idle_retention_minutes": 120}})
        new_mtime, new_inputs = ar._maybe_write_plan_fit_on_config_change(
            self.state_dir, 1000.0, False, last_inputs)
        self.assertEqual(self.fake.calls, 0, "retention-only edit: no plan_fit rewrite")
        self.assertEqual(new_mtime, 2000.0, "mtime still advanced")
        self.assertEqual(new_inputs, last_inputs)

    def test_budget_change_triggers_write(self):
        self._write_cfg(1000.0)
        last_inputs = self._inputs()
        self._write_cfg(2000.0, {"version": 1, "budget": {"monthly_usd": 300}})
        ar._maybe_write_plan_fit_on_config_change(
            self.state_dir, 1000.0, False, last_inputs)
        self.assertEqual(self.fake.calls, 1, "budget edit must rewrite plan_fit")

    def test_unknown_last_inputs_counts_as_differing(self):
        # last_plan_inputs=None (unknown) must fail safe: rewrite once.
        self._write_cfg(1000.0)
        self._write_cfg(2000.0)
        ar._maybe_write_plan_fit_on_config_change(self.state_dir, 1000.0, False, None)
        self.assertEqual(self.fake.calls, 1)

    def test_remote_mode_never_writes(self):
        self._write_cfg(1000.0)
        new_mtime, inputs = ar._maybe_write_plan_fit_on_config_change(
            self.state_dir, 500.0, True, ("sentinel",))
        self.assertEqual(self.fake.calls, 0, "remote host: Mac owns plan_fit")
        self.assertEqual(new_mtime, 500.0, "last_mtime unchanged in remote mode")
        self.assertEqual(inputs, ("sentinel",), "cached inputs unchanged in remote mode")


# ---------------------------------------------------------------------------
# Idle retention: sessions must drop AT the retention edge, not ~3x later
# ---------------------------------------------------------------------------

class TestIdleRetentionDrop(TempEnvMixin, unittest.TestCase):
    """Regression tests for the equal-windows bug: with scan == active window
    the quiet->None->delete band was empty, so idle sessions lingered until
    the old 2x-last_seen safety net (~90 min at a 30m setting) instead of
    dropping at the retention edge."""

    def test_idle_just_past_retention_gets_none_record(self):
        now = ar.time.time()
        # 32 min idle with a 30m retention: inside the scan buffer band,
        # outside the active window -> must yield an explicit None record so
        # merge deletes the entry, not silence.
        mtime = now - 32 * 60
        self.write_cli_transcript("sess_band", [human_user(cwd=str(self.tmp))], mtime=mtime)
        records = ar.compute_cli_records(now, {}, {}, 30)
        self.assertIn("sess_band", records)
        self.assertIsNone(records["sess_band"]["status"])

    def test_idle_inside_retention_stays_active(self):
        now = ar.time.time()
        mtime = now - 20 * 60
        self.write_cli_transcript("sess_live", [human_user(cwd=str(self.tmp))], mtime=mtime)
        records = ar.compute_cli_records(now, {}, {}, 30)
        self.assertEqual(records["sess_live"]["status"], "active")

    def test_prune_keys_on_real_activity_not_last_seen(self):
        # A fresh last_seen (e.g. re-stamped by a transient window widening)
        # must not keep a long-idle session alive: prune uses
        # last_activity_at + grace.
        now = ar.time.time()
        state = {
            "idle_old": {"kind": "cli", "status": "active", "handled": False,
                          "last_seen": now,  # fresh bookkeeping
                          "last_activity_at": now - 60 * 60},  # 1h idle
            "idle_recent": {"kind": "cli", "status": "active", "handled": False,
                             "last_seen": now,
                             "last_activity_at": now - 20 * 60},
        }
        ar.prune_old_entries(state, 30)
        self.assertNotIn("idle_old", state)
        self.assertIn("idle_recent", state)

    def test_prune_falls_back_to_last_seen_without_activity_field(self):
        now = ar.time.time()
        state = {"legacy": {"kind": "cli", "status": "active", "handled": False,
                             "last_seen": now - 60 * 60}}
        ar.prune_old_entries(state, 30)
        self.assertNotIn("legacy", state)


# ---------------------------------------------------------------------------
# Quiet-drop must not delete sessions with a pending tool call (audit MAJOR #3)
# ---------------------------------------------------------------------------

def assistant_tool_use(name="Bash", tool_id="toolu_01", ts="2026-07-18T14:01:00.000Z") -> dict:
    return {
        "type": "assistant",
        "message": {
            "role": "assistant",
            "content": [{"type": "tool_use", "id": tool_id, "name": name,
                         "input": {"command": "sleep 600"}}],
            "stop_reason": "tool_use",
        },
        "timestamp": ts,
    }


def tool_result_user(tool_id="toolu_01", ts="2026-07-18T14:03:00.000Z") -> dict:
    return {
        "type": "user",
        "message": {"role": "user",
                    "content": [{"type": "tool_result", "tool_use_id": tool_id,
                                 "content": "ok"}]},
        "timestamp": ts,
    }


class TestQuietDropPendingTool(TempEnvMixin, unittest.TestCase):
    """The audit scenario: retention=5 (the MIN floor), a session whose tail
    is a pending Bash tool_use goes >5min without a transcript write during a
    long tool run. The old quiet branch emitted a None record, which deleted
    the entry — including widget-owned enabled=True — and the session came
    back later as enabled=False."""

    def test_pending_tool_use_survives_quiet_window(self):
        now = ar.time.time()
        mtime = now - 6 * 60  # 6 min idle, retention 5
        self.write_cli_transcript("sess_pending", [
            human_user(cwd=str(self.tmp)),
            assistant_tool_use(),  # flushed tool_use, no tool_result yet
        ], mtime=mtime)
        records = ar.compute_cli_records(now, {}, {}, 5)
        self.assertIn("sess_pending", records)
        self.assertEqual(records["sess_pending"]["status"], "active",
                         "pending tool call: must stay active, not quiet-drop")

    def test_pending_tool_keeps_enabled_toggle_across_merge(self):
        # End-to-end shape of the audit bug: the enabled=True entry must
        # survive the merge instead of being deleted and later re-added off.
        now = ar.time.time()
        self.write_cli_transcript("sess_toggled", [
            human_user(cwd=str(self.tmp)),
            assistant_tool_use(),
        ], mtime=now - 6 * 60)
        records = ar.compute_cli_records(now, {}, {}, 5)
        state = {"sess_toggled": {"kind": "cli", "status": "active",
                                  "handled": False, "enabled": True}}
        ar.merge_cli_records(state, records, now)
        self.assertIn("sess_toggled", state)
        self.assertTrue(state["sess_toggled"]["enabled"],
                        "widget-owned enabled=True must survive")

    def test_completed_tail_still_quiet_drops(self):
        # Same shape but the tool call completed and the turn ended cleanly:
        # past the retention edge this is genuinely idle -> None record.
        now = ar.time.time()
        self.write_cli_transcript("sess_done", [
            human_user(cwd=str(self.tmp)),
            assistant_tool_use(),
            tool_result_user(),
            assistant_text("all done"),
        ], mtime=now - 6 * 60)
        records = ar.compute_cli_records(now, {}, {}, 5)
        self.assertIn("sess_done", records)
        self.assertIsNone(records["sess_done"]["status"],
                          "completed tail past retention: quiet-drop as before")

    def test_pending_tool_inside_retention_unchanged(self):
        now = ar.time.time()
        self.write_cli_transcript("sess_fresh", [
            human_user(cwd=str(self.tmp)),
            assistant_tool_use(),
        ], mtime=now - 2 * 60)
        records = ar.compute_cli_records(now, {}, {}, 5)
        self.assertEqual(records["sess_fresh"]["status"], "active")


# ---------------------------------------------------------------------------
# autoresume_config: account.plan canonicalization (audit MINOR #5)
# ---------------------------------------------------------------------------

class TestConfigPlanCanonicalization(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.state_dir = Path(self._tmp.name)

    def tearDown(self):
        self._tmp.cleanup()

    def _plan_for(self, plan_value):
        import autoresume_config as acfg
        (self.state_dir / "config.json").write_text(
            json.dumps({"version": 1, "account": {"type": "max", "plan": plan_value}}))
        return acfg.load_config(self.state_dir)["account"]["plan"]

    def test_valid_plans_accepted(self):
        for plan in ("pro", "max_5x", "max_20x"):
            self.assertEqual(self._plan_for(plan), plan)

    def test_whitespace_stripped(self):
        self.assertEqual(self._plan_for("  pro  "), "pro")

    def test_unknown_plan_falls_back_to_default(self):
        import autoresume_config as acfg
        # Any non-canonical string (the old code accepted ALL non-empty
        # strings) must fall back to the default plan.
        for bad in ("enterprise_9000", "Max 20x", "max20x", "PRO"):
            self.assertEqual(self._plan_for(bad), acfg.DEFAULT_PLAN)

    def test_non_string_plan_falls_back_to_default(self):
        import autoresume_config as acfg
        for bad in (None, 20, True, ["max_20x"]):
            self.assertEqual(self._plan_for(bad), acfg.DEFAULT_PLAN)


if __name__ == "__main__":
    unittest.main()
