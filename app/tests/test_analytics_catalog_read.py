"""Contract and functional tests for migration 276: the Analytics v1
catalogue read, analytics.get_portal_analytics_catalog (ADR-022 step B1).

Runs against the disposable ems_test database (see conftest.py). Each
functional test builds its own tenant fixtures inside one transaction that
is rolled back. Fixture devices use the ENERGY_METER_ENISCOPE_V1 profile so
config.device_point_configuration is populated for them (metadata.asset_points
has a composite FK into it), exactly as the migration 263 assertions do.
"""

import os
import re
import uuid
from datetime import datetime, timedelta, timezone

import psycopg
import pytest

CONNINFO = (
    f"host={os.environ['EMS_APP_DB_HOST']} port={os.environ['EMS_APP_DB_PORT']} "
    f"dbname={os.environ['EMS_APP_DB_NAME']} user={os.environ['EMS_APP_DB_USER']} "
    f"password={os.environ['EMS_APP_DB_PASSWORD']}"
)

CATALOG_SIG = "analytics.get_portal_analytics_catalog(bigint, uuid)"
CATALOG_SQL = """
    SELECT asset_id::text, asset_name, data_point, data_point_name, category, unit,
           qualifier, attribution_basis, assigned_from, assigned_to
    FROM analytics.get_portal_analytics_catalog(%s, %s)
    ORDER BY asset_name, data_point, qualifier, assigned_from NULLS FIRST
"""
NEG_INF = "-infinity"


class Fixture:
    def __init__(self, cur):
        self.cur = cur
        self.tag = uuid.uuid4().hex[:8].upper()
        cur.execute("SELECT id FROM config.device_profiles WHERE profile_code = 'ENERGY_METER_ENISCOPE_V1'")
        row = cur.fetchone()
        if row is None:
            pytest.skip("ENERGY_METER_ENISCOPE_V1 profile is not seeded in this database")
        self.profile_id = row[0]
        cur.execute("SELECT id FROM config.device_categories WHERE lower(name) = 'energy meter'")
        category_id = cur.fetchone()[0]
        cur.execute(
            """
            INSERT INTO metadata.device_models (vendor, model, device_type, device_category_id)
            VALUES ('WiseWatts Test', %s, 'Energy Meter', %s) RETURNING id
            """,
            (f"Analytics Catalog Meter {self.tag}", category_id),
        )
        self.model_id = cur.fetchone()[0]

    def point(self, name: str) -> str:
        self.cur.execute("SELECT id FROM metadata.logical_points WHERE name = %s", (name,))
        return self.cur.fetchone()[0]

    def org_site(self, label: str) -> tuple[str, str, str]:
        code = f"AC_{label}_{self.tag}"
        self.cur.execute(
            "INSERT INTO metadata.organizations (name, code) VALUES (%s, %s) RETURNING id",
            (f"Analytics Catalog {label} {self.tag}", code),
        )
        org = self.cur.fetchone()[0]
        self.cur.execute(
            "INSERT INTO metadata.sites (organization_id, name, code, timezone) VALUES (%s, %s, %s, 'Asia/Kolkata') RETURNING id",
            (org, f"Analytics Catalog Site {label} {self.tag}", code),
        )
        site = self.cur.fetchone()[0]
        self.cur.execute(
            "INSERT INTO metadata.gateways (organization_id, site_id, name, external_id) VALUES (%s, %s, %s, %s) RETURNING id",
            (org, site, f"AC GW {label} {self.tag}", f"AC-GW-{label}-{self.tag}"),
        )
        return org, site, self.cur.fetchone()[0]

    def asset(self, org, site, gateway, name: str, lifecycle: str) -> tuple[str, str]:
        slug = re.sub(r"[^A-Z0-9]+", "_", name.upper()).strip("_")
        self.cur.execute(
            """
            INSERT INTO metadata.devices (organization_id, gateway_id, device_model_id, profile_id, name, external_id)
            VALUES (%s, %s, %s, %s, %s, %s) RETURNING id
            """,
            (org, gateway, self.model_id, self.profile_id, f"{name} meter", f"AC_DEV_{slug}_{self.tag}"),
        )
        device = self.cur.fetchone()[0]
        self.cur.execute(
            """
            INSERT INTO metadata.assets (organization_id, site_id, name, external_id, metering_requirement, lifecycle_status)
            VALUES (%s, %s, %s, %s, 'NOT_REQUIRED', %s) RETURNING id
            """,
            (org, site, name, f"AC_ASSET_{slug}_{self.tag}", lifecycle),
        )
        return self.cur.fetchone()[0], device

    def bind(self, org, asset, device, point_name: str, *, start=None, end=None) -> None:
        self.cur.execute(
            """
            INSERT INTO metadata.asset_points (asset_id, device_id, logical_point_id, organization_id, effective_from, effective_to)
            VALUES (%s, %s, %s, %s, %s, %s)
            """,
            (asset, device, self.point(point_name), org,
             start if start is not None else datetime(2026, 9, 1, tzinfo=timezone.utc), end),
        )

    def portal_user(self, org, scope: str, role: str = "VIEWER") -> int:
        self.cur.execute(
            """
            INSERT INTO admin.portal_users
                (username, display_name, password_hash, role_code, organization_id, access_scope_mode, created_by)
            VALUES (%s, %s, '$argon2id$placeholder', %s, %s, %s, 'analytics-catalog-test')
            RETURNING portal_user_id
            """,
            (f"ac-{scope.lower()}-{uuid.uuid4().hex[:8]}@test", "Analytics Catalog Test", role,
             org, scope),
        )
        return self.cur.fetchone()[0]


