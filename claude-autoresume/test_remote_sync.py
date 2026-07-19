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
import os
import re
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

import autoresume as ar
import remote_sync as rs

REPO_DIR = Path(__file__).resolve().parent


# ---------------------------------------------------------------------------
# Fake ssh transport
# ---------------------------------------------------------------------------

class FakeTransport:
    """Records calls and returns canned (rc, stdout, stderr) responses keyed by
    remote_ctl subcommand. Distinguishes `dump`, `dump --usage`, and
    `apply-toggles` by inspecting remote_argv."""

    def __init__(self, dump=None, usage=None, apply_ok=True, raise_on=None,
                 apply_config_ok=True):
        self._dump = dump                # dict for `dump` → serialized to stdout
        self._usage = usage              # dict for `dump --usage`
        self._apply_ok = apply_ok        # bool | (rc, body) for apply-toggles
        self._raise_on = raise_on or set()  # subcommands that raise (unreachable)
        # bool | (rc, stdout, stderr) for apply-config. "old_remote" simulates
        # a deployed remote_ctl predating the command (rc 2, unknown command).
        self._apply_config_ok = apply_config_ok
        self.calls = []                  # list of (kind, ssh_target, stdin_data)

    def _kind(self, remote_argv):
        # remote_argv is now a one-element list holding the composed remote
        # shell command line — substring-match rather than membership.
        joined = " ".join(remote_argv)
        if "apply-config" in joined:
            return "apply_config"
        if "apply-toggles" in joined:
            return "apply"
        if "--usage" in joined:
            return "usage"
        return "dump"

    def __call__(self, ssh_target, remote_argv, stdin_data=None, timeout=15):
        kind = self._kind(remote_argv)
        self.calls.append((kind, ssh_target, stdin_data))
        if kind in self._raise_on:
            raise TimeoutError(f"fake ssh timeout on {kind}")
        if kind == "apply_config":
            if self._apply_config_ok is True:
                return 0, json.dumps({"ok": True}), ""
            if self._apply_config_ok == "old_remote":
                return 2, "", "unknown command: apply-config"
            return self._apply_config_ok  # explicit (rc, stdout, stderr) tuple
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


def dump_payload(now, state, retention=None):
    """A remote_ctl dump body. `retention=None` reproduces an OLD remote_ctl
    (no retention_minutes field); pass a number for a current one."""
    out = {"v": 1, "now": now, "state": state}
    if retention is not None:
        out["retention_minutes"] = retention
    return out


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
        # Retention-relay failure memo is module-level (once-per-config-change
        # semantics) — reset so tests can't leak state into each other.
        rs._RETENTION_PUSH_FAILED.clear()

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


# ---------------------------------------------------------------------------
# Remote command composition (M3): single quoted shell line, tilde + spaces +
# custom state_dir all handled
# ---------------------------------------------------------------------------

class TestRemoteCommandComposition(unittest.TestCase):
    def test_default_state_dir_tilde_resolved_to_home(self):
        cmd_list = rs._remote_ctl_command(HOST, "dump")
        self.assertEqual(len(cmd_list), 1, "must be ONE ssh argument")
        cmd = cmd_list[0]
        self.assertIn('AUTORESUME_STATE_DIR="$HOME/.claude-autoresume"', cmd)
        self.assertIn('"$HOME/.claude-autoresume/bin/remote_ctl.py"', cmd)
        self.assertTrue(cmd.endswith(" dump"))
        self.assertNotIn("~", cmd, "leading ~/ must be rewritten to $HOME/")

    def test_usage_flag_appended(self):
        cmd = rs._remote_ctl_command(HOST, "dump", "--usage")[0]
        self.assertTrue(cmd.endswith(" dump --usage"))

    def test_custom_state_dir_with_spaces_is_quoted(self):
        host = dict(HOST, state_dir="/opt/my daemon/state", python="/usr/bin/python3")
        cmd = rs._remote_ctl_command(host, "apply-toggles")[0]
        # Double-quoted so the space survives the remote shell's word-splitting.
        self.assertIn('AUTORESUME_STATE_DIR="/opt/my daemon/state"', cmd)
        self.assertIn('"/opt/my daemon/state/bin/remote_ctl.py"', cmd)
        self.assertIn('"/usr/bin/python3"', cmd)
        self.assertIn("apply-toggles", cmd)

    def test_python_with_spaces_is_quoted(self):
        host = dict(HOST, python="/home/user/py venv/bin/python")
        cmd = rs._remote_ctl_command(host, "dump")[0]
        self.assertIn('"/home/user/py venv/bin/python"', cmd)

    def test_resolve_state_dir_forms(self):
        self.assertEqual(rs._resolve_state_dir("~"), "$HOME")
        self.assertEqual(rs._resolve_state_dir("~/x"), "$HOME/x")
        self.assertEqual(rs._resolve_state_dir("/abs/path"), "/abs/path")
        self.assertEqual(rs._resolve_state_dir("$HOME/y"), "$HOME/y")

    def test_custom_state_dir_reaches_transport_as_single_arg(self):
        host = dict(HOST, state_dir="~/alt-state")
        captured = {}

        def transport(ssh_target, remote_argv, stdin_data=None, timeout=15):
            captured["argv"] = remote_argv
            return 1, "", "unreachable"  # short-circuit; we only inspect argv

        rs.fetch_dump(host, transport)
        self.assertEqual(len(captured["argv"]), 1)
        self.assertIn('AUTORESUME_STATE_DIR="$HOME/alt-state"', captured["argv"][0])


