"""Contract and functional tests for migration 271 (ADR-019 D2, Analytics v1
step B0): a site's timezone cannot change once the site has telemetry.

Runs against the disposable ems_test database (see conftest.py). Every
functional test runs inside one transaction that is rolled back, so the
organization/site/gateway/device fixtures and telemetry rows never persist.
"""

import os
import uuid
from datetime import date, datetime, timezone

import psycopg
import pytest

CONNINFO = (
    f"host={os.environ['EMS_APP_DB_HOST']} port={os.environ['EMS_APP_DB_PORT']} "
    f"dbname={os.environ['EMS_APP_DB_NAME']} user={os.environ['EMS_APP_DB_USER']} "
    f"password={os.environ['EMS_APP_DB_PASSWORD']}"
)

GUARD_SIG = "metadata.prevent_site_timezone_change_with_telemetry()"
GUARD_MESSAGE = "Site timezone cannot be changed once the site has telemetry."
HOUR = datetime(2026, 9, 1, 6, 0, tzinfo=timezone.utc)


@pytest.fixture
def tx():
    with psycopg.connect(CONNINFO) as connection:
        yield connection
        connection.rollback()


def _site(cur, *, tz: str = "Asia/Kolkata") -> dict:
    ids = {k: str(uuid.uuid4()) for k in ("org", "site", "gateway", "device")}
    suffix = ids["site"][:8].upper()
    cur.execute(
        "INSERT INTO metadata.organizations (id, name, code) VALUES (%s, %s, %s)",
        (ids["org"], f"TZ Guard Org {suffix}", f"TZG_ORG_{suffix}"),
    )
    cur.execute(
        "INSERT INTO metadata.sites (id, organization_id, name, code, timezone) VALUES (%s, %s, %s, %s, %s)",
        (ids["site"], ids["org"], f"TZ Guard Site {suffix}", f"TZG_SITE_{suffix}", tz),
    )
    cur.execute(
        "INSERT INTO metadata.gateways (id, organization_id, site_id, name, external_id) VALUES (%s, %s, %s, %s, %s)",
        (ids["gateway"], ids["org"], ids["site"], f"TZ Guard GW {suffix}", f"TZG_GW_{suffix}"),
    )
    cur.execute(
        "INSERT INTO metadata.devices (id, organization_id, gateway_id, name, external_id) VALUES (%s, %s, %s, %s, %s)",
        (ids["device"], ids["org"], ids["gateway"], f"TZ Guard Device {suffix}", f"TZG_DEV_{suffix}"),
    )
    return ids


def _logical_point_id(cur) -> str:
    cur.execute("SELECT id FROM metadata.logical_points WHERE name = 'ENERGY_IMPORT_TOTAL'")
    return str(cur.fetchone()[0])


def _add_normalized_point(cur, ids: dict, *, site_id: str | None = None) -> None:
    cur.execute(
        """
        INSERT INTO telemetry.normalized_points
            (event_time, organization_id, site_id, device_id, logical_point_id, numeric_value, quality_code)
        VALUES (%s, %s, %s, %s, %s, 1, 'GOOD')
        """,
        (HOUR, ids["org"], site_id or ids["site"], ids["device"], _logical_point_id(cur)),
    )


def _add_point_telemetry_1h(cur, ids: dict) -> None:
    cur.execute(
        """
        INSERT INTO analytics.point_telemetry_1h
            (bucket_start, organization_id, site_id, device_id, logical_point_id,
             sum_value, sample_count, min_value, max_value, source_bucket_count)
        VALUES (%s, %s, %s, %s, %s, 60, 60, 1, 1, 4)
        """,
        (HOUR, ids["org"], ids["site"], ids["device"], _logical_point_id(cur)),
    )


def _add_energy_daily(cur, ids: dict) -> None:
    cur.execute(
        """
        INSERT INTO analytics.energy_consumption_daily
            (bucket_start, consumption_date, site_timezone, organization_id, site_id, device_id,
             source_interval_count, valid_import_intervals, invalid_import_intervals,
             valid_export_intervals, invalid_export_intervals, gap_interval_count,
             reset_interval_count, rollover_interval_count, invalid_interval_count)
        VALUES (%s, %s, 'Asia/Kolkata', %s, %s, %s, 96, 96, 0, 96, 0, 0, 0, 0, 0)
        """,
        (HOUR, date(2026, 9, 1), ids["org"], ids["site"], ids["device"]),
    )


def _set_timezone(cur, site_id: str, tz: str) -> None:
    cur.execute("UPDATE metadata.sites SET timezone = %s WHERE id = %s", (tz, site_id))


