"""Fault-injection tests for p11_lag_acceptance.py (standard library only).

  python -I -m unittest discover -s docs/10-operations/prepared/release-d -p 'test_p11_lag_acceptance.py' -v

A synthetic 24-hour window: one sample every 30 s per stage (2,880 per stage), a
healthy sawtooth whose per-cycle peak is below target (normalized 306 s,
routing 485 s, 1-minute tier 517 s, as measured on staging 2026-10-25). Faults
are injected per sample: `slot` k is the sample at W0 + 30 s * k; cycle c holds
slots 10c .. 10c + 9.
"""

from __future__ import annotations

import datetime as dt
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
EVALUATOR = HERE / "p11_lag_acceptance.py"
FMT = "%Y-%m-%d %H:%M:%S"
W0 = dt.datetime(2026, 10, 26, 0, 0, 0)
NORM, ER, ENV, TIER = ("run_normalization_job", "run_energy_routing_job",
                       "run_environment_routing_job", "run_energy_consumption_1min_job")
HEALTHY = {NORM: 306, ER: 485, ENV: 485, TIER: 517}
STAGE = {NORM: "normalized", ER: "energy_routing", ENV: "environment_routing", TIER: "one_minute_tier"}


def plateau(role, first_slot, n, value):
    """n consecutive samples of `role` at `value`, starting at first_slot."""
    return {(role, k): value for k in range(first_slot, first_slot + n)}


def synthetic(overrides=None, drop=(), hours=24, offset_s=0):
    """Rows for [W0, W0 + hours). overrides: {(role, slot): lag}; drop: {(role, slot)} or {slot} (all roles)."""
    overrides = overrides or {}
    rows = []
    for k in range(hours * 120):
        t = W0 + dt.timedelta(seconds=30 * k + offset_s)
        for role, peak in HEALTHY.items():
            if k in drop or (role, k) in drop:
                continue
            lag = overrides.get((role, k), peak - (9 - k % 10) * 30)
            rows.append(f"{t.strftime(FMT)}|1|{role}|{t.strftime(FMT)}|0.5|Success|Scheduled|1|0|10|{lag}")
    return rows


def at_cycle(c):
    return (W0 + dt.timedelta(minutes=5 * c)).strftime(FMT)


