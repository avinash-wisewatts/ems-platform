"""Migration 285: analytics.energy_direction_status without SET search_path,
so the planner inlines its IMMUTABLE CASE into
analytics.get_portal_asset_energy_series.

The helper's body, grants and results must be unchanged, and the series
function's output must be identical to the non-inlinable (SET search_path)
helper's, which the parity test reinstates as a session-temporary copy.

Runs against the disposable ems_test database; every scenario is one
rolled-back transaction.
"""

import itertools
from datetime import datetime, timedelta, timezone
from decimal import Decimal
from pathlib import Path

import psycopg
import pytest

from tests.test_asset_energy_tier_read import CONNINFO, FAR, Tenant, checkpoints
from tests.test_energy_series_set_based_quality import RESOLUTIONS, _rows, _scenario

UTC = timezone.utc
HELPER = "analytics.energy_direction_status(bigint, bigint, bigint, bigint, bigint, bigint)"
SERIES = "analytics.get_portal_asset_energy_series"
MIGRATIONS = Path(__file__).resolve().parents[2] / "postgres" / "migrations"
REF_HELPER = "pg_temp.energy_direction_status_279"
REF_SERIES = "pg_temp.energy_series_non_inlined_reference"


def _migration_function(filename: str, head: str) -> str:
    text = (MIGRATIONS / filename).read_text(encoding="utf-8")
    start = text.index(head)
    return text[start:text.index("$function$;", start) + len("$function$;")]


def reference_ddl() -> list[str]:
    """Migration 279's helper (with its SET search_path, so never inlined) and
    migration 284's series function calling it, both in pg_temp."""

    helper = _migration_function("279_asset_energy_tier_read.sql",
                                 "CREATE OR REPLACE FUNCTION analytics.energy_direction_status\n")
    helper = helper.replace("CREATE OR REPLACE FUNCTION analytics.energy_direction_status\n",
                            f"CREATE FUNCTION {REF_HELPER}\n", 1)
    assert "SET search_path TO pg_catalog" in helper
    series = _migration_function("284_analytics_energy_series_set_based_quality.sql",
                                 "CREATE OR REPLACE FUNCTION analytics.get_portal_asset_energy_series\n")
    series = series.replace("CREATE OR REPLACE FUNCTION analytics.get_portal_asset_energy_series\n",
                            f"CREATE FUNCTION {REF_SERIES}\n", 1)
    assert series.count("analytics.energy_direction_status(") == 4
    series = series.replace("analytics.energy_direction_status(", f"{REF_HELPER}(")
    return [helper, series]


@pytest.fixture
def tx():
    with psycopg.connect(CONNINFO) as connection:
        yield connection
        connection.rollback()


# ---------------------------------------------------------------------------
# Contract
# ---------------------------------------------------------------------------


def test_helper_has_no_set_clause_and_is_otherwise_unchanged():
    with psycopg.connect(CONNINFO) as connection:
        row = connection.execute(
            """
            SELECT l.lanname, p.provolatile, p.prosecdef, p.proisstrict, p.proconfig, r.rolname, p.prosrc,
                   has_function_privilege('public', p.oid, 'EXECUTE'),
                   has_function_privilege('ems_app', p.oid, 'EXECUTE'),
                   has_function_privilege('grafana_reader', p.oid, 'EXECUTE'),
                   obj_description(p.oid, 'pg_proc')
            FROM pg_proc p JOIN pg_roles r ON r.oid = p.proowner JOIN pg_language l ON l.oid = p.prolang
            WHERE p.oid = %s::regprocedure
            """,
            (HELPER,),
        ).fetchone()
    lang, volatile, secdef, strict, config, owner, src, public, ems_app, grafana, comment = row
    assert (lang, volatile, secdef, strict, config, owner) == ("sql", "i", False, False, None, "ems_admin")
    assert (public, ems_app, grafana) == (False, False, False)
    body_279 = _migration_function("279_asset_energy_tier_read.sql",
                                   "CREATE OR REPLACE FUNCTION analytics.energy_direction_status\n")
    assert src == body_279.split("AS $function$", 1)[1].rsplit("$function$", 1)[0]
    assert comment.startswith("Per-direction Energy status of an aggregated bucket")


def test_helper_is_inlined_into_its_caller():
    with psycopg.connect(CONNINFO) as connection:
        plan = "\n".join(r[0] for r in connection.execute(
            f"EXPLAIN (VERBOSE, COSTS OFF) SELECT {HELPER.split('(')[0]}(g, g + 1, g, g, g, g) "
            "FROM generate_series(0::bigint, 3::bigint) AS g"
        ).fetchall())
    assert "energy_direction_status" not in plan
    assert "CASE WHEN" in plan