def _assert_blocked(connection, site_id: str) -> None:
    with connection.cursor() as cur:
        cur.execute("SAVEPOINT tz_guard")
        with pytest.raises(psycopg.errors.CheckViolation) as excinfo:
            _set_timezone(cur, site_id, "Europe/London")
        cur.execute("ROLLBACK TO SAVEPOINT tz_guard")
        cur.execute("SELECT timezone FROM metadata.sites WHERE id = %s", (site_id,))
        assert cur.fetchone()[0] == "Asia/Kolkata"
    assert excinfo.value.diag.message_primary == GUARD_MESSAGE


# ---------------------------------------------------------------------------
# Catalog contract
# ---------------------------------------------------------------------------


def test_guard_trigger_is_installed_on_timezone_updates_only():
    with psycopg.connect(CONNINFO) as connection:
        definition = connection.execute(
            """
            SELECT pg_get_triggerdef(t.oid)
            FROM pg_trigger AS t
            WHERE t.tgrelid = 'metadata.sites'::regclass
              AND t.tgname = 'sites_prevent_timezone_change_with_telemetry'
              AND t.tgenabled = 'O'
            """
        ).fetchone()
    assert definition is not None
    assert "BEFORE UPDATE OF timezone ON metadata.sites" in definition[0]
    assert "FOR EACH ROW" in definition[0]
    assert "old.timezone IS DISTINCT FROM new.timezone" in definition[0]


def test_guard_function_is_security_definer_owned_and_not_public():
    with psycopg.connect(CONNINFO) as connection:
        row = connection.execute(
            """
            SELECT p.prosecdef, r.rolname, p.proconfig,
                   has_function_privilege('public', p.oid, 'EXECUTE')
            FROM pg_proc AS p
            JOIN pg_roles AS r ON r.oid = p.proowner
            WHERE p.oid = %s::regprocedure
            """,
            (GUARD_SIG,),
        ).fetchone()
    prosecdef, owner, proconfig, public_execute = row
    assert prosecdef is True
    assert owner == "ems_admin"
    assert any(setting.startswith("search_path=") for setting in proconfig)
    assert public_execute is False


def test_migration_is_recorded_in_ledger():
    with psycopg.connect(CONNINFO) as connection:
        row = connection.execute(
            "SELECT 1 FROM admin.schema_migrations WHERE migration_id = '271_site_timezone_immutable_with_telemetry'"
        ).fetchone()
    assert row is not None


# ---------------------------------------------------------------------------
# Behaviour
# ---------------------------------------------------------------------------


def test_site_without_telemetry_can_change_timezone(tx):
    with tx.cursor() as cur:
        ids = _site(cur)
        _set_timezone(cur, ids["site"], "Europe/London")
        cur.execute("SELECT timezone FROM metadata.sites WHERE id = %s", (ids["site"],))
        assert cur.fetchone()[0] == "Europe/London"


def test_raw_normalized_points_block_timezone_change(tx):
    with tx.cursor() as cur:
        ids = _site(cur)
        _add_normalized_point(cur, ids)
    _assert_blocked(tx, ids["site"])


def test_point_telemetry_1h_blocks_timezone_change(tx):
    with tx.cursor() as cur:
        ids = _site(cur)
        _add_point_telemetry_1h(cur, ids)
    _assert_blocked(tx, ids["site"])


def test_energy_consumption_daily_blocks_timezone_change(tx):
    """Daily Energy has no retention policy, so it keeps a site locked after
    raw telemetry has aged out, and it covers devices that since moved."""

    with tx.cursor() as cur:
        ids = _site(cur)
        _add_energy_daily(cur, ids)
    _assert_blocked(tx, ids["site"])


def test_unchanged_timezone_update_is_allowed_with_telemetry(tx):
    with tx.cursor() as cur:
        ids = _site(cur)
        _add_normalized_point(cur, ids)
        _set_timezone(cur, ids["site"], "Asia/Kolkata")
        cur.execute(
            "UPDATE metadata.sites SET name = name || ' (renamed)' WHERE id = %s", (ids["site"],)
        )
        assert cur.rowcount == 1


def test_another_sites_telemetry_does_not_block(tx):
    with tx.cursor() as cur:
        locked = _site(cur)
        free = _site(cur)
        _add_normalized_point(cur, locked)
        _add_energy_daily(cur, locked)
        _set_timezone(cur, free["site"], "Europe/London")
        cur.execute("SELECT timezone FROM metadata.sites WHERE id = %s", (free["site"],))
        assert cur.fetchone()[0] == "Europe/London"
    _assert_blocked(tx, locked["site"])


def test_device_rows_recorded_for_another_site_do_not_block(tx):
    """A device's raw rows count only for the site they were recorded at."""

    with tx.cursor() as cur:
        ids = _site(cur)
        other = _site(cur)
        _add_normalized_point(cur, ids, site_id=other["site"])
        _set_timezone(cur, ids["site"], "Europe/London")
        cur.execute("SELECT timezone FROM metadata.sites WHERE id = %s", (ids["site"],))
        assert cur.fetchone()[0] == "Europe/London"
