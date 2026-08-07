#!/usr/bin/env python3
"""Stdlib unittest suite for contracts.py and docs/contracts/*.schema.json.

Three layers, in increasing order of usefulness:

1. Validator self-tests — the hand-rolled JSON Schema subset actually does
   what the schemas assume (type unions, bool-is-not-a-number, oneOf
   exclusivity, additionalProperties:false, dependentRequired, $ref).
2. Fixture tests — each schema accepts a synthesized good instance and
   REJECTS targeted bad ones, so a schema can't quietly degrade into
   "accepts anything".
3. Round-trip tests — the REAL writers (plan_fit.compute, autoresume's
   compute_cli_records -> merge_cli_records / merge_cowork_records,
   remote_sync._merge_host, usage_collector.compact) are run against
   synthetic inputs and their output is asserted to validate. This layer is
   what actually catches drift: add a field to a writer without adding it to
   the schema and these fail.

All fixture data is SYNTHESIZED. Nothing here reads the owner's real
~/.claude-autoresume store, and no real session id, project path, title or
token count appears anywhere in this file.

Run with:
    python3 test_contracts.py        # or: python3 -m unittest test_contracts
"""

from __future__ import annotations

import copy
import json
import os
import sys
import tempfile
import time
import unittest
from datetime import datetime, timedelta, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import contracts


# ---------------------------------------------------------------------------
# Synthesized fixtures
# ---------------------------------------------------------------------------

FAKE_CLI_SID = "00000000-0000-4000-8000-00000000cafe"
FAKE_COWORK_SID = "local_00000000-0000-4000-8000-00000000beef"
FAKE_PROJECT_DIR = "/tmp/contract-fixture/widget-demo"


def cli_entry(**overrides) -> dict:
    """A state.json entry as merge_cli_records writes a brand-new one."""
    entry = {
        "kind": "cli",
        "project_dir": FAKE_PROJECT_DIR,
        "project_name": "widget-demo",
        "session_title": "Fixture session",
        "prompt_preview": "do the fixture thing",
        "resets_at": None,
        "last_activity_at": 1_800_000_000.0,
        "detected_at": 1_800_000_000.0,
        "last_seen": 1_800_000_010.0,
        "enabled": False,
        "force_resume": False,
        "handled": False,
        "handled_at": None,
        "status": "active",
        "scoped_model": None,
        "work_status": "running",
        "pending_tool": False,
    }
    entry.update(overrides)
    return entry


def cowork_entry(**overrides) -> dict:
    entry = {
        "kind": "cowork",
        "project_dir": FAKE_PROJECT_DIR,
        "project_name": "Cowork",
        "session_title": "Fixture Cowork session",
        "prompt_preview": "",
        "resets_at": None,
        "detected_at": 1_800_000_000.0,
        "last_seen": 1_800_000_010.0,
        "last_activity_at": 1_800_000_005.0,
        "enabled": False,
        "force_resume": False,
        "handled": False,
        "handled_at": None,
        "status": "active",
        "work_status": "running",
        "resume_armed": False,
        "needs_attention": False,
    }
    entry.update(overrides)
    return entry


def remote_entry(**overrides) -> dict:
    entry = cli_entry()
    entry.update({
        "host": "fixturebox",
        "remote_id": FAKE_CLI_SID,
        "remote_stale": False,
        "remote_last_sync": 1_800_000_012.0,
        "resume_armed": False,
    })
    entry.update(overrides)
    return entry


def good_config() -> dict:
    return {
        "version": 1,
        "account": {"type": "max", "plan": "max_20x"},
        "budget": {
            "weekly_usd": None,
            "monthly_usd": 250.0,
            "week_start": "monday",
            "timezone": "local",
        },
        "sessions": {"idle_retention_minutes": 30},
        "remote_hosts": [{
            "name": "fixturebox",
            "ssh": "fixture@example.invalid",
            "enabled": True,
            "python": "python3",
            "state_dir": "~/.claude-autoresume",
            "poll_seconds": 30,
            "collect_usage": True,
            "deployed_at": None,
            "deployed_version": None,
        }],
    }


def good_raw_snapshot_row() -> dict:
    return {
        "ts": "2026-07-26T15:26:03Z",
        "five_hour": {"utilization": 42, "resets_at": "2026-07-26T18:00:00Z"},
        "seven_day": {"utilization": 61, "resets_at": "2026-07-30T00:00:00Z"},
        "raw": {"opaque": "payload", "nested": {"kept": "whole"}},
    }


def good_bucket_row() -> dict:
    return {
        "ts_start": "2026-07-26T15:15:00Z",
        "n": 7,
        "five_hour": {"min": 40.0, "max": 48.0, "avg": 44.0, "last": 48.0,
                      "_sum": 308.0, "_n": 7, "_last_ts": 1_800_000_000.0},
        "seven_day": {"min": 60.0, "max": 62.0, "avg": 61.0, "last": 62.0,
                      "_sum": 427.0, "_n": 7, "_last_ts": 1_800_000_000.0},
    }


def good_scoped_limits() -> dict:
    return {
        "updated_at": "2026-07-26T15:26:03Z",
        "limits": [{
            "model_display_name": "Fable",
            "model_id": None,
            "resets_at": "2026-07-30T00:00:00Z",
            "percent": 100,
            "severity": "critical",
        }],
    }


def _tokens_hourly(hours: dict) -> dict:
    return {"version": 1, "hours": hours, "progress": {}}


# ---------------------------------------------------------------------------
# 1. Validator self-tests
# ---------------------------------------------------------------------------