@pytest.fixture
def tx():
    with psycopg.connect(CONNINFO) as connection:
        yield connection
        connection.rollback()


# ---------------------------------------------------------------------------
# Catalog contract
# ---------------------------------------------------------------------------


def test_catalog_function_security_and_grants():
    with psycopg.connect(CONNINFO) as connection:
        row = connection.execute(
            """
            SELECT p.prosecdef, p.provolatile, r.rolname,
                   has_function_privilege('public', p.oid, 'EXECUTE'),
                   has_function_privilege('ems_app', p.oid, 'EXECUTE')
            FROM pg_proc AS p JOIN pg_roles AS r ON r.oid = p.proowner
            WHERE p.oid = %s::regprocedure
            """,
            (CATALOG_SIG,),
        ).fetchone()
    assert row == (True, "s", "ems_admin", False, True)


def test_catalog_never_reads_device_capability_or_primary_meter():
    with psycopg.connect(CONNINFO) as connection:
        body = connection.execute(
            "SELECT lower(pg_get_functiondef(%s::regprocedure))", (CATALOG_SIG,)
        ).fetchone()[0]
    for forbidden in ("primary_meter", "asset_devices", "device_point_configuration",
                      "v_grafana_asset_point_selector", "insert into", "update ", "delete from"):
        assert forbidden not in body, forbidden
    assert "metadata.asset_points" in body


# ---------------------------------------------------------------------------
# Behaviour
# ---------------------------------------------------------------------------


def test_catalog_lists_every_assignment_period_of_active_assets(tx):
    """Migration 288: current, closed and future bindings of ACTIVE assets are
    all listed, each with its assignment period (closed and future
    assignments were excluded before 288). DRAFT / COMMISSIONING assets
    and unbound assets stay out."""
    with tx.cursor() as cur:
        f = Fixture(cur)
        org, site, gw = f.org_site("A")
        confirmed, dev_confirmed = f.asset(org, site, gw, "A1 Confirmed", "ACTIVE")
        f.bind(org, confirmed, dev_confirmed, "ENERGY_IMPORT_TOTAL")
        f.bind(org, confirmed, dev_confirmed, "ENERGY_EXPORT_TOTAL")

        draft, dev_draft = f.asset(org, site, gw, "A2 Draft", "DRAFT")
        f.bind(org, draft, dev_draft, "ENERGY_IMPORT_TOTAL")

        commissioning, dev_comm = f.asset(org, site, gw, "A3 Commissioning", "COMMISSIONING")
        f.bind(org, commissioning, dev_comm, "ENERGY_IMPORT_TOTAL")

        ended, dev_ended = f.asset(org, site, gw, "A4 Ended", "ACTIVE")
        now = datetime.now(timezone.utc)
        f.bind(org, ended, dev_ended, "ENERGY_IMPORT_TOTAL",
               start=now - timedelta(days=10), end=now - timedelta(days=1))

        future, dev_future = f.asset(org, site, gw, "A5 Future", "ACTIVE")
        f.bind(org, future, dev_future, "ENERGY_IMPORT_TOTAL", start=now + timedelta(days=1))

        _unbound, _ = f.asset(org, site, gw, "A6 Unbound", "ACTIVE")
        admin = f.portal_user(None, "GLOBAL", role="ADMIN")

        cur.execute(CATALOG_SQL, (admin, site))
        rows = cur.fetchall()

    default_start = datetime(2026, 9, 1, tzinfo=timezone.utc)
    assert [(r[1], r[2], r[6], r[8], r[9]) for r in rows] == [
        ("A1 Confirmed", "ENERGY_EXPORT", "TOTAL", default_start, None),
        ("A1 Confirmed", "ENERGY_IMPORT", "TOTAL", default_start, None),
        ("A4 Ended", "ENERGY_IMPORT", "TOTAL", now - timedelta(days=10), now - timedelta(days=1)),
        ("A5 Future", "ENERGY_IMPORT", "TOTAL", now + timedelta(days=1), None),
    ]
    assert {r[3] for r in rows} == {"Active Energy Import", "Active Energy Export"}
    assert {(r[4], r[5]) for r in rows} == {("Energy", "kWh")}
    assert {r[7] for r in rows} == {"CONFIRMED"}


