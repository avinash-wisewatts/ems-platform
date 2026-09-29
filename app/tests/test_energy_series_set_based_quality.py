"""Migration 284: set-based Data Quality work in
analytics.get_portal_asset_energy_series.

Migration 284 replaces the per-bucket correlated subqueries of migration 282
(NOT_ASSIGNED, the device-first INITIAL count, assigned expected intervals)
with CTEs joined to the grid. Every output must be unchanged, so the property
test installs migration 283's exact function, taken from its migration file,
as a session-temporary reference and compares both functions row for row, on
every column, over randomised scenarios: binding windows starting and ending
inside buckets, device replacement with the new device's first reading inside
the range, separate import/export windows, missing, rejected and gap minutes,
never-reporting devices, several site time zones, capture intervals and tier
checkpoints, and as_of before, inside and after the range.

Runs against the disposable ems_test database; every scenario is one
rolled-back transaction.
"""

import random
from collections import Counter
from datetime import datetime, timedelta, timezone
from decimal import Decimal
from pathlib import Path

import psycopg
import pytest

from tests.test_asset_energy_tier_read import CONNINFO, FAR, Tenant, checkpoints

UTC = timezone.utc
SIG = "analytics.get_portal_asset_energy_series(bigint, uuid, uuid[], timestamptz, timestamptz, text, timestamptz)"
REFERENCE = "pg_temp.energy_series_283_reference"
MIGRATIONS = Path(__file__).resolve().parents[2] / "postgres" / "migrations"
RESOLUTIONS = ("1m", "15m", "30m", "1h", "1d")
PER_BUCKET = ("CROSS JOIN LATERAL (", "NOT EXISTS (SELECT 1 FROM imp_w", "NOT EXISTS (SELECT 1 FROM exp_w")


def reference_ddl() -> str:
    """Migration 283's CREATE FUNCTION, renamed into pg_temp."""

    text = (MIGRATIONS / "283_analytics_energy_rollup_tail_pruning.sql").read_text(encoding="utf-8")
    head = "CREATE OR REPLACE FUNCTION analytics.get_portal_asset_energy_series\n"
    start = text.index(head)
    end = text.index("$function$;", start) + len("$function$;")
    ddl = text[start:end].replace(head, f"CREATE FUNCTION {REFERENCE}\n", 1)
    assert all(marker in ddl for marker in PER_BUCKET)
    return ddl


@pytest.fixture
def tx():
    with psycopg.connect(CONNINFO) as connection:
        yield connection
        connection.rollback()


# ---------------------------------------------------------------------------
# Contract
# ---------------------------------------------------------------------------


def test_series_function_is_set_based_and_keeps_its_security():
    with psycopg.connect(CONNINFO) as connection:
        definition, secdef, volatile, owner, pinned, public, ems_app, grafana = connection.execute(
            """
            SELECT pg_get_functiondef(p.oid), p.prosecdef, p.provolatile, r.rolname, p.proconfig IS NOT NULL,
                   has_function_privilege('public', p.oid, 'EXECUTE'),
                   has_function_privilege('ems_app', p.oid, 'EXECUTE'),
                   has_function_privilege('grafana_reader', p.oid, 'EXECUTE')
            FROM pg_proc p JOIN pg_roles r ON r.oid = p.proowner WHERE p.oid = %s::regprocedure
            """,
            (SIG,),
        ).fetchone()
    assert not any(marker in definition for marker in PER_BUCKET)
    for cte in ("imp_first_ts AS (", "exp_first_ts AS (", "imp_cov AS (", "exp_cov AS (", "imp_init AS (", "exp_init AS ("):
        assert definition.count(cte) == 2, cte          # the 1m and the tiered result paths
    assert "energy_semantic_rollup_15min_range(v_org, v_all_devs, GREATEST(v_c15, v_fine_from), v_grid_to)" in definition
    assert (secdef, volatile, owner, pinned, public, ems_app, grafana) == (True, "s", "ems_admin", True, False, True, False)


# ---------------------------------------------------------------------------
# Property: 284 == 283 reference on every row and column
# ---------------------------------------------------------------------------