class ValidatorMechanicsTests(unittest.TestCase):
    """The schemas lean on these behaviours; if the validator gets them wrong
    every other test in this file is measuring nothing."""

    def _v(self, schema, value):
        ctx = contracts._Ctx({"$defs": {}})
        contracts._check(ctx, schema, value, "")
        return ctx.errors

    def test_type_union_accepts_either_member(self):
        schema = {"type": ["number", "null"]}
        self.assertEqual(self._v(schema, 1.5), [])
        self.assertEqual(self._v(schema, None), [])
        self.assertTrue(self._v(schema, "1.5"))

    def test_boolean_is_not_a_number(self):
        # Python's True == 1 would otherwise let a bool satisfy a numeric
        # field — exactly the confusion autoresume_config._positive_number
        # guards against on the reader side.
        self.assertTrue(self._v({"type": "number"}, True))
        self.assertTrue(self._v({"type": "integer"}, False))
        self.assertEqual(self._v({"type": "boolean"}, True), [])

    def test_integer_accepts_whole_float(self):
        # json.loads gives ints, but a value that round-tripped through a
        # float (or through Swift's NSNumber) can arrive as 7.0.
        self.assertEqual(self._v({"type": "integer"}, 7.0), [])
        self.assertTrue(self._v({"type": "integer"}, 7.5))

    def test_enum_does_not_conflate_bool_and_int(self):
        self.assertTrue(self._v({"enum": [0, 1]}, True))
        self.assertEqual(self._v({"enum": [0, 1]}, 1), [])

    def test_enum_allows_null_member(self):
        schema = {"enum": ["7d", None]}
        self.assertEqual(self._v(schema, None), [])
        self.assertTrue(self._v(schema, "5d"))

    def test_additional_properties_false_rejects_unknown_key(self):
        schema = {"type": "object", "properties": {"a": {"type": "string"}},
                  "additionalProperties": False}
        self.assertEqual(self._v(schema, {"a": "x"}), [])
        errs = self._v(schema, {"a": "x", "b": 1})
        self.assertTrue(any("unexpected property 'b'" in e for e in errs))

    def test_required_reports_each_missing_key(self):
        schema = {"type": "object", "required": ["a", "b"]}
        errs = self._v(schema, {})
        self.assertEqual(len(errs), 2)

    def test_dependent_required(self):
        schema = {"type": "object", "dependentRequired": {"host": ["remote_id"]}}
        self.assertEqual(self._v(schema, {}), [])
        self.assertEqual(self._v(schema, {"host": "h", "remote_id": "r"}), [])
        self.assertTrue(self._v(schema, {"host": "h"}))

    def test_one_of_rejects_ambiguous_match(self):
        schema = {"oneOf": [{"type": "object"}, {"type": "object"}]}
        errs = self._v(schema, {})
        self.assertTrue(any("ambiguously" in e for e in errs))

    def test_ref_resolves_local_pointer(self):
        doc = {"$defs": {"leaf": {"type": "string"}}}
        ctx = contracts._Ctx(doc)
        contracts._check(ctx, {"$ref": "#/$defs/leaf"}, 5, "")
        self.assertTrue(ctx.errors)

    def test_exclusive_minimum_and_pattern(self):
        self.assertTrue(self._v({"exclusiveMinimum": 0}, 0))
        self.assertEqual(self._v({"exclusiveMinimum": 0}, 0.01), [])
        self.assertTrue(self._v({"pattern": "^[0-9]{4}$"}, "12"))

    def test_error_messages_do_not_dump_large_values(self):
        # Error text can reach logs; these files carry real session titles and
        # project paths, so offending containers/long strings are summarised.
        errs = self._v({"enum": ["a"]}, {"secret": "x" * 500})
        self.assertTrue(errs)
        self.assertNotIn("secret", errs[0])
        errs = self._v({"enum": ["a"]}, "y" * 500)
        self.assertLess(len(errs[0]), 200)

    def test_validate_rejects_unknown_contract_name(self):
        with self.assertRaises(KeyError):
            contracts.validate("no_such_contract", {})

    def test_every_schema_only_uses_implemented_keywords(self):
        """The guard against a schema silently depending on a keyword this
        stdlib validator ignores (which would make it look like it validates
        something it does not)."""
        for name in contracts.schema_names():
            with self.subTest(name=name):
                unsupported = contracts.schema_keywords_used(name) - contracts.SUPPORTED_KEYWORDS
                self.assertEqual(unsupported, set(),
                                 f"{name} uses unimplemented keyword(s): {sorted(unsupported)}")

    def test_all_schemas_declare_id_title_and_contract_version(self):
        seen_ids = set()
        for name in contracts.schema_names():
            _, doc = contracts.load(name)
            self.assertIn("$id", doc)
            self.assertIn("title", doc)
            self.assertIn("x-contract-version", doc)
            self.assertIn("$schema", doc)
            self.assertEqual(doc["$schema"],
                             "https://json-schema.org/draft/2020-12/schema")
            seen_ids.add(doc["$id"])
        self.assertEqual(len(seen_ids), 5, "expected exactly five schema documents")

    def test_every_documented_property_carries_a_description(self):
        """A schema without descriptions is just a type checker; the point of
        these is to carry the WHY from the code comments."""
        def walk(node, path, missing):
            if isinstance(node, dict):
                for key, sub in (node.get("properties") or {}).items():
                    if isinstance(sub, dict) and "description" not in sub and "$ref" not in sub:
                        missing.append(f"{path}.{key}")
                    walk(sub, f"{path}.{key}", missing)
                for key in ("$defs", ):
                    for dname, sub in (node.get(key) or {}).items():
                        walk(sub, f"{path}#{dname}", missing)
                if isinstance(node.get("items"), dict):
                    walk(node["items"], path + "[]", missing)
                if isinstance(node.get("additionalProperties"), dict):
                    walk(node["additionalProperties"], path + "{}", missing)
        for name in contracts.schema_names():
            _, doc = contracts.load(name)
            missing: list[str] = []
            walk(doc, name, missing)
            self.assertEqual(missing, [], f"undocumented fields: {missing}")


# ---------------------------------------------------------------------------
# 2a. state.json fixtures
# ---------------------------------------------------------------------------

