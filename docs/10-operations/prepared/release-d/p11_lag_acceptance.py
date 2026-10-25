"""Release D lag acceptance from P11 sampler output (PROPOSED criteria; local only).

Reads the '|'-separated rows written by scripts/diagnostics/run_readonly_job_sampler.sh
(samples.txt, or segments/*.txt) and evaluates the proposed lag criteria over a
fixed window [w0, w1). Read-only: it only reads local files.

  python -I p11_lag_acceptance.py --w0 '2026-10-26 06:00:00' [--w1 ...] \
      [--gaps gaps.csv] <samples files...>

Criteria (PROPOSED; production-release-plan-266-301.md, section 6):
  L0 coverage   >= 99 % of the expected 30-second samples, per stage, over the
                whole window: a source gap never excuses a missing sample.
  L1 target     per-cycle peak (max lag in each 5-minute UTC cycle): normalized
                330 s, energy / environment routing 540 s, 1-minute tier 540 s.
  L2 ceiling    ABSOLUTE, every cycle: normalized and routing 600 s, 1-minute tier
                620 s. Only a documented source gap (L4) exempts a cycle.
  L3 excursions a cycle above its L1 target is an excursion; each run of
                consecutive excursion cycles must be one cycle long, and there are
                at most 3 excursions per 24 h of window. An excursion never
                exempts L2.
  L4 gaps       --gaps CSV rows `start,end,stages,reason` (UTC; stages = names
                below joined by '|', or 'all'). A gap exempts, for its stages only,
                the cycles that overlap [start, end + 5 min) (one cycle of
                catch-up after the gap). Rows must be inside the window, not
                overlap for a stage, have end > start and a reason; otherwise the
                evaluator stops (exit 2). Every exempt cycle is listed.

Exit 0 = window complete and PASS; 1 = FAIL or window incomplete; 2 = input error.
"""

from __future__ import annotations

import argparse
import collections
import csv
import datetime as dt
import sys

FMT = "%Y-%m-%d %H:%M:%S"
CYCLE = dt.timedelta(minutes=5)
# role in the P11 rows -> (stage name, L1 target s, L2 ceiling s)
STAGES = {
    "run_normalization_job": ("normalized", 330, 600),
    "run_energy_routing_job": ("energy_routing", 540, 600),
    "run_environment_routing_job": ("environment_routing", 540, 600),
    "run_energy_consumption_1min_job": ("one_minute_tier", 540, 620),
}
STAGE_NAMES = {name for name, _, _ in STAGES.values()}


class InputError(Exception):
    pass


def cycle_of(t: dt.datetime) -> dt.datetime:
    return t.replace(minute=t.minute - t.minute % 5, second=0, microsecond=0)


def load_gaps(path: str | None, w0: dt.datetime, w1: dt.datetime) -> list[tuple]:
    if not path:
        return []
    gaps = []
    for number, row in enumerate(csv.reader(open(path, encoding="utf-8")), start=1):
        if not row or row[0].strip().startswith("#"):
            continue
        if len(row) < 4 or not row[3].strip():
            raise InputError(f"gaps line {number}: expected start,end,stages,reason with a non-empty reason")
        try:
            start = dt.datetime.strptime(row[0].strip(), FMT)
            end = dt.datetime.strptime(row[1].strip(), FMT)
        except ValueError as exc:
            raise InputError(f"gaps line {number}: {exc}") from None
        stages = STAGE_NAMES if row[2].strip() == "all" else set(row[2].strip().split("|"))
        unknown = stages - STAGE_NAMES
        if unknown:
            raise InputError(f"gaps line {number}: unknown stage(s) {sorted(unknown)}")
        if end <= start:
            raise InputError(f"gaps line {number}: end must be after start")
        if start < w0 or end > w1:
            raise InputError(f"gaps line {number}: gap must lie inside the window [{w0}, {w1})")
        gaps.append((start, end, frozenset(stages), row[3].strip()))
    for stage in STAGE_NAMES:
        mine = sorted((g for g in gaps if stage in g[2]), key=lambda g: g[0])
        for a, b in zip(mine, mine[1:]):
            if b[0] < a[1]:
                raise InputError(f"gaps overlap for {stage}: {a[0]}..{a[1]} and {b[0]}..{b[1]}")
    return gaps


def gap_for(stage: str, cycle: dt.datetime, gaps: list[tuple]):
    """The gap exempting this stage's cycle, or None. Reach: [start, end + 5 min)."""
    for start, end, stages, reason in gaps:
        if stage in stages and cycle < end + CYCLE and cycle + CYCLE > start:
            return start, end, reason
    return None


