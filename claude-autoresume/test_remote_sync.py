#!/usr/bin/env python3
"""
Unit tests for remote_sync.py (WS-4 — Mac-side remote/SSH session sync).

Stdlib unittest only (matches the daemon's system-python3 constraint). Every
state.json / config.json / usage path is monkeypatched onto a throwaway tmp dir
(same TempEnv approach as test_autoresume.py), so nothing here touches the real
~/.claude-autoresume. The ssh transport is a FAKE callable — no test ever shells
out — matching the injectable transport signature
`(ssh_target, remote_argv, stdin_data, timeout) -> (returncode, stdout, stderr)`.

Run with:
    python3 test_remote_sync.py        # or: python3 -m unittest test_remote_sync -v
"""

from __future__ import annotations

import json
import tempfile
import unittest
from pathlib import Path

import autoresume as ar
import remote_sync as rs


# ---------------------------------------------------------------------------
# Fake ssh transport
# ---------------------------------------------------------------------------

class FakeTransport:
    """Records calls and returns canned (rc, stdout, stderr) responses keyed by
    remote_ctl subcommand. Distinguishes `dump`, `dump --usage`, and
    `apply-toggles` by inspecting remote_argv."""

    def __init__(self, dump=None, usage=None, apply_ok=True, raise_on=None):
        self._dump = dump                # dict for `dump` → serialized to stdout
        self._usage = usage              # dict for `dump --usage`
        self._apply_ok = apply_ok        # bool | (rc, body) for apply-toggles
        self._raise_on = raise_on or set()  # subcommands that raise (unreachable)
        self.calls = []                  # list of (kind, ssh_target, stdin_data)

    def _kind(self, remote_argv):
        if "apply-toggles" in remote_argv:
            return "apply"
        if "--usage" in remote_argv:
            return "usage"
        return "dump"

    def __call__(self, ssh_target, remote_argv, stdin_data=None, timeout=15):
        kind = self._kind(remote_argv)
        self.calls.append((kind, ssh_target, stdin_data))
        if kind in self._raise_on:
            raise TimeoutError(f"fake ssh timeout on {kind}")
        if kind == "apply":
            if self._apply_ok is True:
                return 0, json.dumps({"ok": True, "applied": 1}), ""
            if self._apply_ok is False:
                return 0, json.dumps({"ok": False}), ""
            return self._apply_ok  # explicit (rc, stdout, stderr) tuple
        if kind == "usage":
            if self._usage is None:
                return 1, "", "no usage"
            return 0, json.dumps(self._usage), ""
        # dump
        if self._dump is None:
            return 1, "", "unreachable"
        return 0, json.dumps(self._dump), ""


def dump_payload(now, state):
    return {"v": 1, "now": now, "state": state}


def remote_entry(**kw):
    """A remote-daemon-owned entry as it would appear in a dump's state map."""
    base = {
        "kind": "cli",
        "status": "active",
        "work_status": "running",
        "resets_at": None,
        "last_activity_at": 1000.0,
        "detected_at": 900.0,
        "handled": False,
        "handled_at": None,
        "project_dir": "/home/sam/proj",
        "project_name": "proj",
        "session_title": "remote work",
        "prompt_preview": "do the thing",
        "enabled": False,
        "resume_armed": False,
        "force_resume": False,
    }
    base.update(kw)
    return base


HOST = {
    "name": "devbox",
    "ssh": "sam@devbox",
    "enabled": True,
    "python": "python3",
    "state_dir": "~/.claude-autoresume",
    "poll_seconds": 30,
    "collect_usage": True,
}