class StateSchemaTests(unittest.TestCase):
    def test_good_cli_cowork_and_remote_entries(self):
        state = {
            FAKE_CLI_SID: cli_entry(),
            FAKE_COWORK_SID: cowork_entry(),
            f"fixturebox::{FAKE_CLI_SID}": remote_entry(),
        }
        self.assertEqual(contracts.validate("state", state), [])

    def test_waiting_entry_with_scoped_model_and_reset(self):
        entry = cli_entry(status="waiting", resets_at=1_800_003_600.0,
                          scoped_model="claude-fable-5", work_status="idle")
        self.assertEqual(contracts.validate("state.entry", entry), [])

    def test_handled_terminal_entry(self):
        for status in ("resumed", "failed"):
            entry = cli_entry(status=status, handled=True,
                              handled_at=1_800_000_100.0)
            self.assertEqual(contracts.validate("state.entry", entry), [],
                             f"{status} should be a legal terminal status")

    def test_rejects_unknown_status(self):
        errs = contracts.validate("state.entry", cli_entry(status="paused"))
        self.assertTrue(errs)

    def test_rejects_unknown_work_status(self):
        self.assertTrue(contracts.validate("state.entry", cli_entry(work_status="thinking")))

    def test_rejects_unknown_kind(self):
        self.assertTrue(contracts.validate("state.entry", cli_entry(kind="chat")))

    def test_rejects_missing_widget_owned_toggle(self):
        # enabled/force_resume are the opt-in gate; losing them silently would
        # be the single worst regression this file can suffer.
        entry = cli_entry()
        del entry["enabled"]
        errs = contracts.validate("state.entry", entry)
        self.assertTrue(any("'enabled'" in e for e in errs))

    def test_rejects_resets_at_as_iso_string(self):
        # resets_at is epoch seconds on BOTH sides. A daemon that started
        # writing an ISO string here would render as "active now" forever,
        # because Swift decodes it with `as? Double`.
        self.assertTrue(contracts.validate(
            "state.entry", cli_entry(resets_at="2026-07-30T00:00:00Z")))

    def test_rejects_stringified_boolean_toggle(self):
        self.assertTrue(contracts.validate("state.entry", cli_entry(enabled="true")))

    def test_rejects_unknown_entry_field(self):
        entry = cli_entry()
        entry["totally_new_field"] = 1
        errs = contracts.validate("state.entry", entry)
        self.assertTrue(any("totally_new_field" in e for e in errs))

    def test_remote_entry_requires_its_companions(self):
        entry = remote_entry()
        del entry["remote_id"]
        errs = contracts.validate("state.entry", entry)
        self.assertTrue(any("remote_id" in e for e in errs))

    def test_root_must_be_object_of_entries(self):
        self.assertTrue(contracts.validate("state", []))
        self.assertTrue(contracts.validate("state", {FAKE_CLI_SID: "not an entry"}))


# ---------------------------------------------------------------------------
# 2b. config.json fixtures
# ---------------------------------------------------------------------------

class ConfigSchemaTests(unittest.TestCase):
    def test_good_config(self):
        self.assertEqual(contracts.validate("config", good_config()), [])

    def test_partial_config_is_legal(self):
        # The sole writer only writes keys the user has touched, so a real
        # config.json is normally partial. Only `version` is guaranteed.
        self.assertEqual(contracts.validate("config", {"version": 1}), [])

    def test_unknown_top_level_keys_are_preserved_not_rejected(self):
        cfg = good_config()
        cfg["some_future_block"] = {"x": 1}
        self.assertEqual(contracts.validate("config", cfg), [],
                         "unknown-key preservation is a stated design rule here")

    def test_rejects_unknown_account_type(self):
        cfg = good_config()
        cfg["account"]["type"] = "enterprise"
        self.assertTrue(contracts.validate("config", cfg))

    def test_rejects_non_canonical_plan(self):
        cfg = good_config()
        cfg["account"]["plan"] = "max_10x"
        self.assertTrue(contracts.validate("config", cfg))

    def test_rejects_zero_or_negative_budget(self):
        for bad in (0, -5):
            cfg = good_config()
            cfg["budget"]["monthly_usd"] = bad
            self.assertTrue(contracts.validate("config", cfg), f"{bad} must be rejected")

    def test_null_budget_is_the_unconfigured_encoding(self):
        cfg = good_config()
        cfg["budget"]["monthly_usd"] = None
        self.assertEqual(contracts.validate("config", cfg), [])

    def test_rejects_host_name_containing_colon(self):
        # ':' would corrupt the "<host>::<sid>" state.json key.
        cfg = good_config()
        cfg["remote_hosts"][0]["name"] = "bad:name"
        errs = contracts.validate("config", cfg)
        self.assertTrue(errs)

    def test_rejects_host_without_ssh(self):
        cfg = good_config()
        del cfg["remote_hosts"][0]["ssh"]
        self.assertTrue(contracts.validate("config", cfg))

    def test_rejects_unknown_week_start(self):
        cfg = good_config()
        cfg["budget"]["week_start"] = "friday"
        self.assertTrue(contracts.validate("config", cfg))

    def test_accepts_both_projection_bases_and_rejects_others(self):
        for basis in ("calendar", "weekdays"):
            cfg = good_config()
            cfg["budget"]["projection_basis"] = basis
            self.assertEqual(contracts.validate("config", cfg), [])
        cfg = good_config()
        cfg["budget"]["projection_basis"] = "business_days"
        self.assertTrue(contracts.validate("config", cfg))

    def test_schema_conformant_config_loads_cleanly_in_the_daemon(self):
        """Round-trip against the REAL reader: a config that validates must
        survive autoresume_config.load_config with its values intact (nothing
        silently defaulted away)."""
        import autoresume_config
        with tempfile.TemporaryDirectory() as tmp:
            state_dir = Path(tmp)
            (state_dir / "config.json").write_text(json.dumps(good_config()))
            cfg, meta = autoresume_config.load_config_with_meta(state_dir)
        self.assertEqual(cfg["account"], {"type": "max", "plan": "max_20x"})
        self.assertTrue(meta["plan_from_file"])
        self.assertEqual(cfg["budget"]["monthly_usd"], 250.0)
        self.assertIsNone(cfg["budget"]["weekly_usd"])
        self.assertEqual(cfg["sessions"]["idle_retention_minutes"], 30)
        self.assertEqual(len(cfg["remote_hosts"]), 1)
        self.assertEqual(cfg["remote_hosts"][0]["name"], "fixturebox")

    def test_daemon_default_config_is_schema_conformant(self):
        """The defaults the daemon falls back to must themselves describe a
        legal config — otherwise 'no file' and 'default file' would disagree."""
        import autoresume_config
        default = autoresume_config._default_config()
        self.assertEqual(contracts.validate("config", default), [])