def _insert_rows(t: Tenant, device: str, rows) -> None:
    """rows: (instant, quality); valid only for GOOD."""

    for m, quality in rows:
        valid = quality == "GOOD"
        t.cur.execute(
            """
            INSERT INTO analytics.energy_consumption_1min (
                bucket_start, organization_id, site_id, device_id,
                import_consumption_kwh, import_quality_code, import_is_valid, import_reset_detected, import_rollover_detected,
                export_consumption_kwh, export_quality_code, export_is_valid, export_reset_detected, export_rollover_detected,
                gap_detected)
            VALUES (%s, %s, %s, %s, %s, %s, %s, FALSE, FALSE, %s, %s, %s, FALSE, FALSE, FALSE)
            """,
            (m, t.org, t.site, device, Decimal("0.1") if valid else None, quality, valid,
             Decimal("0.01") if valid else None, quality, valid),
        )


def _seed_device(t: Tenant, rng: random.Random, device: str, lo: datetime, hi: datetime, *, first_initial: bool) -> None:
    rows, m = [], lo
    while m < hi:
        roll = rng.random()
        if roll < 0.05:
            pass                                               # missing minute
        elif roll < 0.07:
            rows.append((m, "GAP"))
        elif roll < 0.10:
            rows.append((m, "IMPLAUSIBLE_DELTA"))
        elif roll < 0.11:
            rows.append((m, "INITIAL"))                         # a later INITIAL: counted as rejected
        else:
            rows.append((m, "GOOD"))
        m += timedelta(minutes=1)
    if first_initial and rows:
        rows[0] = (rows[0][0], "INITIAL")                       # the device's first-ever reading
    _insert_rows(t, device, rows)