def _expected(valid, invalid, reset, gap, reconstructed, rollover):
    """Migration 269's precedence; NULL never satisfies a comparison."""

    def gt0(v):
        return v is not None and v > 0

    def eq0(v):
        return v is not None and v == 0

    if gt0(invalid):
        return "INVALID_INTERVALS"
    if gt0(reset):
        return "RESET_DETECTED"
    if gt0(gap):
        return "GAPS_DETECTED"
    if gt0(reconstructed):
        return "RECONSTRUCTED_TIMING"
    if gt0(rollover):
        return "ROLLOVER_DETECTED"
    if eq0(valid) and eq0(invalid) and eq0(reconstructed):
        return "INVALID_INTERVALS"
    return "GOOD"


def test_every_counter_combination_including_null_matches_the_precedence(tx):
    values = (None, 0, 1, 2)
    combos = list(itertools.product(values, repeat=6))
    with tx.cursor() as cur:
        cur.execute(
            f"""
            SELECT c.ord, {HELPER.split('(')[0]}(c.a, c.b, c.c, c.d, c.e, c.f)
            FROM jsonb_to_recordset(%s::jsonb) AS c(ord int, a bigint, b bigint, c bigint, d bigint, e bigint, f bigint)
            ORDER BY c.ord
            """,
            (psycopg.types.json.Jsonb([dict(zip("abcdef", combo), ord=i) for i, combo in enumerate(combos)]),),
        )
        got = [r[1] for r in cur.fetchall()]
    assert len(got) == 4 ** 6
    assert got == [_expected(*combo) for combo in combos]


# ---------------------------------------------------------------------------
# Parity: the series with the inlined helper == with the non-inlinable one
# ---------------------------------------------------------------------------


def test_series_output_is_identical_to_the_non_inlined_helper_on_randomised_scenarios():
    ddl = reference_ddl()
    statuses = set()
    for seed in range(12):
        with psycopg.connect(CONNINFO) as connection:
            with connection.cursor() as cur:
                for statement in ddl:
                    cur.execute(statement)
                t, assets, start, end, as_ofs = _scenario(cur, 100 + seed)
                for resolution in RESOLUTIONS:
                    lo, hi = (start, start + timedelta(hours=3)) if resolution == "1m" else (start, end)
                    for as_of in as_ofs:
                        args = (t.user, t.site, assets, lo, hi, resolution, as_of)
                        names, new = _rows(cur, SERIES, args)
                        _, ref = _rows(cur, REF_SERIES, args)
                        assert new == ref, (seed, resolution, as_of, new - ref, ref - new)
                        i, e = names.index("import_status"), names.index("export_status")
                        statuses.update(r[i] for r in new)
                        statuses.update(r[e] for r in new)
            connection.rollback()
    assert {"GOOD", "INVALID_INTERVALS"} <= statuses, statuses


def test_series_output_is_identical_for_reset_gap_and_rollover_statuses(tx):
    """Every status the precedence can produce from measured rows (reset,
    gap, rollover, invalid, good), per 15-minute bucket and rolled up."""

    with tx.cursor() as cur:
        for statement in reference_ddl():
            cur.execute(statement)
        t = Tenant(cur)
        base = datetime.now(UTC).replace(minute=0, second=0, microsecond=0) - timedelta(days=2)
        asset, device = t.simple_asset("Flags")
        flags = {5: "reset", 20: "rollover", 35: "gap", 50: "invalid", 65: "reset", 66: "gap"}
        for m in range(-1, 180):
            kind = "initial" if m == -1 else flags.get(m, "good")
            valid = kind not in ("initial", "invalid")
            cur.execute(
                """
                INSERT INTO analytics.energy_consumption_1min (
                    bucket_start, organization_id, site_id, device_id,
                    import_consumption_kwh, import_quality_code, import_is_valid, import_reset_detected, import_rollover_detected,
                    export_consumption_kwh, export_quality_code, export_is_valid, export_reset_detected, export_rollover_detected,
                    gap_detected)
                VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s)
                """,
                (base + timedelta(minutes=m), t.org, t.site, device,
                 Decimal("0.1") if valid else None, {"initial": "INITIAL", "invalid": "IMPLAUSIBLE_DELTA", "gap": "GAP"}.get(kind, "GOOD"),
                 valid, kind == "reset", kind == "rollover",
                 Decimal("0.01") if valid else None, {"initial": "INITIAL", "invalid": "IMPLAUSIBLE_DELTA", "gap": "GAP"}.get(kind, "GOOD"),
                 valid, False, kind == "rollover", kind == "gap"),
            )
        t.refresh(base, base + timedelta(hours=3))
        statuses = set()
        for checkpoint in ({}, {"c15": base + timedelta(minutes=45)}):
            checkpoints(cur, **checkpoint)
            for resolution in ("15m", "30m", "1h", "1d"):
                args = (t.user, t.site, [asset], base, base + timedelta(hours=3), resolution, FAR)
                names, new = _rows(cur, SERIES, args)
                _, ref = _rows(cur, REF_SERIES, args)
                assert new == ref, (checkpoint, resolution)
                i, e = names.index("import_status"), names.index("export_status")
                statuses.update(r[i] for r in new)
                statuses.update(r[e] for r in new)
    assert {"GOOD", "INVALID_INTERVALS", "RESET_DETECTED", "GAPS_DETECTED", "ROLLOVER_DETECTED"} <= statuses, statuses
