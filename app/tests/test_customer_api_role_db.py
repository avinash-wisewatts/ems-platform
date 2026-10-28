"""Migration 313 -- ems_customer_api, the customer API's least-privilege role,
against the disposable ems_test database (ADR-023).

Every statement runs as the role itself (SET ROLE inside a transaction):

- it is NOLOGIN, unprivileged and a member of no role;
- it can execute every database function the customer API code calls (the
  list is parsed from the code, so a new call without a grant fails here);
- tenant isolation holds through it: portal-scoped reads return only the
  calling identity's organisation / selected sites;
- it can read no table directly, call no administration write function and
  use no schema other than admin and analytics.
"""

from __future__ import annotations

import os
import re
from datetime import datetime, timedelta, timezone
from pathlib import Path

import psycopg
import pytest
from psycopg import errors

CONNINFO = (
    f"host={os.environ['EMS_APP_DB_HOST']} "
    f"port={os.environ['EMS_APP_DB_PORT']} "
    f"dbname={os.environ['EMS_APP_DB_NAME']} "
    f"user={os.environ['EMS_APP_DB_USER']} "
    f"password={os.environ['EMS_APP_DB_PASSWORD']}"
)
ROLE = "ems_customer_api"
SRC = Path(__file__).resolve().parents[1] / "src"
CUSTOMER_CODE = [
    "analytics_api_service.py",
    "analytics_trends_service.py",
    "report_export_service.py",
    "report_export_worker.py",
    "auth/repository.py",
    "auth/server_session.py",
    "routers/analytics_api.py",
    "routers/report_exports.py",
    "routers/customer_auth.py",
    "customer_main.py",
]

ORG_A = "00000000-0000-0000-0000-0000000000a3"
ORG_B = "00000000-0000-0000-0000-0000000001a3"
SITE_A = "00000000-0000-0000-0000-0000000002a3"
SITE_A2 = "00000000-0000-0000-0000-0000000003a3"
SITE_B = "00000000-0000-0000-0000-0000000004a3"
USERS = {
    "global": ("ca.global@test", "ADMIN", None, "GLOBAL"),
    "org_a": ("ca.orga@test", "VIEWER", ORG_A, "ORGANIZATION"),
    "org_b": ("ca.orgb@test", "VIEWER", ORG_B, "ORGANIZATION"),
    "sel_a2": ("ca.sel-a2@test", "VIEWER", ORG_A, "SELECTED_SITES"),
}


@pytest.fixture(scope="module", autouse=True)
def seed() -> dict[str, int]:
    ids: dict[str, int] = {}
    with psycopg.connect(CONNINFO) as conn, conn.cursor() as cur:
        for org, code in ((ORG_A, "CA_ORG_A"), (ORG_B, "CA_ORG_B")):
            cur.execute(
                "INSERT INTO metadata.organizations (id, name, code) VALUES (%s, %s, %s) ON CONFLICT (id) DO NOTHING",
                (org, code, code),
            )
        for site, org, code in ((SITE_A, ORG_A, "CA_SITE_A"), (SITE_A2, ORG_A, "CA_SITE_A2"), (SITE_B, ORG_B, "CA_SITE_B")):
            cur.execute(
                "INSERT INTO metadata.sites (id, organization_id, name, code) VALUES (%s, %s, %s, %s) "
                "ON CONFLICT (id) DO NOTHING",
                (site, org, code, code),
            )
        for key, (username, role, org, scope) in USERS.items():
            cur.execute(
                """
                INSERT INTO admin.portal_users
                    (username, display_name, password_hash, role_code, organization_id, access_scope_mode, created_by)
                VALUES (%s, %s, '$argon2id$placeholder', %s, %s, %s, 'customer-api-role-test')
                ON CONFLICT (username) DO NOTHING
                """,
                (username, username, role, org, scope),
            )
            cur.execute("SELECT portal_user_id FROM admin.portal_users WHERE username = %s", (username,))
            ids[key] = cur.fetchone()[0]
        cur.execute(
            "INSERT INTO admin.portal_user_site_access (portal_user_id, site_id, created_by_portal_user_id) "
            "VALUES (%s, %s, %s) ON CONFLICT DO NOTHING",
            (ids["sel_a2"], SITE_A2, ids["global"]),
        )
        conn.commit()
    return ids


def _as_role(sql: str, params: tuple = ()) -> list[tuple]:
    """Run one statement as ems_customer_api; always rolled back."""

    with psycopg.connect(CONNINFO) as conn, conn.cursor() as cur:
        cur.execute(f"SET LOCAL ROLE {ROLE}")
        cur.execute(sql, params)
        rows = cur.fetchall() if cur.description else []
        conn.rollback()
        return rows


def _admin(sql: str, params: tuple = ()) -> list[tuple]:
    with psycopg.connect(CONNINFO) as conn, conn.cursor() as cur:
        cur.execute(sql, params)
        return cur.fetchall()


# --- the role itself -------------------------------------------------------------

def test_role_is_nologin_unprivileged_and_in_no_role() -> None:
    assert _admin(
        "SELECT rolcanlogin, rolsuper, rolcreaterole, rolcreatedb, rolbypassrls, rolreplication "
        "FROM pg_roles WHERE rolname = %s",
        (ROLE,),
    ) == [(False, False, False, False, False, False)]
    assert _admin(
        "SELECT count(*) FROM pg_auth_members WHERE member = (SELECT oid FROM pg_roles WHERE rolname = %s)",
        (ROLE,),
    ) == [(0,)]


