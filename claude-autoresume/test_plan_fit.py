#!/usr/bin/env python3
"""Stdlib unittest suite for plan_fit.py, run against synthetic store
fixtures in temp directories (never the real ~/.claude-autoresume store,
and never the network — refresh_pricing() is never called here).

Run with:
    python3 -m unittest test_plan_fit
"""

from __future__ import annotations

import json
import sys
import tempfile
import unittest
from datetime import datetime, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import plan_fit


def _write_json(path: Path, data) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(data))


def _write_jsonl(path: Path, rows: list) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("\n".join(json.dumps(r) for r in rows) + ("\n" if rows else ""))


def _tokens_hourly(hours: dict) -> dict:
    return {"version": 1, "hours": hours, "progress": {}}


class TempStateDirTestCase(unittest.TestCase):
    def setUp(self):
        self._tmpdir = tempfile.TemporaryDirectory()
        self.state_dir = Path(self._tmpdir.name)
        self.usage_dir = self.state_dir / "usage"
        self.usage_dir.mkdir(parents=True, exist_ok=True)

    def tearDown(self):
        self._tmpdir.cleanup()


# ---------------------------------------------------------------------------
# Moving averages
# ---------------------------------------------------------------------------

class MovingAverageTests(TempStateDirTestCase):
    def test_partially_filled_windows(self):
        # $10/day of opus cost on three consecutive days ending "today".
        # input_tok * 5 / 1e6 == 10.0  ->  input_tok == 2,000,000
        hours = {
            "2026-07-16T09": {"code_cli": {"claude-opus-4-5-x": {"input": 2_000_000, "output": 0}}},
            "2026-07-17T09": {"code_cli": {"claude-opus-4-5-x": {"input": 2_000_000, "output": 0}}},
            "2026-07-18T09": {"code_cli": {"claude-opus-4-5-x": {"input": 2_000_000, "output": 0}}},
        }
        _write_json(self.usage_dir / "tokens_hourly.json", _tokens_hourly(hours))

        now = datetime(2026, 7, 18, 12, 0, tzinfo=timezone.utc)
        result = plan_fit.compute(self.state_dir, now)
        ma = result["moving_averages"]

        self.assertEqual(ma["1d"]["days_covered"], 1)
        self.assertEqual(ma["1d"]["window_days"], 1)
        self.assertAlmostEqual(ma["1d"]["value_usd_per_day"], 10.0, places=2)

        self.assertEqual(ma["7d"]["days_covered"], 3)
        self.assertEqual(ma["7d"]["window_days"], 7)
        self.assertAlmostEqual(ma["7d"]["value_usd_per_day"], 10.0, places=2)

        self.assertEqual(ma["30d"]["days_covered"], 3)
        self.assertEqual(ma["90d"]["days_covered"], 3)
        self.assertAlmostEqual(ma["30d"]["value_usd_per_day"], 10.0, places=2)
        self.assertAlmostEqual(ma["90d"]["value_usd_per_day"], 10.0, places=2)

        # Monthly run-rate should use the 7d MA as its basis.
        rr = result["monthly_run_rate"]
        self.assertEqual(rr["basis"], "7d")
        self.assertAlmostEqual(rr["value_usd_per_month"], 10.0 * 30.44, places=2)

    def test_zero_days_covered_gives_null_value(self):
        _write_json(self.usage_dir / "tokens_hourly.json", _tokens_hourly({}))
        now = datetime(2026, 7, 18, 12, 0, tzinfo=timezone.utc)
        result = plan_fit.compute(self.state_dir, now)
        for window in ("1d", "7d", "30d", "90d"):
            ma = result["moving_averages"][window]
            self.assertEqual(ma["days_covered"], 0)
            self.assertIsNone(ma["value_usd_per_day"])
        self.assertIsNone(result["monthly_run_rate"]["value_usd_per_month"])
        self.assertIsNone(result["monthly_run_rate"]["basis"])


# ---------------------------------------------------------------------------
# Cost peaks: 1h and rolling 5h
# ---------------------------------------------------------------------------

class CostPeakTests(TempStateDirTestCase):
    def test_peak_1h_and_rolling_5h_detection(self):
        # opus cost per hour = input_tok * 5 / 1e6. Costs: 1,2,3,4,5,1 across
        # hours 00..05 on the same day -> rolling 5h window peaks at the
        # window ending hour 04 (1+2+3+4+5=15), not hour 05 (2+3+4+5+1=15,
        # a tie that shouldn't overtake the earlier max).
        costs = [1.0, 2.0, 3.0, 4.0, 5.0, 1.0]
        hours = {}
        for h, cost in enumerate(costs):
            input_tok = int(cost * 1_000_000 / 5)
            hours[f"2026-07-01T{h:02d}"] = {"code_cli": {"claude-opus-4-5-x": {"input": input_tok, "output": 0}}}
        _write_json(self.usage_dir / "tokens_hourly.json", _tokens_hourly(hours))

        now = datetime(2026, 7, 1, 23, 0, tzinfo=timezone.utc)
        result = plan_fit.compute(self.state_dir, now)
        peaks = result["cost_peaks"]

        self.assertAlmostEqual(peaks["one_hour"]["value_usd"], 5.0, places=2)
        self.assertEqual(peaks["one_hour"]["at"], "2026-07-01T04:00:00+00:00")

        self.assertAlmostEqual(peaks["rolling_five_hour"]["value_usd"], 15.0, places=2)
        self.assertEqual(peaks["rolling_five_hour"]["at"], "2026-07-01T04:00:00+00:00")

    def test_no_hourly_data_gives_null_peaks(self):
        _write_json(self.usage_dir / "tokens_hourly.json", _tokens_hourly({}))
        now = datetime(2026, 7, 18, 12, 0, tzinfo=timezone.utc)
        result = plan_fit.compute(self.state_dir, now)
        peaks = result["cost_peaks"]
        self.assertIsNone(peaks["one_hour"]["value_usd"])
        self.assertIsNone(peaks["rolling_five_hour"]["value_usd"])


# ---------------------------------------------------------------------------
# Utilization peaks + tier rescaling
# ---------------------------------------------------------------------------