# ---------------------------------------------------------------------------
# _prune_removed_hosts return value (drives the worker's idle early-out)
# ---------------------------------------------------------------------------

class TestPruneReturnsRemaining(TempEnvMixin, unittest.TestCase):
    def test_returns_true_when_host_entries_remain(self):
        self.write_state({"keep::s1": {"host": "keep", "remote_id": "s1"}})
        self.assertTrue(rs._prune_removed_hosts(self.state_dir, {"keep"}))

    def test_returns_false_when_none_remain(self):
        self.write_state({
            "gone::s1": {"host": "gone", "remote_id": "s1"},
            "local-uuid": {"kind": "cli", "status": "active"},  # not a host entry
        })
        # host "gone" not in the (empty) configured set → pruned; only the
        # non-host local entry remains ⇒ no host entries left.
        self.assertFalse(rs._prune_removed_hosts(self.state_dir, set()))


# ---------------------------------------------------------------------------
# Worker tick: idle early-out never takes the lock; scheduler eviction
# ---------------------------------------------------------------------------

class _CountingLock:
    """Drop-in for ar.StateLock that counts acquisitions."""
    count = 0

    def __enter__(self):
        type(self).count += 1
        return self

    def __exit__(self, *exc):
        return False


class TestWorkerTick(TempEnvMixin, unittest.TestCase):
    def _write_config(self, cfg):
        (self.state_dir / "config.json").write_text(json.dumps(cfg))

    def setUp(self):
        super().setUp()
        self._real_lock = ar.StateLock
        _CountingLock.count = 0
        ar.StateLock = _CountingLock

    def tearDown(self):
        ar.StateLock = self._real_lock
        super().tearDown()

    def test_idle_early_out_takes_no_lock(self):
        # No config (no hosts) and we tell the loop nothing is believed present.
        loop = rs._RemoteSyncLoop(self.state_dir, FakeTransport())
        loop.believe_host_entries = False
        did_work = loop.tick(now_fn=lambda: 1000.0)
        self.assertFalse(did_work, "no hosts + nothing believed ⇒ early-out")
        self.assertEqual(_CountingLock.count, 0,
                         "idle early-out must never acquire StateLock")

    def test_first_tick_cleans_leftovers_then_goes_idle(self):
        # A leftover host:: entry from a removed-hosts config, no config file.
        with self._real_lock():
            ar.save_state({"gone::s1": {"host": "gone", "remote_id": "s1"}})
        loop = rs._RemoteSyncLoop(self.state_dir, FakeTransport())
        self.assertTrue(loop.believe_host_entries, "starts believing → forces a check")
        did_work = loop.tick(now_fn=lambda: 1000.0)
        self.assertTrue(did_work, "first tick must run to clean leftovers")
        self.assertGreaterEqual(_CountingLock.count, 1)
        with self._real_lock():
            self.assertNotIn("gone::s1", ar.load_state())
        # Now nothing is believed present; next tick early-outs without a lock.
        self.assertFalse(loop.believe_host_entries)
        before = _CountingLock.count
        self.assertFalse(loop.tick(now_fn=lambda: 1000.0))
        self.assertEqual(_CountingLock.count, before,
                         "second tick early-outs, no further lock")

    def test_configured_host_is_serviced_and_tracked(self):
        self._write_config({"remote_hosts": [
            {"name": "devbox", "ssh": "sam@devbox", "enabled": True,
             "poll_seconds": 30, "collect_usage": False}
        ]})
        dump = dump_payload(1000.0, {"s1": remote_entry()})
        loop = rs._RemoteSyncLoop(self.state_dir, FakeTransport(dump=dump))
        self.assertTrue(loop.tick(now_fn=lambda: 1000.0))
        with self._real_lock():
            self.assertIn("devbox::s1", ar.load_state())
        self.assertTrue(loop.believe_host_entries)

    def test_scheduler_dicts_evict_removed_hosts(self):
        loop = rs._RemoteSyncLoop(self.state_dir, FakeTransport())
        # Simulate stale schedule entries for a host no longer configured.
        loop.next_poll = {"devbox": 5.0, "gone": 5.0}
        loop.next_usage = {"gone": 5.0}
        # Config lists only devbox.
        self._write_config({"remote_hosts": [
            {"name": "devbox", "ssh": "sam@devbox", "enabled": False}
        ]})
        loop.tick(now_fn=lambda: 1000.0)
        self.assertIn("devbox", loop.next_poll, "still-configured host kept")
        self.assertNotIn("gone", loop.next_poll, "removed host evicted from next_poll")
        self.assertNotIn("gone", loop.next_usage, "removed host evicted from next_usage")


