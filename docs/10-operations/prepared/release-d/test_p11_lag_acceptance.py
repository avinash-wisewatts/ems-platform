"""Fault-injection tests for p11_lag_acceptance.py (standard library only).

  python -I -m unittest discover -s docs/10-operations/prepared/release-d -p 'test_p11_lag_acceptance.py' -v

A synthetic 24-hour window: one sample every 30 s per stage, a healthy
sawtooth whose per-cycle peak is below target (normalized 306 s, routing
485 s, 1-minute tier 517 s, as measured on staging 2026-10-25). Faults are
injected as one cycle's peak for one stage.
"""

from __future__ import annotations

import datetime as dt
import importlib.util
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
EVALUATOR = HERE / "p11_lag_acceptance.py"
FMT = "%Y-%m-%d %H:%M:%S"
W0 = dt.datetime(2026, 10, 26, 0, 0, 0)
ROLES = {
    "run_normalization_job": 306,
    "run_energy_routing_job": 485,
    "run_environment_routing_job": 485,
    "run_energy_consumption_1min_job": 517,
}


def synthetic(peaks=None, drop=(), hours=24):
    """Rows for [W0, W0 + hours). peaks: {(role, cycle_index): peak_s}; drop: sample times to omit."""
    peaks = peaks or {}
    rows = []
    for k in range(hours * 120):
        t = W0 + dt.timedelta(seconds=30 * k)
        if t in drop:
            continue
        cycle, position = divmod(k, 10)                      # 10 samples per 5-minute cycle
        for role, healthy in ROLES.items():
            top = peaks.get((role, cycle), healthy)
            lag = top - (9 - position) * 30                  # rises to the cycle's peak at its last sample
            rows.append(f"{t.strftime(FMT)}|1|{role}|{t.strftime(FMT)}|0.5|Success|Scheduled|1|0|10|{lag}")
    return rows


def at_cycle(index):
    return W0 + dt.timedelta(minutes=5 * index)