class TierRescalingTests(TempStateDirTestCase):
    def test_peak_and_average_rescale_linearly_by_tier(self):
        rows = [{
            "ts_start": "2026-07-01T00:00:00+00:00",
            "n": 10,
            "five_hour": {"min": 10, "max": 40, "avg": 25, "last": 30},
            "seven_day": {"min": 5, "max": 20, "avg": 15, "last": 18},
        }]
        _write_jsonl(self.usage_dir / "snapshots_1h.jsonl", rows)
        _write_json(self.usage_dir / "tokens_hourly.json", _tokens_hourly({}))

        now = datetime(2026, 7, 18, 12, 0, tzinfo=timezone.utc)
        result = plan_fit.compute(self.state_dir, now)

        observed = result["utilization_observed"]
        self.assertAlmostEqual(observed["five_hour"]["peak_pct"], 40.0, places=1)
        self.assertAlmostEqual(observed["five_hour"]["avg_pct"], 25.0, places=1)
        self.assertAlmostEqual(observed["seven_day"]["peak_pct"], 20.0, places=1)
        self.assertAlmostEqual(observed["seven_day"]["avg_pct"], 15.0, places=1)

        proj = result["tier_projection"]
        # pro: factor 20/1=20
        self.assertAlmostEqual(proj["pro"]["peak_five_hour_pct"], 800.0, places=1)
        self.assertAlmostEqual(proj["pro"]["avg_five_hour_pct"], 500.0, places=1)
        self.assertTrue(proj["pro"]["would_hit_cap"])
        # max_5x: factor 20/5=4
        self.assertAlmostEqual(proj["max_5x"]["peak_five_hour_pct"], 160.0, places=1)
        self.assertAlmostEqual(proj["max_5x"]["avg_five_hour_pct"], 100.0, places=1)
        self.assertTrue(proj["max_5x"]["would_hit_cap"])
        # max_20x: factor 20/20=1, matches observed exactly
        self.assertAlmostEqual(proj["max_20x"]["peak_five_hour_pct"], 40.0, places=1)
        self.assertAlmostEqual(proj["max_20x"]["peak_seven_day_pct"], 20.0, places=1)
        self.assertFalse(proj["max_20x"]["would_hit_cap"])

        verdict = result["verdict"]
        self.assertFalse(verdict["plans"]["pro"]["viable"])
        self.assertFalse(verdict["plans"]["max_5x"]["viable"])
        self.assertTrue(verdict["plans"]["max_20x"]["viable"])

    def test_projection_baseline_follows_configured_plan(self):
        # Observed percentages are relative to the CONFIGURED plan's caps, not
        # a hardcoded Max-20x baseline: 80% observed on Pro is 80% of Pro's
        # cap, which projects to 16%/4% on Max 5x/20x (factor = 1/mult), and
        # the identity projection is the pro row itself.
        rows = [{
            "ts_start": "2026-07-01T00:00:00+00:00",
            "n": 10,
            "five_hour": {"min": 10, "max": 80, "avg": 40, "last": 50},
            "seven_day": {"min": 5, "max": 60, "avg": 30, "last": 40},
        }]
        _write_jsonl(self.usage_dir / "snapshots_1h.jsonl", rows)
        _write_json(self.usage_dir / "tokens_hourly.json", _tokens_hourly({}))
        _write_json(self.state_dir / "config.json",
                    _config(account={"type": "max", "plan": "pro"}))

        now = datetime(2026, 7, 18, 12, 0, tzinfo=timezone.utc)
        result = plan_fit.compute(self.state_dir, now)

        proj = result["tier_projection"]
        # pro: identity (factor 1/1)
        self.assertAlmostEqual(proj["pro"]["peak_five_hour_pct"], 80.0, places=1)
        self.assertFalse(proj["pro"]["would_hit_cap"])
        # max_5x: factor 1/5
        self.assertAlmostEqual(proj["max_5x"]["peak_five_hour_pct"], 16.0, places=1)
        # max_20x: factor 1/20
        self.assertAlmostEqual(proj["max_20x"]["peak_five_hour_pct"], 4.0, places=1)
        # Pro fits, so the verdict should call the current plan sufficient.
        self.assertTrue(result["verdict"]["plans"]["pro"]["viable"])
        self.assertIn("current plan", result["verdict"]["recommendation"])

    def test_projection_unknown_plan_falls_back_to_default_baseline(self):
        # An unrecognized plan string (hand-edited config) must not crash the
        # analytics path — it degrades to the Max-20x default baseline.
        observed = {
            "five_hour": {"peak_pct": 40.0, "avg_pct": 25.0},
            "seven_day": {"peak_pct": 20.0, "avg_pct": 15.0},
        }
        proj = plan_fit._tier_projection(observed, current_plan="enterprise_9000")
        self.assertAlmostEqual(proj["pro"]["peak_five_hour_pct"], 800.0, places=1)
        self.assertAlmostEqual(proj["max_20x"]["peak_five_hour_pct"], 40.0, places=1)

    def test_merge_prefers_raw_over_overlapping_bucket(self):
        # Same timestamp appears in both the raw store and an hourly bucket;
        # the bucket's (much higher) max/avg must NOT be double-counted
        # since raw is finer-grained and covers that instant already.
        raw_rows = [{
            "ts": "2026-07-18T10:00:00+00:00",
            "five_hour": {"utilization": 50},
            "seven_day": {"utilization": 10},
        }]
        bucket_rows = [{
            "ts_start": "2026-07-18T10:00:00+00:00",
            "n": 5,
            "five_hour": {"min": 0, "max": 90, "avg": 45, "last": 50},
            "seven_day": {"min": 0, "max": 20, "avg": 9, "last": 10},
        }]
        _write_jsonl(self.usage_dir / "snapshots.jsonl", raw_rows)
        _write_jsonl(self.usage_dir / "snapshots_1h.jsonl", bucket_rows)
        _write_json(self.usage_dir / "tokens_hourly.json", _tokens_hourly({}))

        now = datetime(2026, 7, 18, 12, 0, tzinfo=timezone.utc)
        result = plan_fit.compute(self.state_dir, now)
        observed = result["utilization_observed"]
        # Only the raw point should count: peak == avg == 50, not 90/45.
        self.assertAlmostEqual(observed["five_hour"]["peak_pct"], 50.0, places=1)
        self.assertAlmostEqual(observed["five_hour"]["avg_pct"], 50.0, places=1)

    def test_no_snapshots_gives_null_utilization_and_warning(self):
        _write_json(self.usage_dir / "tokens_hourly.json", _tokens_hourly({}))
        now = datetime(2026, 7, 18, 12, 0, tzinfo=timezone.utc)
        result = plan_fit.compute(self.state_dir, now)
        observed = result["utilization_observed"]
        self.assertIsNone(observed["five_hour"]["peak_pct"])
        self.assertIsNone(observed["seven_day"]["peak_pct"])
        self.assertTrue(any("utilization snapshots" in w for w in result["warnings"]))