class TestDeployPayloadImports(unittest.TestCase):
    """Finding 1 (empirical): the exact PAYLOAD_FILES set deploy_remote.sh ships
    must be self-sufficient for `import autoresume` on a bare remote — nothing
    else is on the remote's sys.path. autoresume.py imports remote_sync at
    module top, so a payload omitting it crash-loops the remote daemon at import
    before main(). We stage EXACTLY the deploy payload into a throwaway bin/ and
    confirm the import there; we also confirm the pre-fix set (no remote_sync.py)
    DID fail, so this test is meaningful, not vacuously green."""

    def _parse_payload_files(self):
        """Read the PAYLOAD_FILES=(...) array straight out of deploy_remote.sh so
        the test tracks the real deploy list rather than a hardcoded copy."""
        text = (REPO_DIR / "deploy_remote.sh").read_text()
        m = re.search(r"^PAYLOAD_FILES=\(([^)]*)\)", text, re.MULTILINE)
        self.assertIsNotNone(m, "could not find PAYLOAD_FILES=(...) in deploy_remote.sh")
        return m.group(1).split()

    def _stage_and_import(self, files):
        """Copy `files` into a temp bin/ (isolated from repo sys.path) and try
        `import autoresume` under system python3. Returns (returncode, stderr)."""
        tmp = Path(tempfile.mkdtemp())
        try:
            bin_dir = tmp / "bin"
            bin_dir.mkdir()
            for f in files:
                src = REPO_DIR / f
                self.assertTrue(src.is_file(), f"payload file missing in repo: {f}")
                shutil.copy(src, bin_dir / f)
            # Empty PYTHONPATH + cwd=bin_dir so ONLY the staged files resolve —
            # mirrors the remote where nothing but bin/ is importable.
            env = dict(os.environ)
            env["PYTHONPATH"] = ""
            env["AUTORESUME_REMOTE"] = "1"
            proc = subprocess.run(
                [sys.executable, "-c", "import autoresume"],
                cwd=str(bin_dir), env=env,
                capture_output=True, text=True, timeout=30,
            )
            return proc.returncode, proc.stderr
        finally:
            shutil.rmtree(tmp, ignore_errors=True)

    def test_deploy_payload_includes_remote_sync(self):
        self.assertIn("remote_sync.py", self._parse_payload_files(),
                      "deploy_remote.sh PAYLOAD_FILES must ship remote_sync.py "
                      "(autoresume.py imports it at module top)")

    def test_full_payload_imports_cleanly(self):
        rc, err = self._stage_and_import(self._parse_payload_files())
        self.assertEqual(rc, 0, f"import autoresume failed under deploy payload:\n{err}")

    def test_payload_without_remote_sync_fails(self):
        # The pre-fix set: prove omitting remote_sync.py genuinely breaks import,
        # so the positive test above is not vacuous.
        reduced = [f for f in self._parse_payload_files() if f != "remote_sync.py"]
        rc, err = self._stage_and_import(reduced)
        self.assertNotEqual(rc, 0, "import unexpectedly succeeded without remote_sync.py")
        self.assertIn("remote_sync", err,
                      f"expected a ModuleNotFoundError for remote_sync, got:\n{err}")