class Evaluator(unittest.TestCase):
    def run_eval(self, rows, gaps=None, w1=None):
        with tempfile.TemporaryDirectory() as d:
            samples = Path(d) / "samples.txt"
            samples.write_text("\n".join(rows) + "\n", encoding="utf-8")
            args = [sys.executable, "-I", str(EVALUATOR), "--w0", W0.strftime(FMT)]
            if w1:
                args += ["--w1", w1.strftime(FMT)]
            if gaps is not None:
                g = Path(d) / "gaps.csv"
                g.write_text("\n".join(gaps) + "\n", encoding="utf-8")
                args += ["--gaps", str(g)]
            result = subprocess.run(args + [str(samples)], capture_output=True, text=True, timeout=120)
            return result.returncode, result.stdout + result.stderr

    def assertPass(self, rows, **kw):
        code, out = self.run_eval(rows, **kw)
        self.assertEqual(code, 0, out)
        self.assertIn("RESULT: PASS", out)
        return out

    def assertFail(self, rows, needle, **kw):
        code, out = self.run_eval(rows, **kw)
        self.assertEqual(code, 1, out)
        self.assertIn("RESULT: FAIL", out)
        self.assertIn(needle, out)
        return out

    # Baseline
    def test_healthy_window_passes(self):
        out = self.assertPass(synthetic())
        self.assertIn("coverage 100.0 %", out)

    # Ceilings: at, below, above
    def test_routing_excursion_at_the_ceiling_passes(self):
        self.assertPass(synthetic({("run_energy_routing_job", 40): 600}))

    def test_routing_excursion_below_the_ceiling_passes(self):
        self.assertPass(synthetic({("run_energy_routing_job", 40): 599}))

    def test_routing_one_second_above_the_ceiling_fails(self):
        self.assertFail(synthetic({("run_energy_routing_job", 40): 601}), "peak 601 s > 600 s")

    def test_d021_routing_retry_fails_under_absolute_ceilings(self):
        self.assertFail(synthetic({("run_environment_routing_job", 40): 785}), "peak 785 s > 600 s")

    def test_one_minute_tier_at_ceiling_passes_and_above_fails(self):
        self.assertPass(synthetic({("run_energy_consumption_1min_job", 40): 620}))
        self.assertFail(synthetic({("run_energy_consumption_1min_job", 40): 621}), "peak 621 s > 620 s")

    def test_normalized_excursion_between_target_and_ceiling_passes_above_fails(self):
        self.assertPass(synthetic({("run_normalization_job", 40): 600}))
        self.assertFail(synthetic({("run_normalization_job", 40): 601}), "peak 601 s > 600 s")

    # Excursion duration and count
    def test_two_consecutive_excursion_cycles_fail(self):
        out = self.assertFail(synthetic({("run_energy_routing_job", 40): 560, ("run_energy_routing_job", 41): 560}),
                              "L3 excursions 1 (allowed 3) FAIL")
        self.assertIn("2 cycle(s), peak 560 s", out)

    def test_three_excursions_pass_and_four_fail(self):
        three = {("run_energy_routing_job", c): 560 for c in (10, 100, 200)}
        self.assertPass(synthetic(three))
        four = {**three, ("run_energy_routing_job", 250): 560}
        self.assertFail(synthetic(four), "L3 excursions 4 (allowed 3) FAIL")

    def test_excursions_are_counted_per_stage(self):
        spread = {("run_energy_routing_job", c): 560 for c in (10, 100, 200)}
        spread.update({("run_environment_routing_job", c): 560 for c in (20, 120, 220)})
        self.assertPass(synthetic(spread))

    # Source gaps: explicit, scoped, bounded
    def gap(self, start_cycle, end_cycle, stages, reason="raw messages absent for all gateways (acceptance SQL D)"):
        return f"{at_cycle(start_cycle).strftime(FMT)},{at_cycle(end_cycle).strftime(FMT)},{stages},{reason}"

    def test_documented_gap_exempts_its_stage_and_is_listed(self):
        out = self.assertPass(synthetic({("run_energy_routing_job", 40): 900}), gaps=[self.gap(40, 41, "energy_routing")])
        self.assertIn("EXEMPT (source gap", out)
        self.assertIn("peak 900 s", out)

    def test_gap_does_not_exempt_another_stage(self):
        self.assertFail(synthetic({("run_environment_routing_job", 40): 900}),
                        "peak 900 s > 600 s", gaps=[self.gap(40, 41, "energy_routing")])

    def test_gap_reaches_one_catch_up_cycle_only(self):
        # Gap 40..41 (end at cycle 41's start): exempts cycles 40 and 41; cycle 42 is not exempt.
        self.assertPass(synthetic({("run_energy_routing_job", 41): 900}), gaps=[self.gap(40, 41, "energy_routing")])
        self.assertFail(synthetic({("run_energy_routing_job", 42): 900}),
                        "peak 900 s > 600 s", gaps=[self.gap(40, 41, "energy_routing")])

    def test_gap_elsewhere_does_not_exempt_an_unrelated_cycle(self):
        self.assertFail(synthetic({("run_energy_routing_job", 200): 900}),
                        "peak 900 s > 600 s", gaps=[self.gap(40, 41, "all")])

    def test_gap_does_not_excuse_missing_samples(self):
        missing = {at_cycle(40) + dt.timedelta(seconds=30 * k) for k in range(40)}       # 40 samples = 1.4 %
        self.assertFail(synthetic(drop=missing), "(L0 FAIL)", gaps=[self.gap(40, 44, "all")])

    def test_malformed_gaps_are_input_errors(self):
        bad = {
            "outside window": f"{(W0 - dt.timedelta(hours=1)).strftime(FMT)},{at_cycle(1).strftime(FMT)},all,x",
            "end before start": self.gap(41, 40, "all"),
            "missing reason": f"{at_cycle(40).strftime(FMT)},{at_cycle(41).strftime(FMT)},all,",
            "unknown stage": self.gap(40, 41, "routing"),
        }
        for label, row in bad.items():
            code, out = self.run_eval(synthetic(), gaps=[row])
            self.assertEqual(code, 2, f"{label}: {out}")
            self.assertIn("INPUT ERROR", out)
        code, out = self.run_eval(synthetic(), gaps=[self.gap(40, 44, "energy_routing"), self.gap(42, 46, "all")])
        self.assertEqual(code, 2, out)
        self.assertIn("gaps overlap for energy_routing", out)

    # Coverage and completeness
    def test_coverage_below_99_percent_fails(self):
        missing = {W0 + dt.timedelta(seconds=30 * k) for k in range(0, 2880, 50)}       # 58 samples = 2 %
        self.assertFail(synthetic(drop=missing), "(L0 FAIL)")

    def test_incomplete_window_never_passes(self):
        code, out = self.run_eval(synthetic(hours=12))
        self.assertEqual(code, 1, out)
        self.assertIn("[window incomplete]", out)


if __name__ == "__main__":
    unittest.main()
