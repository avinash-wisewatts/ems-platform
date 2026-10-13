"""Migration 299: a dedicated, configurable freshness threshold for NORMALIZED
telemetry (config.telemetry_availability_policy.normalized_receiving_
threshold_seconds, default 600 s).

The three readers fed by normalization (portal site freshness, Grafana asset
telemetry context, v_device_telemetry_availability) treat data aged up to
600 s as fresh and older data as stale. Raw-receipt connectivity and live-tile
state keep the 300 s receiving_threshold_seconds.

Runs against the disposable ems_test database (see conftest.py). Every
functional test runs inside one transaction that is rolled back. Timestamps
are fixed relative to T0 (passed as p_at) except for the view, which uses
now() -- a transaction's now() is constant, so view fixtures are relative to it.
"""

from __future__ import annotations

import csv
import os
import re
import uuid
from datetime import datetime, timedelta, timezone
from pathlib import Path

import psycopg
import pytest

CONNINFO = (
    f"host={os.environ['EMS_APP_DB_HOST']} "
    f"port={os.environ['EMS_APP_DB_PORT']} "
    f"dbname={os.environ['EMS_APP_DB_NAME']} "
    f"user={os.environ['EMS_APP_DB_USER']} "
    f"password={os.environ['EMS_APP_DB_PASSWORD']}"
)

ROOT = Path(__file__).resolve().parents[2]
MIGRATION = ROOT / "postgres" / "migrations" / "299_normalized_data_freshness_threshold.sql"
MANIFEST = ROOT / "postgres" / "restructure_manifest.csv"

T0 = datetime(2026, 10, 13, 12, 0, 0, tzinfo=timezone.utc)

NORMALIZED_READERS = (
    "analytics.get_portal_site_telemetry_freshness(bigint,uuid,timestamptz)",
    "analytics.get_grafana_asset_telemetry_context(bigint,uuid,timestamptz)",
)
RAW_AND_LIVE_READERS = (
    "analytics.get_grafana_asset_connectivity_context(bigint,uuid,timestamptz)",
    "analytics.get_grafana_asset_live_state(bigint,uuid,timestamptz)",
    "admin.get_portal_asset_live_state(bigint,uuid,timestamptz)",
)


@pytest.fixture
def tx():
    """One transaction per test, always rolled back."""
    with psycopg.connect(CONNINFO) as conn:
        try:
            yield conn
        finally:
            conn.rollback()


def _one(conn, sql, params=None):
    return conn.execute(sql, params).fetchone()


