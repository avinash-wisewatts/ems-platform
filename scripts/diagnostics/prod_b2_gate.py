#!/usr/bin/env python3
"""Fail-closed gate for prod_b2_precheck.sql / prod_b2_postcheck.sql output.

Usage:
    python3 -I prod_b2_gate.py precheck|postcheck OUTPUT.txt --rc N

N is the psql exit status of the run that wrote OUTPUT.txt. Reads only that
file. Exit status 0 (GATE PASS) only if all of these hold:
  - psql exited 0;
  - every line is a check line '<KEY> <evidence> PASS', a 'now ' line
    (exactly one), an 'INFO ' line, or the END line;
  - the last line is 'END prod_b2_<kind>' (the run was not truncated);
  - the check keys are exactly the expected set, each exactly once.
Anything else -- a FAIL, a missing, duplicate or unknown key, a blank line,
a psql message (ERROR, WARNING, NOTICE ...), empty output -- is GATE FAIL
(exit 1). Usage errors exit 2.
"""

import argparse
import re
import sys

PRECHECK_KEYS = [
    "PRE.runner_tz", "PRE.283_viewdef", "SESSION.readonly", "SESSION.identity",
    "P1.ledger", "P2.pending", "P2.ledger_in_manifest", "PRE.canonical_269",
    "PRE.deps", "PRE.b2_absent", "PRE.trigger_absent", "P5.bridge", "P5.capture_set",
    "P10.failures", "P10.errors", "P10.paused", "P10.backfill",
    "JOBS.1062", "JOBS.1063", "JOBS.1064", "JOBS.1097", "JOBS.1100", "JOBS.1103",
    "LOCK.long_xact", "LOCK.idle_xact", "LOCK.sites",
]

POSTCHECK_KEYS = [
    "SESSION.readonly", "SESSION.identity", "LEDGER.rows",
    *(f"LEDGER.{m}" for m in ("263", "270", "279", "275", "276", "277", "278",
                              "280", "281", "282", "283", "284", "285", "286")),
    "LEDGER.order", "LEDGER.earlier135", "LEDGER.all149",
    *(f"POST.fn_{k}" for k in ("asset_series", "availability", "canonical_read", "catalog",
                               "direction_status", "floors", "floors_site",
                               "rollup_15min_range", "source_windows", "tz_trigger_fn")),
    "POST.dropped", "POST.availability_comment", "POST.tz_trigger", "POST.bridge",
    "HEALTH.failures", "HEALTH.errors",
    *(f"HEALTH.job{j}" for j in (1062, 1063, 1064, 1097, 1100, 1103)),
    "HEALTH.lock_waiters", "HEALTH.paused", "HEALTH.1h_checkpoint",
]

EXPECTED = {"precheck": PRECHECK_KEYS, "postcheck": POSTCHECK_KEYS}
CHECK = re.compile(r"^([A-Z0-9]+\.[A-Za-z0-9_]+)(?:[ =].*)? (PASS|FAIL)$")


def evaluate(kind, lines, rc):
    """Return the list of reasons the gate fails (empty list = PASS)."""
    reasons = []
    if rc != 0:
        reasons.append(f"psql exit status {rc}")
    if not lines:
        return reasons + ["empty output"]
    end = f"END prod_b2_{kind}"
    if lines[-1] != end:
        reasons.append(f"last line is not '{end}' (truncated or extra output)")
    seen, now_lines = {}, 0
    for number, line in enumerate(lines, 1):
        if line == end and number == len(lines):
            continue
        if line.startswith("now "):
            now_lines += 1
            continue
        if line.startswith("INFO "):
            continue
        match = CHECK.match(line)
        if not match:
            reasons.append(f"line {number}: unexpected line {line!r}")
            continue
        key, verdict = match.groups()
        seen[key] = seen.get(key, 0) + 1
        if verdict != "PASS":
            reasons.append(f"line {number}: {key} FAIL")
    if now_lines != 1:
        reasons.append(f"{now_lines} 'now' lines (expected 1)")
    expected = EXPECTED[kind]
    for key in expected:
        if key not in seen:
            reasons.append(f"missing check {key}")
        elif seen[key] > 1:
            reasons.append(f"check {key} printed {seen[key]} times")
    for key in sorted(set(seen) - set(expected)):
        reasons.append(f"unknown check {key}")
    return reasons


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("kind", choices=sorted(EXPECTED))
    parser.add_argument("output")
    parser.add_argument("--rc", type=int, required=True)
    args = parser.parse_args()
    with open(args.output, encoding="utf-8", errors="replace") as handle:
        lines = [raw.rstrip("\r\n") for raw in handle]
    reasons = evaluate(args.kind, lines, args.rc)
    passed = len(EXPECTED[args.kind])
    if reasons:
        for reason in reasons:
            print(f"  {reason}")
        print(f"{args.kind.upper()} GATE: FAIL ({len(reasons)} reason(s))")
        return 1
    print(f"{args.kind.upper()} GATE: PASS ({passed}/{passed} checks)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
