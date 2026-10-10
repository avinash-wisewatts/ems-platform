"""Migration 296: telemetry.normalized_points identity index reordered to
(device_id, logical_point_id, event_time). Uniqueness and the ON CONFLICT
(event_time, device_id, logical_point_id) arbiter are unchanged."""

from __future__ import annotations

from datetime import datetime, timedelta, timezone

import psycopg
import pytest

from tests.test_analytics_point_series_read import seed_raw
from tests.test_asset_energy_tier_read import CONNINFO, Tenant

UTC = timezone.utc


@pytest.fixture
def tx():
    with psycopg.connect(CONNINFO) as connection:
        yield connection
        connection.rollback()


def test_identity_index_is_unique_valid_and_led_by_device_and_point(tx):
    row = tx.execute(
        """
        SELECT i.indisunique, i.indisvalid, i.indisready,
               (SELECT string_agg(a.attname, ',' ORDER BY k.ord)
                FROM unnest(i.indkey) WITH ORDINALITY AS k(attnum, ord)
                JOIN pg_attribute AS a ON a.attrelid = i.indrelid AND a.attnum = k.attnum)
        FROM pg_index AS i WHERE i.indexrelid = to_regclass('telemetry.uq_normalized_points_identity')
        """
    ).fetchone()
    assert row == (True, True, True, "device_id,logical_point_id,event_time")
    assert tx.execute("SELECT to_regclass('telemetry.uq_normalized_points_identity_v2')").fetchone()[0] is None


def test_on_conflict_on_the_identity_columns_still_updates(tx):
    t = Tenant(tx.cursor())
    device = t.device("Identity meter")
    t.cur.execute("SELECT id FROM metadata.logical_points WHERE name = 'ACTIVE_POWER_TOTAL'")
    point = str(t.cur.fetchone()[0])
    at = datetime.now(UTC).replace(microsecond=0) - timedelta(minutes=5)
    seed_raw(t, device, point, at, 10)
    t.cur.execute(
        """
        INSERT INTO telemetry.normalized_points (
            event_time, organization_id, site_id, device_id, logical_point_id,
            device_uid, logical_point, raw_field_name, raw_value, numeric_value, quality_code, mapping_source)
        VALUES (%s, %s, %s, %s, %s, 'b3-test', 'b3', 'b3', '20', 20, 'GOOD', 'test-fixture-296')
        ON CONFLICT (event_time, device_id, logical_point_id) DO UPDATE SET numeric_value = EXCLUDED.numeric_value
        """,
        (at, t.org, t.site, device, point),
    )
    t.cur.execute(
        "SELECT count(*), max(numeric_value) FROM telemetry.normalized_points WHERE device_id = %s AND logical_point_id = %s",
        (device, point),
    )
    assert t.cur.fetchone() == (1, 20)


def test_a_duplicate_identity_is_rejected(tx):
    t = Tenant(tx.cursor())
    device = t.device("Duplicate meter")
    t.cur.execute("SELECT id FROM metadata.logical_points WHERE name = 'ACTIVE_POWER_TOTAL'")
    point = str(t.cur.fetchone()[0])
    at = datetime.now(UTC).replace(microsecond=0) - timedelta(minutes=5)
    seed_raw(t, device, point, at, 10)
    with pytest.raises(psycopg.errors.UniqueViolation):
        seed_raw(t, device, point, at, 11)


def test_manifest_registers_migration_296_last():
    import csv
    from pathlib import Path

    manifest = Path(__file__).resolve().parents[2] / "postgres" / "restructure_manifest.csv"
    rows = [r for r in csv.DictReader(manifest.read_text(encoding="utf-8").splitlines()) if r["target_category"] == "migration"]
    assert rows[-1]["source_file"] == "296_normalized_points_identity_index_order.sql"
    assert rows[-1]["target_path"] == "postgres/migrations/296_normalized_points_identity_index_order.sql"
