#!/usr/bin/env python3
"""
Unit tests for usage_collector.py. Stdlib unittest only (no pip deps, to
match the module's own SYSTEM python3 constraint). Run with:

    python3 -m unittest test_usage_collector -v

All timestamps are injected via the `now=` parameters on collect()/compact()
so nothing here depends on wall-clock time.
"""

from __future__ import annotations

import json
import os
import tempfile
import unittest
from pathlib import Path

import usage_collector as uc

BASE_EPOCH = 1_800_000_000.0  # arbitrary fixed "now" for deterministic tests


def _write_jsonl(path: Path, rows: list[dict], mtime: float | None = None) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with open(path, "w") as f:
        for row in rows:
            f.write(json.dumps(row) + "\n")
    if mtime is not None:
        os.utime(path, (mtime, mtime))


def _append_jsonl(path: Path, rows: list[dict], mtime: float | None = None) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with open(path, "a") as f:
        for row in rows:
            f.write(json.dumps(row) + "\n")
    if mtime is not None:
        os.utime(path, (mtime, mtime))


def _assistant_event(msg_id: str, request_id: str | None, model: str, ts: str,
                      input_tokens=0, output_tokens=0, cache_write=0, cache_read=0,
                      web_searches=0, request_id_field="requestId") -> dict:
    usage = {
        "input_tokens": input_tokens,
        "output_tokens": output_tokens,
        "cache_creation_input_tokens": cache_write,
        "cache_read_input_tokens": cache_read,
        "server_tool_use": {"web_search_requests": web_searches, "web_fetch_requests": 0},
    }
    event = {
        "type": "assistant",
        "message": {"id": msg_id, "model": model, "usage": usage},
        "timestamp": ts,
    }
    if request_id is not None:
        event[request_id_field] = request_id
    return event


class TempStateMixin:
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.tmp = Path(self._tmp.name)
        self.state_dir = self.tmp / "state"
        self.projects_dir = self.tmp / "projects"
        self.cowork_dir = self.tmp / "cowork"
        self.state_dir.mkdir()
        self.projects_dir.mkdir()
        self.cowork_dir.mkdir()

    def tearDown(self):
        self._tmp.cleanup()


