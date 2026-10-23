"""Migration 307 (parity audit 2026-10-23, H1): analytics.v_energy_consumption_1min
and analytics.v_energy_consumption_15min join config.energy_register_semantics
only on the ENERGY_IMPORT_TOTAL / ENERGY_EXPORT_TOTAL rows.

The seeded energy profile carries one active semantics row per register
(L1, L2, L3, TOTAL) for each flow. The baseline 001 bodies joined by profile
and flow only, so every device bucket came back 4 x 4 = 16 times. Production
already ran the corrected bodies; 307 brings every environment to them.

The module seeds its own organization / site / gateway / device on the seeded
profile, writes three minutes of energy readings, materializes them into
telemetry.ca_energy_1min, and removes everything afterwards (ems_test is the
disposable database from conftest.py).
"""
import uuid
from datetime import datetime, timedelta, timezone
from pathlib import Path

import psycopg
import pytest

from tests.test_asset_energy_tier_read import CONNINFO

REPO = Path(__file__).resolve().parents[2]
MIGRATION = REPO / "postgres" / "migrations" / "307_energy_consumption_views_total_register_semantics.sql"
BASELINE = REPO / "postgres" / "migrations" / "001_ems_platform_baseline_20260807.sql"

VIEW_1MIN = "analytics.v_energy_consumption_1min"
VIEW_15MIN = "analytics.v_energy_consumption_15min"
# pg_get_viewdef(oid) md5: corrected body (= production 2026-10-23) and the
# 001 body (= staging 2026-10-23).
CORRECTED_MD5 = {VIEW_1MIN: "2c75df8831276bdd8643f2d90147ffad", VIEW_15MIN: "8a6d00ca3464cc890fe474dd3bec18a4"}
BASELINE_MD5 = {VIEW_1MIN: "8435a69ba516afc0d245ac91aaa7a1eb", VIEW_15MIN: "4841e5d1b1edb96a13d0bc9a7257648d"}

ORG = str(uuid.uuid4())
SITE = str(uuid.uuid4())
GATEWAY = str(uuid.uuid4())
DEVICE = str(uuid.uuid4())
GRAFANA_ORG = 930701


def _baseline_view_sql(view):
    """The view's CREATE statement from baseline 001 (used to prove the fan-out)."""
    text = BASELINE.read_text(encoding="utf-8")
    start = text.index(f"CREATE OR REPLACE VIEW {view}")
    return text[start:text.index(";", start) + 1]


@pytest.fixture(scope="module")
def buckets():
    """Three consecutive closed minutes of readings for a fresh device on the
    seeded profile (the one with per-phase + TOTAL semantics rows)."""
    end = datetime.now(timezone.utc).replace(second=0, microsecond=0) - timedelta(minutes=2)
    minutes = [end - timedelta(minutes=k) for k in (3, 2, 1)]
    with psycopg.connect(CONNINFO, autocommit=True) as c:
        profile_id, n_import = c.execute(
            """
            SELECT s.profile_id, count(*)
            FROM config.energy_register_semantics AS s
            WHERE s.is_active AND s.flow_interpretation = 'GRID_IMPORT'
            GROUP BY s.profile_id
            ORDER BY count(*) DESC
            LIMIT 1
            """
        ).fetchone()
        assert n_import > 1, "fixture needs a profile with per-phase semantics rows"
        c.execute("INSERT INTO metadata.organizations (id, name, code) VALUES (%s, 'Mig 307 Org', 'MIG307_ORG')", (ORG,))
        c.execute("INSERT INTO metadata.sites (id, organization_id, name, code) VALUES (%s, %s, 'Mig 307 Site', 'MIG307_SITE')", (SITE, ORG))
        c.execute(
            "INSERT INTO metadata.gateways (id, organization_id, site_id, name, external_id) VALUES (%s, %s, %s, 'Mig 307 GW', 'MIG307_GW')",
            (GATEWAY, ORG, SITE),
        )
        c.execute(
            "INSERT INTO metadata.devices (id, organization_id, gateway_id, profile_id, name, external_id) VALUES (%s, %s, %s, %s, 'Mig 307 Meter', 'MIG307_DEV')",
            (DEVICE, ORG, GATEWAY, profile_id),
        )
        c.execute(
            "INSERT INTO metadata.grafana_organization_map (grafana_org_id, organization_id, is_active) VALUES (%s, %s, true)",
            (GRAFANA_ORG, ORG),
        )
        # One routed row per capture bucket (60 s platform default policy).
        for k, t in enumerate(minutes):
            c.execute(
                """
                INSERT INTO telemetry.energy_measurements (
                    organization_id, site_id, device_id, bucket_start, source_timestamp, received_at,
                    import_energy_total_wh, export_energy_total_wh
                ) VALUES (%s, %s, %s, %s, %s, %s, %s, %s)
                """,
                (ORG, SITE, DEVICE, t, t + timedelta(seconds=30), t + timedelta(seconds=35), 1000 + 10 * k, 500),
            )
        c.execute("CALL refresh_continuous_aggregate('telemetry.ca_energy_1min', %s, %s)",
                  (minutes[0] - timedelta(minutes=1), end + timedelta(minutes=1)))
    yield minutes
    with psycopg.connect(CONNINFO, autocommit=True) as c:
        c.execute("DELETE FROM telemetry.energy_measurements WHERE device_id = %s", (DEVICE,))
        c.execute("CALL refresh_continuous_aggregate('telemetry.ca_energy_1min', %s, %s)",
                  (minutes[0] - timedelta(minutes=1), end + timedelta(minutes=1)))
        c.execute("DELETE FROM metadata.grafana_organization_map WHERE grafana_org_id = %s", (GRAFANA_ORG,))
        c.execute("DELETE FROM metadata.devices WHERE id = %s", (DEVICE,))
        c.execute("DELETE FROM metadata.gateways WHERE id = %s", (GATEWAY,))
        c.execute("DELETE FROM metadata.sites WHERE id = %s", (SITE,))
        c.execute("DELETE FROM metadata.organizations WHERE id = %s", (ORG,))


