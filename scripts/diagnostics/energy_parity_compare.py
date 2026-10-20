#!/usr/bin/env python3
"""Compare two energy_parity_capture.sql outputs (release-plan P5 / G2, B1).

Usage:
    python3 energy_parity_compare.py BEFORE.txt AFTER.txt [--criterion values|full]

Reads only the two local files. Exit status:
    0  PASS   same capture parameters, same (asset, resolution) set, no
              errors, and every fingerprint selected by --criterion equal
    1  FAIL   at least one mismatch, missing pair or capture error
    2  INVALID the captures are not comparable (different range or
              resolutions, or an incomplete capture)

--criterion values (default) compares rows, import/export totals and
values_md5 (interval bounds, consumption, quality status). --criterion full
also requires full_md5 (every returned column) to match. The pass criterion
for a release is product-owner decision D3; this tool only reports.

The timing summary (per-call milliseconds of analytics.get_canonical_energy_read)
is informational and never affects the exit status.
"""

import argparse
import statistics
import sys


def parse(path):
    capture, end, rows, errors = None, None, {}, []
    with open(path, encoding="utf-8", errors="replace") as handle:
        for raw in handle:
            line = raw.strip()
            # psql prefixes notices with "NOTICE:" or, with -f, "psql:<file>:<line>: NOTICE:".
            marker = line.find("NOTICE:")
            if marker != -1:
                line = line[marker + len("NOTICE:"):].strip()
            fields = line.split("|")
            kind = fields[0]
            if kind == "CAPTURE" and len(fields) == 8:
                capture = {
                    "label": fields[1], "from": fields[2], "to": fields[3],
                    "resolutions": fields[4], "started": fields[5],
                    "read_fn_md5": fields[6], "assets": int(fields[7]),
                }
            elif kind == "PARITY" and len(fields) == 11:
                key = (fields[2], fields[4])
                rows[key] = {
                    "rows": int(fields[5]), "import": fields[6], "export": fields[7],
                    "values_md5": fields[8], "full_md5": fields[9], "ms": int(fields[10]),
                }
            elif kind == "PARITY_ERROR" and len(fields) >= 6:
                errors.append((fields[2], fields[3], fields[4], "|".join(fields[5:])))
            elif kind == "CAPTURE_END" and len(fields) == 5:
                end = {"calls": int(fields[2]), "errors": int(fields[3]), "total_ms": int(fields[4])}
    return capture, end, rows, errors


def timing(rows):
    values = sorted(r["ms"] for r in rows.values())
    if not values:
        return "no calls"
    p95 = values[min(len(values) - 1, int(round(0.95 * (len(values) - 1))))]
    return (f"calls={len(values)} p50={statistics.median(values):.0f} ms "
            f"p95={p95} ms max={values[-1]} ms total={sum(values)} ms")


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("before")
    parser.add_argument("after")
    parser.add_argument("--criterion", choices=("values", "full"), default="values")
    parser.add_argument("--expect-assets", type=int, default=None,
                        help="INVALID unless both captures cover exactly this many assets, one line per resolution")
    args = parser.parse_args()

    b_cap, b_end, b_rows, b_err = parse(args.before)
    a_cap, a_end, a_rows, a_err = parse(args.after)

    for name, cap, end in (("before", b_cap, b_end), ("after", a_cap, a_end)):
        if cap is None or end is None:
            print(f"INVALID: {name} capture has no CAPTURE / CAPTURE_END line (incomplete or failed run)")
            return 2
    for field in ("from", "to", "resolutions"):
        if b_cap[field] != a_cap[field]:
            print(f"INVALID: {field} differs: {b_cap[field]} vs {a_cap[field]}")
            return 2
    if args.expect_assets is not None:
        expected_pairs = args.expect_assets * len(b_cap["resolutions"].split(","))
        for name, cap, rows in (("before", b_cap, b_rows), ("after", a_cap, a_rows)):
            if cap["assets"] != args.expect_assets or len(rows) != expected_pairs:
                print(f"INVALID: {name} capture has assets={cap['assets']} and {len(rows)} PARITY lines; "
                      f"expected {args.expect_assets} assets and {expected_pairs} lines")
                return 2

    print(f"before: {b_cap['label']} started {b_cap['started']} assets={b_cap['assets']} read_fn_md5={b_cap['read_fn_md5']}")
    print(f"after:  {a_cap['label']} started {a_cap['started']} assets={a_cap['assets']} read_fn_md5={a_cap['read_fn_md5']}")
    print(f"range {b_cap['from']} -> {b_cap['to']}, resolutions {b_cap['resolutions']}, criterion {args.criterion}")
    print("read function " + ("UNCHANGED" if b_cap["read_fn_md5"] == a_cap["read_fn_md5"] else "REPLACED") + " between captures")

    problems = []
    for name, errs in (("before", b_err), ("after", a_err)):
        for asset, res, state, msg in errs:
            problems.append(f"ERROR in {name}: asset {asset} res {res}: {state} {msg}")
    for key in sorted(set(b_rows) | set(a_rows)):
        if key not in b_rows or key not in a_rows:
            problems.append(f"MISSING: asset {key[0]} res {key[1]} only in {'before' if key in b_rows else 'after'}")
            continue
        b, a = b_rows[key], a_rows[key]
        fields = ["rows", "import", "export", "values_md5"] + (["full_md5"] if args.criterion == "full" else [])
        diffs = [f"{f} {b[f]} -> {a[f]}" for f in fields if b[f] != a[f]]
        if diffs:
            problems.append(f"MISMATCH: asset {key[0]} res {key[1]}: " + "; ".join(diffs))

    compared = len(set(b_rows) & set(a_rows))
    print(f"pairs compared: {compared}")
    print(f"timing before: {timing(b_rows)}")
    print(f"timing after:  {timing(a_rows)}")
    for problem in problems:
        print(problem)
    if problems:
        print(f"RESULT: FAIL ({len(problems)} problem(s))")
        return 1
    if compared == 0:
        print("RESULT: INVALID (nothing to compare)")
        return 2
    print("RESULT: PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
