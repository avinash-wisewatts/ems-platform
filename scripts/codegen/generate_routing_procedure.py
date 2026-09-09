#!/usr/bin/env python3
"""Phase 4 -- deterministic OFFLINE routing procedure generator.

Renders a domain routing procedure (currently only
telemetry.load_environment_measurements_incremental) from a declarative routing
spec plus a fixed SQL template. It performs NO database access, NO network I/O,
and emits NO runtime-dynamic SQL: the output is a plain
`CREATE OR REPLACE PROCEDURE ...` body identical in structure to the
hand-written one, with the routing-driven name/column lists filled in from the
spec. Repeated runs on the same inputs produce byte-identical output.

Source of truth for the spec: scripts/codegen/routing/*.routing.json
The 12 `payload_columns` entries of kind "pivot" mirror, one-for-one, the
config.parameter_routing rows seeded by
postgres/migrations/227_parameter_routing_foundation.sql. Entries of kind
"null" are fixed non-sourced columns of the destination table (they are NOT
routing rows). `legacy_source_aliases` are pre-rename source names the deployed
loader still accepts defensively; they are NOT semantic identities and NOT
config.parameter_routing rows.

Usage:
    generate_routing_procedure.py --spec SPEC.json --template TMPL --out OUT.sql
    generate_routing_procedure.py --spec SPEC.json --template TMPL --out OUT.sql --check

--check regenerates and compares against OUT.sql without writing; exit 1 on any
difference (for CI). Invalid or ambiguous specs exit 2 (fail closed).
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

ALLOWED_DESTINATION_TABLES = ("telemetry.environment_measurements",)
ALLOWED_TRANSFORMS = ("IDENTITY", "DOUBLE_PRECISION", "ROUND_INTEGER")
ALLOWED_KINDS = ("pivot", "null")

MARKERS = (
    "{{PREFILTER_IN_LIST__12}}",
    "{{PREFILTER_IN_LIST__6}}",
    "{{PREFILTER_IN_LIST__23}}",
    "{{FULL_RESOLUTION_PAYLOAD}}",
    "{{RANKED_PAYLOAD}}",
    "{{UPDATE_SET_PAYLOAD}}",
    "{{INSERT_PAYLOAD_COLS}}",
    "{{INSERT_SELECT_PAYLOAD}}",
)


class SpecError(Exception):
    """Raised for an invalid or ambiguous routing spec (fail closed)."""


def _require(cond: bool, msg: str) -> None:
    if not cond:
        raise SpecError(msg)


def _is_nonempty_str(v: object) -> bool:
    return isinstance(v, str) and v != "" and v.strip() == v


def validate_spec(spec: dict) -> None:
    _require(isinstance(spec, dict), "spec must be a JSON object")
    _require(spec.get("destination_table") in ALLOWED_DESTINATION_TABLES,
             f"destination_table must be one of {ALLOWED_DESTINATION_TABLES}, "
             f"got {spec.get('destination_table')!r}")
    _require(_is_nonempty_str(spec.get("profile_code")), "profile_code must be a non-empty string")
    _require(_is_nonempty_str(spec.get("procedure")), "procedure must be a non-empty string")

    cols = spec.get("payload_columns")
    _require(isinstance(cols, list) and len(cols) >= 1,
             "payload_columns must be a non-empty list")

    seen_cols: set[str] = set()
    seen_points: set[str] = set()
    canonical_points: list[str] = []
    alias_points: list[str] = []

    for idx, c in enumerate(cols):
        _require(isinstance(c, dict), f"payload_columns[{idx}] must be an object")
        col = c.get("destination_column")
        _require(_is_nonempty_str(col), f"payload_columns[{idx}].destination_column must be a non-empty string")
        _require(col not in seen_cols, f"duplicate destination_column {col!r}")
        seen_cols.add(col)

        kind = c.get("kind")
        _require(kind in ALLOWED_KINDS, f"payload_columns[{idx}].kind must be one of {ALLOWED_KINDS}, got {kind!r}")

        if kind == "null":
            _require(_is_nonempty_str(c.get("null_type")),
                     f"payload_columns[{idx}] (null) requires a non-empty null_type")
            _require("logical_point" not in c and "value_transform" not in c and "legacy_source_aliases" not in c,
                     f"payload_columns[{idx}] (null) must not carry routing keys")
            continue

        # kind == "pivot"
        lp = c.get("logical_point")
        _require(_is_nonempty_str(lp), f"payload_columns[{idx}] (pivot) requires a non-empty logical_point")
        _require(lp not in seen_points, f"duplicate logical_point {lp!r} across pivot rows")
        seen_points.add(lp)
        canonical_points.append(lp)

        vt = c.get("value_transform")
        _require(vt in ALLOWED_TRANSFORMS,
                 f"payload_columns[{idx}] value_transform must be one of {ALLOWED_TRANSFORMS}, got {vt!r}")

        pc = c.get("parameter_code", None)
        _require(pc is None or _is_nonempty_str(pc),
                 f"payload_columns[{idx}].parameter_code must be null or a non-empty string")

        aliases = c.get("legacy_source_aliases")
        if aliases is not None:
            _require(isinstance(aliases, list) and len(aliases) >= 1,
                     f"payload_columns[{idx}].legacy_source_aliases must be a non-empty list when present")
            for a in aliases:
                _require(_is_nonempty_str(a),
                         f"payload_columns[{idx}].legacy_source_aliases entries must be non-empty strings")
                _require(a not in seen_points and a != lp,
                         f"legacy alias {a!r} collides with a canonical logical_point")
                alias_points.append(a)

    _require(canonical_points, "spec must contain at least one pivot payload column")

    prefilter = spec.get("prefilter_logical_points")
    _require(isinstance(prefilter, list) and len(prefilter) >= 1,
             "prefilter_logical_points must be a non-empty list")
    for p in prefilter:
        _require(_is_nonempty_str(p), "prefilter_logical_points entries must be non-empty strings")
    _require(len(prefilter) == len(set(prefilter)), "prefilter_logical_points contains duplicates")

    expected = set(canonical_points) | set(alias_points)
    got = set(prefilter)
    missing = expected - got
    extra = got - expected
    _require(not missing, f"prefilter_logical_points is missing required names: {sorted(missing)}")
    _require(not extra, f"prefilter_logical_points has names not backed by a pivot row or alias: {sorted(extra)}")


def _pivot_predicate(entry: dict) -> str:
    lp = entry["logical_point"]
    aliases = entry.get("legacy_source_aliases") or []
    if not aliases:
        return f"np.logical_point = '{lp}'"
    names = list(aliases) + [lp]
    return "np.logical_point IN (" + ",".join(f"'{n}'" for n in names) + ")"


def _pivot_expression(entry: dict) -> str:
    pred = _pivot_predicate(entry)
    vt = entry["value_transform"]
    if vt == "ROUND_INTEGER":
        return f"ROUND(MAX(np.numeric_value) FILTER (WHERE {pred}))::INTEGER"
    if vt == "DOUBLE_PRECISION":
        return f"MAX(np.numeric_value) FILTER (WHERE {pred})::DOUBLE PRECISION"
    # IDENTITY
    return f"MAX(np.numeric_value) FILTER (WHERE {pred})"


def _in_list(names: list[str], indent: int) -> str:
    pad = " " * indent
    out = []
    for i, n in enumerate(names):
        comma = "," if i < len(names) - 1 else ""
        out.append(f"{pad}'{n}'{comma}")
    return "\n".join(out)


def _full_resolution_payload(cols: list[dict]) -> str:
    pad = " " * 4
    out = []
    for i, c in enumerate(cols):
        comma = "," if i < len(cols) - 1 else ""
        col = c["destination_column"]
        if c["kind"] == "null":
            out.append(f"{pad}NULL::{c['null_type']} AS {col}{comma}")
        else:
            out.append(f"{pad}{_pivot_expression(c)} AS {col}{comma}")
    return "\n".join(out)


def _ranked_payload(cols: list[dict]) -> str:
    pad = " " * 11
    # every ranked.<col> line carries a trailing comma (correction_deadline follows)
    return "\n".join(f"{pad}ranked.{c['destination_column']}," for c in cols)


def _update_set_payload(cols: list[dict]) -> str:
    pad = " " * 8
    out = []
    for i, c in enumerate(cols):
        comma = "," if i < len(cols) - 1 else ""
        col = c["destination_column"]
        out.append(f"{pad}{col}=COALESCE(s.{col},t.{col}){comma}")
    return "\n".join(out)


def _insert_payload_cols(cols: list[dict]) -> str:
    pad = " " * 6
    out = []
    for i, c in enumerate(cols):
        comma = "," if i < len(cols) - 1 else ""
        out.append(f"{pad}{c['destination_column']}{comma}")
    return "\n".join(out)


def _insert_select_payload(cols: list[dict]) -> str:
    pad = " " * 6
    out = []
    for i, c in enumerate(cols):
        comma = "," if i < len(cols) - 1 else ""
        out.append(f"{pad}s.{c['destination_column']}{comma}")
    return "\n".join(out)


def render(spec: dict, template: str) -> str:
    """Pure, deterministic render. Raises SpecError on an invalid/ambiguous spec."""
    validate_spec(spec)

    for marker in MARKERS:
        if marker not in template:
            raise SpecError(f"template is missing required marker {marker}")

    cols = spec["payload_columns"]
    prefilter = spec["prefilter_logical_points"]

    replacements = {
        "{{PREFILTER_IN_LIST__12}}": _in_list(prefilter, 12),
        "{{PREFILTER_IN_LIST__6}}": _in_list(prefilter, 6),
        "{{PREFILTER_IN_LIST__23}}": _in_list(prefilter, 23),
        "{{FULL_RESOLUTION_PAYLOAD}}": _full_resolution_payload(cols),
        "{{RANKED_PAYLOAD}}": _ranked_payload(cols),
        "{{UPDATE_SET_PAYLOAD}}": _update_set_payload(cols),
        "{{INSERT_PAYLOAD_COLS}}": _insert_payload_cols(cols),
        "{{INSERT_SELECT_PAYLOAD}}": _insert_select_payload(cols),
    }

    out = template
    for marker, value in replacements.items():
        out = out.replace(marker, value)

    if "{{" in out or "}}" in out:
        raise SpecError("unexpanded marker remains after render")
    return out


def routing_rows(spec: dict) -> list[dict]:
    """The config.parameter_routing seed rows implied by the spec: exactly the
    'pivot' payload columns. 'null' columns and legacy aliases are NOT rows."""
    validate_spec(spec)
    rows = []
    for c in spec["payload_columns"]:
        if c["kind"] != "pivot":
            continue
        rows.append({
            "profile_code": spec["profile_code"],
            "logical_point": c["logical_point"],
            "parameter_code": c.get("parameter_code"),
            "destination_table": spec["destination_table"],
            "destination_column": c["destination_column"],
            "value_transform": c["value_transform"],
            "legacy_source_aliases": c.get("legacy_source_aliases"),
        })
    return rows


def load_spec(path: str | Path) -> dict:
    return json.loads(Path(path).read_text(encoding="utf-8"))


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--spec", required=True)
    ap.add_argument("--template", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--check", action="store_true",
                    help="regenerate and diff against --out; do not write; exit 1 on difference")
    args = ap.parse_args(argv)

    try:
        spec = load_spec(args.spec)
        template = Path(args.template).read_text(encoding="utf-8")
        rendered = render(spec, template)
    except SpecError as exc:
        print(f"routing-generator: FAIL (invalid spec): {exc}", file=sys.stderr)
        return 2
    except (OSError, json.JSONDecodeError) as exc:
        print(f"routing-generator: FAIL (io): {exc}", file=sys.stderr)
        return 2

    if args.check:
        try:
            current = Path(args.out).read_text(encoding="utf-8")
        except OSError as exc:
            print(f"routing-generator: FAIL (--check: cannot read {args.out}): {exc}", file=sys.stderr)
            return 1
        if current != rendered:
            print(f"routing-generator: DRIFT: {args.out} does not match a fresh render of {args.spec}",
                  file=sys.stderr)
            return 1
        print(f"routing-generator: OK ({args.out} matches {args.spec})")
        return 0

    Path(args.out).write_text(rendered, encoding="utf-8", newline="\n")
    print(f"routing-generator: wrote {args.out} ({len(rendered)} bytes)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