# ---------------------------------------------------------------------------
# Cost math per model, including cache rates and date-based Sonnet 5 pricing
# ---------------------------------------------------------------------------

class CostMathTests(TempStateDirTestCase):
    def test_per_model_pricing_including_cache_and_unknown(self):
        hours = {
            # Before the Sonnet 5 intro cutoff -> $2/$10 rates apply.
            "2026-07-10T05": {
                "code_cli": {
                    "claude-sonnet-5-20260601": {
                        "input": 1_000_000, "output": 500_000,
                        "cache_write": 200_000, "cache_read": 100_000,
                    },
                    "claude-opus-4-5-20260101": {"input": 100_000, "output": 50_000},
                    "claude-haiku-4-5-20260101": {"input": 100_000, "output": 50_000},
                    "claude-super-9000": {"input": 100_000, "output": 50_000},
                    "synthetic": {"input": 999_999, "output": 999_999},
                    "<synthetic>": {"input": 999_999, "output": 999_999},
                    "": {"input": 999_999, "output": 999_999},
                },
            },
        }
        _write_json(self.usage_dir / "tokens_hourly.json", _tokens_hourly(hours))

        now = datetime(2026, 7, 18, 12, 0, tzinfo=timezone.utc)
        result = plan_fit.compute(self.state_dir, now)
        by_model = result["totals"]["by_model"]

        # sonnet-5, intro rates: (1e6*2 + 5e5*10 + 2e5*(2*2) + 1e5*(2*0.1)) / 1e6 = 7.82
        self.assertAlmostEqual(by_model["claude-sonnet-5-20260601"]["cost_usd"], 7.82, places=2)
        # opus-4-5: (1e5*5 + 5e4*25) / 1e6 = 1.75
        self.assertAlmostEqual(by_model["claude-opus-4-5-20260101"]["cost_usd"], 1.75, places=2)
        # haiku-4-5: (1e5*1 + 5e4*5) / 1e6 = 0.35
        self.assertAlmostEqual(by_model["claude-haiku-4-5-20260101"]["cost_usd"], 0.35, places=2)
        # unknown model -> Sonnet 5 STANDARD rates ($3/$15) regardless of date:
        # (1e5*3 + 5e4*15) / 1e6 = 1.05
        self.assertAlmostEqual(by_model["claude-super-9000"]["cost_usd"], 1.05, places=2)

        # synthetic / empty ids never show up in totals at all.
        self.assertNotIn("synthetic", by_model)
        self.assertNotIn("<synthetic>", by_model)
        self.assertNotIn("", by_model)

        # Unknown model produced a warning; sentinel ids did not.
        self.assertTrue(any("claude-super-9000" in w for w in result["warnings"]))
        self.assertFalse(any("synthetic" in w for w in result["warnings"]))

    def test_sonnet5_standard_pricing_after_cutoff(self):
        hours = {
            "2026-09-05T05": {
                "code_cli": {
                    "claude-sonnet-5-20260901": {"input": 1_000_000, "output": 0},
                },
            },
        }
        _write_json(self.usage_dir / "tokens_hourly.json", _tokens_hourly(hours))
        now = datetime(2026, 9, 6, 0, 0, tzinfo=timezone.utc)
        result = plan_fit.compute(self.state_dir, now)
        # Standard rate is $3/Mtok input -> 1e6 tok * 3 / 1e6 = 3.0
        self.assertAlmostEqual(
            result["totals"]["by_model"]["claude-sonnet-5-20260901"]["cost_usd"], 3.0, places=2
        )


# ---------------------------------------------------------------------------
# Empty / missing stores
# ---------------------------------------------------------------------------

class EmptyStoreTests(TempStateDirTestCase):
    def test_completely_missing_stores_do_not_raise(self):
        # Nothing written at all -- not even the usage/ dir contents.
        now = datetime(2026, 7, 18, 12, 0, tzinfo=timezone.utc)
        result = plan_fit.compute(self.state_dir, now)

        self.assertEqual(result["current_plan"], "max_20x")
        for window in ("1d", "7d", "30d", "90d"):
            self.assertIsNone(result["moving_averages"][window]["value_usd_per_day"])
        self.assertIsNone(result["monthly_run_rate"]["value_usd_per_month"])
        self.assertIsNone(result["cost_peaks"]["one_hour"]["value_usd"])
        self.assertIsNone(result["utilization_observed"]["five_hour"]["peak_pct"])
        self.assertEqual(result["totals"]["by_model"], {})
        self.assertEqual(result["totals"]["all_models_cost_usd"], 0.0)
        self.assertIn("0/90 days collected", result["verdict"]["data_maturity"])
        self.assertTrue(any("tokens_hourly.json" in w for w in result["warnings"]))
        self.assertTrue(any("utilization snapshots" in w for w in result["warnings"]))

    def test_malformed_tokens_hourly_json_does_not_raise(self):
        (self.usage_dir / "tokens_hourly.json").write_text("{not valid json")
        now = datetime(2026, 7, 18, 12, 0, tzinfo=timezone.utc)
        result = plan_fit.compute(self.state_dir, now)
        self.assertEqual(result["totals"]["by_model"], {})

    def test_write_plan_fit_creates_file(self):
        _write_json(self.usage_dir / "tokens_hourly.json", _tokens_hourly({}))
        now = datetime(2026, 7, 18, 12, 0, tzinfo=timezone.utc)
        plan_fit.write_plan_fit(self.state_dir, now)
        out_path = self.usage_dir / "plan_fit.json"
        self.assertTrue(out_path.exists())
        data = json.loads(out_path.read_text())
        self.assertEqual(data["current_plan"], "max_20x")


# ---------------------------------------------------------------------------
# Pricing resolution chain: override > fetched cache > bundled defaults
# ---------------------------------------------------------------------------