class TempEnvMixin:
    """Redirect autoresume's state paths onto a tmp dir so tests never touch
    the real state file. state_dir passed to remote_sync == this same tmp dir."""

    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.tmp = Path(self._tmp.name)
        self.state_dir = self.tmp / "state"
        self.state_dir.mkdir()

        self._saved = {
            "STATE_DIR": ar.STATE_DIR,
            "STATE_FILE": ar.STATE_FILE,
            "LOCK_FILE": ar.LOCK_FILE,
            "DAEMON_LOG": ar.DAEMON_LOG,
        }
        ar.STATE_DIR = self.state_dir
        ar.STATE_FILE = self.state_dir / "state.json"
        ar.LOCK_FILE = self.state_dir / "state.json.lock"
        ar.DAEMON_LOG = self.state_dir / "daemon.log"

    def tearDown(self):
        for k, v in self._saved.items():
            setattr(ar, k, v)
        self._tmp.cleanup()

    def write_state(self, state):
        with ar.StateLock():
            ar.save_state(state)

    def read_state(self):
        with ar.StateLock():
            return ar.load_state()


# ---------------------------------------------------------------------------
# Merge: local toggles preserved; remote-owned fields overwritten
# ---------------------------------------------------------------------------

class TestMergePreservesToggles(TempEnvMixin, unittest.TestCase):
    def test_local_enabled_and_armed_survive_merge(self):
        # Widget armed this remote session locally; remote hasn't got it yet.
        self.write_state({
            "devbox::s1": {
                "host": "devbox", "remote_id": "s1",
                "enabled": True, "resume_armed": True, "force_resume": False,
                "status": "waiting", "remote_last_sync": 500.0,
            }
        })
        dump = dump_payload(1000.0, {"s1": remote_entry(status="active", enabled=False)})
        ft = FakeTransport(dump=dump)
        rs.sync_host(HOST, self.state_dir, ft, now_fn=lambda: 1000.0)

        e = self.read_state()["devbox::s1"]
        self.assertTrue(e["enabled"], "local enabled must be preserved (Mac authoritative)")
        self.assertTrue(e["resume_armed"])
        self.assertEqual(e["status"], "active", "remote-owned status overwritten from dump")
        self.assertEqual(e["host"], "devbox")
        self.assertEqual(e["remote_id"], "s1")
        self.assertFalse(e["remote_stale"])

    def test_divergent_toggle_is_pushed(self):
        self.write_state({
            "devbox::s1": {"host": "devbox", "remote_id": "s1",
                           "enabled": True, "resume_armed": False, "force_resume": False}
        })
        dump = dump_payload(1000.0, {"s1": remote_entry(enabled=False, resume_armed=False)})
        ft = FakeTransport(dump=dump, apply_ok=True)
        rs.sync_host(HOST, self.state_dir, ft, now_fn=lambda: 1000.0)

        applies = [c for c in ft.calls if c[0] == "apply"]
        self.assertEqual(len(applies), 1, "a diverging enabled toggle must be pushed")
        payload = json.loads(applies[0][2])
        self.assertEqual(payload, {"s1": {"enabled": True}})

    def test_no_divergence_no_push(self):
        self.write_state({
            "devbox::s1": {"host": "devbox", "remote_id": "s1",
                           "enabled": False, "resume_armed": False, "force_resume": False}
        })
        dump = dump_payload(1000.0, {"s1": remote_entry(enabled=False, resume_armed=False)})
        ft = FakeTransport(dump=dump)
        rs.sync_host(HOST, self.state_dir, ft, now_fn=lambda: 1000.0)
        self.assertEqual([c for c in ft.calls if c[0] == "apply"], [])

    def test_new_remote_session_defaults_disabled(self):
        # No local entry at all; dump introduces a fresh session.
        dump = dump_payload(1000.0, {"s_new": remote_entry(enabled=False)})
        ft = FakeTransport(dump=dump)
        rs.sync_host(HOST, self.state_dir, ft, now_fn=lambda: 1000.0)
        e = self.read_state()["devbox::s_new"]
        self.assertFalse(e["enabled"])
        self.assertFalse(e["resume_armed"])
        self.assertFalse(e["force_resume"])


# ---------------------------------------------------------------------------
# Vanished remote sessions are deleted
# ---------------------------------------------------------------------------

