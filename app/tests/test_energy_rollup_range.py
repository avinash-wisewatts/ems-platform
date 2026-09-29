"""Migration 283: analytics.energy_semantic_rollup_15min_range -- the
15-minute semantic rollup view restricted, before grouping, to an
organization, devices and a whole-bucket UTC range -- and its use for the
fresh 15-minute tail of analytics.get_portal_asset_energy_series.

The helper must return exactly the view's rows: for every range, its rows
equal the view's rows for the same organization, devices and whole UTC
15-minute buckets, on every column. Runs against the disposable ems_test
database; every test is one rolled-back transaction.
"""

from datetime import datetime, timedelta, timezone
from decimal import Decimal

import psycopg
import pytest

from tests.test_asset_energy_tier_read import CONNINFO, T0, Tenant

UTC = timezone.utc
HELPER_SIG = "analytics.energy_semantic_rollup_15min_range(uuid, uuid[], timestamptz, timestamptz)"
SERIES_SIG = "analytics.get_portal_asset_energy_series(bigint, uuid, uuid[], timestamptz, timestamptz, text, timestamptz)"
OLD_LINE = "            FROM analytics.v_energy_semantic_rollup_15min AS r"
NEW_LINE = ("            FROM analytics.energy_semantic_rollup_15min_range(v_org, v_all_devs, "
            "GREATEST(v_c15, v_fine_from), v_grid_to) AS r")
M282_MD5 = "4d3ead0684b9b75938126020455d15d3"


@pytest.fixture
def tx():
    with psycopg.connect(CONNINFO) as connection:
        yield connection
        connection.rollback()


# ---------------------------------------------------------------------------
# Contract
# ---------------------------------------------------------------------------


def test_helper_is_invoker_sql_stable_inlinable_and_not_granted():
    with psycopg.connect(CONNINFO) as connection:
        row = connection.execute(
            """
            SELECT p.prosecdef, p.provolatile, p.proconfig IS NULL, l.lanname, r.rolname,
                   has_function_privilege('public', p.oid, 'EXECUTE'),
                   has_function_privilege('ems_app', p.oid, 'EXECUTE'),
                   has_function_privilege('grafana_reader', p.oid, 'EXECUTE')
            FROM pg_proc p JOIN pg_roles r ON r.oid = p.proowner JOIN pg_language l ON l.oid = p.prolang
            WHERE p.oid = %s::regprocedure
            """,
            (HELPER_SIG,),
        ).fetchone()
    assert row == (False, "s", True, "sql", "ems_admin", False, False, False)


def test_helper_is_the_view_definition_plus_only_the_bounded_where():
    """Drift guard: if the view is ever redefined, this fails until the
    helper is re-derived from it."""

    with psycopg.connect(CONNINFO) as connection:
        src, viewdef = connection.execute(
            "SELECT prosrc, pg_get_viewdef('analytics.v_energy_semantic_rollup_15min'::regclass) "
            "FROM pg_proc WHERE oid = %s::regprocedure",
            (HELPER_SIG,),
        ).fetchone()
    anchor = "FROM analytics.v_energy_consumption_native n"
    head, tail = src.split(anchor, 1)
    where, rest = tail.split("\n          GROUP BY", 1)
    assert head + anchor + "\n          GROUP BY" + rest == viewdef
    assert where.lstrip().startswith("WHERE n.organization_id = p_org")
    for required in ("n.device_id = ANY (p_device_ids)", "p_from < p_to", "isfinite(p_from)", "isfinite(p_to)",
                     "'2000-01-01 00:00:00+00'"):
        assert required in where


def test_series_function_is_migration_282_with_only_the_tail_line_changed():
    with psycopg.connect(CONNINFO) as connection:
        definition, secdef, owner, ems_app, grafana = connection.execute(
            """
            SELECT pg_get_functiondef(p.oid), p.prosecdef, r.rolname,
                   has_function_privilege('ems_app', p.oid, 'EXECUTE'),
                   has_function_privilege('grafana_reader', p.oid, 'EXECUTE')
            FROM pg_proc p JOIN pg_roles r ON r.oid = p.proowner WHERE p.oid = %s::regprocedure
            """,
            (SERIES_SIG,),
        ).fetchone()
        reverted_md5 = connection.execute(
            "SELECT md5(replace(%s, %s, %s))", (definition, NEW_LINE, OLD_LINE)
        ).fetchone()[0]
    assert NEW_LINE in definition and OLD_LINE not in definition
    assert reverted_md5 == M282_MD5
    assert (secdef, owner, ems_app, grafana) == (True, "ems_admin", True, False)