class PricingResolutionChainTests(TempStateDirTestCase):
    def _hours_with_opus(self, input_tok=1_000_000):
        return _tokens_hourly({
            "2026-07-10T05": {"code_cli": {"claude-opus-4-5-x": {"input": input_tok, "output": 0}}},
        })

    def test_override_beats_cache_beats_bundled(self):
        _write_json(self.usage_dir / "tokens_hourly.json", self._hours_with_opus())
        _write_json(self.usage_dir / "pricing_cache.json", {
            "fetched_at": "2026-07-17T00:00:00+00:00",
            "source": "https://example.invalid/pricing.json",
            "models": {"claude-opus-4-5": {"input_per_mtok": 999.0, "output_per_mtok": 999.0}},
        })
        _write_json(self.usage_dir / "pricing_override.json", {
            "claude-opus-4-5": {
                "input_per_mtok": 1.0, "output_per_mtok": 2.0,
                "cache_write_multiplier": 3.0, "cache_read_multiplier": 0.05,
            },
        })

        now = datetime(2026, 7, 18, 12, 0, tzinfo=timezone.utc)
        result = plan_fit.compute(self.state_dir, now)
        model = result["totals"]["by_model"]["claude-opus-4-5-x"]
        self.assertAlmostEqual(model["cost_usd"], 1.0, places=2)  # 1e6 * 1.0 / 1e6
        self.assertEqual(model["pricing_sources"], ["override"])
        self.assertTrue(result["pricing_meta"]["override_active"])

    def test_cache_beats_bundled_when_no_override(self):
        _write_json(self.usage_dir / "tokens_hourly.json", self._hours_with_opus())
        now = datetime(2026, 7, 18, 12, 0, tzinfo=timezone.utc)
        _write_json(self.usage_dir / "pricing_cache.json", {
            "fetched_at": now.isoformat(),
            "source": "https://example.invalid/pricing.json",
            "models": {"claude-opus-4-5": {"input_per_mtok": 7.0, "output_per_mtok": 35.0}},
        })

        result = plan_fit.compute(self.state_dir, now)
        model = result["totals"]["by_model"]["claude-opus-4-5-x"]
        # Cache rate (7.0), not the bundled default (5.0).
        self.assertAlmostEqual(model["cost_usd"], 7.0, places=2)
        self.assertEqual(model["pricing_sources"], ["litellm_cache"])
        self.assertEqual(result["pricing_meta"]["sources_used"], ["litellm_cache"])

    def test_falls_back_to_bundled_when_nothing_else_present(self):
        _write_json(self.usage_dir / "tokens_hourly.json", self._hours_with_opus())
        now = datetime(2026, 7, 18, 12, 0, tzinfo=timezone.utc)
        result = plan_fit.compute(self.state_dir, now)
        model = result["totals"]["by_model"]["claude-opus-4-5-x"]
        self.assertAlmostEqual(model["cost_usd"], 5.0, places=2)  # bundled opus-4-5 input rate
        self.assertEqual(model["pricing_sources"], ["bundled_defaults"])

    def test_malformed_cache_file_is_ignored_falls_back_to_bundled(self):
        _write_json(self.usage_dir / "tokens_hourly.json", self._hours_with_opus())
        (self.usage_dir / "pricing_cache.json").write_text("{not valid json at all")
        now = datetime(2026, 7, 18, 12, 0, tzinfo=timezone.utc)
        result = plan_fit.compute(self.state_dir, now)
        model = result["totals"]["by_model"]["claude-opus-4-5-x"]
        self.assertAlmostEqual(model["cost_usd"], 5.0, places=2)
        self.assertEqual(model["pricing_sources"], ["bundled_defaults"])

    def test_cache_with_no_valid_models_is_treated_as_absent(self):
        _write_json(self.usage_dir / "tokens_hourly.json", self._hours_with_opus())
        _write_json(self.usage_dir / "pricing_cache.json", {
            "fetched_at": "2026-07-17T00:00:00+00:00",
            "models": {"claude-opus-4-5": {"input_per_mtok": "not-a-number"}},
        })
        now = datetime(2026, 7, 18, 12, 0, tzinfo=timezone.utc)
        result = plan_fit.compute(self.state_dir, now)
        model = result["totals"]["by_model"]["claude-opus-4-5-x"]
        self.assertAlmostEqual(model["cost_usd"], 5.0, places=2)
        self.assertFalse(result["pricing_meta"]["cache_present"])

    def test_stale_bundled_only_pricing_warns(self):
        _write_json(self.usage_dir / "tokens_hourly.json", self._hours_with_opus())
        # 61 days past BUNDLED_PRICING_AS_OF (2026-07-18) with no override/cache.
        now = datetime(2026, 9, 17, 12, 0, tzinfo=timezone.utc)
        result = plan_fit.compute(self.state_dir, now)
        self.assertTrue(any("bundled defaults" in w and "days old" in w for w in result["warnings"]))

    def test_fresh_bundled_only_pricing_does_not_warn(self):
        _write_json(self.usage_dir / "tokens_hourly.json", self._hours_with_opus())
        now = datetime(2026, 7, 20, 12, 0, tzinfo=timezone.utc)
        result = plan_fit.compute(self.state_dir, now)
        self.assertFalse(any("bundled defaults" in w and "days old" in w for w in result["warnings"]))


class LoadPricingHelperTests(TempStateDirTestCase):
    def test_load_pricing_override_missing_file(self):
        self.assertEqual(plan_fit.load_pricing_override(self.usage_dir), {})

    def test_load_pricing_cache_missing_file(self):
        self.assertIsNone(plan_fit.load_pricing_cache(self.usage_dir))

    def test_load_pricing_override_skips_bad_entries(self):
        _write_json(self.usage_dir / "pricing_override.json", {
            "claude-good": {"input_per_mtok": 1.0, "output_per_mtok": 2.0},
            "claude-bad": {"input_per_mtok": "nope"},
            "claude-also-bad": "not-a-dict",
        })
        table = plan_fit.load_pricing_override(self.usage_dir)
        self.assertIn("claude-good", table)
        self.assertNotIn("claude-bad", table)
        self.assertNotIn("claude-also-bad", table)