# ---------------------------------------------------------------------------
# 2c. snapshots fixtures
# ---------------------------------------------------------------------------

class SnapshotSchemaTests(unittest.TestCase):
    def test_good_rows(self):
        self.assertEqual(contracts.validate("snapshots.raw", good_raw_snapshot_row()), [])
        self.assertEqual(contracts.validate("snapshots.bucket", good_bucket_row()), [])

    def test_root_one_of_accepts_either_row_and_only_one(self):
        for row in (good_raw_snapshot_row(), good_bucket_row()):
            self.assertEqual(contracts.validate("snapshots", row), [])
        # A row carrying BOTH discriminators is not a legal shape.
        hybrid = good_raw_snapshot_row()
        hybrid["ts_start"] = "2026-07-26T15:15:00Z"
        self.assertTrue(contracts.validate("snapshots", hybrid))

    def test_null_utilization_is_legal(self):
        row = good_raw_snapshot_row()
        row["five_hour"]["utilization"] = None
        self.assertEqual(contracts.validate("snapshots.raw", row), [])

    def test_raw_row_must_keep_the_opaque_blob(self):
        row = good_raw_snapshot_row()
        del row["raw"]
        self.assertTrue(contracts.validate("snapshots.raw", row))

    def test_bucket_row_must_keep_bookkeeping_fields(self):
        # _sum/_n/_last_ts are what let a later compact() merge more rows into
        # an existing bucket without re-reading discarded data.
        for field in ("_sum", "_n", "_last_ts"):
            row = good_bucket_row()
            del row["five_hour"][field]
            errs = contracts.validate("snapshots.bucket", row)
            self.assertTrue(errs, f"missing {field} must be rejected")

    def test_bucket_ts_start_format_is_enforced(self):
        row = good_bucket_row()
        row["ts_start"] = "2026-07-26T15:15:00+00:00"  # raw-row lexical form
        self.assertTrue(contracts.validate("snapshots.bucket", row))

    def test_bucket_row_must_not_carry_raw_or_resets_at(self):
        # Compaction deliberately DROPS these; a compactor that started
        # carrying them forward would blow the file up unboundedly.
        row = good_bucket_row()
        row["raw"] = {}
        self.assertTrue(contracts.validate("snapshots.bucket", row))
        row = good_bucket_row()
        row["five_hour"]["resets_at"] = "2026-07-26T18:00:00Z"
        self.assertTrue(contracts.validate("snapshots.bucket", row))

    def test_validate_jsonl_reports_line_numbers(self):
        text = "\n".join([
            json.dumps(good_raw_snapshot_row()),
            "",
            "{not json",
            json.dumps({"ts": "2026-07-26T15:26:03Z"}),
        ])
        errs = contracts.validate_jsonl("snapshots.raw", text)
        self.assertTrue(any(e.startswith("line 3:") for e in errs))
        self.assertTrue(any(e.startswith("line 4:") for e in errs))
        self.assertFalse(any(e.startswith("line 1:") for e in errs))


# ---------------------------------------------------------------------------
# 2d. scoped_limits fixtures
# ---------------------------------------------------------------------------

class ScopedLimitsSchemaTests(unittest.TestCase):
    def test_good_payload(self):
        self.assertEqual(contracts.validate("scoped_limits", good_scoped_limits()), [])

    def test_empty_limits_is_meaningful_not_invalid(self):
        # An empty array clears a cap that just reset — it is a full-state
        # snapshot, not a log.
        payload = {"updated_at": "2026-07-26T15:26:03Z", "limits": []}
        self.assertEqual(contracts.validate("scoped_limits", payload), [])

    def test_nullable_fields(self):
        payload = good_scoped_limits()
        payload["limits"][0].update({"model_id": None, "resets_at": None,
                                     "percent": None, "severity": None})
        self.assertEqual(contracts.validate("scoped_limits", payload), [])

    def test_display_name_may_not_be_null(self):
        payload = good_scoped_limits()
        payload["limits"][0]["model_display_name"] = None
        self.assertTrue(contracts.validate("scoped_limits", payload))

    def test_rejects_is_active_field(self):
        # The widget filters on isActive BEFORE writing; the daemon therefore
        # does no filtering. Reintroducing the field would mean the invariant
        # moved, and the daemon would start honouring inactive caps.
        payload = good_scoped_limits()
        payload["limits"][0]["is_active"] = True
        self.assertTrue(contracts.validate("scoped_limits", payload))

    def test_daemon_consumes_a_schema_conformant_payload(self):
        """Round-trip against the REAL reader: load_scoped_limits must turn a
        schema-valid file into an armed reset for the matching model family."""
        import autoresume as ar
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "scoped_limits.json"
            path.write_text(json.dumps(good_scoped_limits()))
            saved = ar.SCOPED_LIMITS_FILE
            try:
                ar.SCOPED_LIMITS_FILE = path
                limits = ar.load_scoped_limits()
                reset = ar.scoped_limit_reset(limits, "claude-fable-5")
            finally:
                ar.SCOPED_LIMITS_FILE = saved
        self.assertIsNotNone(reset, "'Fable' must match a 'claude-fable-5' transcript model")


