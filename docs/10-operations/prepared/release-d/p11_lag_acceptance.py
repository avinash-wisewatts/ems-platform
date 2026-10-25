"""Release D lag acceptance from P11 sampler output (formal criteria; local only).

Reads the '|'-separated rows written by scripts/diagnostics/run_readonly_job_sampler.sh
(samples.txt, or segments/*.txt) and evaluates the formal Release D lag criteria
over a fixed 24-hour window [w0, w0 + 24 h). Read-only: it only reads local files.

  python -I p11_lag_acceptance.py --w0 '2026-10-26 06:00:00' [--gaps gaps.csv] <samples files...>

Criteria (production-release-plan-266-301.md, section 6, "Release D lag criteria"):
  L0 coverage   >= 99 % of the 2,880 expected 30-second samples, per stage, over
                the whole window. A source gap never excuses a missing sample.
  L1 target     normal per-cycle peak: normalized 330 s, energy / environment
                routing 540 s, 1-minute tier 540 s.
  L2 ceiling    ABSOLUTE, every sample: normalized and routing 600 s, 1-minute
                tier 620 s. Only a documented source gap (L4) exempts a sample.
  L3 excursions an excursion is a run of consecutive samples above the stage's
                L1 target. It may last at most one five-minute cycle = 10
                consecutive 30-second samples; a missing sample inside a run
                counts towards its length. At most 3 excursions per stage in the
                window. An excursion never exempts L2.
  L4 gaps       --gaps CSV rows `start,end,stages,reason` (UTC; stages = names
                below joined by '|', or 'all'). A gap exempts, for its stages only,
                the samples in cycles that overlap [start, end + 5 min) (the
                overlapping cycles plus one catch-up cycle). Rows must be inside
                the window, not overlap for a stage, have end > start and a reason;
                otherwise the evaluator stops (exit 2). Every exempt cycle is listed.
  Window        only a complete window of exactly 24 h can pass; anything else
                (shorter window, samples ending early) is reported and fails.

Exit 0 = complete 24-hour window and PASS; 1 = FAIL, incomplete or not a 24-hour
window; 2 = input error.
"""

from __future__ import annotations

import argparse
import collections
import csv
import datetime as dt
import sys

FMT = "%Y-%m-%d %H:%M:%S"
STEP = dt.timedelta(seconds=30)
CYCLE = dt.timedelta(minutes=5)
WINDOW = dt.timedelta(hours=24)
MAX_EXCURSION_SAMPLES = 10            # one five-minute cycle of 30-second samples
MAX_EXCURSIONS = 3                    # per stage per 24-hour window
MIN_COVERAGE = 99.0
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
    """The gap exempting this stage's cycle, or None. Reach: cycles overlapping [start, end + 5 min)."""
    for start, end, stages, reason in gaps:
        if stage in stages and cycle < end + CYCLE and cycle + CYCLE > start:
            return start, end, reason
    return None