class TestVanishedDeletion(TempEnvMixin, unittest.TestCase):
    def test_session_absent_from_dump_is_deleted(self):
        self.write_state({
            "devbox::s1": {"host": "devbox", "remote_id": "s1", "enabled": False},
            "devbox::s2": {"host": "devbox", "remote_id": "s2", "enabled": False},
            # An unrelated local session must be left untouched.
            "local-uuid-xyz": {"kind": "cli", "enabled": True, "status": "active"},
        })
        dump = dump_payload(1000.0, {"s1": remote_entry()})  # s2 vanished
        ft = FakeTransport(dump=dump)
        rs.sync_host(HOST, self.state_dir, ft, now_fn=lambda: 1000.0)

        state = self.read_state()
        self.assertIn("devbox::s1", state)
        self.assertNotIn("devbox::s2", state, "session gone from dump must be dropped")
        self.assertIn("local-uuid-xyz", state, "local (non-host) entries untouched")

    def test_other_hosts_untouched_by_one_host_sync(self):
        self.write_state({
            "devbox::s1": {"host": "devbox", "remote_id": "s1", "enabled": False},
            "other::z9": {"host": "other", "remote_id": "z9", "enabled": True},
        })
        dump = dump_payload(1000.0, {"s1": remote_entry()})
        ft = FakeTransport(dump=dump)
        rs.sync_host(HOST, self.state_dir, ft, now_fn=lambda: 1000.0)
        self.assertIn("other::z9", self.read_state(),
                      "syncing devbox must not touch another host's entries")


# ---------------------------------------------------------------------------
# Clock-skew adjustment (right fields only; never resets_at)
# ---------------------------------------------------------------------------

class TestSkewAdjustment(TempEnvMixin, unittest.TestCase):
    def test_skew_applied_to_activity_detected_handled_not_resets(self):
        # mac_now (constant) = 2000, remote "now" = 1000 → offset = +1000.
        dump = dump_payload(1000.0, {
            "s1": remote_entry(
                last_activity_at=1000.0,
                detected_at=900.0,
                handled_at=950.0,
                resets_at=5000.0,
            )
        })
        ft = FakeTransport(dump=dump)
        rs.sync_host(HOST, self.state_dir, ft, now_fn=lambda: 2000.0)

        e = self.read_state()["devbox::s1"]
        self.assertEqual(e["last_activity_at"], 2000.0)   # 1000 + 1000
        self.assertEqual(e["detected_at"], 1900.0)        # 900 + 1000
        self.assertEqual(e["handled_at"], 1950.0)         # 950 + 1000
        self.assertEqual(e["resets_at"], 5000.0, "resets_at is server wall-clock — never skewed")

    def test_none_handled_at_passes_through(self):
        dump = dump_payload(1000.0, {"s1": remote_entry(handled_at=None)})
        ft = FakeTransport(dump=dump)
        rs.sync_host(HOST, self.state_dir, ft, now_fn=lambda: 2000.0)
        self.assertIsNone(self.read_state()["devbox::s1"]["handled_at"])

    def test_missing_remote_now_means_zero_offset(self):
        dump = {"v": 1, "state": {"s1": remote_entry(last_activity_at=1000.0)}}  # no "now"
        ft = FakeTransport(dump=dump)
        rs.sync_host(HOST, self.state_dir, ft, now_fn=lambda: 2000.0)
        self.assertEqual(self.read_state()["devbox::s1"]["last_activity_at"], 1000.0)


# ---------------------------------------------------------------------------
# force_resume one-shot semantics
# ---------------------------------------------------------------------------