class TestDedupe(TempStateMixin, unittest.TestCase):
    def test_repeated_content_blocks_counted_once(self):
        """The real-world case this module exists to handle: the same
        message.id + requestId repeated across multiple consecutive
        'assistant' lines (one per streamed content block) must only be
        counted once."""
        session = self.projects_dir / "proj1" / "sess1.jsonl"
        rows = [
            _assistant_event("msg_A", "req_A", "claude-sonnet-5",
                              "2026-07-18T14:00:00.000Z", input_tokens=10, output_tokens=5),
            _assistant_event("msg_A", "req_A", "claude-sonnet-5",
                              "2026-07-18T14:00:00.500Z", input_tokens=10, output_tokens=5),
            _assistant_event("msg_A", "req_A", "claude-sonnet-5",
                              "2026-07-18T14:00:01.000Z", input_tokens=10, output_tokens=5),
        ]
        _write_jsonl(session, rows)

        uc.collect(self.state_dir, now=BASE_EPOCH, projects_dir=self.projects_dir,
                   cowork_dir=self.cowork_dir, quiet=True)

        store = uc.load_store(self.state_dir)
        bucket = store["hours"]["2026-07-18T14"][uc.SOURCE_CODE_CLI]["claude-sonnet-5"]
        self.assertEqual(bucket["input"], 10)
        self.assertEqual(bucket["output"], 5)
        self.assertEqual(bucket["messages"], 1)

    def test_message_id_alone_when_request_id_absent(self):
        session = self.projects_dir / "proj1" / "sess2.jsonl"
        rows = [
            _assistant_event("msg_B", None, "claude-sonnet-5", "2026-07-18T14:00:00.000Z",
                              input_tokens=7, output_tokens=3),
            _assistant_event("msg_B", None, "claude-sonnet-5", "2026-07-18T14:00:00.100Z",
                              input_tokens=7, output_tokens=3),
        ]
        _write_jsonl(session, rows)

        uc.collect(self.state_dir, now=BASE_EPOCH, projects_dir=self.projects_dir,
                   cowork_dir=self.cowork_dir, quiet=True)

        store = uc.load_store(self.state_dir)
        bucket = store["hours"]["2026-07-18T14"][uc.SOURCE_CODE_CLI]["claude-sonnet-5"]
        self.assertEqual(bucket["input"], 7)
        self.assertEqual(bucket["messages"], 1)

    def test_different_request_ids_same_message_id_not_deduped(self):
        """A genuine retry can reuse a message id with a new requestId --
        that should count as a second message, not a duplicate."""
        session = self.projects_dir / "proj1" / "sess3.jsonl"
        rows = [
            _assistant_event("msg_C", "req_1", "claude-sonnet-5", "2026-07-18T14:00:00.000Z",
                              input_tokens=1, output_tokens=1),
            _assistant_event("msg_C", "req_2", "claude-sonnet-5", "2026-07-18T14:00:05.000Z",
                              input_tokens=1, output_tokens=1),
        ]
        _write_jsonl(session, rows)

        uc.collect(self.state_dir, now=BASE_EPOCH, projects_dir=self.projects_dir,
                   cowork_dir=self.cowork_dir, quiet=True)

        store = uc.load_store(self.state_dir)
        bucket = store["hours"]["2026-07-18T14"][uc.SOURCE_CODE_CLI]["claude-sonnet-5"]
        self.assertEqual(bucket["messages"], 2)

    def test_cowork_snake_case_request_id_and_missing_server_tool_use(self):
        audit = self.cowork_dir / "proj" / "sess" / "local_x" / "audit.jsonl"
        event = _assistant_event("msg_D", "req_D", "claude-sonnet-5", "2026-07-18T14:00:00.000Z",
                                  input_tokens=4, output_tokens=2, request_id_field="request_id")
        # Cowork usage sometimes omits server_tool_use entirely.
        del event["message"]["usage"]["server_tool_use"]
        _write_jsonl(audit, [event])

        uc.collect(self.state_dir, now=BASE_EPOCH, projects_dir=self.projects_dir,
                   cowork_dir=self.cowork_dir, quiet=True)

        store = uc.load_store(self.state_dir)
        bucket = store["hours"]["2026-07-18T14"][uc.SOURCE_COWORK]["claude-sonnet-5"]
        self.assertEqual(bucket["input"], 4)
        self.assertEqual(bucket["web_searches"], 0)

    def test_cowork_result_rollup_not_double_counted(self):
        """'result' events carry a cumulative usage rollup and must be
        ignored -- only 'assistant' events are counted."""
        audit = self.cowork_dir / "proj" / "sess" / "local_y" / "audit.jsonl"
        rows = [
            _assistant_event("msg_E", "req_E", "claude-sonnet-5", "2026-07-18T14:00:00.000Z",
                              input_tokens=100, output_tokens=50, request_id_field="request_id"),
            {
                "type": "result",
                "session_id": "sess",
                "usage": {"input_tokens": 100, "output_tokens": 50},
            },
        ]
        _write_jsonl(audit, rows)

        uc.collect(self.state_dir, now=BASE_EPOCH, projects_dir=self.projects_dir,
                   cowork_dir=self.cowork_dir, quiet=True)

        store = uc.load_store(self.state_dir)
        bucket = store["hours"]["2026-07-18T14"][uc.SOURCE_COWORK]["claude-sonnet-5"]
        self.assertEqual(bucket["input"], 100)
        self.assertEqual(bucket["messages"], 1)