def _rows_per_bucket(c):
    return c.execute(
        f"SELECT bucket_start, count(*) FROM {VIEW_1MIN} WHERE device_id = %s GROUP BY 1 ORDER BY 1",
        (DEVICE,),
    ).fetchall()


def test_one_row_per_device_minute(buckets):
    with psycopg.connect(CONNINFO) as c:
        rows = _rows_per_bucket(c)
    assert [b for b, _ in rows] == buckets
    assert all(n == 1 for _, n in rows), rows


def test_baseline_body_fans_out(buckets):
    """Mutation check: the 001 body returns one row per semantics pair."""
    with psycopg.connect(CONNINFO) as c:
        c.execute(_baseline_view_sql(VIEW_1MIN))
        rows = _rows_per_bucket(c)
        c.rollback()
    assert [b for b, _ in rows] == buckets
    assert all(n == 16 for _, n in rows), rows


def test_delta_uses_total_register(buckets):
    with psycopg.connect(CONNINFO) as c:
        rows = c.execute(
            f"""
            SELECT bucket_start, import_consumption_wh, import_quality_code
            FROM {VIEW_1MIN} WHERE device_id = %s ORDER BY bucket_start
            """,
            (DEVICE,),
        ).fetchall()
    # Registers 1000 / 1010 / 1020 Wh; the first bucket has no predecessor.
    assert [r[1] for r in rows[1:]] == [10, 10]


@pytest.mark.parametrize("view", [VIEW_1MIN, VIEW_15MIN])
def test_live_definition_and_metadata(view):
    with psycopg.connect(CONNINFO) as c:
        md5, options, owner = c.execute(
            "SELECT md5(pg_get_viewdef(%s::regclass)), reloptions, pg_get_userbyid(relowner) FROM pg_class WHERE oid = %s::regclass",
            (view, view),
        ).fetchone()
    assert md5 == CORRECTED_MD5[view]
    assert options == ["security_barrier=true"]
    assert owner == "ems_admin"


def test_migration_pins_and_rollback_contract():
    sql = MIGRATION.read_text(encoding="utf-8")
    for view in (VIEW_1MIN, VIEW_15MIN):
        assert sql.count(f"CREATE OR REPLACE VIEW {view}\nWITH (security_barrier = true) AS") == 1
        assert CORRECTED_MD5[view] in sql and BASELINE_MD5[view] in sql
    assert sql.count("logical_point_id = (( SELECT lp.id") == 4
    assert "ENERGY_IMPORT_TOTAL" in sql and "ENERGY_EXPORT_TOTAL" in sql


def test_migration_is_idempotent():
    """Re-running the statements on the corrected body (production) is a no-op."""
    with psycopg.connect(CONNINFO) as c:
        c.execute(MIGRATION.read_text(encoding="utf-8"))
        for view, md5 in CORRECTED_MD5.items():
            assert c.execute("SELECT md5(pg_get_viewdef(%s::regclass))", (view,)).fetchone()[0] == md5
        c.rollback()


def test_manifest_registers_307_after_306():
    import csv

    rows = list(csv.DictReader((REPO / "postgres" / "restructure_manifest.csv").read_text(encoding="utf-8").splitlines()))
    files = [r["source_file"] for r in rows if r["target_category"] == "migration"]
    assert files.index(MIGRATION.name) == files.index("306_demand_reconcile_wide_cadence.sql") + 1