def _fixture(conn):
    """Org, site, Grafana org map, gateway, Energy Meter model, one device on
    an asset (PRIMARY_METER), the device as SITE_CONSUMPTION meter and SITE
    demand source, and a GLOBAL admin portal user. Returns ids."""
    tag = uuid.uuid4().hex[:8].upper()
    ids = {k: uuid.uuid4() for k in ("org", "site", "gw", "model", "dev", "asset")}
    ids["grafana_org"] = int(uuid.uuid4().int % 900_000_000) + 100_000_000
    conn.execute("INSERT INTO metadata.organizations (id, name, code) VALUES (%s, %s, %s)",
                 (ids["org"], f"M299 Org {tag}", f"M299_ORG_{tag}"))
    conn.execute("INSERT INTO metadata.sites (id, organization_id, name, code, timezone) VALUES (%s, %s, %s, %s, 'Asia/Kolkata')",
                 (ids["site"], ids["org"], f"M299 Site {tag}", f"M299_SITE_{tag}"))
    conn.execute("INSERT INTO metadata.grafana_organization_map (grafana_org_id, organization_id, is_active) VALUES (%s, %s, TRUE)",
                 (ids["grafana_org"], ids["org"]))
    conn.execute("INSERT INTO metadata.gateways (id, organization_id, site_id, name, external_id) VALUES (%s, %s, %s, %s, %s)",
                 (ids["gw"], ids["org"], ids["site"], f"M299 GW {tag}", f"M299-GW-{tag}"))
    category = _one(conn, "SELECT id FROM config.device_categories WHERE lower(name) = 'energy meter'")[0]
    conn.execute("INSERT INTO metadata.device_models (id, vendor, model, device_category_id) VALUES (%s, 'M299 Vendor', %s, %s)",
                 (ids["model"], f"M299 Meter {tag}", category))
    profile = _one(conn, "SELECT id FROM config.device_profiles WHERE profile_code = 'ENERGY_METER_ENISCOPE_V1'")[0]
    conn.execute(
        "INSERT INTO config.device_profile_categories (profile_id, device_category_id) VALUES (%s, %s) ON CONFLICT DO NOTHING",
        (profile, category),
    )
    conn.execute(
        "INSERT INTO metadata.devices (id, organization_id, gateway_id, device_model_id, profile_id, name, external_id) "
        "VALUES (%s, %s, %s, %s, %s, %s, %s)",
        (ids["dev"], ids["org"], ids["gw"], ids["model"], profile, f"M299 Device {tag}", f"M299-DEV-{tag}"),
    )
    conn.execute(
        "INSERT INTO metadata.assets (id, organization_id, site_id, asset_type_id, name, status, metering_requirement, metadata) "
        "SELECT %s, %s, %s, at.id, %s, 'active', 'DIRECT_METER_REQUIRED', '{}'::jsonb FROM metadata.asset_types at ORDER BY at.name LIMIT 1",
        (ids["asset"], ids["org"], ids["site"], f"M299 Asset {tag}"),
    )
    conn.execute("INSERT INTO metadata.asset_devices (asset_id, device_id, relationship_type) VALUES (%s, %s, 'PRIMARY_METER')",
                 (ids["asset"], ids["dev"]))
    conn.execute(
        "INSERT INTO config.site_energy_meter_roles (site_id, device_id, meter_role) VALUES (%s, %s, 'SITE_CONSUMPTION')",
        (ids["site"], ids["dev"]),
    )
    conn.execute(
        """
        INSERT INTO config.site_demand_policies
            (site_id, demand_interval_seconds, demand_basis, site_demand_source_role, effective_from)
        VALUES (%s, 900, 'ACTIVE_POWER_KW', 'SITE_CONSUMPTION', '2000-01-01T00:00:00Z')
        """,
        (ids["site"],),
    )
    ids["user"] = _one(
        conn,
        """
        INSERT INTO admin.portal_users
            (username, display_name, password_hash, role_code, organization_id, access_scope_mode, created_by)
        VALUES (%s, %s, '$argon2id$placeholder', 'ADMIN', NULL, 'GLOBAL', 'm299-test')
        RETURNING portal_user_id
        """,
        (f"m299.{tag.lower()}@test", f"m299 {tag}"),
    )[0]
    return ids


def _set_normalized_state(conn, device, at, *, received_age, valid_source_age=None,
                          valid_received_age=None):
    """device_telemetry_state with ages (seconds before `at`). valid_* default
    to received_age; None for a component means that timestamp is NULL."""
    def ts(age):
        return None if age is None else at - timedelta(seconds=age)
    valid_source_age = received_age if valid_source_age is None else valid_source_age
    valid_received_age = received_age if valid_received_age is None else valid_received_age
    conn.execute("DELETE FROM telemetry.device_telemetry_state WHERE device_id = %s", (device,))
    conn.execute(
        """
        INSERT INTO telemetry.device_telemetry_state
            (device_id, latest_source_timestamp, latest_received_timestamp,
             latest_valid_source_timestamp, latest_valid_received_timestamp)
        VALUES (%s, %s, %s, %s, %s)
        """,
        (device, ts(received_age), ts(received_age), ts(valid_source_age), ts(valid_received_age)),
    )


def _portal(conn, ids, at=T0):
    return _one(
        conn,
        "SELECT energy_state, demand_state, power_quality_state "
        "FROM analytics.get_portal_site_telemetry_freshness(%s, %s, %s)",
        (ids["user"], ids["site"], at),
    )


def _grafana(conn, ids, at=T0):
    return _one(
        conn,
        "SELECT telemetry_state FROM analytics.get_grafana_asset_telemetry_context(%s, %s, %s)",
        (ids["grafana_org"], ids["asset"], at),
    )[0]


def _view(conn, ids):
    return _one(
        conn,
        "SELECT telemetry_state, receiving_threshold_seconds, stale_threshold_seconds, silent_threshold_seconds "
        "FROM analytics.v_device_telemetry_availability WHERE device_id = %s",
        (ids["dev"],),
    )


# ---------------------------------------------------------------------------
# Migration file and catalog contract
# ---------------------------------------------------------------------------