class TestForceResumeOneShot(TempEnvMixin, unittest.TestCase):
    def _seed_forced(self):
        self.write_state({
            "devbox::s1": {"host": "devbox", "remote_id": "s1",
                           "enabled": True, "resume_armed": False, "force_resume": True}
        })
        return dump_payload(1000.0, {"s1": remote_entry(enabled=True)})

    def test_push_ok_clears_force_resume(self):
        dump = self._seed_forced()
        ft = FakeTransport(dump=dump, apply_ok=True)
        rs.sync_host(HOST, self.state_dir, ft, now_fn=lambda: 1000.0)

        applies = [c for c in ft.calls if c[0] == "apply"]
        self.assertEqual(len(applies), 1)
        self.assertEqual(json.loads(applies[0][2]), {"s1": {"force_resume": True}})
        self.assertFalse(self.read_state()["devbox::s1"]["force_resume"],
                         "force_resume must be cleared after a confirmed push")

    def test_push_fail_keeps_force_resume(self):
        dump = self._seed_forced()
        ft = FakeTransport(dump=dump, apply_ok=False)  # remote returns ok:false
        rs.sync_host(HOST, self.state_dir, ft, now_fn=lambda: 1000.0)
        self.assertTrue(self.read_state()["devbox::s1"]["force_resume"],
                        "a failed push must keep force_resume for next-cycle retry")

    def test_push_transport_error_keeps_force_resume(self):
        dump = self._seed_forced()
        ft = FakeTransport(dump=dump, raise_on={"apply"})
        rs.sync_host(HOST, self.state_dir, ft, now_fn=lambda: 1000.0)
        self.assertTrue(self.read_state()["devbox::s1"]["force_resume"])


# ---------------------------------------------------------------------------
# Unreachable → remote_stale, then dropped after 24h
# ---------------------------------------------------------------------------

class TestUnreachable(TempEnvMixin, unittest.TestCase):
    def test_dump_failure_marks_stale_and_keeps_recent_last_sync(self):
        self.write_state({
            "devbox::s1": {"host": "devbox", "remote_id": "s1", "enabled": True,
                           "remote_stale": False, "remote_last_sync": 990.0},
        })
        ft = FakeTransport(dump=None)  # rc=1 → unreachable
        ok = rs.sync_host(HOST, self.state_dir, ft, now_fn=lambda: 1000.0)
        self.assertFalse(ok)
        e = self.read_state()["devbox::s1"]
        self.assertTrue(e["remote_stale"])
        self.assertEqual(e["remote_last_sync"], 990.0, "last successful sync not advanced on failure")

    def test_transport_exception_marks_stale(self):
        self.write_state({
            "devbox::s1": {"host": "devbox", "remote_id": "s1",
                           "remote_stale": False, "remote_last_sync": 990.0},
        })
        ft = FakeTransport(raise_on={"dump"})
        rs.sync_host(HOST, self.state_dir, ft, now_fn=lambda: 1000.0)
        self.assertTrue(self.read_state()["devbox::s1"]["remote_stale"])

    def test_dropped_after_24h_continuous_unreachability(self):
        now = 1_000_000.0
        old = now - (rs.REMOTE_DROP_HOURS * 3600 + 60)  # just over 24h ago
        self.write_state({
            "devbox::s1": {"host": "devbox", "remote_id": "s1",
                           "remote_stale": True, "remote_last_sync": old},
        })
        ft = FakeTransport(dump=None)
        rs.sync_host(HOST, self.state_dir, ft, now_fn=lambda: now)
        self.assertNotIn("devbox::s1", self.read_state(),
                         "entry unreachable >24h should be dropped")

    def test_not_dropped_before_24h(self):
        now = 1_000_000.0
        recent = now - (rs.REMOTE_DROP_HOURS * 3600 - 60)  # just under 24h
        self.write_state({
            "devbox::s1": {"host": "devbox", "remote_id": "s1",
                           "remote_stale": True, "remote_last_sync": recent},
        })
        ft = FakeTransport(dump=None)
        rs.sync_host(HOST, self.state_dir, ft, now_fn=lambda: now)
        self.assertIn("devbox::s1", self.read_state())

    def test_recovery_clears_stale(self):
        self.write_state({
            "devbox::s1": {"host": "devbox", "remote_id": "s1",
                           "remote_stale": True, "remote_last_sync": 500.0},
        })
        dump = dump_payload(1000.0, {"s1": remote_entry()})
        ft = FakeTransport(dump=dump)
        rs.sync_host(HOST, self.state_dir, ft, now_fn=lambda: 1000.0)
        e = self.read_state()["devbox::s1"]
        self.assertFalse(e["remote_stale"])
        self.assertEqual(e["remote_last_sync"], 1000.0)