class TestIncremental(TempStateMixin, unittest.TestCase):
    def test_second_pass_only_counts_new_bytes(self):
        session = self.projects_dir / "proj1" / "sess1.jsonl"
        _write_jsonl(session, [
            _assistant_event("msg_1", "req_1", "claude-sonnet-5", "2026-07-18T14:00:00.000Z",
                              input_tokens=10, output_tokens=5),
        ])

        uc.collect(self.state_dir, now=BASE_EPOCH, projects_dir=self.projects_dir,
                   cowork_dir=self.cowork_dir, quiet=True)

        # Simulate more of the session being appended later.
        _append_jsonl(session, [
            _assistant_event("msg_2", "req_2", "claude-sonnet-5", "2026-07-18T14:05:00.000Z",
                              input_tokens=20, output_tokens=8),
        ])

        uc.collect(self.state_dir, now=BASE_EPOCH + 30, projects_dir=self.projects_dir,
                   cowork_dir=self.cowork_dir, quiet=True)
        # Run again with no new bytes -- must be a true no-op.
        uc.collect(self.state_dir, now=BASE_EPOCH + 60, projects_dir=self.projects_dir,
                   cowork_dir=self.cowork_dir, quiet=True)

        store = uc.load_store(self.state_dir)
        bucket = store["hours"]["2026-07-18T14"][uc.SOURCE_CODE_CLI]["claude-sonnet-5"]
        self.assertEqual(bucket["input"], 30)
        self.assertEqual(bucket["output"], 13)
        self.assertEqual(bucket["messages"], 2)

    def test_duplicate_split_across_two_collect_calls(self):
        """Worst case for the bounded dedupe ledger: the first line of a
        duplicate cluster is on disk (and gets read) before the second
        line is flushed. The second collect() call, reading only the newly
        appended bytes, must still recognize the repeat via the persisted
        seen_ids ledger for this still-hot file."""
        session = self.projects_dir / "proj1" / "sess1.jsonl"
        # mtime pinned to line up with the injected `now` clock below -- the
        # OS sets real wall-clock mtimes on write, which would otherwise be
        # wildly out of sync with a synthetic `now` and make every file look
        # "cold" immediately, defeating the hot-ledger logic under test.
        _write_jsonl(session, [
            _assistant_event("msg_1", "req_1", "claude-sonnet-5", "2026-07-18T14:00:00.000Z",
                              input_tokens=10, output_tokens=5),
        ], mtime=BASE_EPOCH)
        uc.collect(self.state_dir, now=BASE_EPOCH, projects_dir=self.projects_dir,
                   cowork_dir=self.cowork_dir, quiet=True)

        # File is still hot (mtime ~ now) when the duplicate line lands.
        _append_jsonl(session, [
            _assistant_event("msg_1", "req_1", "claude-sonnet-5", "2026-07-18T14:00:00.500Z",
                              input_tokens=10, output_tokens=5),
        ], mtime=BASE_EPOCH + 5)
        uc.collect(self.state_dir, now=BASE_EPOCH + 5, projects_dir=self.projects_dir,
                   cowork_dir=self.cowork_dir, quiet=True)

        store = uc.load_store(self.state_dir)
        bucket = store["hours"]["2026-07-18T14"][uc.SOURCE_CODE_CLI]["claude-sonnet-5"]
        self.assertEqual(bucket["input"], 10)
        self.assertEqual(bucket["messages"], 1)

    def test_seen_ids_dropped_once_file_goes_cold(self):
        session = self.projects_dir / "proj1" / "sess1.jsonl"
        _write_jsonl(session, [
            _assistant_event("msg_1", "req_1", "claude-sonnet-5", "2026-07-18T14:00:00.000Z",
                              input_tokens=10, output_tokens=5),
        ], mtime=BASE_EPOCH)
        uc.collect(self.state_dir, now=BASE_EPOCH, projects_dir=self.projects_dir,
                   cowork_dir=self.cowork_dir, quiet=True)

        # Long after HOT_WINDOW_SECONDS has passed, with no new bytes.
        far_future = BASE_EPOCH + uc.HOT_WINDOW_SECONDS + 3600
        uc.collect(self.state_dir, now=far_future, projects_dir=self.projects_dir,
                   cowork_dir=self.cowork_dir, quiet=True)

        store = uc.load_store(self.state_dir)
        key = str(session)
        self.assertEqual(store["progress"][key]["seen_ids"], [])
        # Offset is still preserved, so a later resume wouldn't replay it.
        self.assertGreater(store["progress"][key]["offset"], 0)

    def test_subagent_transcripts_are_scanned_and_attributed_code_cli(self):
        session = self.projects_dir / "proj1" / "sess1.jsonl"
        subagent = self.projects_dir / "proj1" / "sess1" / "subagents" / "agent-a1.jsonl"
        _write_jsonl(session, [
            _assistant_event("msg_top", "req_top", "claude-sonnet-5", "2026-07-18T14:00:00.000Z",
                              input_tokens=1, output_tokens=1),
        ])
        _write_jsonl(subagent, [
            _assistant_event("msg_sub", "req_sub", "claude-haiku-4-5", "2026-07-18T14:01:00.000Z",
                              input_tokens=50, output_tokens=25),
        ])

        uc.collect(self.state_dir, now=BASE_EPOCH, projects_dir=self.projects_dir,
                   cowork_dir=self.cowork_dir, quiet=True)

        store = uc.load_store(self.state_dir)
        models = store["hours"]["2026-07-18T14"][uc.SOURCE_CODE_CLI]
        self.assertIn("claude-sonnet-5", models)
        self.assertIn("claude-haiku-4-5", models)
        self.assertEqual(models["claude-haiku-4-5"]["input"], 50)

    def test_workflow_nested_subagent_transcripts_are_scanned(self):
        # Workflow-spawned agents nest one level deeper than plain subagents:
        # <session_id>/subagents/workflows/wf_<id>/agent-*.jsonl. A
        # non-recursive glob silently dropped their entire token spend
        # (regression: 2026-07-19, 55 agents / ~$338 API-equivalent missed).
        session = self.projects_dir / "proj1" / "sess1.jsonl"
        wf_agent = (self.projects_dir / "proj1" / "sess1" / "subagents"
                    / "workflows" / "wf_abc123-1" / "agent-a1.jsonl")
        _write_jsonl(session, [
            _assistant_event("msg_top", "req_top", "claude-sonnet-5", "2026-07-18T14:00:00.000Z",
                              input_tokens=1, output_tokens=1),
        ])
        _write_jsonl(wf_agent, [
            _assistant_event("msg_wf", "req_wf", "claude-fable-5", "2026-07-18T14:02:00.000Z",
                              input_tokens=70, output_tokens=35),
        ])

        uc.collect(self.state_dir, now=BASE_EPOCH, projects_dir=self.projects_dir,
                   cowork_dir=self.cowork_dir, quiet=True)

        store = uc.load_store(self.state_dir)
        models = store["hours"]["2026-07-18T14"][uc.SOURCE_CODE_CLI]
        self.assertIn("claude-fable-5", models)
        self.assertEqual(models["claude-fable-5"]["input"], 70)
        self.assertEqual(models["claude-fable-5"]["output"], 35)

    def test_malformed_lines_skipped_not_fatal(self):
        session = self.projects_dir / "proj1" / "sess1.jsonl"
        session.parent.mkdir(parents=True, exist_ok=True)
        with open(session, "w") as f:
            f.write("{not valid json\n")
            f.write(json.dumps(_assistant_event(
                "msg_ok", "req_ok", "claude-sonnet-5", "2026-07-18T14:00:00.000Z",
                input_tokens=3, output_tokens=1)) + "\n")

        uc.collect(self.state_dir, now=BASE_EPOCH, projects_dir=self.projects_dir,
                   cowork_dir=self.cowork_dir, quiet=True)

        store = uc.load_store(self.state_dir)
        bucket = store["hours"]["2026-07-18T14"][uc.SOURCE_CODE_CLI]["claude-sonnet-5"]
        self.assertEqual(bucket["input"], 3)

    def test_non_assistant_events_ignored(self):
        session = self.projects_dir / "proj1" / "sess1.jsonl"
        _write_jsonl(session, [
            {"type": "user", "message": {"content": "hi"}},
            {"type": "system", "subtype": "init"},
            _assistant_event("msg_1", "req_1", "claude-sonnet-5", "2026-07-18T14:00:00.000Z",
                              input_tokens=1, output_tokens=1),
        ])
        uc.collect(self.state_dir, now=BASE_EPOCH, projects_dir=self.projects_dir,
                   cowork_dir=self.cowork_dir, quiet=True)
        store = uc.load_store(self.state_dir)
        total_messages = sum(
            m["messages"]
            for sources in store["hours"].values()
            for models in sources.values()
            for m in models.values()
        )
        self.assertEqual(total_messages, 1)

    def test_synthetic_rate_limit_notice_not_counted_as_a_message(self):
        """Real-world discovery: Claude Code locally synthesizes an
        'assistant' line to show a rate-limit notice inline in the
        transcript (model: '<synthetic>', all-zero usage, marked
        isApiErrorMessage: true). It never touched a real model and must
        not inflate the message count."""
        session = self.projects_dir / "proj1" / "sess1.jsonl"
        synthetic_row = {
            "type": "assistant",
            "timestamp": "2026-07-18T14:00:00.000Z",
            "message": {
                "id": "e2878aa2-3d8f-47b2-805d-52ec16bee972",
                "model": "<synthetic>",
                "usage": {
                    "input_tokens": 0, "output_tokens": 0,
                    "cache_creation_input_tokens": 0, "cache_read_input_tokens": 0,
                },
                "content": [{"type": "text", "text": "You've hit your session limit"}],
            },
            "requestId": "req_synthetic",
            "error": "rate_limit",
            "isApiErrorMessage": True,
        }
        real_row = _assistant_event("msg_real", "req_real", "claude-sonnet-5",
                                     "2026-07-18T14:01:00.000Z", input_tokens=5, output_tokens=2)
        _write_jsonl(session, [synthetic_row, real_row])

        uc.collect(self.state_dir, now=BASE_EPOCH, projects_dir=self.projects_dir,
                   cowork_dir=self.cowork_dir, quiet=True)

        store = uc.load_store(self.state_dir)
        models = store["hours"]["2026-07-18T14"][uc.SOURCE_CODE_CLI]
        self.assertNotIn("<synthetic>", models)
        self.assertEqual(models["claude-sonnet-5"]["messages"], 1)

    def test_pruned_transcript_file_progress_dropped(self):
        session = self.projects_dir / "proj1" / "sess1.jsonl"
        _write_jsonl(session, [
            _assistant_event("msg_1", "req_1", "claude-sonnet-5", "2026-07-18T14:00:00.000Z",
                              input_tokens=1, output_tokens=1),
        ])
        uc.collect(self.state_dir, now=BASE_EPOCH, projects_dir=self.projects_dir,
                   cowork_dir=self.cowork_dir, quiet=True)
        store = uc.load_store(self.state_dir)
        self.assertIn(str(session), store["progress"])

        os.remove(session)
        uc.collect(self.state_dir, now=BASE_EPOCH + 10, projects_dir=self.projects_dir,
                   cowork_dir=self.cowork_dir, quiet=True)
        store = uc.load_store(self.state_dir)
        self.assertNotIn(str(session), store["progress"])
        # But the already-collected totals must survive the pruning.
        bucket = store["hours"]["2026-07-18T14"][uc.SOURCE_CODE_CLI]["claude-sonnet-5"]
        self.assertEqual(bucket["input"], 1)

    def test_file_shrink_does_not_crash_and_rescans(self):
        session = self.projects_dir / "proj1" / "sess1.jsonl"
        _write_jsonl(session, [
            _assistant_event("msg_1", "req_1", "claude-sonnet-5", "2026-07-18T14:00:00.000Z",
                              input_tokens=100, output_tokens=1),
            _assistant_event("msg_2", "req_2", "claude-sonnet-5", "2026-07-18T14:00:01.000Z",
                              input_tokens=100, output_tokens=1),
        ])
        uc.collect(self.state_dir, now=BASE_EPOCH, projects_dir=self.projects_dir,
                   cowork_dir=self.cowork_dir, quiet=True)

        # Replace with a shorter file (simulating an unexpected rewrite).
        _write_jsonl(session, [
            _assistant_event("msg_3", "req_3", "claude-sonnet-5", "2026-07-18T14:00:02.000Z",
                              input_tokens=5, output_tokens=1),
        ])
        # Should not raise.
        uc.collect(self.state_dir, now=BASE_EPOCH + 10, projects_dir=self.projects_dir,
                   cowork_dir=self.cowork_dir, quiet=True)
        store = uc.load_store(self.state_dir)
        self.assertIn(str(session), store["progress"])

    def test_idempotent_multiple_runs_no_new_data(self):
        session = self.projects_dir / "proj1" / "sess1.jsonl"
        _write_jsonl(session, [
            _assistant_event("msg_1", "req_1", "claude-sonnet-5", "2026-07-18T14:00:00.000Z",
                              input_tokens=10, output_tokens=5),
        ])
        for i in range(5):
            uc.collect(self.state_dir, now=BASE_EPOCH + i, projects_dir=self.projects_dir,
                       cowork_dir=self.cowork_dir, quiet=True)
        store = uc.load_store(self.state_dir)
        bucket = store["hours"]["2026-07-18T14"][uc.SOURCE_CODE_CLI]["claude-sonnet-5"]
        self.assertEqual(bucket["input"], 10)
        self.assertEqual(bucket["messages"], 1)


