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


if __name__ == "__main__":
    unittest.main()