def test_catalog_reports_power_in_kw_kva_kvar_and_energy_in_kwh(tx):
    """Migration 289: the power parameters report their logical-point units
    (kW / kVA / kvar), Energy stays kWh, Power Factor stays unitless."""
    with tx.cursor() as cur:
        f = Fixture(cur)
        org, site, gw = f.org_site("U")
        asset, dev = f.asset(org, site, gw, "U1 Units", "ACTIVE")
        for point in ("ACTIVE_POWER_TOTAL", "APPARENT_POWER_TOTAL", "REACTIVE_POWER_TOTAL",
                      "POWER_FACTOR_TOTAL", "ENERGY_IMPORT_TOTAL", "ENERGY_EXPORT_TOTAL"):
            f.bind(org, asset, dev, point)
        admin = f.portal_user(None, "GLOBAL", role="ADMIN")
        cur.execute(CATALOG_SQL, (admin, site))
        rows = cur.fetchall()

    assert {r[2]: r[5] for r in rows} == {
        "ACTIVE_POWER": "kW",
        "APPARENT_POWER": "kVA",
        "REACTIVE_POWER": "kvar",
        "POWER_FACTOR": None,
        "ENERGY_IMPORT": "kWh",
        "ENERGY_EXPORT": "kWh",
    }


def test_separate_assignments_are_separate_periods_and_a_same_instant_replacement_is_one(tx):
    with tx.cursor() as cur:
        f = Fixture(cur)
        org, site, gw = f.org_site("P")
        t = datetime(2026, 9, 1, tzinfo=timezone.utc)
        # Assigned, unassigned for a week, assigned again (still open).
        gap_asset, dev = f.asset(org, site, gw, "P1 Reassigned", "ACTIVE")
        f.bind(org, gap_asset, dev, "ENERGY_IMPORT_TOTAL", start=t, end=t + timedelta(days=5))
        f.bind(org, gap_asset, dev, "ENERGY_IMPORT_TOTAL", start=t + timedelta(days=12))
        # Meter replaced at one instant: device A until T, device B from T.
        swap_asset, dev_a = f.asset(org, site, gw, "P2 Replaced", "ACTIVE")
        _spare, dev_b = f.asset(org, site, gw, "P9 Spare meter holder", "DRAFT")
        f.bind(org, swap_asset, dev_a, "ENERGY_EXPORT_TOTAL", start=t, end=t + timedelta(days=3))
        f.bind(org, swap_asset, dev_b, "ENERGY_EXPORT_TOTAL", start=t + timedelta(days=3), end=t + timedelta(days=20))
        admin = f.portal_user(None, "GLOBAL", role="ADMIN")
        cur.execute(CATALOG_SQL, (admin, site))
        rows = cur.fetchall()

    assert [(r[1], r[2], r[8], r[9]) for r in rows] == [
        ("P1 Reassigned", "ENERGY_IMPORT", t, t + timedelta(days=5)),
        ("P1 Reassigned", "ENERGY_IMPORT", t + timedelta(days=12), None),
        ("P2 Replaced", "ENERGY_EXPORT", t, t + timedelta(days=20)),
    ]