class TestCompaction(TempStateMixin, unittest.TestCase):
    def _snap_row(self, ts: str, five_hour: float, seven_day: float) -> dict:
        return {
            "ts": ts,
            "five_hour": {"utilization": five_hour, "resets_at": "2026-07-18T20:00:00Z"},
            "seven_day": {"utilization": seven_day, "resets_at": "2026-07-25T00:00:00Z"},
            "raw": {},
        }

    def test_raw_rows_within_24h_stay_raw(self):
        now = BASE_EPOCH
        raw_path = uc.snapshots_raw_path(self.state_dir)
        recent_ts = "2026-07-18T13:00:00Z"  # well within 24h of `now`'s wall time below
        # Anchor `now` to a real datetime so ISO parsing / cutoffs line up.
        from datetime import datetime, timezone
        now_dt = datetime(2026, 7, 18, 14, 0, 0, tzinfo=timezone.utc)
        now = now_dt.timestamp()
        _write_jsonl(raw_path, [self._snap_row(recent_ts, 10.0, 5.0)])

        uc.compact(self.state_dir, now=now, quiet=True)

        rows, _ = uc._read_jsonl_rows(raw_path)
        self.assertEqual(len(rows), 1)
        rows_15m, _ = uc._read_jsonl_rows(uc.snapshots_15m_path(self.state_dir))
        self.assertEqual(len(rows_15m), 0)

    def test_raw_rows_older_than_24h_move_to_15m_with_correct_stats(self):
        from datetime import datetime, timezone
        now_dt = datetime(2026, 7, 18, 14, 0, 0, tzinfo=timezone.utc)
        now = now_dt.timestamp()
        raw_path = uc.snapshots_raw_path(self.state_dir)

        # All in the same 15-min bucket (13:00:00 - 13:14:59), > 24h old.
        old_rows = [
            self._snap_row("2026-07-17T13:00:00Z", 10.0, 1.0),
            self._snap_row("2026-07-17T13:05:00Z", 30.0, 2.0),
            self._snap_row("2026-07-17T13:10:00Z", 20.0, 3.0),
        ]
        _write_jsonl(raw_path, old_rows)

        uc.compact(self.state_dir, now=now, quiet=True)

        raw_after, _ = uc._read_jsonl_rows(raw_path)
        self.assertEqual(len(raw_after), 0)

        rows_15m, _ = uc._read_jsonl_rows(uc.snapshots_15m_path(self.state_dir))
        self.assertEqual(len(rows_15m), 1)
        bucket = rows_15m[0]
        self.assertEqual(bucket["ts_start"], "2026-07-17T13:00:00Z")
        self.assertEqual(bucket["n"], 3)
        self.assertEqual(bucket["five_hour"]["min"], 10.0)
        self.assertEqual(bucket["five_hour"]["max"], 30.0)
        self.assertAlmostEqual(bucket["five_hour"]["avg"], 20.0)
        self.assertEqual(bucket["five_hour"]["last"], 20.0)  # chronologically last row (13:10)
        self.assertEqual(bucket["seven_day"]["max"], 3.0)

    def test_15m_merge_across_multiple_compact_runs_out_of_order_last(self):
        """Simulates two separate compact() runs feeding the same 15-min
        bucket, with the second run's data actually being chronologically
        earlier than the first run's -- the merge must still resolve
        'last' correctly by timestamp, not by arrival order."""
        from datetime import datetime, timezone
        raw_path = uc.snapshots_raw_path(self.state_dir)

        # First run moves the *later* sample in the bucket.
        _write_jsonl(raw_path, [self._snap_row("2026-07-17T13:10:00Z", 99.0, 1.0)])
        now1 = datetime(2026, 7, 18, 14, 0, 0, tzinfo=timezone.utc).timestamp()
        uc.compact(self.state_dir, now=now1, quiet=True)

        # Second run moves an *earlier* sample into the same bucket.
        _write_jsonl(raw_path, [self._snap_row("2026-07-17T13:02:00Z", 5.0, 9.0)])
        now2 = now1 + 60
        uc.compact(self.state_dir, now=now2, quiet=True)

        rows_15m, _ = uc._read_jsonl_rows(uc.snapshots_15m_path(self.state_dir))
        self.assertEqual(len(rows_15m), 1)
        bucket = rows_15m[0]
        self.assertEqual(bucket["n"], 2)
        self.assertEqual(bucket["five_hour"]["min"], 5.0)
        self.assertEqual(bucket["five_hour"]["max"], 99.0)
        # 'last' must be the 13:10 sample (99.0) since it's chronologically
        # later, even though it was merged in first.
        self.assertEqual(bucket["five_hour"]["last"], 99.0)

    def test_15m_rows_older_than_30d_roll_to_1h_preserving_max(self):
        from datetime import datetime, timezone
        m15_path = uc.snapshots_15m_path(self.state_dir)
        # Four 15-min buckets making up hour 09:00-10:00 on a day >30d old.
        rows = []
        for minute, peak in ((0, 10.0), (15, 80.0), (30, 40.0), (45, 20.0)):
            ts = f"2026-06-01T09:{minute:02d}:00Z"
            rows.append({
                "ts_start": ts, "n": 5,
                "five_hour": {"min": peak - 5, "max": peak, "avg": peak - 2, "last": peak - 1,
                              "_sum": (peak - 2) * 5, "_n": 5, "_last_ts": uc._parse_ts(ts) + 600},
                "seven_day": {"min": 1.0, "max": 2.0, "avg": 1.5, "last": 1.5,
                              "_sum": 7.5, "_n": 5, "_last_ts": uc._parse_ts(ts) + 600},
            })
        _write_jsonl(m15_path, rows)

        now = datetime(2026, 7, 18, 14, 0, 0, tzinfo=timezone.utc).timestamp()
        uc.compact(self.state_dir, now=now, quiet=True)

        rows_15m_after, _ = uc._read_jsonl_rows(m15_path)
        self.assertEqual(len(rows_15m_after), 0)

        rows_1h, _ = uc._read_jsonl_rows(uc.snapshots_1h_path(self.state_dir))
        self.assertEqual(len(rows_1h), 1)
        bucket = rows_1h[0]
        self.assertEqual(bucket["ts_start"], "2026-06-01T09:00:00Z")
        self.assertEqual(bucket["n"], 20)
        self.assertEqual(bucket["five_hour"]["max"], 80.0)  # peak preserved through the roll-up
        self.assertEqual(bucket["five_hour"]["min"], 5.0)

    def test_read_jsonl_rows_skips_and_counts_malformed_lines(self):
        """_read_jsonl_rows is the primitive both compact() stages share for
        tolerating bad input; test it directly since compact() rewrites its
        source files clean on the way out, so re-reading *after* compact()
        would just see the already-cleaned file."""
        raw_path = uc.snapshots_raw_path(self.state_dir)
        raw_path.parent.mkdir(parents=True, exist_ok=True)
        with open(raw_path, "w") as f:
            f.write("not json at all\n")
            f.write(json.dumps(self._snap_row("2026-07-18T13:59:00Z", 1.0, 1.0)) + "\n")
            f.write("{\"incomplete\":\n")

        rows, malformed = uc._read_jsonl_rows(raw_path)
        self.assertEqual(len(rows), 1)
        self.assertEqual(malformed, 2)

    def test_compact_tolerates_malformed_lines_without_raising(self):
        raw_path = uc.snapshots_raw_path(self.state_dir)
        raw_path.parent.mkdir(parents=True, exist_ok=True)
        with open(raw_path, "w") as f:
            f.write("not json at all\n")
            f.write(json.dumps(self._snap_row("2026-07-18T13:59:00Z", 1.0, 1.0)) + "\n")
            f.write("{\"incomplete\":\n")

        from datetime import datetime, timezone
        now = datetime(2026, 7, 18, 14, 0, 0, tzinfo=timezone.utc).timestamp()
        uc.compact(self.state_dir, now=now, quiet=True)  # must not raise

        # The malformed lines are gone from the rewritten file; the one
        # valid, still-recent row survives.
        rows, malformed_after = uc._read_jsonl_rows(raw_path)
        self.assertEqual(len(rows), 1)
        self.assertEqual(malformed_after, 0)

    def test_missing_snapshot_files_tolerated(self):
        # No snapshots.jsonl written at all -- widget hasn't landed yet.
        uc.compact(self.state_dir, now=BASE_EPOCH, quiet=True)  # must not raise
        rows, malformed = uc._read_jsonl_rows(uc.snapshots_raw_path(self.state_dir))
        self.assertEqual(rows, [])
        self.assertEqual(malformed, 0)