def evaluate(rows, w0, w1, gaps):
    slots = int((w1 - w0) / STEP)                     # expected samples (2,880 for 24 h)
    grid = collections.defaultdict(dict)              # role -> {slot: (time, lag)}
    last_seen = None
    for r in rows:
        if len(r) < 11 or r[2] not in STAGES or not r[10]:
            continue
        t = dt.datetime.strptime(r[0], FMT)
        if w0 <= t < w1:
            grid[r[2]][int((t - w0) / STEP)] = (t, int(float(r[10])))
            last_seen = t if last_seen is None else max(last_seen, t)
    complete = last_seen is not None and last_seen + STEP >= w1
    formal = (w1 - w0) == WINDOW
    report = {"complete": complete, "formal": formal, "slots": slots, "stages": {}, "pass": complete and formal}
    for role, (stage, target, ceiling) in STAGES.items():
        g = grid.get(role, {})
        coverage = 100.0 * len(g) / slots if slots else 0.0
        # Each slot's cycle: from its sample time, or the grid time when missing.
        slot_cycle = [cycle_of(g[k][0] if k in g else w0 + k * STEP) for k in range(slots)]
        exempt_cycles = {}
        for c in sorted(set(slot_cycle)):
            hit = gap_for(stage, c, gaps)
            if hit:
                exempt_cycles[c] = hit
        over_ceiling, excursions, run, pending = [], [], [], 0
        for k in range(slots):
            if slot_cycle[k] in exempt_cycles:
                if run:                                  # a gap ends the run (exempt, not counted)
                    excursions.append(run)
                run, pending = [], 0
                continue
            if k not in g:                               # missing sample: part of a run if one is open
                if run:
                    pending += 1
                continue
            t, lag = g[k]
            if lag > ceiling:
                over_ceiling.append((t, lag))
            if lag > target:
                if run:
                    run.extend([None] * pending)         # interior missing samples count
                run.append((t, lag))
                pending = 0
            else:
                if run:
                    excursions.append(run)
                run, pending = [], 0
        if run:
            excursions.append(run)
        exc = [(next(x for x in r if x)[0], len(r), max(x[1] for x in r if x)) for r in excursions]
        peaks = collections.defaultdict(int)
        for k, (t, lag) in g.items():
            if slot_cycle[k] not in exempt_cycles:
                peaks[slot_cycle[k]] = max(peaks[slot_cycle[k]], lag)
        l0 = coverage >= MIN_COVERAGE
        l2 = not over_ceiling
        l3 = all(n <= MAX_EXCURSION_SAMPLES for _, n, _ in exc) and len(exc) <= MAX_EXCURSIONS
        ok = l0 and l2 and l3
        report["pass"] &= ok
        report["stages"][stage] = {
            "target": target, "ceiling": ceiling, "samples": len(g), "coverage": coverage,
            "peaks": sorted(peaks.values()), "cycles_above_target": sum(1 for v in peaks.values() if v > target),
            "over_ceiling": over_ceiling, "excursions": exc,
            "exempt": [(c, max((g[k][1] for k in g if slot_cycle[k] == c), default=None), hit)
                       for c, hit in sorted(exempt_cycles.items())],
            "L0": l0, "L2": l2, "L3": l3, "pass": ok,
        }
    return report


def main() -> int:
    p = argparse.ArgumentParser()
    p.add_argument("--w0", required=True)
    p.add_argument("--w1", help="default and formal: w0 + 24 h; any other end is informational and cannot pass")
    p.add_argument("--gaps")
    p.add_argument("files", nargs="+")
    a = p.parse_args()
    try:
        w0 = dt.datetime.strptime(a.w0, FMT)
        w1 = dt.datetime.strptime(a.w1, FMT) if a.w1 else w0 + WINDOW
        if w1 <= w0:
            raise InputError("w1 must be after w0")
        gaps = load_gaps(a.gaps, w0, w1)
    except (InputError, ValueError) as exc:
        print(f"INPUT ERROR: {exc}", file=sys.stderr)
        return 2
    rows = [line.rstrip("\n").split("|") for name in a.files for line in open(name, encoding="utf-8")]
    rep = evaluate(rows, w0, w1, gaps)
    notes = ([] if rep["formal"] else ["not a 24-hour window: informational only"]) + \
            ([] if rep["complete"] else ["window incomplete"])
    print(f"window {w0} .. {w1} UTC; {rep['slots']} expected samples per stage" + "".join(f"; {n.upper()}" for n in notes))
    for stage, s in rep["stages"].items():
        pk = s["peaks"]
        print(f"\n{stage}: samples {s['samples']}, coverage {s['coverage']:.1f} % (L0 {'PASS' if s['L0'] else 'FAIL'})")
        if pk:
            print(f"  per-cycle peak min {pk[0]} s, max {pk[-1]} s, cycles above target {s['cycles_above_target']}; "
                  f"target {s['target']} s, ceiling {s['ceiling']} s")
        print(f"  L2 ceiling {'PASS' if s['L2'] else 'FAIL'}" +
              "".join(f"; {t} {v} s > {s['ceiling']} s" for t, v in s["over_ceiling"][:5]) +
              (f"; ... {len(s['over_ceiling'])} samples in all" if len(s["over_ceiling"]) > 5 else ""))
        print(f"  L3 excursions {len(s['excursions'])} (allowed {MAX_EXCURSIONS}, each <= {MAX_EXCURSION_SAMPLES} samples) "
              f"{'PASS' if s['L3'] else 'FAIL'}")
        for t, n, peak in s["excursions"]:
            print(f"    excursion from {t}: {n} sample(s), peak {peak} s")
        for c, peak, (g0, g1, reason) in s["exempt"]:
            print(f"    EXEMPT (source gap {g0}..{g1}: {reason}) cycle {c}: peak {peak if peak is not None else 'no samples'} s")
    print(f"\nRESULT: {'PASS' if rep['pass'] else 'FAIL'}" + "".join(f"  [{n}]" for n in notes))
    return 0 if rep["pass"] else 1


if __name__ == "__main__":
    sys.exit(main())