def test_helper_prunes_by_bucket_start_and_is_inlined():
    with psycopg.connect(CONNINFO) as connection:
        plan = "\n".join(r[0] for r in connection.execute(
            # Stable arguments, as the series function passes (a volatile argument
            # such as gen_random_uuid() would legitimately prevent inlining).
            "EXPLAIN (COSTS OFF) SELECT * FROM analytics.energy_semantic_rollup_15min_range("
            "'00000000-0000-0000-0000-0000000000a1'::uuid, ARRAY['00000000-0000-0000-0000-0000000002a1'::uuid], "
            "now() - interval '20 minutes', now())"
        ).fetchall())
    assert "Function Scan" not in plan               # inlined
    assert "bucket_start >=" in plan and "bucket_start <" in plan


# ---------------------------------------------------------------------------
# Parity: helper rows == view rows
# ---------------------------------------------------------------------------


def _seed_1min(cur, t: Tenant, device: str, start: datetime, minutes: int, *, skip=(), quality=None):
    for i in range(minutes):
        if i in skip:
            continue
        b = start + timedelta(minutes=i)
        q = (quality or {}).get(i, "GOOD")
        valid = q not in ("IMPLAUSIBLE_DELTA", "INITIAL")
        cur.execute(
            """
            INSERT INTO analytics.energy_consumption_1min (
                bucket_start, organization_id, site_id, device_id, previous_bucket_start,
                import_register_wh, previous_import_register_wh, import_consumption_wh,
                import_consumption_kwh, import_quality_code, import_is_valid, import_reset_detected, import_rollover_detected,
                export_register_wh, previous_export_register_wh, export_consumption_wh,
                export_consumption_kwh, export_quality_code, export_is_valid, export_reset_detected, export_rollover_detected,
                gap_detected)
            VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, FALSE, %s, %s, %s, %s, %s, %s, FALSE, FALSE, %s)
            """,
            (b, t.org, t.site, device, b - timedelta(minutes=1),
             1000 + 100 * i, 900 + 100 * i, Decimal(100) if valid else None, Decimal("0.1") if valid else None,
             q, valid, q == "RESET",
             50 + i, 49 + i, Decimal(1) if valid else None, Decimal("0.001") if valid else None, q, valid,
             q == "GAP"),
        )


def _seed_5min(cur, t: Tenant, device: str, start: datetime, count: int):
    for i in range(count):
        b = start + timedelta(minutes=5 * i)
        cur.execute(
            """
            INSERT INTO analytics.energy_consumption_5min (
                bucket_start, organization_id, site_id, device_id, previous_bucket_start,
                import_consumption_wh, import_consumption_kwh, import_quality_code, import_is_valid,
                import_reset_detected, import_rollover_detected,
                export_consumption_wh, export_consumption_kwh, export_quality_code, export_is_valid,
                export_reset_detected, export_rollover_detected, gap_detected)
            VALUES (%s, %s, %s, %s, %s, 500, 0.5, 'GOOD', TRUE, FALSE, FALSE, 5, 0.005, 'GOOD', TRUE, FALSE, FALSE, FALSE)
            """,
            (b, t.org, t.site, device, b - timedelta(minutes=5)),
        )