def test_migration_file_is_lf_registered_and_has_no_transaction_control():
    raw = MIGRATION.read_bytes()
    assert b"\r" not in raw
    text = raw.decode("utf-8")
    assert not re.search(r"^\s*(BEGIN|COMMIT|ROLLBACK)\s*;", text, re.MULTILINE)
    with MANIFEST.open(newline="", encoding="utf-8") as fh:
        rows = [r for r in csv.DictReader(fh) if r["source_file"] == MIGRATION.name]
    assert len(rows) == 1 and rows[0]["target_category"] == "migration"


def test_column_default_and_policy_values(tx):
    col = _one(
        tx,
        """
        SELECT data_type, is_nullable, column_default FROM information_schema.columns
        WHERE table_schema = 'config' AND table_name = 'telemetry_availability_policy'
          AND column_name = 'normalized_receiving_threshold_seconds'
        """,
    )
    assert col == ("integer", "NO", "600")
    row = _one(
        tx,
        "SELECT receiving_threshold_seconds, normalized_receiving_threshold_seconds, stale_threshold_seconds, "
        "silent_threshold_seconds FROM config.telemetry_availability_policy WHERE policy_key = 'DEFAULT'",
    )
    # The shared receiving threshold is untouched; the normalized one is new.
    assert row == (300, 600, 900, 3600)


@pytest.mark.parametrize("value", [0, -1, 900, 901])
def test_check_constraint_rejects_out_of_range_values(tx, value):
    with pytest.raises(psycopg.errors.CheckViolation):
        tx.execute(
            "UPDATE config.telemetry_availability_policy SET normalized_receiving_threshold_seconds = %s "
            "WHERE policy_key = 'DEFAULT'",
            (value,),
        )


@pytest.mark.parametrize("sig", NORMALIZED_READERS)
def test_normalized_readers_read_the_normalized_threshold(tx, sig):
    src = _one(tx, "SELECT prosrc FROM pg_proc WHERE oid = %s::regprocedure", (sig,))[0]
    assert "p.normalized_receiving_threshold_seconds" in src
    assert "p.receiving_threshold_seconds" not in src


def test_view_reads_the_normalized_threshold(tx):
    v = _one(tx, "SELECT pg_get_viewdef('analytics.v_device_telemetry_availability'::regclass)")[0]
    assert "normalized_receiving_threshold_seconds AS receiving_threshold_seconds" in v


@pytest.mark.parametrize("sig", RAW_AND_LIVE_READERS)
def test_raw_and_live_readers_keep_the_shared_threshold(tx, sig):
    src = _one(tx, "SELECT prosrc FROM pg_proc WHERE oid = %s::regprocedure", (sig,))[0]
    assert "receiving_threshold_seconds" in src
    assert "normalized_receiving_threshold_seconds" not in src


# ---------------------------------------------------------------------------
# Normalized-data readers: fresh up to 600 s, stale after (boundaries)
# ---------------------------------------------------------------------------

FRESH_AGES = [0, 60, 299, 300, 301, 450, 599, 600]
STALE_AGES = [601, 700, 899]


@pytest.mark.parametrize("age", FRESH_AGES)
def test_portal_and_grafana_fresh_up_to_600_seconds(tx, age):
    ids = _fixture(tx)
    _set_normalized_state(tx, ids["dev"], T0, received_age=age)
    assert _portal(tx, ids) == ("FRESH", "FRESH", "FRESH")
    assert _grafana(tx, ids) == "VALIDATED"


@pytest.mark.parametrize("age", STALE_AGES)
def test_portal_and_grafana_stale_after_600_seconds(tx, age):
    ids = _fixture(tx)
    _set_normalized_state(tx, ids["dev"], T0, received_age=age)
    assert _portal(tx, ids) == ("STALE", "STALE", "STALE")
    assert _grafana(tx, ids) == "RECEIVING"


@pytest.mark.parametrize("age,expected", [(299, "VALIDATED"), (450, "VALIDATED"), (600, "VALIDATED"),
                                          (601, "RECEIVING"), (700, "RECEIVING")])
def test_view_uses_600_seconds_and_reports_it(tx, age, expected):
    ids = _fixture(tx)
    now = _one(tx, "SELECT now()")[0]
    _set_normalized_state(tx, ids["dev"], now, received_age=age)
    state, receiving, stale, silent = _view(tx, ids)
    assert state == expected
    # The admin telemetry-validation page shows the threshold actually applied.
    assert (receiving, stale, silent) == (600, 900, 3600)