# ---------------------------------------------------------------------------
# 2e. plan_fit fixtures (structural — the round-trip below is the real test)
# ---------------------------------------------------------------------------

class PlanFitSchemaShapeTests(unittest.TestCase):
    def _report(self) -> dict:
        """The report plan_fit.compute() produces from an EMPTY store: every
        analytic is null, which is the most schema-stressing shape there is."""
        with tempfile.TemporaryDirectory() as tmp:
            state_dir = Path(tmp)
            (state_dir / "usage").mkdir()
            (state_dir / "usage" / "tokens_hourly.json").write_text(
                json.dumps(_tokens_hourly({})))
            import plan_fit
            return plan_fit.compute(state_dir, datetime(2026, 7, 26, 12, 0, tzinfo=timezone.utc))

    def test_rejects_missing_top_level_block(self):
        report = self._report()
        for block in ("verdict", "budget", "cost_series", "throttle_projection"):
            trimmed = copy.deepcopy(report)
            del trimmed[block]
            errs = contracts.validate("plan_fit", trimmed)
            self.assertTrue(any(block in e for e in errs), f"{block} must be required")

    def test_rejects_unknown_tier_key(self):
        report = self._report()
        report["verdict"]["plans"]["max_50x"] = report["verdict"]["plans"]["pro"]
        self.assertTrue(contracts.validate("plan_fit", report),
                        "a new tier must be added to the schema, not silently accepted")

    def test_rejects_unknown_verdict_field(self):
        report = self._report()
        report["verdict"]["plans"]["pro"]["brand_new_metric"] = 1.0
        errs = contracts.validate("plan_fit", report)
        self.assertTrue(any("brand_new_metric" in e for e in errs))

    def test_rejects_string_where_a_number_is_expected(self):
        report = self._report()
        report["verdict"]["plans"]["pro"]["price_usd"] = "$20"
        self.assertTrue(contracts.validate("plan_fit", report))

    def test_rejects_bad_daily_cost_key_format(self):
        report = self._report()
        report["cost_series"]["daily"]["2026-07-26T00:00:00+00:00"] = 1.0
        errs = contracts.validate("plan_fit", report)
        self.assertTrue(errs, "daily keys are 'YYYY-MM-DD'; hourly keys are full ISO")

    def test_null_analytics_are_legal(self):
        report = self._report()
        self.assertIsNone(report["monthly_run_rate"]["value_usd_per_month"])
        self.assertEqual(contracts.validate("plan_fit", report), [])


# ---------------------------------------------------------------------------
# 3. ROUND-TRIP: the real writers must produce schema-conformant output
# ---------------------------------------------------------------------------