class TestReportAndCLI(TempStateMixin, unittest.TestCase):
    def test_report_on_empty_store(self):
        text = uc.build_report(self.state_dir)
        self.assertIn("no usage data collected yet", text)

    def test_report_on_populated_store(self):
        session = self.projects_dir / "proj1" / "sess1.jsonl"
        _write_jsonl(session, [
            _assistant_event("msg_1", "req_1", "claude-sonnet-5", "2026-07-18T14:00:00.000Z",
                              input_tokens=123, output_tokens=45),
        ])
        uc.collect(self.state_dir, now=BASE_EPOCH, projects_dir=self.projects_dir,
                   cowork_dir=self.cowork_dir, quiet=True)
        text = uc.build_report(self.state_dir)
        self.assertIn("code_cli", text)
        self.assertIn("claude-sonnet-5", text)
        self.assertIn("123", text)

    def test_cli_collect_compact_report_smoke(self):
        session = self.projects_dir / "proj1" / "sess1.jsonl"
        _write_jsonl(session, [
            _assistant_event("msg_1", "req_1", "claude-sonnet-5", "2026-07-18T14:00:00.000Z",
                              input_tokens=1, output_tokens=1),
        ])
        # collect()/compact() via main() use real projects/cowork dirs, so
        # just exercise report() through the CLI path here; collect/compact
        # direct-call coverage is above.
        rc = uc.main(["--state-dir", str(self.state_dir), "report"])
        self.assertEqual(rc, 0)


if __name__ == "__main__":
    unittest.main()