def test_threshold_is_configurable_not_hard_coded(tx):
    ids = _fixture(tx)
    tx.execute("UPDATE config.telemetry_availability_policy SET normalized_receiving_threshold_seconds = 450 "
               "WHERE policy_key = 'DEFAULT'")
    _set_normalized_state(tx, ids["dev"], T0, received_age=450)
    assert _portal(tx, ids)[0] == "FRESH"
    assert _grafana(tx, ids) == "VALIDATED"
    _set_normalized_state(tx, ids["dev"], T0, received_age=451)
    assert _portal(tx, ids)[0] == "STALE"
    assert _grafana(tx, ids) == "RECEIVING"


def test_missing_telemetry_is_no_data_never_fresh(tx):
    ids = _fixture(tx)  # no device_telemetry_state row
    assert _portal(tx, ids) == ("NO_DATA", "NO_DATA", "NO_DATA")
    assert _grafana(tx, ids) == "NEVER_SEEN"
    assert _view(tx, ids)[0] == "NEVER_SEEN"


def test_offline_device_is_no_data_after_the_silent_threshold(tx):
    ids = _fixture(tx)
    _set_normalized_state(tx, ids["dev"], T0, received_age=3601)
    assert _portal(tx, ids) == ("NO_DATA", "NO_DATA", "NO_DATA")
    assert _grafana(tx, ids) == "SILENT"
    _set_normalized_state(tx, ids["dev"], T0, received_age=3599)
    # Received within the silent threshold but source older than 900 s.
    assert _portal(tx, ids) == ("STALE", "STALE", "STALE")
    assert _grafana(tx, ids) == "STALE"


def test_stale_source_wins_over_a_recent_receipt(tx):
    ids = _fixture(tx)
    _set_normalized_state(tx, ids["dev"], T0, received_age=10, valid_source_age=901, valid_received_age=10)
    assert _portal(tx, ids) == ("STALE", "STALE", "STALE")
    assert _grafana(tx, ids) == "STALE"


def test_no_valid_reading_yet_is_not_fresh(tx):
    ids = _fixture(tx)
    tx.execute(
        "INSERT INTO telemetry.device_telemetry_state (device_id, latest_source_timestamp, latest_received_timestamp) "
        "VALUES (%s, %s, %s)",
        (ids["dev"], T0 - timedelta(seconds=30), T0 - timedelta(seconds=30)),
    )
    assert _portal(tx, ids) == ("STALE", "STALE", "STALE")
    assert _grafana(tx, ids) == "RECEIVING"


# ---------------------------------------------------------------------------
# Raw connectivity and live tiles: still 300 s
# ---------------------------------------------------------------------------


@pytest.mark.parametrize("age,expected", [(299, "RECEIVING"), (300, "RECEIVING"), (301, "STALE"), (450, "STALE")])
def test_raw_connectivity_keeps_300_seconds(tx, age, expected):
    ids = _fixture(tx)
    tx.execute(
        "INSERT INTO telemetry.device_raw_receipt_state (device_id, latest_raw_received_at, latest_raw_source_timestamp) "
        "VALUES (%s, %s, %s)",
        (ids["dev"], T0 - timedelta(seconds=age), T0 - timedelta(seconds=age)),
    )
    state = _one(
        tx,
        "SELECT connectivity_state FROM analytics.get_grafana_asset_connectivity_context(%s, %s, %s)",
        (ids["grafana_org"], ids["asset"], T0),
    )[0]
    assert state == expected


@pytest.mark.parametrize("age,expected", [(299, "LIVE"), (300, "LIVE"), (301, "STALE"), (450, "STALE")])
def test_live_tiles_keep_300_seconds(tx, age, expected):
    ids = _fixture(tx)
    point = _one(tx, "SELECT id FROM metadata.logical_points WHERE name = 'ACTIVE_POWER_TOTAL'")[0]
    tx.execute(
        """
        INSERT INTO telemetry.device_live_point_state
            (device_id, logical_point_id, organization_id, site_id, gateway_id, event_time, received_at,
             numeric_value, quality_code, raw_field_name, mapping_source)
        VALUES (%s, %s, %s, %s, %s, %s, %s, 1.0, 'GOOD', 'P', 'DEVICE_PROFILE')
        """,
        (ids["dev"], point, ids["org"], ids["site"], ids["gw"],
         T0 - timedelta(seconds=age), T0 - timedelta(seconds=age)),
    )
    state = _one(
        tx,
        "SELECT freshness_state FROM analytics.get_grafana_asset_live_state(%s, %s, %s) WHERE logical_point = 'ACTIVE_POWER_TOTAL'",
        (ids["grafana_org"], ids["asset"], T0),
    )[0]
    assert state == expected