# ---------------------------------------------------------------------------
# Usage lane: per-host token file
# ---------------------------------------------------------------------------

class TestUsageLane(TempEnvMixin, unittest.TestCase):
    def test_usage_lane_writes_per_host_file(self):
        tokens = {"2026-07-19T12": {"code_cli": {"claude-x": {"input_tokens": 10}}}}
        ft = FakeTransport(usage={"v": 1, "now": 1000.0, "state": {},
                                  "tokens_hourly": tokens})
        ok = rs.fetch_host_usage(HOST, self.state_dir, ft)
        self.assertTrue(ok)
        out = self.state_dir / "usage" / "remote" / "devbox_tokens_hourly.json"
        self.assertTrue(out.exists())
        self.assertEqual(json.loads(out.read_text()), tokens)
        # And it requested the usage lane specifically.
        self.assertEqual([c[0] for c in ft.calls], ["usage"])

    def test_usage_failure_keeps_stale_copy(self):
        out_dir = self.state_dir / "usage" / "remote"
        out_dir.mkdir(parents=True)
        stale = out_dir / "devbox_tokens_hourly.json"
        stale.write_text(json.dumps({"old": "data"}))

        ft = FakeTransport(usage=None)  # rc=1 → unreachable
        ok = rs.fetch_host_usage(HOST, self.state_dir, ft)
        self.assertFalse(ok)
        self.assertEqual(json.loads(stale.read_text()), {"old": "data"},
                         "a failed usage fetch must leave the previous file intact")


# ---------------------------------------------------------------------------
# Config host removal cleans up entries
# ---------------------------------------------------------------------------

class TestConfigHostRemoval(TempEnvMixin, unittest.TestCase):
    def test_removed_host_entries_pruned(self):
        self.write_state({
            "gone::s1": {"host": "gone", "remote_id": "s1", "enabled": False},
            "keep::s2": {"host": "keep", "remote_id": "s2", "enabled": True},
            "local-uuid": {"kind": "cli", "status": "active"},  # no host → untouched
        })
        rs._prune_removed_hosts(self.state_dir, {"keep"})
        state = self.read_state()
        self.assertNotIn("gone::s1", state, "entries of a config-removed host are dropped")
        self.assertIn("keep::s2", state)
        self.assertIn("local-uuid", state)

    def test_no_removal_no_write_churn(self):
        self.write_state({"keep::s2": {"host": "keep", "remote_id": "s2"}})
        rs._prune_removed_hosts(self.state_dir, {"keep"})
        self.assertIn("keep::s2", self.read_state())


# ---------------------------------------------------------------------------
# has_enabled_hosts gate (drives whether main() starts the thread)
# ---------------------------------------------------------------------------

class TestHasEnabledHosts(TempEnvMixin, unittest.TestCase):
    def _write_config(self, cfg):
        (self.state_dir / "config.json").write_text(json.dumps(cfg))

    def test_no_config_means_false(self):
        self.assertFalse(rs.has_enabled_hosts(self.state_dir))

    def test_enabled_host_true(self):
        self._write_config({"remote_hosts": [
            {"name": "devbox", "ssh": "sam@devbox", "enabled": True}
        ]})
        self.assertTrue(rs.has_enabled_hosts(self.state_dir))

    def test_only_disabled_host_false(self):
        self._write_config({"remote_hosts": [
            {"name": "devbox", "ssh": "sam@devbox", "enabled": False}
        ]})
        self.assertFalse(rs.has_enabled_hosts(self.state_dir))


if __name__ == "__main__":
    unittest.main()