class LiteLLMConversionTests(unittest.TestCase):
    """Pure-function tests for the per-token -> per-Mtok conversion used by
    refresh_pricing(). No network involved."""

    def test_converts_per_token_costs_to_per_mtok(self):
        entry = {
            "input_cost_per_token": 0.000003,
            "output_cost_per_token": 0.000015,
            "cache_creation_input_token_cost": 0.000006,
            "cache_read_input_token_cost": 0.0000003,
            "litellm_provider": "anthropic",
        }
        rate = plan_fit._litellm_entry_to_rate(entry)
        self.assertIsNotNone(rate)
        self.assertAlmostEqual(rate["input_per_mtok"], 3.0, places=6)
        self.assertAlmostEqual(rate["output_per_mtok"], 15.0, places=6)
        self.assertAlmostEqual(rate["cache_write_multiplier"], 2.0, places=6)
        self.assertAlmostEqual(rate["cache_read_multiplier"], 0.1, places=6)

    def test_missing_cache_costs_fall_back_to_defaults(self):
        entry = {"input_cost_per_token": 0.000003, "output_cost_per_token": 0.000015}
        rate = plan_fit._litellm_entry_to_rate(entry)
        self.assertIsNotNone(rate)
        self.assertAlmostEqual(rate["cache_write_multiplier"], plan_fit.DEFAULT_CACHE_WRITE_MULTIPLIER)
        self.assertAlmostEqual(rate["cache_read_multiplier"], plan_fit.DEFAULT_CACHE_READ_MULTIPLIER)

    def test_missing_required_fields_returns_none(self):
        self.assertIsNone(plan_fit._litellm_entry_to_rate({"output_cost_per_token": 0.000015}))
        self.assertIsNone(plan_fit._litellm_entry_to_rate({}))

    def test_zero_cost_entry_returns_none(self):
        self.assertIsNone(plan_fit._litellm_entry_to_rate({
            "input_cost_per_token": 0.0, "output_cost_per_token": 0.0,
        }))


# ---------------------------------------------------------------------------
# Account + budget blocks (C1/C2)
# ---------------------------------------------------------------------------

def _config(account=None, budget=None) -> dict:
    cfg = {"version": 1}
    if account is not None:
        cfg["account"] = account
    if budget is not None:
        cfg["budget"] = budget
    return cfg


class AccountBlockTests(TempStateDirTestCase):
    def test_default_account_block_when_no_config(self):
        _write_json(self.usage_dir / "tokens_hourly.json", _tokens_hourly({}))
        now = datetime(2026, 7, 18, 12, 0, tzinfo=timezone.utc)
        result = plan_fit.compute(self.state_dir, now)
        # No config.json -> defaults: max / max_20x, byte-compatible current_plan.
        self.assertEqual(result["current_plan"], "max_20x")
        self.assertEqual(result["account"], {"type": "max", "plan": "max_20x"})
        # budget block always present; both windows null when unconfigured.
        self.assertEqual(result["budget"], {"weekly": None, "monthly": None})

    def test_account_type_and_plan_flow_from_config(self):
        _write_json(self.usage_dir / "tokens_hourly.json", _tokens_hourly({}))
        _write_json(self.state_dir / "config.json",
                    _config(account={"type": "api", "plan": "max_5x"}))
        now = datetime(2026, 7, 18, 12, 0, tzinfo=timezone.utc)
        result = plan_fit.compute(self.state_dir, now)
        self.assertEqual(result["account"], {"type": "api", "plan": "max_5x"})
        self.assertEqual(result["current_plan"], "max_5x")

    def test_verdict_uses_config_plan_for_current_match(self):
        # Utilization that makes only max_20x viable; with current_plan=max_20x
        # the recommendation phrases it as "Your current plan".
        rows = [{
            "ts_start": "2026-07-01T00:00:00+00:00", "n": 10,
            "five_hour": {"min": 10, "max": 40, "avg": 25, "last": 30},
            "seven_day": {"min": 5, "max": 20, "avg": 15, "last": 18},
        }]
        _write_jsonl(self.usage_dir / "snapshots_1h.jsonl", rows)
        _write_json(self.usage_dir / "tokens_hourly.json", _tokens_hourly({}))
        _write_json(self.state_dir / "config.json",
                    _config(account={"type": "max", "plan": "max_20x"}))
        now = datetime(2026, 7, 18, 12, 0, tzinfo=timezone.utc)
        result = plan_fit.compute(self.state_dir, now)
        self.assertIn("Your current plan", result["verdict"]["recommendation"])


class BudgetPeriodBoundsTests(unittest.TestCase):
    def test_monthly_bounds_utc(self):
        now = datetime(2026, 7, 19, 15, 0, tzinfo=timezone.utc)
        start, end = plan_fit._budget_period_bounds(now, "monthly", "monday", "utc")
        self.assertEqual(start, datetime(2026, 7, 1, tzinfo=timezone.utc))
        self.assertEqual(end, datetime(2026, 8, 1, tzinfo=timezone.utc))

    def test_monthly_bounds_december_wraps_year(self):
        now = datetime(2026, 12, 20, 8, 0, tzinfo=timezone.utc)
        start, end = plan_fit._budget_period_bounds(now, "monthly", "monday", "utc")
        self.assertEqual(start, datetime(2026, 12, 1, tzinfo=timezone.utc))
        self.assertEqual(end, datetime(2027, 1, 1, tzinfo=timezone.utc))

    def test_weekly_bounds_monday_start_utc(self):
        # 2026-07-19 is a Sunday; week starting Monday -> Mon 2026-07-13.
        now = datetime(2026, 7, 19, 23, 0, tzinfo=timezone.utc)
        start, end = plan_fit._budget_period_bounds(now, "weekly", "monday", "utc")
        self.assertEqual(start, datetime(2026, 7, 13, tzinfo=timezone.utc))
        self.assertEqual(end, datetime(2026, 7, 20, tzinfo=timezone.utc))

    def test_weekly_bounds_sunday_start_utc(self):
        # 2026-07-19 is a Sunday; week starting Sunday -> that same Sunday.
        now = datetime(2026, 7, 19, 1, 0, tzinfo=timezone.utc)
        start, end = plan_fit._budget_period_bounds(now, "weekly", "sunday", "utc")
        self.assertEqual(start, datetime(2026, 7, 19, tzinfo=timezone.utc))
        self.assertEqual(end, datetime(2026, 7, 26, tzinfo=timezone.utc))

    def test_local_bounds_are_utc_aware_and_span_a_calendar_month(self):
        # tz "local": result is UTC-aware, exactly one month apart, and the
        # month-length matches a calendar month (28-31 days) regardless of the
        # runner's local zone / DST.
        now = datetime(2026, 3, 15, 12, 0, tzinfo=timezone.utc)
        start, end = plan_fit._budget_period_bounds(now, "monthly", "monday", "local")
        self.assertEqual(start.tzinfo, timezone.utc)
        self.assertEqual(end.tzinfo, timezone.utc)
        self.assertLess(start, now)
        self.assertLessEqual(now, end)
        span_days = (end - start).total_seconds() / 86400.0
        self.assertTrue(27.9 <= span_days <= 31.1, span_days)