def gap(start_cycle, end_cycle, stages, reason="raw messages absent for all gateways (acceptance SQL D)"):
    return f"{at_cycle(start_cycle)},{at_cycle(end_cycle)},{stages},{reason}"


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

    # --- baseline ---------------------------------------------------------
    def test_healthy_window_passes(self):
        out = self.assertPass(synthetic())
        self.assertIn("2880 expected samples", out)
        self.assertEqual(out.count("coverage 100.0 %"), 4)

    def test_real_sampler_second_offsets_are_handled(self):
        self.assertPass(synthetic(offset_s=7))                     # P11 samples at :07 / :37

    # --- L2 absolute ceilings: at / below / one second above, every stage --
    def test_ceilings_at_and_below_pass(self):
        for role, ceiling in ((NORM, 600), (ER, 600), (ENV, 600), (TIER, 620)):
            with self.subTest(stage=STAGE[role], value=ceiling):
                self.assertPass(synthetic(plateau(role, 409, 1, ceiling)))
            with self.subTest(stage=STAGE[role], value=ceiling - 1):
                self.assertPass(synthetic(plateau(role, 409, 1, ceiling - 1)))

    def test_one_second_above_each_ceiling_fails(self):
        for role, ceiling in ((NORM, 600), (ER, 600), (ENV, 600), (TIER, 620)):
            with self.subTest(stage=STAGE[role]):
                self.assertFail(synthetic(plateau(role, 409, 1, ceiling + 1)), f"{ceiling + 1} s > {ceiling} s")

    def test_d021_routing_retry_around_785_s_fails_the_ceiling(self):
        for role in (ER, ENV):
            with self.subTest(stage=STAGE[role]):
                self.assertFail(synthetic(plateau(role, 409, 1, 785)), "785 s > 600 s")

    def test_an_excursion_never_exempts_the_ceiling(self):
        # One short excursion (2 samples) whose second sample is above the ceiling.
        self.assertFail(synthetic({**plateau(ER, 408, 1, 560), **plateau(ER, 409, 1, 601)}), "601 s > 600 s")

    # --- L3 excursion duration: 10 consecutive samples ---------------------
    def test_excursion_of_exactly_ten_samples_passes(self):
        out = self.assertPass(synthetic(plateau(ER, 400, 10, 560)))
        self.assertIn("10 sample(s), peak 560 s", out)

    def test_excursion_of_eleven_samples_fails(self):
        self.assertFail(synthetic(plateau(ER, 400, 11, 560)), "11 sample(s), peak 560 s")

    def test_ten_samples_across_a_cycle_boundary_pass_eleven_fail(self):
        self.assertPass(synthetic(plateau(ER, 405, 10, 560)))      # slots 405..414 span cycles 40 and 41
        self.assertFail(synthetic(plateau(ER, 405, 11, 560)), "11 sample(s)")

    def test_missing_samples_inside_an_excursion_count_towards_its_length(self):
        rows = synthetic(plateau(ER, 400, 11, 560), drop={(ER, 405)})      # 5 + missing + 5 = 11
        self.assertFail(rows, "11 sample(s)")

    def test_trailing_missing_samples_do_not_lengthen_an_excursion(self):
        rows = synthetic(plateau(ER, 400, 10, 560), drop={(ER, 410), (ER, 411)})
        self.assertPass(rows)

    def test_excursion_samples_above_target_but_within_ceiling_are_the_only_kind_allowed(self):
        self.assertPass(synthetic(plateau(TIER, 400, 10, 620)))   # 1-minute tier at its ceiling for 10 samples

    # --- L3 excursion count: at most 3 per stage per 24 h -------------------
    def test_three_excursions_pass_four_fail(self):
        three = {**plateau(ER, 100, 3, 560), **plateau(ER, 1000, 3, 560), **plateau(ER, 2000, 3, 560)}
        self.assertPass(synthetic(three))
        self.assertFail(synthetic({**three, **plateau(ER, 2500, 3, 560)}), "L3 excursions 4 (allowed 3")

    def test_excursions_are_counted_per_stage(self):
        spread = {}
        for role, base in ((NORM, 0), (ER, 50), (ENV, 100), (TIER, 150)):
            for start in (base + 200, base + 1200, base + 2200):
                spread.update(plateau(role, start, 2, HEALTHY[role] + 60 if role != NORM else 400))
        self.assertPass(synthetic(spread))

    # --- L4 source gaps -----------------------------------------------------
    def test_documented_gap_exempts_its_stage_and_is_listed(self):
        out = self.assertPass(synthetic(plateau(ER, 405, 3, 900)), gaps=[gap(40, 41, "energy_routing")])
        self.assertIn("EXEMPT (source gap", out)
        self.assertIn("peak 900 s", out)

    def test_gap_does_not_exempt_another_stage(self):
        self.assertFail(synthetic(plateau(ENV, 405, 1, 900)), "900 s > 600 s", gaps=[gap(40, 41, "energy_routing")])

    def test_gap_reaches_overlapping_cycles_plus_one_catch_up_cycle_only(self):
        g = [gap(40, 41, "energy_routing")]                         # gap cycle 40; catch-up cycle 41
        self.assertPass(synthetic(plateau(ER, 415, 1, 900)), gaps=g)   # cycle 41: exempt
        self.assertFail(synthetic(plateau(ER, 425, 1, 900)), "900 s > 600 s", gaps=g)   # cycle 42: not

    def test_gap_elsewhere_does_not_exempt_an_unrelated_sample(self):
        self.assertFail(synthetic(plateau(ER, 2000, 1, 900)), "900 s > 600 s", gaps=[gap(40, 41, "all")])

    def test_gap_does_not_excuse_missing_sampler_coverage(self):
        missing = set(range(400, 440))                                # 40 samples = 1.4 %, inside the gap
        self.assertFail(synthetic(drop=missing), "(L0 FAIL)", gaps=[gap(40, 44, "all")])

    def test_invalid_gap_rows_are_input_errors(self):
        bad = {
            "outside window": f"{(W0 - dt.timedelta(hours=1)).strftime(FMT)},{at_cycle(1)},all,x",
            "end before start": gap(41, 40, "all"),
            "end equals start": gap(40, 40, "all"),
            "missing reason": f"{at_cycle(40)},{at_cycle(41)},all,",
            "missing stages": f"{at_cycle(40)},{at_cycle(41)}",
            "unknown stage": gap(40, 41, "routing"),
            "bad time": f"2026-10-26 25:00:00,{at_cycle(41)},all,x",
        }
        for label, row in bad.items():
            with self.subTest(label):
                code, out = self.run_eval(synthetic(), gaps=[row])
                self.assertEqual(code, 2, out)
                self.assertIn("INPUT ERROR", out)

    def test_overlapping_gaps_for_a_stage_are_input_errors(self):
        code, out = self.run_eval(synthetic(), gaps=[gap(40, 44, "energy_routing"), gap(42, 46, "all")])
        self.assertEqual(code, 2, out)
        self.assertIn("gaps overlap for energy_routing", out)

    def test_adjacent_and_other_stage_gaps_are_valid(self):
        self.assertPass(synthetic(), gaps=[gap(40, 44, "energy_routing"), gap(44, 46, "energy_routing"),
                                           gap(42, 46, "normalized|one_minute_tier")])

    # --- L0 coverage and insufficient evidence -------------------------------
    def test_coverage_boundary_99_percent(self):
        # 99 % of 2,880 = 2,851.2: 28 missing (2,852 = 99.03 %) passes, 29 missing (2,851 = 98.99 %) fails.
        self.assertPass(synthetic(drop={(ER, k) for k in range(0, 2800, 100)}))           # 28 missing
        self.assertFail(synthetic(drop={(ER, k) for k in range(0, 2900, 100)}), "(L0 FAIL)")   # 29 missing

    def test_a_stage_with_no_samples_fails(self):
        self.assertFail(synthetic(drop={(TIER, k) for k in range(2880)}), "one_minute_tier: samples 0")

    def test_incomplete_window_never_passes(self):
        self.assertFail(synthetic(hours=12), "[window incomplete]")

    def test_a_shorter_window_is_informational_and_cannot_pass(self):
        self.assertFail(synthetic(hours=12), "[not a 24-hour window", w1=W0 + dt.timedelta(hours=12))


if __name__ == "__main__":
    unittest.main()