class PlanFitRoundTripTests(unittest.TestCase):
    """plan_fit.compute() is run for real against synthetic stores. This is
    what catches a field added to the report without a schema update."""

    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.state_dir = Path(self._tmp.name)
        self.usage_dir = self.state_dir / "usage"
        self.usage_dir.mkdir(parents=True)
        self.now = datetime(2026, 7, 26, 12, 0, tzinfo=timezone.utc)
        import plan_fit
        self.plan_fit = plan_fit

    def tearDown(self):
        self._tmp.cleanup()

    def _write(self, name, obj):
        (self.usage_dir / name).write_text(json.dumps(obj))

    def _write_jsonl(self, name, rows):
        (self.usage_dir / name).write_text(
            "".join(json.dumps(r) + "\n" for r in rows))

    def _assert_valid(self, report):
        errors = contracts.validate("plan_fit", report)
        self.assertEqual(errors, [], "plan_fit.compute() drifted from the schema:\n"
                                     + "\n".join(errors[:20]))

    def test_empty_store(self):
        self._write("tokens_hourly.json", _tokens_hourly({}))
        self._assert_valid(self.plan_fit.compute(self.state_dir, self.now))

    def test_no_store_files_at_all(self):
        self._assert_valid(self.plan_fit.compute(self.state_dir, self.now))

    def test_full_store_with_cost_snapshots_budget_and_lockouts(self):
        """The richest realistic shape: multi-day cost, raw + compacted
        utilization spanning both under- and over-cap stretches (so episode
        stats, any_cap and median_throttle_peak_pct are all non-null), an API
        account with both budget periods configured, and a plan history."""
        hours = {}
        day0 = datetime(2026, 7, 20, tzinfo=timezone.utc)
        for d in range(6):
            for h in (9, 10, 14):
                key = (day0 + timedelta(days=d, hours=h)).strftime("%Y-%m-%dT%H")
                hours[key] = {"code_cli": {
                    "claude-opus-4-5-fixture": {"input": 400_000, "output": 20_000,
                                                "cache_write": 5_000, "cache_read": 90_000},
                }}
        self._write("tokens_hourly.json", _tokens_hourly(hours))

        # Raw rows: a climb well past 100% and back down, 2 minutes apart.
        raw_rows = []
        base = self.now - timedelta(hours=6)
        for i, util in enumerate([10, 30, 55, 80, 97, 104, 118, 96, 40, 12]):
            ts = (base + timedelta(minutes=2 * i)).strftime("%Y-%m-%dT%H:%M:%SZ")
            raw_rows.append({
                "ts": ts,
                "five_hour": {"utilization": util, "resets_at": None},
                "seven_day": {"utilization": min(99, util // 2), "resets_at": None},
                "raw": {"fixture": True},
            })
        self._write_jsonl("snapshots.jsonl", raw_rows)

        bucket_rows = []
        bbase = self.now - timedelta(days=4)
        for i in range(12):
            ts = (bbase + timedelta(minutes=15 * i)).strftime("%Y-%m-%dT%H:%M:%SZ")
            lo, hi = (20 + i * 3), (35 + i * 8)
            bucket_rows.append({
                "ts_start": ts, "n": 7,
                "five_hour": {"min": float(lo), "max": float(hi),
                              "avg": float((lo + hi) / 2), "last": float(hi),
                              "_sum": float((lo + hi) / 2 * 7), "_n": 7,
                              "_last_ts": 1_800_000_000.0},
                "seven_day": {"min": float(lo) / 2, "max": float(hi) / 2,
                              "avg": float((lo + hi) / 4), "last": float(hi) / 2,
                              "_sum": float((lo + hi) / 4 * 7), "_n": 7,
                              "_last_ts": 1_800_000_000.0},
            })
        self._write_jsonl("snapshots_15m.jsonl", bucket_rows)
        self._write_jsonl("snapshots_1h.jsonl", [{
            "ts_start": (bbase - timedelta(days=2)).strftime("%Y-%m-%dT%H:00:00Z"),
            "n": 25,
            "five_hour": {"min": 5.0, "max": 140.0, "avg": 60.0, "last": 30.0,
                          "_sum": 1500.0, "_n": 25, "_last_ts": 1_700_000_000.0},
            "seven_day": {"min": 2.0, "max": 70.0, "avg": 30.0, "last": 15.0,
                          "_sum": 750.0, "_n": 25, "_last_ts": 1_700_000_000.0},
        }])

        cfg = good_config()
        cfg["account"] = {"type": "api", "plan": "max_5x"}
        cfg["budget"] = {"weekly_usd": 100.0, "monthly_usd": 400.0,
                         "week_start": "sunday", "timezone": "utc"}
        (self.state_dir / "config.json").write_text(json.dumps(cfg))

        report = self.plan_fit.compute(self.state_dir, self.now)
        self._assert_valid(report)

        # Sanity: the fixture really did exercise the interesting branches,
        # otherwise the round-trip is validating an all-null report again.
        self.assertIsNotNone(report["budget"]["weekly"])
        self.assertIsNotNone(report["budget"]["monthly"])
        self.assertIsNotNone(report["monthly_run_rate"]["value_usd_per_month"])
        self.assertTrue(report["totals"]["by_model"])
        pro = report["throttle_projection"]["pro"]
        self.assertGreater(pro["any_cap"]["capped_hours"], 0)
        self.assertIsNotNone(pro["five_hour"]["median_episode_hours"])
        self.assertEqual(report["account"]["type"], "api")

    def test_written_file_on_disk_validates(self):
        """write_plan_fit's atomic tmp+replace output, parsed back off disk —
        catches anything json.dumps would mangle that an in-memory dict hides."""
        self._write("tokens_hourly.json", _tokens_hourly({
            "2026-07-25T09": {"code_cli": {"claude-opus-4-5-fixture": {"input": 1_000_000, "output": 10_000}}},
        }))
        self.plan_fit.write_plan_fit(self.state_dir, self.now)
        on_disk = json.loads((self.usage_dir / "plan_fit.json").read_text())
        self.assertEqual(contracts.validate("plan_fit", on_disk), [])


class StateRoundTripTests(unittest.TestCase):
    """The real daemon state writers: compute_cli_records -> merge_cli_records,
    compute_cowork_records -> merge_cowork_records, resume_due_sessions and
    remote_sync._merge_host. All output is asserted schema-conformant AFTER a
    json round-trip, so a value json.dumps cannot represent also fails."""

    def setUp(self):
        import autoresume as ar
        self.ar = ar
        self._tmp = tempfile.TemporaryDirectory()
        self.tmp = Path(self._tmp.name)
        self.projects_dir = self.tmp / "projects"
        self.cowork_dir = self.tmp / "cowork"
        self.state_dir = self.tmp / "state"
        for d in (self.projects_dir, self.cowork_dir, self.state_dir):
            d.mkdir(parents=True, exist_ok=True)
        (self.state_dir / "usage").mkdir(exist_ok=True)
        self._saved = {k: getattr(ar, k) for k in (
            "PROJECTS_DIR", "COWORK_SESSIONS_DIR", "STATE_DIR", "STATE_FILE",
            "LOCK_FILE", "DAEMON_LOG", "SESSIONS_DIR", "SCOPED_LIMITS_FILE")}
        ar.PROJECTS_DIR = self.projects_dir
        ar.COWORK_SESSIONS_DIR = self.cowork_dir
        ar.STATE_DIR = self.state_dir
        ar.STATE_FILE = self.state_dir / "state.json"
        ar.LOCK_FILE = self.state_dir / "state.json.lock"
        ar.DAEMON_LOG = self.state_dir / "daemon.log"
        ar.SESSIONS_DIR = self.tmp / "sessions"  # nonexistent -> no live procs
        ar.SCOPED_LIMITS_FILE = self.state_dir / "usage" / "scoped_limits.json"
        ar._PARSE_CACHE.clear()

    def tearDown(self):
        for k, v in self._saved.items():
            setattr(self.ar, k, v)
        self.ar._PARSE_CACHE.clear()
        self._tmp.cleanup()

    def _assert_state_valid(self, state, label):
        round_tripped = json.loads(json.dumps(state))
        errors = contracts.validate("state", round_tripped)
        self.assertEqual(errors, [], f"{label} drifted from the schema:\n"
                                     + "\n".join(errors[:20]))

    def _write_transcript(self, session_id, rows, project="fixtureproj"):
        folder = self.projects_dir / project
        folder.mkdir(parents=True, exist_ok=True)
        path = folder / f"{session_id}.jsonl"
        path.write_text("".join(json.dumps(r) + "\n" for r in rows))
        return path

    def _human(self, text="hello", ts="2026-07-26T14:00:00.000Z"):
        return {"type": "user", "origin": {"kind": "human"},
                "message": {"role": "user", "content": [{"type": "text", "text": text}]},
                "cwd": FAKE_PROJECT_DIR, "timestamp": ts}

    def _assistant(self, ts="2026-07-26T14:01:00.000Z"):
        return {"type": "assistant",
                "message": {"role": "assistant", "model": "claude-opus-fixture",
                            "content": [{"type": "text", "text": "ok"}],
                            "stop_reason": "end_turn"},
                "timestamp": ts}

    def test_active_cli_session(self):
        self._write_transcript(FAKE_CLI_SID, [self._human(), self._assistant()])
        now = time.time()
        records = self.ar.compute_cli_records(now, {}, self.ar._PARSE_CACHE)
        self.assertIn(FAKE_CLI_SID, records)
        state: dict = {}
        self.ar.merge_cli_records(state, records, now)
        self.assertIn(FAKE_CLI_SID, state)
        self._assert_state_valid(state, "merge_cli_records (new active entry)")

    def test_rate_limited_cli_session_and_its_second_merge(self):
        """Both merge branches: the create branch and the update branch (which
        writes a different, smaller set of keys onto an existing entry)."""
        rows = [self._human(), {"type": "rate_limit_event",
                                "resetsAt": int(time.time()) + 3600,
                                "timestamp": "2026-07-26T14:02:00.000Z"}]
        self._write_transcript(FAKE_CLI_SID, rows)
        now = time.time()
        records = self.ar.compute_cli_records(now, {}, self.ar._PARSE_CACHE)
        state: dict = {}
        self.ar.merge_cli_records(state, records, now)
        self.assertEqual(state[FAKE_CLI_SID]["status"], "waiting")
        self._assert_state_valid(state, "merge_cli_records (waiting, create)")

        # Second cycle: the user flips the widget toggle, then merge runs again.
        state[FAKE_CLI_SID]["enabled"] = True
        self.ar._PARSE_CACHE.clear()
        records = self.ar.compute_cli_records(now + 10, {}, self.ar._PARSE_CACHE)
        self.ar.merge_cli_records(state, records, now + 10)
        self.assertTrue(state[FAKE_CLI_SID]["enabled"], "widget-owned field must survive merge")
        self._assert_state_valid(state, "merge_cli_records (waiting, update)")

    def test_per_model_capped_session_with_relayed_reset(self):
        """The Fable path: a 429 model-limit tail plus a relayed scoped limit,
        which is the only branch that populates scoped_model."""
        self.ar.SCOPED_LIMITS_FILE.parent.mkdir(parents=True, exist_ok=True)
        self.ar.SCOPED_LIMITS_FILE.write_text(json.dumps({
            "updated_at": "2026-07-26T14:00:00Z",
            "limits": [{"model_display_name": "Fable", "model_id": None,
                        "resets_at": "2026-07-30T00:00:00Z",
                        "percent": 100, "severity": "critical"}],
        }))
        rows = [
            self._human(),
            {"type": "assistant",
             "message": {"role": "assistant", "model": "claude-fable-5",
                         "content": [{"type": "text", "text": "working"}]},
             "timestamp": "2026-07-26T14:01:00.000Z"},
            {"type": "assistant", "isApiErrorMessage": True, "apiErrorStatus": 429,
             "message": {"role": "assistant", "model": "<synthetic>",
                         "content": [{"type": "text",
                                      "text": "You've reached your Fable 5 limit."}]},
             "timestamp": "2026-07-26T14:02:00.000Z"},
        ]
        self._write_transcript(FAKE_CLI_SID, rows)
        now = time.time()
        records = self.ar.compute_cli_records(now, {}, self.ar._PARSE_CACHE)
        state: dict = {}
        self.ar.merge_cli_records(state, records, now)
        entry = state[FAKE_CLI_SID]
        self.assertEqual(entry["status"], "waiting")
        self.assertEqual(entry["scoped_model"], "claude-fable-5")
        self._assert_state_valid(state, "merge_cli_records (per-model cap)")

        # reconcile runs on every poll, independent of the scan window.
        limits = self.ar.load_scoped_limits()
        self.ar.reconcile_scoped_limit_resets(state, limits)
        self.assertIsNotNone(entry["resets_at"])
        self._assert_state_valid(state, "reconcile_scoped_limit_resets")

    def test_cowork_session(self):
        sid = FAKE_COWORK_SID
        meta = {"id": sid, "title": "Fixture Cowork session",
                "lastActivityAt": int(time.time() * 1000), "isArchived": False}
        (self.cowork_dir / f"{sid}.json").write_text(json.dumps(meta))
        audit_dir = self.cowork_dir / sid
        audit_dir.mkdir(exist_ok=True)
        (audit_dir / "audit.jsonl").write_text(json.dumps(
            {"type": "tool_use", "timestamp": "2026-07-26T14:00:00.000Z"}) + "\n")
        now = time.time()
        records = self.ar.compute_cowork_records(now)
        if not records:
            self.skipTest("Cowork scanner produced no record for the fixture layout")
        state: dict = {}
        self.ar.merge_cowork_records(state, records, now)
        self._assert_state_valid(state, "merge_cowork_records")

    def test_resume_marks_entry_handled_and_stays_conformant(self):
        """resume_due_sessions writes status/handled/handled_at/force_resume —
        the terminal shape the schema has to accept too. CLAUDE_BIN is pointed
        at a nonexistent path so the FileNotFoundError branch runs; nothing is
        actually launched."""
        state = {FAKE_CLI_SID: cli_entry(status="waiting", resets_at=time.time() - 600,
                                         enabled=True)}
        saved_bin = self.ar.CLAUDE_BIN
        try:
            self.ar.CLAUDE_BIN = str(self.tmp / "definitely-not-a-real-binary")
            self.ar.resume_due_sessions(state)
        finally:
            self.ar.CLAUDE_BIN = saved_bin
        entry = state[FAKE_CLI_SID]
        self.assertTrue(entry["handled"])
        self.assertIn(entry["status"], ("resumed", "failed"))
        self._assert_state_valid(state, "resume_due_sessions")

    def test_remote_sync_merge_produces_conformant_entries(self):
        """remote_sync._merge_host writes the host/remote_id/remote_stale/
        remote_last_sync quartet plus the coerced widget-owned toggles."""
        import remote_sync
        dump = {"now": 1_800_000_000.0, "state": {FAKE_CLI_SID: cli_entry()}}
        state: dict = {}
        remote_sync._merge_host(state, "fixturebox", dump, offset=5.0,
                                mac_now=1_800_000_005.0)
        key = f"fixturebox::{FAKE_CLI_SID}"
        self.assertIn(key, state)
        self.assertEqual(state[key]["host"], "fixturebox")
        self.assertEqual(state[key]["remote_id"], FAKE_CLI_SID)
        self._assert_state_valid(state, "remote_sync._merge_host")

    def test_save_state_output_on_disk_validates(self):
        state = {FAKE_CLI_SID: cli_entry(), FAKE_COWORK_SID: cowork_entry()}
        self.ar.save_state(state)
        on_disk = json.loads(self.ar.STATE_FILE.read_text())
        self.assertEqual(contracts.validate("state", on_disk), [])


class SnapshotCompactionRoundTripTests(unittest.TestCase):
    """usage_collector.compact() is the only writer of the bucket row shape —
    run it for real and validate every file it leaves behind."""

    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.state_dir = Path(self._tmp.name)
        self.usage_dir = self.state_dir / "usage"
        self.usage_dir.mkdir(parents=True)
        import usage_collector
        self.uc = usage_collector

    def tearDown(self):
        self._tmp.cleanup()

    def _raw_rows(self, count, base_epoch):
        rows = []
        for i in range(count):
            ts = datetime.fromtimestamp(base_epoch + i * 120, tz=timezone.utc)
            rows.append({
                "ts": ts.strftime("%Y-%m-%dT%H:%M:%SZ"),
                "five_hour": {"utilization": 10 + (i % 40), "resets_at": None},
                "seven_day": {"utilization": 5 + (i % 20),
                              "resets_at": "2026-07-30T00:00:00Z"},
                "raw": {"fixture": i},
            })
        return rows

    def test_compaction_output_matches_the_bucket_schema(self):
        now = 1_800_000_000.0
        # Old enough to be rolled out of the raw tier (>24h), and old enough
        # for some of the 15m buckets to roll on into the 1h tier (>30d).
        old_raw = self._raw_rows(60, now - 40 * 86400)
        recent_raw = self._raw_rows(5, now - 600)
        (self.usage_dir / "snapshots.jsonl").write_text(
            "".join(json.dumps(r) + "\n" for r in old_raw + recent_raw))

        self.uc.compact(self.state_dir, now=now, quiet=True)

        raw_text = (self.usage_dir / "snapshots.jsonl").read_text()
        self.assertEqual(contracts.validate_jsonl("snapshots.raw", raw_text), [])

        for name in ("snapshots_15m.jsonl", "snapshots_1h.jsonl"):
            path = self.usage_dir / name
            if not path.exists():
                continue
            errors = contracts.validate_jsonl("snapshots.bucket", path.read_text())
            self.assertEqual(errors, [], f"{name} drifted from the bucket schema:\n"
                                         + "\n".join(errors[:20]))
        # The fixture must actually have produced compacted rows, or this test
        # is validating empty files.
        self.assertTrue((self.usage_dir / "snapshots_15m.jsonl").exists()
                        or (self.usage_dir / "snapshots_1h.jsonl").exists())

    def test_second_compaction_pass_merges_without_breaking_the_shape(self):
        """A bucket receiving contributions across MORE THAN ONE compact() run
        is exactly what the persisted _sum/_n/_last_ts fields exist for."""
        now = 1_800_000_000.0
        (self.usage_dir / "snapshots.jsonl").write_text(
            "".join(json.dumps(r) + "\n" for r in self._raw_rows(20, now - 3 * 86400)))
        self.uc.compact(self.state_dir, now=now, quiet=True)
        # A second batch landing in the same 15-minute buckets.
        (self.usage_dir / "snapshots.jsonl").write_text(
            "".join(json.dumps(r) + "\n" for r in self._raw_rows(20, now - 3 * 86400 + 60)))
        self.uc.compact(self.state_dir, now=now, quiet=True)
        text = (self.usage_dir / "snapshots_15m.jsonl").read_text()
        self.assertEqual(contracts.validate_jsonl("snapshots.bucket", text), [])
        rows = [json.loads(ln) for ln in text.splitlines() if ln.strip()]
        self.assertTrue(any(r["n"] > 1 for r in rows), "expected merged buckets")

    def test_plan_fit_consumes_compactor_output(self):
        """Cross-writer round-trip: the compactor's bucket rows must be
        readable by plan_fit's snapshot merger, since those two are the pair
        most likely to drift apart (different files, same format)."""
        import plan_fit
        now = 1_800_000_000.0
        (self.usage_dir / "snapshots.jsonl").write_text(
            "".join(json.dumps(r) + "\n" for r in self._raw_rows(40, now - 3 * 86400)))
        (self.usage_dir / "tokens_hourly.json").write_text(json.dumps(_tokens_hourly({})))
        self.uc.compact(self.state_dir, now=now, quiet=True)
        report = plan_fit.compute(
            self.state_dir, datetime.fromtimestamp(now, tz=timezone.utc))
        self.assertEqual(contracts.validate("plan_fit", report), [])
        self.assertIsNotNone(report["utilization_observed"]["five_hour"]["peak_pct"],
                             "compacted buckets must still yield a peak")


if __name__ == "__main__":
    unittest.main(verbosity=2)