class BudgetBlockTests(TempStateDirTestCase):
    # opus cost per hour = input_tok * 5 / 1e6, priced by the bundled chain.
    def _hour_cost(self, hour_key: str, cost_usd: float) -> dict:
        input_tok = int(cost_usd * 1_000_000 / 5)
        return {hour_key: {"code_cli": {"claude-opus-4-5-x": {"input": input_tok, "output": 0}}}}

    def _compute(self, hours, budget=None, account=None, now=None):
        _write_json(self.usage_dir / "tokens_hourly.json", _tokens_hourly(hours))
        if budget is not None or account is not None:
            _write_json(self.state_dir / "config.json", _config(account=account, budget=budget))
        return plan_fit.compute(self.state_dir, now)

    def test_none_budget_both_windows_null(self):
        result = self._compute({}, budget={"weekly_usd": None, "monthly_usd": None,
                                            "week_start": "monday", "timezone": "utc"},
                               now=datetime(2026, 7, 19, 12, 0, tzinfo=timezone.utc))
        self.assertIsNone(result["budget"]["weekly"])
        self.assertIsNone(result["budget"]["monthly"])

    def test_monthly_only_budget(self):
        # Two hours of $30 each inside July -> spent 60 against a $500 monthly.
        hours = {}
        hours.update(self._hour_cost("2026-07-05T09", 30.0))
        hours.update(self._hour_cost("2026-07-12T09", 30.0))
        result = self._compute(hours, budget={"weekly_usd": None, "monthly_usd": 500.0,
                                              "week_start": "monday", "timezone": "utc"},
                               now=datetime(2026, 7, 19, 12, 0, tzinfo=timezone.utc))
        self.assertIsNone(result["budget"]["weekly"])
        m = result["budget"]["monthly"]
        self.assertAlmostEqual(m["limit_usd"], 500.0, places=2)
        self.assertAlmostEqual(m["spent_usd"], 60.0, places=2)
        self.assertAlmostEqual(m["pct"], 12.0, places=1)
        self.assertEqual(m["period_start"], "2026-07-01T00:00:00+00:00")
        self.assertEqual(m["period_end"], "2026-08-01T00:00:00+00:00")
        self.assertFalse(m["includes_remote"])

    def test_weekly_only_budget(self):
        # now = Sun 2026-07-19; Monday-start week = Mon 07-13 .. Sun 07-19.
        # $10 on 07-14 (in week) + $10 on 07-10 (previous week, excluded).
        hours = {}
        hours.update(self._hour_cost("2026-07-14T09", 10.0))
        hours.update(self._hour_cost("2026-07-10T09", 10.0))
        result = self._compute(hours, budget={"weekly_usd": 200.0, "monthly_usd": None,
                                              "week_start": "monday", "timezone": "utc"},
                               now=datetime(2026, 7, 19, 12, 0, tzinfo=timezone.utc))
        self.assertIsNone(result["budget"]["monthly"])
        w = result["budget"]["weekly"]
        self.assertAlmostEqual(w["spent_usd"], 10.0, places=2)
        self.assertAlmostEqual(w["pct"], 5.0, places=1)
        self.assertEqual(w["period_start"], "2026-07-13T00:00:00+00:00")
        self.assertEqual(w["period_end"], "2026-07-20T00:00:00+00:00")

    def test_both_budgets_configured(self):
        hours = {}
        hours.update(self._hour_cost("2026-07-14T09", 40.0))
        result = self._compute(hours, budget={"weekly_usd": 200.0, "monthly_usd": 500.0,
                                              "week_start": "monday", "timezone": "utc"},
                               now=datetime(2026, 7, 19, 12, 0, tzinfo=timezone.utc))
        self.assertIsNotNone(result["budget"]["weekly"])
        self.assertIsNotNone(result["budget"]["monthly"])
        self.assertAlmostEqual(result["budget"]["weekly"]["spent_usd"], 40.0, places=2)
        self.assertAlmostEqual(result["budget"]["monthly"]["spent_usd"], 40.0, places=2)
        # Budget assumptions get appended once a budget is configured.
        self.assertTrue(any("Budget spend sums" in a for a in result["assumptions"]))
        self.assertTrue(any("2026-07-18" in a for a in result["assumptions"]))

    def test_budget_emitted_even_for_max_account(self):
        result = self._compute({}, account={"type": "max", "plan": "max_20x"},
                               budget={"weekly_usd": None, "monthly_usd": 100.0,
                                       "week_start": "monday", "timezone": "utc"},
                               now=datetime(2026, 7, 19, 12, 0, tzinfo=timezone.utc))
        self.assertEqual(result["account"]["type"], "max")
        self.assertIsNotNone(result["budget"]["monthly"])

    def test_projection_null_in_first_hour_of_period(self):
        # now is 30 min into the month -> less than an hour elapsed.
        hours = self._hour_cost("2026-07-01T00", 5.0)
        result = self._compute(hours, budget={"weekly_usd": None, "monthly_usd": 500.0,
                                              "week_start": "monday", "timezone": "utc"},
                               now=datetime(2026, 7, 1, 0, 30, tzinfo=timezone.utc))
        m = result["budget"]["monthly"]
        self.assertIsNone(m["projected_usd"])
        self.assertIsNone(m["projected_pct"])
        self.assertAlmostEqual(m["spent_usd"], 5.0, places=2)

    def test_projection_present_after_first_hour(self):
        # Halfway through a 31-day month with $100 spent -> ~$200 projected.
        hours = self._hour_cost("2026-07-05T00", 100.0)
        # 2026-07-16 12:00 is ~ the midpoint of July (31 days).
        result = self._compute(hours, budget={"weekly_usd": None, "monthly_usd": 1000.0,
                                              "week_start": "monday", "timezone": "utc"},
                               now=datetime(2026, 7, 16, 12, 0, tzinfo=timezone.utc))
        m = result["budget"]["monthly"]
        self.assertAlmostEqual(m["spent_usd"], 100.0, places=2)
        self.assertIsNotNone(m["projected_usd"])
        # Midpoint -> projection roughly doubles spend.
        self.assertTrue(180.0 <= m["projected_usd"] <= 220.0, m["projected_usd"])
        self.assertAlmostEqual(m["projected_pct"], m["projected_usd"] / 1000.0 * 100.0, places=1)

    def test_spent_zero_on_empty_hours(self):
        result = self._compute({}, budget={"weekly_usd": 50.0, "monthly_usd": 500.0,
                                            "week_start": "monday", "timezone": "utc"},
                               now=datetime(2026, 7, 16, 12, 0, tzinfo=timezone.utc))
        self.assertEqual(result["budget"]["weekly"]["spent_usd"], 0.0)
        self.assertEqual(result["budget"]["monthly"]["spent_usd"], 0.0)
        self.assertEqual(result["budget"]["weekly"]["pct"], 0.0)

    def test_month_boundary_excludes_prior_month_spend(self):
        # $500 spent on the last day of June, $20 on the first day of July.
        # A July monthly budget must see only the $20 (spend >= period start).
        hours = {}
        hours.update(self._hour_cost("2026-06-30T23", 500.0))
        hours.update(self._hour_cost("2026-07-01T10", 20.0))
        result = self._compute(hours, budget={"weekly_usd": None, "monthly_usd": 1000.0,
                                              "week_start": "monday", "timezone": "utc"},
                               now=datetime(2026, 7, 3, 12, 0, tzinfo=timezone.utc))
        m = result["budget"]["monthly"]
        self.assertAlmostEqual(m["spent_usd"], 20.0, places=2)
        self.assertEqual(m["period_start"], "2026-07-01T00:00:00+00:00")