# ---------------------------------------------------------------------------
# Retention relay: Mac's sessions.idle_retention_minutes pushed to remotes
# ---------------------------------------------------------------------------

class TestRetentionRelay(TempEnvMixin, unittest.TestCase):
    """Feature: after a successful dump+merge, if the dump's reported
    retention_minutes differs from the Mac's configured
    sessions.idle_retention_minutes, remote_sync pushes apply-config —
    idempotent convergence like the toggle relay."""

    def _write_mac_config(self, retention):
        (self.state_dir / "config.json").write_text(json.dumps(
            {"version": 1, "sessions": {"idle_retention_minutes": retention}}))

    def _daemon_log(self):
        try:
            return (self.state_dir / "daemon.log").read_text()
        except OSError:
            return ""

    def test_differing_retention_pushes_apply_config(self):
        self._write_mac_config(10)
        dump = dump_payload(1000.0, {"s1": remote_entry()}, retention=30)
        ft = FakeTransport(dump=dump)
        rs.sync_host(HOST, self.state_dir, ft, now_fn=lambda: 1000.0)

        pushes = [c for c in ft.calls if c[0] == "apply_config"]
        self.assertEqual(len(pushes), 1, "differing retention must be pushed")
        self.assertEqual(json.loads(pushes[0][2]),
                         {"sessions": {"idle_retention_minutes": 10}},
                         "payload carries ONLY the retention key")

    def test_equal_retention_no_push(self):
        self._write_mac_config(10)
        dump = dump_payload(1000.0, {"s1": remote_entry()}, retention=10)
        ft = FakeTransport(dump=dump)
        rs.sync_host(HOST, self.state_dir, ft, now_fn=lambda: 1000.0)
        self.assertEqual([c for c in ft.calls if c[0] == "apply_config"], [])

    def test_default_config_matches_default_remote_no_push(self):
        # No Mac config at all (default 30) vs remote reporting 30.
        dump = dump_payload(1000.0, {"s1": remote_entry()}, retention=30)
        ft = FakeTransport(dump=dump)
        rs.sync_host(HOST, self.state_dir, ft, now_fn=lambda: 1000.0)
        self.assertEqual([c for c in ft.calls if c[0] == "apply_config"], [])

    def test_convergence_next_cycle_no_repush(self):
        # Cycle 1 pushes; cycle 2's dump reflects the applied value -> silent.
        self._write_mac_config(10)
        ft = FakeTransport(dump=dump_payload(1000.0, {"s1": remote_entry()}, retention=30))
        rs.sync_host(HOST, self.state_dir, ft, now_fn=lambda: 1000.0)
        ft2 = FakeTransport(dump=dump_payload(1100.0, {"s1": remote_entry()}, retention=10))
        rs.sync_host(HOST, self.state_dir, ft2, now_fn=lambda: 1100.0)
        self.assertEqual(len([c for c in ft.calls if c[0] == "apply_config"]), 1)
        self.assertEqual([c for c in ft2.calls if c[0] == "apply_config"], [])

    def test_old_remote_dump_without_retention_no_push_one_hint(self):
        # An old remote_ctl reports no retention_minutes at all: nothing to
        # compare, no push attempt, ONE redeploy hint per host per config
        # value — not one per cycle.
        self._write_mac_config(10)
        dump = dump_payload(1000.0, {"s1": remote_entry()})  # no retention field
        for t in (1000.0, 1030.0, 1060.0):
            ft = FakeTransport(dump=dump)
            rs.sync_host(HOST, self.state_dir, ft, now_fn=lambda t=t: t)
            self.assertEqual([c for c in ft.calls if c[0] == "apply_config"], [])
        self.assertEqual(self._daemon_log().count("old remote_ctl"), 1,
                         "redeploy hint logged exactly once, not per cycle")

    def test_old_remote_apply_config_failure_no_retry_spam(self):
        # Remote reports a retention (differing) but its remote_ctl predates
        # apply-config: the push fails rc=2 once; subsequent cycles must not
        # retry while the Mac's value is unchanged.
        self._write_mac_config(10)
        dump = dump_payload(1000.0, {"s1": remote_entry()}, retention=30)
        ft = FakeTransport(dump=dump, apply_config_ok="old_remote")
        rs.sync_host(HOST, self.state_dir, ft, now_fn=lambda: 1000.0)
        rs.sync_host(HOST, self.state_dir, ft, now_fn=lambda: 1030.0)
        rs.sync_host(HOST, self.state_dir, ft, now_fn=lambda: 1060.0)
        self.assertEqual(len([c for c in ft.calls if c[0] == "apply_config"]), 1,
                         "failed push must not be retried for the same value")
        self.assertEqual(self._daemon_log().count("redeploy to update"), 1)
        # ...and the merge itself still worked (sync degraded gracefully).
        self.assertIn("devbox::s1", self.read_state())

    def test_retention_change_after_failure_retries_once(self):
        self._write_mac_config(10)
        dump = dump_payload(1000.0, {"s1": remote_entry()}, retention=30)
        ft = FakeTransport(dump=dump, apply_config_ok="old_remote")
        rs.sync_host(HOST, self.state_dir, ft, now_fn=lambda: 1000.0)
        self.assertEqual(len([c for c in ft.calls if c[0] == "apply_config"]), 1)
        # The user changes the Mac's retention: one fresh attempt is allowed.
        self._write_mac_config(20)
        rs.sync_host(HOST, self.state_dir, ft, now_fn=lambda: 1030.0)
        self.assertEqual(len([c for c in ft.calls if c[0] == "apply_config"]), 2)

    def test_redeploy_clears_no_field_memo_and_pushes(self):
        # Round-2 audit MINOR: the memo keyed on the Mac value alone, so after
        # the redeploy its own hint requested, nothing pushed until the value
        # changed or the daemon restarted. A dump that DOES carry
        # retention_minutes must clear the "no_field" memo and push same-cycle.
        self._write_mac_config(10)
        ft = FakeTransport(dump=dump_payload(1000.0, {"s1": remote_entry()}))  # old remote_ctl
        rs.sync_host(HOST, self.state_dir, ft, now_fn=lambda: 1000.0)
        self.assertEqual([c for c in ft.calls if c[0] == "apply_config"], [])
        self.assertEqual(self._daemon_log().count("old remote_ctl"), 1)
        # user redeploys; the new remote_ctl reports its local default 30
        ft2 = FakeTransport(dump=dump_payload(1030.0, {"s1": remote_entry()}, retention=30))
        rs.sync_host(HOST, self.state_dir, ft2, now_fn=lambda: 1030.0)
        self.assertEqual(len([c for c in ft2.calls if c[0] == "apply_config"]), 1,
                         "redeployed remote must converge without a config change")
        self.assertEqual(json.loads([c for c in ft2.calls
                                     if c[0] == "apply_config"][0][2]),
                         {"sessions": {"idle_retention_minutes": 10}})

    def test_failed_push_retries_after_an_hour(self):
        # Round-2 audit MINOR: a transient apply-config failure blocked all
        # retries while the Mac value was unchanged. Failure memos now age:
        # retry after RETENTION_PUSH_RETRY_SECONDS (~1h).
        self._write_mac_config(10)
        dump = {"s1": remote_entry()}
        ft_fail = FakeTransport(dump=dump_payload(1000.0, dump, retention=30),
                                apply_config_ok=(255, "", "ssh: connection reset"))
        rs.sync_host(HOST, self.state_dir, ft_fail, now_fn=lambda: 1000.0)
        self.assertEqual(len([c for c in ft_fail.calls if c[0] == "apply_config"]), 1)
        # 30s later: memo young, same value -> no retry (no per-cycle spam)
        ft_soon = FakeTransport(dump=dump_payload(1030.0, dump, retention=30))
        rs.sync_host(HOST, self.state_dir, ft_soon, now_fn=lambda: 1030.0)
        self.assertEqual([c for c in ft_soon.calls if c[0] == "apply_config"], [])
        # >1h later: memo aged out -> one fresh attempt, which converges
        later = 1000.0 + rs.RETENTION_PUSH_RETRY_SECONDS + 1
        ft_late = FakeTransport(dump=dump_payload(later, dump, retention=30))
        rs.sync_host(HOST, self.state_dir, ft_late, now_fn=lambda: later)
        self.assertEqual(len([c for c in ft_late.calls if c[0] == "apply_config"]), 1,
                         "aged failure memo must allow a retry")
        self.assertNotIn(HOST["name"], rs._RETENTION_PUSH_FAILED,
                         "successful retry clears the memo")

    def test_push_happens_even_with_no_toggle_delta(self):
        # The relay must not be starved by the `if not payload: return True`
        # toggle early-out: no toggle divergence, retention differs -> push.
        self.write_state({
            "devbox::s1": {"host": "devbox", "remote_id": "s1",
                           "enabled": False, "resume_armed": False, "force_resume": False}
        })
        self._write_mac_config(10)
        dump = dump_payload(1000.0, {"s1": remote_entry()}, retention=30)
        ft = FakeTransport(dump=dump)
        rs.sync_host(HOST, self.state_dir, ft, now_fn=lambda: 1000.0)
        self.assertEqual(len([c for c in ft.calls if c[0] == "apply_config"]), 1)
        self.assertEqual([c for c in ft.calls if c[0] == "apply"], [],
                         "no toggle delta expected")