def _diff(cur, org, devices, lo, hi) -> tuple[int, int, int]:
    """(helper-only rows, view-only rows, helper rows) where the view is
    filtered to the same organization, devices and whole UTC 15-minute
    buckets the helper covers."""

    cur.execute(
        """
        WITH b AS (
            SELECT CASE WHEN isfinite(%(lo)s::timestamptz)
                        THEN date_bin('15 minutes', %(lo)s::timestamptz, TIMESTAMPTZ '2000-01-01 00:00:00+00')
                        ELSE %(lo)s::timestamptz END AS f,
                   CASE WHEN isfinite(%(hi)s::timestamptz)
                        THEN date_bin('15 minutes', %(hi)s::timestamptz - interval '1 microsecond',
                                      TIMESTAMPTZ '2000-01-01 00:00:00+00') + interval '15 minutes'
                        ELSE %(hi)s::timestamptz END AS t
        ),
        h AS (SELECT * FROM analytics.energy_semantic_rollup_15min_range(%(org)s, %(dev)s::uuid[], %(lo)s, %(hi)s)),
        v AS (SELECT r.* FROM analytics.v_energy_semantic_rollup_15min r, b
              WHERE r.organization_id = %(org)s AND r.device_id = ANY(%(dev)s::uuid[])
                AND %(lo)s::timestamptz < %(hi)s::timestamptz
                AND r.bucket_start >= b.f AND r.bucket_start < b.t)
        SELECT (SELECT count(*) FROM (SELECT * FROM h EXCEPT ALL SELECT * FROM v) x),
               (SELECT count(*) FROM (SELECT * FROM v EXCEPT ALL SELECT * FROM h) y),
               (SELECT count(*) FROM h)
        """,
        {"org": org, "dev": devices, "lo": lo, "hi": hi},
    )
    return cur.fetchone()


def test_helper_rows_equal_the_view_rows_for_every_range(tx):
    with tx.cursor() as cur:
        t = Tenant(cur)
        a = t.device("Range meter A")
        b = t.device("Range meter B")
        c = t.device("Range meter C")            # 5-minute native rows
        _seed_1min(cur, t, a, T0, 90, skip=(7, 8, 40),
                   quality={3: "GAP", 20: "IMPLAUSIBLE_DELTA", 33: "RESET", 0: "INITIAL"})
        _seed_1min(cur, t, b, T0 + timedelta(minutes=5), 60, quality={10: "GAP"})
        _seed_5min(cur, t, c, T0, 18)
        other = Tenant(cur)                      # another organization's data must never appear
        d = other.device("Foreign meter")
        _seed_1min(cur, other, d, T0, 60)

        ranges = [
            (T0, T0 + timedelta(minutes=90)),                                      # aligned
            (T0 + timedelta(minutes=7), T0 + timedelta(minutes=52)),               # unaligned both ends
            (T0 + timedelta(minutes=15), T0 + timedelta(minutes=16)),              # inside one bucket
            (T0 + timedelta(minutes=30), T0 + timedelta(minutes=30)),              # empty: from = to
            (T0 + timedelta(minutes=45), T0 + timedelta(minutes=30)),              # empty: from > to
            (datetime(2000, 1, 1, tzinfo=UTC), T0 + timedelta(minutes=45)),         # long history
            (T0 + timedelta(days=5), T0 + timedelta(days=6)),                      # no data
        ]
        results = {}
        for lo, hi in ranges:
            results[(lo, hi)] = _diff(cur, t.org, [a, b, c], lo, hi)
        results["infinite"] = _diff(cur, t.org, [a, b, c], "-infinity", "infinity")
        results["foreign"] = _diff(cur, t.org, [d], T0, T0 + timedelta(hours=2))

    for key, (helper_only, view_only, helper_rows) in results.items():
        assert (helper_only, view_only) == (0, 0), key
    # A: minutes 0-89 -> 6 buckets; B: minutes 5-64 -> 5 buckets; C: 18 x 5 min -> 6 buckets.
    assert results[(T0, T0 + timedelta(minutes=90))][2] == 6 + 5 + 6
    assert results[(T0 + timedelta(minutes=30), T0 + timedelta(minutes=30))][2] == 0
    assert results[(T0 + timedelta(minutes=45), T0 + timedelta(minutes=30))][2] == 0
    assert results[(T0 + timedelta(days=5), T0 + timedelta(days=6))][2] == 0
    assert results["foreign"][2] == 0            # organization filter: the tenant does not own device D