# ---------------------------------------------------------------------------
# Remote usage merge (WS-6)
# ---------------------------------------------------------------------------

class RemoteUsageMergeTests(TempStateDirTestCase):
    # opus cost per hour = input_tok * 5 / 1e6, priced by the bundled chain.
    def _tok_for(self, cost_usd: float) -> int:
        return int(cost_usd * 1_000_000 / 5)

    def _local_hours(self, hour_key: str, cost_usd: float) -> dict:
        return {hour_key: {"code_cli": {"claude-opus-4-5-x": {"input": self._tok_for(cost_usd), "output": 0}}}}

    def _remote_store(self, hours: dict) -> dict:
        return {"version": 1, "hours": hours, "progress": {}}

    def _write_remote(self, host: str, hours: dict) -> Path:
        path = self.usage_dir / "remote" / f"{host}_tokens_hourly.json"
        _write_json(path, self._remote_store(hours))
        return path

    def _remote_host_cfg(self, name, enabled=True, collect_usage=True):
        return {"name": name, "ssh": f"sam@{name}", "enabled": enabled, "collect_usage": collect_usage}

    def _compute(self, local_hours, remote_hosts=None, budget=None, now=None):
        _write_json(self.usage_dir / "tokens_hourly.json", _tokens_hourly(local_hours))
        cfg = _config(budget=budget)
        if remote_hosts is not None:
            cfg["remote_hosts"] = remote_hosts
        _write_json(self.state_dir / "config.json", cfg)
        return plan_fit.compute(self.state_dir, now or datetime(2026, 7, 16, 12, 0, tzinfo=timezone.utc))

    def test_two_host_summed_costs_and_at_host_surfaces(self):
        # Local $10, hostA $20, hostB $30, all in the same July hour bucket.
        local = self._local_hours("2026-07-14T09", 10.0)
        self._write_remote("hosta", {"2026-07-14T09": {"code_cli": {"claude-opus-4-5-x": {"input": self._tok_for(20.0), "output": 0}}}})
        self._write_remote("hostb", {"2026-07-14T09": {"code_cli": {"claude-opus-4-5-x": {"input": self._tok_for(30.0), "output": 0}}}})
        hosts = [self._remote_host_cfg("hosta"), self._remote_host_cfg("hostb")]
        result = self._compute(local, remote_hosts=hosts,
                               budget={"weekly_usd": None, "monthly_usd": 500.0,
                                       "week_start": "monday", "timezone": "utc"})
        # Total cost = 10 + 20 + 30 = 60, summed across machines.
        self.assertAlmostEqual(result["totals"]["all_models_cost_usd"], 60.0, places=2)
        # Budget spend includes the remote spend.
        self.assertAlmostEqual(result["budget"]["monthly"]["spent_usd"], 60.0, places=2)
        # Per-host attribution visible via @host surface labels in the merged hours.
        hourly = result["cost_series"]["hourly"]
        self.assertAlmostEqual(hourly["2026-07-14T09:00:00+00:00"], 60.0, places=2)
        # Assumptions name each merged host with its store's fetch time.
        self.assertTrue(any("Remote host hosta usage last fetched" in a for a in result["assumptions"]))
        self.assertTrue(any("Remote host hostb usage last fetched" in a for a in result["assumptions"]))
        # Model-level total aggregates across all three machines' opus usage.
        self.assertAlmostEqual(result["totals"]["by_model"]["claude-opus-4-5-x"]["cost_usd"], 60.0, places=2)

    def test_at_host_surface_labels_present_in_merged_hours(self):
        local = self._local_hours("2026-07-14T09", 10.0)
        self._write_remote("devbox", {"2026-07-14T09": {"code_cli": {"claude-opus-4-5-x": {"input": self._tok_for(5.0), "output": 0}}}})
        stores = plan_fit.load_remote_tokens(self.usage_dir)
        merged = plan_fit._merge_remote_hours(_tokens_hourly(local)["hours"], stores)
        surfaces = merged["2026-07-14T09"]
        self.assertIn("code_cli", surfaces)           # local surface preserved
        self.assertIn("code_cli@devbox", surfaces)    # remote surface renamed with @host

    def test_includes_remote_true_when_merged(self):
        local = self._local_hours("2026-07-14T09", 10.0)
        self._write_remote("hosta", {"2026-07-14T09": {"code_cli": {"claude-opus-4-5-x": {"input": self._tok_for(20.0), "output": 0}}}})
        result = self._compute(local, remote_hosts=[self._remote_host_cfg("hosta")],
                               budget={"weekly_usd": 100.0, "monthly_usd": 500.0,
                                       "week_start": "monday", "timezone": "utc"})
        self.assertTrue(result["budget"]["weekly"]["includes_remote"])
        self.assertTrue(result["budget"]["monthly"]["includes_remote"])

    def test_includes_remote_false_without_remote_hosts(self):
        local = self._local_hours("2026-07-14T09", 10.0)
        result = self._compute(local, remote_hosts=None,
                               budget={"weekly_usd": None, "monthly_usd": 500.0,
                                       "week_start": "monday", "timezone": "utc"})
        self.assertFalse(result["budget"]["monthly"]["includes_remote"])
        # No remote assumptions/warnings when there are no remote hosts at all.
        self.assertFalse(any("Remote host" in a for a in result["assumptions"]))
        self.assertFalse(any("remote usage store" in w for w in result["warnings"]))

    def test_includes_remote_false_when_configured_host_store_missing(self):
        # Host is configured to collect usage but no store file exists yet.
        local = self._local_hours("2026-07-14T09", 10.0)
        result = self._compute(local, remote_hosts=[self._remote_host_cfg("ghost")],
                               budget={"weekly_usd": None, "monthly_usd": 500.0,
                                       "week_start": "monday", "timezone": "utc"})
        self.assertFalse(result["budget"]["monthly"]["includes_remote"])
        self.assertAlmostEqual(result["budget"]["monthly"]["spent_usd"], 10.0, places=2)
        self.assertTrue(any("ghost" in w and "no usage store" in w for w in result["warnings"]))

    def test_stale_store_warns_but_still_merges(self):
        local = self._local_hours("2026-07-14T09", 10.0)
        path = self._write_remote("hosta", {"2026-07-14T09": {"code_cli": {"claude-opus-4-5-x": {"input": self._tok_for(20.0), "output": 0}}}})
        # Backdate the store's mtime to 5 hours ago (> 3h stale threshold).
        import os
        old = datetime(2026, 7, 16, 7, 0, tzinfo=timezone.utc).timestamp()
        os.utime(path, (old, old))
        result = self._compute(local, remote_hosts=[self._remote_host_cfg("hosta")],
                               budget={"weekly_usd": None, "monthly_usd": 500.0,
                                       "week_start": "monday", "timezone": "utc"},
                               now=datetime(2026, 7, 16, 12, 0, tzinfo=timezone.utc))
        # Warned about staleness…
        self.assertTrue(any("hosta" in w and "stale" in w for w in result["warnings"]))
        # …but still merged (spend includes the stale host).
        self.assertAlmostEqual(result["budget"]["monthly"]["spent_usd"], 30.0, places=2)
        self.assertTrue(result["budget"]["monthly"]["includes_remote"])

    def test_orphan_file_ignored_with_warning(self):
        # A store exists on disk but the host is NOT enabled+collect_usage.
        local = self._local_hours("2026-07-14T09", 10.0)
        self._write_remote("oldhost", {"2026-07-14T09": {"code_cli": {"claude-opus-4-5-x": {"input": self._tok_for(99.0), "output": 0}}}})
        # Case 1: host absent from config entirely.
        result = self._compute(local, remote_hosts=[],
                               budget={"weekly_usd": None, "monthly_usd": 500.0,
                                       "week_start": "monday", "timezone": "utc"})
        self.assertAlmostEqual(result["budget"]["monthly"]["spent_usd"], 10.0, places=2)  # orphan NOT merged
        self.assertFalse(result["budget"]["monthly"]["includes_remote"])
        self.assertTrue(any("orphan" in w and "oldhost" in w for w in result["warnings"]))

    def test_disabled_host_store_not_merged(self):
        # Leftover file for a host that is present in config but disabled.
        local = self._local_hours("2026-07-14T09", 10.0)
        self._write_remote("devbox", {"2026-07-14T09": {"code_cli": {"claude-opus-4-5-x": {"input": self._tok_for(99.0), "output": 0}}}})
        result = self._compute(local, remote_hosts=[self._remote_host_cfg("devbox", enabled=False)],
                               budget={"weekly_usd": None, "monthly_usd": 500.0,
                                       "week_start": "monday", "timezone": "utc"})
        self.assertAlmostEqual(result["budget"]["monthly"]["spent_usd"], 10.0, places=2)
        self.assertFalse(result["budget"]["monthly"]["includes_remote"])
        self.assertTrue(any("orphan" in w and "devbox" in w for w in result["warnings"]))

    def test_collect_usage_false_host_store_not_merged(self):
        local = self._local_hours("2026-07-14T09", 10.0)
        self._write_remote("devbox", {"2026-07-14T09": {"code_cli": {"claude-opus-4-5-x": {"input": self._tok_for(99.0), "output": 0}}}})
        result = self._compute(local, remote_hosts=[self._remote_host_cfg("devbox", collect_usage=False)],
                               budget={"weekly_usd": None, "monthly_usd": 500.0,
                                       "week_start": "monday", "timezone": "utc"})
        self.assertAlmostEqual(result["budget"]["monthly"]["spent_usd"], 10.0, places=2)
        self.assertTrue(any("orphan" in w for w in result["warnings"]))

    def test_remote_cowork_surface_renamed_per_host(self):
        # Remote Macs can carry Cowork usage; it must rename cowork@<host>.
        local = self._local_hours("2026-07-14T09", 10.0)
        self._write_remote("macmini", {"2026-07-14T09": {"cowork": {"claude-opus-4-5-x": {"input": self._tok_for(7.0), "output": 0}}}})
        result = self._compute(local, remote_hosts=[self._remote_host_cfg("macmini")],
                               budget={"weekly_usd": None, "monthly_usd": 500.0,
                                       "week_start": "monday", "timezone": "utc"})
        self.assertAlmostEqual(result["budget"]["monthly"]["spent_usd"], 17.0, places=2)
        stores = plan_fit.load_remote_tokens(self.usage_dir)
        merged = plan_fit._merge_remote_hours(_tokens_hourly(local)["hours"], stores)
        self.assertIn("cowork@macmini", merged["2026-07-14T09"])

    def test_load_remote_tokens_skips_malformed_and_missing_dir(self):
        # No remote/ dir at all.
        self.assertEqual(plan_fit.load_remote_tokens(self.usage_dir), {})
        # Malformed file is skipped, well-formed one is loaded.
        (self.usage_dir / "remote").mkdir(parents=True, exist_ok=True)
        (self.usage_dir / "remote" / "bad_tokens_hourly.json").write_text("{not json")
        self._write_remote("good", {"2026-07-14T09": {"code_cli": {"claude-opus-4-5-x": {"input": 1, "output": 0}}}})
        stores = plan_fit.load_remote_tokens(self.usage_dir)
        self.assertIn("good", stores)
        self.assertNotIn("bad", stores)

    def test_remote_only_spend_when_no_local_usage(self):
        # No local usage at all; a remote host carries all the spend.
        self._write_remote("hosta", {"2026-07-14T09": {"code_cli": {"claude-opus-4-5-x": {"input": self._tok_for(25.0), "output": 0}}}})
        result = self._compute({}, remote_hosts=[self._remote_host_cfg("hosta")],
                               budget={"weekly_usd": None, "monthly_usd": 500.0,
                                       "week_start": "monday", "timezone": "utc"})
        self.assertAlmostEqual(result["budget"]["monthly"]["spent_usd"], 25.0, places=2)
        self.assertTrue(result["budget"]["monthly"]["includes_remote"])


if __name__ == "__main__":
    unittest.main()