def evaluate(rows, w0, w1, gaps):
    samples = collections.defaultdict(dict)
    last_seen = None
    for r in rows:
        if len(r) < 11 or r[2] not in STAGES or not r[10]:
            continue
        t = dt.datetime.strptime(r[0], FMT)
        if w0 <= t < w1:
            samples[r[2]][t] = int(float(r[10]))
            last_seen = t if last_seen is None else max(last_seen, t)
    end = min(w1, (last_seen or w0) + dt.timedelta(seconds=30))
    complete = end >= w1
    hours = (end - w0).total_seconds() / 3600
    allowed_excursions = int(3 * hours / 24 + 1e-9) if complete else 3
    report = {"end": end, "complete": complete, "stages": {}, "pass": True}
    for role, (stage, target, ceiling) in STAGES.items():
        s = samples.get(role, {})
        expected = int((end - w0).total_seconds() // 30)
        # Coverage is about the sampler, not the data: a source gap never excuses
        # a missing sample, so every expected sample in the window counts.
        coverage = 100.0 * len(s) / expected if expected else 0.0
        peaks = collections.defaultdict(int)
        for t, lag in s.items():
            peaks[cycle_of(t)] = max(peaks[cycle_of(t)], lag)
        all_cycles = []
        c = cycle_of(w0)
        while c < end:
            all_cycles.append(c)
            c += CYCLE
        exempt = {c: gap_for(stage, c, gaps) for c in all_cycles if gap_for(stage, c, gaps)}
        counted = [c for c in all_cycles if c not in exempt and c in peaks]
        over_ceiling = [c for c in counted if peaks[c] > ceiling]
        excursions, run = [], []
        for c in counted:
            if peaks[c] > target and run and c - run[-1] == CYCLE:
                run.append(c)
            elif peaks[c] > target:
                if run:
                    excursions.append(run)
                run = [c]
            else:
                if run:
                    excursions.append(run)
                run = []
        if run:
            excursions.append(run)
        l0 = coverage >= 99.0
        l2 = not over_ceiling
        l3 = all(len(r) == 1 for r in excursions) and len(excursions) <= allowed_excursions
        ok = l0 and l2 and l3
        report["pass"] &= ok
        report["stages"][stage] = {
            "target": target, "ceiling": ceiling, "samples": len(s), "coverage": coverage,
            "peaks": sorted(peaks[c] for c in counted), "over_ceiling": [(c, peaks[c]) for c in over_ceiling],
            "excursions": [(r[0], len(r), max(peaks[c] for c in r)) for r in excursions],
            "allowed_excursions": allowed_excursions,
            "exempt": [(c, peaks.get(c), g) for c, g in sorted(exempt.items())],
            "L0": l0, "L2": l2, "L3": l3, "pass": ok,
        }
    report["pass"] &= complete
    return report


def main() -> int:
    p = argparse.ArgumentParser()
    p.add_argument("--w0", required=True)
    p.add_argument("--w1")
    p.add_argument("--gaps")
    p.add_argument("files", nargs="+")
    a = p.parse_args()
    try:
        w0 = dt.datetime.strptime(a.w0, FMT)
        w1 = dt.datetime.strptime(a.w1, FMT) if a.w1 else w0 + dt.timedelta(hours=24)
        if w1 <= w0:
            raise InputError("w1 must be after w0")
        gaps = load_gaps(a.gaps, w0, w1)
    except (InputError, ValueError) as exc:
        print(f"INPUT ERROR: {exc}", file=sys.stderr)
        return 2
    rows = [line.rstrip("\n").split("|") for name in a.files for line in open(name, encoding="utf-8")]
    rep = evaluate(rows, w0, w1, gaps)
    print(f"window {w0} .. {w1} UTC; evaluated to {rep['end']}{'' if rep['complete'] else ' (INCOMPLETE)'}")
    for stage, s in rep["stages"].items():
        pk = s["peaks"]
        print(f"\n{stage}: samples {s['samples']}, coverage {s['coverage']:.1f} % (L0 {'PASS' if s['L0'] else 'FAIL'})")
        if pk:
            print(f"  per-cycle peak min {pk[0]} s, max {pk[-1]} s; target {s['target']} s, ceiling {s['ceiling']} s")
        print(f"  L2 ceiling {'PASS' if s['L2'] else 'FAIL'}" + "".join(f"; {c} peak {v} s > {s['ceiling']} s" for c, v in s["over_ceiling"]))
        print(f"  L3 excursions {len(s['excursions'])} (allowed {s['allowed_excursions']}) {'PASS' if s['L3'] else 'FAIL'}")
        for c, length, peak in s["excursions"]:
            print(f"    excursion {c} .. {c + length * CYCLE}: {length} cycle(s), peak {peak} s")
        for c, peak, (g0, g1, reason) in s["exempt"]:
            print(f"    EXEMPT (source gap {g0}..{g1}: {reason}) cycle {c}: peak {peak if peak is not None else 'no samples'} s")
    print(f"\nRESULT: {'PASS' if rep['pass'] else 'FAIL'}{'' if rep['complete'] else '  [window incomplete]'}")
    return 0 if rep["pass"] else 1


if __name__ == "__main__":
    sys.exit(main())