def _minute(rng: random.Random, lo: datetime, hi: datetime) -> datetime:
    return lo + timedelta(minutes=rng.randrange(int((hi - lo).total_seconds() // 60)))


def _scenario(cur, seed: int):
    rng = random.Random(seed)
    tz = rng.choice(["UTC", "Asia/Kolkata", "Asia/Kathmandu", "Europe/London"])
    capture = rng.choice([60, 60, 60, 300, 900])
    t = Tenant(cur, tz=tz, capture=capture)
    base = datetime.now(UTC).replace(minute=0, second=0, microsecond=0) - timedelta(days=4)
    start = base + timedelta(minutes=rng.randrange(0, 60))     # off-grid range start
    end = start + timedelta(hours=rng.choice([20, 26, 30]), minutes=rng.randrange(0, 60))
    data_lo, data_hi = start - timedelta(hours=2), end + timedelta(hours=1)
    assets = []

    # A: one device bound since before the range; first reading before the range.
    asset, device = t.simple_asset("Steady")
    _seed_device(t, rng, device, data_lo, _minute(rng, start, data_hi), first_initial=True)
    assets.append(asset)

    # B: device replacement inside the range; the new device's first reading is
    # inside the range, before or after its binding starts.
    old_dev, new_dev = t.device("Old meter"), t.device("New meter")
    asset = t.asset("Replaced")
    swap = _minute(rng, start, end)
    t.bind_both(asset, old_dev, end=swap)
    t.bind_both(asset, new_dev, start=swap)
    _seed_device(t, rng, old_dev, data_lo, swap + timedelta(minutes=rng.randrange(0, 30)), first_initial=True)
    _seed_device(t, rng, new_dev, swap - timedelta(minutes=rng.randrange(-20, 20)), data_hi, first_initial=True)
    assets.append(asset)

    # C: import and export bound to different devices with different windows.
    imp_dev, exp_dev = t.device("Import meter"), t.device("Export meter")
    asset = t.asset("Split")
    t.bind(asset, imp_dev, "ENERGY_IMPORT_TOTAL", start=_minute(rng, start, end))
    t.bind(asset, exp_dev, "ENERGY_EXPORT_TOTAL", end=_minute(rng, start, end))
    _seed_device(t, rng, imp_dev, _minute(rng, data_lo, end), data_hi, first_initial=rng.random() < 0.7)
    _seed_device(t, rng, exp_dev, data_lo, _minute(rng, start, data_hi), first_initial=True)
    assets.append(asset)

    # D: bound, never reported (first/last data NULL).
    asset, _ = t.simple_asset("Silent")
    assets.append(asset)

    # E: assigned only for a short window strictly inside one bucket.
    dev = t.device("Short meter")
    asset = t.asset("Short window")
    lo = _minute(rng, start, end)
    t.bind_both(asset, dev, start=lo, end=lo + timedelta(minutes=rng.randrange(1, 14)))
    _seed_device(t, rng, dev, data_lo, data_hi, first_initial=True)
    assets.append(asset)

    t.refresh(data_lo, data_hi)
    mid = _minute(rng, start, end)
    checkpoints(cur, **rng.choice([{}, {"c15": mid}, {"c15": mid, "ch": mid - timedelta(hours=3), "cd": start}]))
    as_ofs = [FAR, _minute(rng, start, end) + timedelta(seconds=rng.randrange(0, 60)), start - timedelta(hours=1)]
    return t, assets, start, end, as_ofs


def _rows(cur, fn, args) -> Counter:
    cur.execute(f"SELECT * FROM {fn}(%s, %s, %s::uuid[], %s, %s, %s, %s)", args)
    names = [c.name for c in cur.description]
    rows = cur.fetchall()
    return names, Counter(tuple(tuple(v) if isinstance(v, list) else v for v in r) for r in rows)


def test_set_based_quality_equals_the_283_reference_on_randomised_scenarios():
    seen = Counter()
    ddl = reference_ddl()
    for seed in range(12):
        with psycopg.connect(CONNINFO) as connection:
            with connection.cursor() as cur:
                cur.execute(ddl)
                t, assets, start, end, as_ofs = _scenario(cur, seed)
                for resolution in RESOLUTIONS:
                    lo, hi = (start, start + timedelta(hours=3)) if resolution == "1m" else (start, end)
                    for as_of in as_ofs:
                        args = (t.user, t.site, assets, lo, hi, resolution, as_of)
                        names, new = _rows(cur, "analytics.get_portal_asset_energy_series", args)
                        _, ref = _rows(cur, REFERENCE, args)
                        assert new == ref, (seed, resolution, as_of, new - ref, ref - new)
                        for row in new:
                            r = dict(zip(names, row))
                            for d in ("import", "export"):
                                seen[r[f"{d}_data_state"]] += 1
                                if r[f"{d}_invalid_intervals"]:
                                    seen["invalid"] += 1
                                a = r[f"{d}_assigned_expected_intervals"]
                                if a is not None and 0 < a < r["expected_intervals"]:
                                    seen["partly_assigned"] += 1
                            if r["unavailable_reasons"]:
                                seen["unavailable"] += 1
            connection.rollback()

    # The scenarios exercise every branch the rewrite touches.
    for key in ("MEASURED", "GAP", "NOT_ASSIGNED", "BEFORE_DATA", "AFTER_LATEST_DATA", "FUTURE", "invalid", "partly_assigned"):
        assert seen[key] > 0, (key, dict(seen))


def test_device_first_initial_counted_once_per_binding_window_as_before(tx):
    """Multiplicity: the device-first instant is subtracted once per binding
    window that contains it, exactly as the 282 count did."""

    with tx.cursor() as cur:
        cur.execute(reference_ddl())
        t = Tenant(cur)
        base = datetime.now(UTC).replace(minute=0, second=0, microsecond=0) - timedelta(days=2)
        dev = t.device("Rebound meter")
        asset = t.asset("Rebound")
        # Two consecutive windows on the same device; its first reading inside the first.
        t.bind_both(asset, dev, start=base, end=base + timedelta(minutes=7))
        t.bind_both(asset, dev, start=base + timedelta(minutes=7))
        rows = [(base + timedelta(minutes=3), "INITIAL")] + [
            (base + timedelta(minutes=m), "GOOD") for m in range(4, 60)]
        _insert_rows(t, dev, rows)
        t.refresh(base, base + timedelta(hours=1))
        checkpoints(cur)
        for resolution in ("1m", "15m", "1h"):
            args = (t.user, t.site, [asset], base, base + timedelta(hours=1), resolution, FAR)
            _, new = _rows(cur, "analytics.get_portal_asset_energy_series", args)
            _, ref = _rows(cur, REFERENCE, args)
            assert new == ref, resolution