def test_parity_bridge_rows_are_classified_internally_and_left_unchanged(tx):
    with tx.cursor() as cur:
        f = Fixture(cur)
        org, site, gw = f.org_site("B")
        bridged, dev = f.asset(org, site, gw, "B1 Bridged", "ACTIVE")
        f.bind(org, bridged, dev, "ENERGY_IMPORT_TOTAL", start=NEG_INF)
        admin = f.portal_user(None, "GLOBAL", role="ADMIN")

        cur.execute(
            "SELECT id, effective_from::text, effective_to::text FROM metadata.asset_points WHERE asset_id = %s",
            (bridged,),
        )
        before = cur.fetchall()
        cur.execute(CATALOG_SQL, (admin, site))
        rows = cur.fetchall()
        cur.execute(
            "SELECT id, effective_from::text, effective_to::text FROM metadata.asset_points WHERE asset_id = %s",
            (bridged,),
        )
        after = cur.fetchall()

    assert [(r[2], r[7]) for r in rows] == [("ENERGY_IMPORT", "PARITY_BRIDGE")]
    # The '-infinity' start is returned as NULL (unbounded), never infinity.
    assert (rows[0][8], rows[0][9]) == (None, None)
    assert before == after
    assert before[0][1] == "-infinity"


def test_semantic_points_only_raw_unmapped_points_are_excluded(tx):
    with tx.cursor() as cur:
        f = Fixture(cur)
        cur.execute(
            """
            SELECT lp.name FROM metadata.logical_points AS lp
            JOIN config.device_point_configuration AS dpc ON dpc.logical_point_id = lp.id
            JOIN config.device_profiles AS dp ON TRUE
            WHERE lp.parameter_id IS NULL AND dp.profile_code = 'ENERGY_METER_ENISCOPE_V1'
            LIMIT 1
            """
        )
        unmapped = cur.fetchone()
        org, site, gw = f.org_site("C")
        asset, dev = f.asset(org, site, gw, "C1 Mixed", "ACTIVE")
        f.bind(org, asset, dev, "ENERGY_IMPORT_TOTAL")
        f.bind(org, asset, dev, "CURRENT_L1")
        if unmapped is not None:
            cur.execute(
                "SELECT 1 FROM config.device_point_configuration WHERE device_id = %s AND logical_point_id = %s",
                (dev, f.point(unmapped[0])),
            )
            if cur.fetchone():
                f.bind(org, asset, dev, unmapped[0])
        admin = f.portal_user(None, "GLOBAL", role="ADMIN")
        cur.execute(CATALOG_SQL, (admin, site))
        rows = cur.fetchall()

    # CURRENT_L1 is semantic, so the read returns it; the application
    # registry (not this function) decides whether Analytics v1 shows it.
    assert {(r[2], r[6]) for r in rows} == {("ENERGY_IMPORT", "TOTAL"), ("CURRENT", "L1")}


def test_other_tenant_and_other_site_see_nothing(tx):
    with tx.cursor() as cur:
        f = Fixture(cur)
        org_a, site_a, gw_a = f.org_site("DA")
        asset, dev = f.asset(org_a, site_a, gw_a, "D1 Tenant A", "ACTIVE")
        f.bind(org_a, asset, dev, "ENERGY_IMPORT_TOTAL")
        org_b, site_b, _gw_b = f.org_site("DB")
        user_a = f.portal_user(org_a, "ORGANIZATION")
        user_b = f.portal_user(org_b, "ORGANIZATION")

        cur.execute(CATALOG_SQL, (user_a, site_a))
        own = cur.fetchall()
        cur.execute(CATALOG_SQL, (user_b, site_a))
        foreign = cur.fetchall()
        cur.execute(CATALOG_SQL, (user_a, site_b))
        other_site = cur.fetchall()

    assert [r[1] for r in own] == ["D1 Tenant A"]
    assert foreign == []
    assert other_site == []


def test_closed_assignments_stay_tenant_scoped(tx):
    with tx.cursor() as cur:
        f = Fixture(cur)
        now = datetime.now(timezone.utc)
        org_a, site_a, gw_a = f.org_site("TA")
        asset, dev = f.asset(org_a, site_a, gw_a, "T1 Closed", "ACTIVE")
        f.bind(org_a, asset, dev, "ENERGY_IMPORT_TOTAL", start=now - timedelta(days=30), end=now - timedelta(days=2))
        org_b, _site_b, _gw_b = f.org_site("TB")
        user_a = f.portal_user(org_a, "ORGANIZATION")
        user_b = f.portal_user(org_b, "ORGANIZATION")
        cur.execute(CATALOG_SQL, (user_a, site_a))
        own = cur.fetchall()
        cur.execute(CATALOG_SQL, (user_b, site_a))
        foreign = cur.fetchall()

    assert [(r[1], r[8], r[9]) for r in own] == [("T1 Closed", now - timedelta(days=30), now - timedelta(days=2))]
    assert foreign == []