def test_every_function_the_customer_code_calls_is_executable() -> None:
    called = set()
    for name in CUSTOMER_CODE:
        called |= set(re.findall(r"\b((?:admin|analytics)\.[a-z_0-9]+)\(", (SRC / name).read_text(encoding="utf-8")))
    assert len(called) >= 40, called
    missing = _admin(
        """
        SELECT n.nspname || '.' || p.proname
        FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
        WHERE n.nspname || '.' || p.proname = ANY(%s)
          AND NOT has_function_privilege(%s, p.oid, 'EXECUTE')
        """,
        (sorted(called), ROLE),
    )
    assert missing == []
    found = {r[0] for r in _admin(
        "SELECT DISTINCT n.nspname || '.' || p.proname FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace "
        "WHERE n.nspname || '.' || p.proname = ANY(%s)",
        (sorted(called),),
    )}
    assert found == called, called - found


def test_grants_are_exactly_the_customer_functions_and_two_schemas() -> None:
    # Direct grants only (PUBLIC defaults are not the role's grants).
    schemas = _admin(
        "SELECT n.nspname FROM pg_namespace n CROSS JOIN LATERAL aclexplode(n.nspacl) a "
        "WHERE n.nspacl IS NOT NULL AND a.grantee = (SELECT oid FROM pg_roles WHERE rolname = %s) ORDER BY 1",
        (ROLE,),
    )
    assert schemas == [("admin",), ("analytics",)]
    relations = _admin(
        "SELECT count(*) FROM pg_class c CROSS JOIN LATERAL aclexplode(c.relacl) a "
        "WHERE c.relacl IS NOT NULL AND a.grantee = (SELECT oid FROM pg_roles WHERE rolname = %s)",
        (ROLE,),
    )
    assert relations == [(0,)]
    granted = _admin(
        "SELECT count(DISTINCT p.oid), bool_and(p.prosecdef) FROM pg_proc p CROSS JOIN LATERAL aclexplode(p.proacl) a "
        "WHERE p.proacl IS NOT NULL AND a.grantee = (SELECT oid FROM pg_roles WHERE rolname = %s)",
        (ROLE,),
    )
    assert granted[0][0] >= 44 and granted[0][1] is True


# --- tenant isolation through the role ------------------------------------------

def _sites(user_id: int) -> set[str]:
    return {
        str(r[0]) for r in _as_role("SELECT id FROM admin.list_accessible_sites(%s)", (user_id,))
        if str(r[0]) in {SITE_A, SITE_A2, SITE_B}
    }


def test_organization_scope_sees_only_its_own_sites(seed) -> None:
    assert _sites(seed["org_a"]) == {SITE_A, SITE_A2}
    assert _sites(seed["org_b"]) == {SITE_B}


def test_selected_sites_scope_sees_only_its_selected_site(seed) -> None:
    assert _sites(seed["sel_a2"]) == {SITE_A2}


@pytest.mark.parametrize("user,site,allowed", [
    ("org_a", SITE_A, True), ("org_a", SITE_B, False), ("org_b", SITE_A, False), ("sel_a2", SITE_A, False),
    ("sel_a2", SITE_A2, True),
])
def test_access_checks_through_the_role(seed, user, site, allowed) -> None:
    assert _as_role("SELECT admin.portal_user_can_access_site(%s, %s)", (seed[user], site)) == [(allowed,)]


def test_cross_tenant_energy_read_returns_nothing(seed) -> None:
    to = datetime(2026, 10, 2, tzinfo=timezone.utc)
    rows = _as_role(
        "SELECT * FROM analytics.get_portal_site_energy_consumption(%s, %s, %s, %s, '1h')",
        (seed["org_b"], SITE_A, to - timedelta(days=1), to),
    )
    assert rows == []


def test_sign_in_lookup_works_through_the_role(seed) -> None:
    rows = _as_role("SELECT portal_user_id, access_scope_mode FROM admin.get_portal_user_for_authentication(%s)",
                    (USERS["org_a"][0],))
    assert rows == [(seed["org_a"], "ORGANIZATION")]


# --- what the role cannot do ---------------------------------------------------------

@pytest.mark.parametrize("table", [
    "admin.portal_users", "admin.portal_user_site_access", "metadata.sites", "metadata.organizations",
    "analytics.energy_consumption_hourly", "telemetry.normalized_points", "telemetry.raw_messages",
])
def test_no_direct_table_access(table) -> None:
    with pytest.raises(errors.InsufficientPrivilege):
        _as_role(f"SELECT 1 FROM {table} LIMIT 1")


def test_no_administration_write_function() -> None:
    with pytest.raises(errors.InsufficientPrivilege):
        _as_role("SELECT admin.create_building(1, %s, 'x', 'x')", (SITE_A,))


@pytest.mark.parametrize("schema", ["metadata", "config", "telemetry"])
def test_no_other_schema_usage(schema) -> None:
    assert _admin("SELECT has_schema_privilege(%s, %s, 'USAGE')", (ROLE, schema)) == [(False,)]


def test_cannot_log_in_until_an_operator_enables_it() -> None:
    host, port, dbname = (os.environ[k] for k in ("EMS_APP_DB_HOST", "EMS_APP_DB_PORT", "EMS_APP_DB_NAME"))
    with pytest.raises(psycopg.OperationalError):
        psycopg.connect(f"host={host} port={port} dbname={dbname} user={ROLE} password=x connect_timeout=5")