# ---------------------------------------------------------------------------
# remote_ctl apply-config / dump retention_minutes — direct, against a tmp dir
# ---------------------------------------------------------------------------

class TestRemoteCtlApplyConfig(unittest.TestCase):
    """Drives the real remote_ctl.py as a subprocess (the same way ssh does)
    against a temp AUTORESUME_STATE_DIR."""

    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.state_dir = Path(self._tmp.name)
        self.env = {**os.environ, "AUTORESUME_STATE_DIR": str(self.state_dir)}

    def tearDown(self):
        self._tmp.cleanup()

    def _run(self, args, stdin=""):
        return subprocess.run(
            [sys.executable, str(REPO_DIR / "remote_ctl.py"), *args],
            input=stdin, env=self.env, capture_output=True, text=True, timeout=30)

    def _apply(self, retention):
        return self._run(["apply-config"],
                         json.dumps({"sessions": {"idle_retention_minutes": retention}}))

    def test_creates_config_when_absent(self):
        proc = self._apply(15)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual(json.loads(proc.stdout), {"ok": True})
        cfg = json.loads((self.state_dir / "config.json").read_text())
        self.assertEqual(cfg, {"sessions": {"idle_retention_minutes": 15}})

    def test_merge_preserves_unknown_keys(self):
        (self.state_dir / "config.json").write_text(json.dumps({
            "version": 1,
            "account": {"type": "max", "plan": "max_20x"},
            "custom_top_level": {"x": [1, 2]},
            "sessions": {"idle_retention_minutes": 30, "future_knob": "keep-me"},
        }))
        proc = self._apply(45)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        cfg = json.loads((self.state_dir / "config.json").read_text())
        self.assertEqual(cfg["sessions"]["idle_retention_minutes"], 45)
        self.assertEqual(cfg["sessions"]["future_knob"], "keep-me",
                         "sibling keys inside sessions preserved")
        self.assertEqual(cfg["account"], {"type": "max", "plan": "max_20x"})
        self.assertEqual(cfg["custom_top_level"], {"x": [1, 2]})
        self.assertEqual(cfg["version"], 1)

    def test_bad_payload_rejected(self):
        for bad in ("not json", json.dumps({"sessions": {}}),
                    json.dumps({"sessions": {"idle_retention_minutes": "soon"}}),
                    json.dumps({"sessions": {"idle_retention_minutes": True}}),
                    json.dumps([1, 2])):
            proc = self._run(["apply-config"], bad)
            self.assertEqual(proc.returncode, 1, f"payload {bad!r} must be rejected")
            self.assertFalse(json.loads(proc.stdout)["ok"])
        self.assertFalse((self.state_dir / "config.json").exists(),
                         "rejected payloads must not create/write config.json")

    def test_dump_reports_effective_retention(self):
        # No config -> autoresume_config-style default (30).
        proc = self._run(["dump"])
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual(json.loads(proc.stdout)["retention_minutes"], 30)
        # After an apply-config, dump reflects the pushed value.
        self._apply(45)
        proc = self._run(["dump"])
        self.assertEqual(json.loads(proc.stdout)["retention_minutes"], 45)

    def test_dump_clamps_out_of_range_retention(self):
        (self.state_dir / "config.json").write_text(
            json.dumps({"sessions": {"idle_retention_minutes": 1}}))
        proc = self._run(["dump"])
        self.assertEqual(json.loads(proc.stdout)["retention_minutes"], 5,
                         "effective value is clamped like autoresume_config")


if __name__ == "__main__":
    unittest.main()
