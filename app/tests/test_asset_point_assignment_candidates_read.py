"""The Assign Data Points candidate read against real rows (ems_test database).

Regression: the staging parity-bridge assignments start at
effective_from = '-infinity'. Loading that into a Python datetime fails
(psycopg DataError), which made the Asset Detail page return 500 for every
asset that has one. The service query maps infinite bounds to NULL.
"""

from datetime import datetime, timezone

import psycopg
import pytest
from psycopg.rows import dict_row

from src.asset_point_assignment_service import LIST_CANDIDATES_SQL
from tests.test_analytics_catalog_read import CONNINFO, Fixture

RAW_CANDIDATES_SQL = "SELECT * FROM admin.list_asset_point_assignment_candidates(%s, %s::uuid)"


@pytest.fixture
def tx():
    with psycopg.connect(CONNINFO) as connection:
        yield connection
        connection.rollback()


def _asset_with_parity_bridge_row(cur) -> tuple[int, str]:
    f = Fixture(cur)
    org, site, gateway = f.org_site("CANDIDATES")
    asset, device = f.asset(org, site, gateway, "Parity Bridge Asset", "ACTIVE")
    cur.execute(
        "INSERT INTO metadata.asset_devices (asset_id, device_id, relationship_type) VALUES (%s, %s, 'PRIMARY_METER')",
        (asset, device),
    )
    f.bind(org, asset, device, "ENERGY_IMPORT_TOTAL", start="-infinity")  # parity-bridge shape
    f.bind(org, asset, device, "ENERGY_EXPORT_TOTAL")  # an ordinary dated assignment
    return f.portal_user(None, "GLOBAL", role="ADMIN"), asset


def test_raw_candidate_rows_with_infinite_effective_from_cannot_be_loaded(tx):
    """Documents the defect the service query avoids."""
    with tx.cursor() as cur:
        actor, asset = _asset_with_parity_bridge_row(cur)
        cur.execute(RAW_CANDIDATES_SQL, (actor, asset))
        with pytest.raises(psycopg.DataError, match="infinity"):
            cur.fetchall()


def test_service_query_loads_parity_bridge_rows_with_unbounded_effective_from_as_none(tx):
    with tx.cursor() as setup:
        actor, asset = _asset_with_parity_bridge_row(setup)
    with tx.cursor(row_factory=dict_row) as cur:
        cur.execute(LIST_CANDIDATES_SQL, (actor, asset))
        rows = {r["logical_point_name"]: r for r in cur.fetchall()}

    parity = rows["ENERGY_IMPORT_TOTAL"]
    assert parity["is_confirmed"] is True
    assert parity["asset_point_id"] is not None
    assert parity["effective_from"] is None  # '-infinity' -> unbounded
    assert parity["effective_to"] is None

    dated = rows["ENERGY_EXPORT_TOTAL"]
    assert dated["is_confirmed"] is True
    assert dated["effective_from"] == datetime(2026, 9, 1, tzinfo=timezone.utc)

    unassigned = [r for r in rows.values() if not r["is_confirmed"]]
    assert unassigned, "the device's other configured points are offered as candidates"
    assert all(r["asset_point_id"] is None and r["effective_from"] is None for r in unassigned)


def test_service_query_returns_every_candidate_column(tx):
    with tx.cursor() as setup:
        actor, asset = _asset_with_parity_bridge_row(setup)
    with tx.cursor(row_factory=dict_row) as cur:
        cur.execute(LIST_CANDIDATES_SQL, (actor, asset))
        service_columns = [d.name for d in cur.description]
        cur.execute(
            "SELECT * FROM admin.list_asset_point_assignment_candidates(%s, %s::uuid) WHERE false",
            (actor, asset),
        )
        function_columns = [d.name for d in cur.description]
    assert service_columns == function_columns
