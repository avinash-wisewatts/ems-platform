"""Migration 319 -- admin.list_manageable_portal_user_audit, against the
disposable ems_test database.

Called as ems_app (SET LOCAL ROLE), the role the Administration App uses;
each test runs in one rolled-back transaction. History is produced through
the real, audited user-management functions (migration 315).

- actor: active ADMIN only (42501 otherwise);
- scope: a target outside the actor's scope returns nothing;
- tenant isolation inside the history: a tenant administrator sees only rows
  of its own organization, never organization / site ids, and only the names
  of actors it may see itself; WiseWatts staff (GLOBAL) see everything;
- payloads redacted; limit clamped; newest first;
- grants and function properties: SECURITY DEFINER, STABLE, pinned
  search_path, owner ems_admin, EXECUTE ems_app only; ems_app has no direct
  SELECT on admin.portal_user_audit.
"""

from __future__ import annotations

import os

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
FN = "admin.list_manageable_portal_user_audit(bigint,bigint,integer)"
ORG_A = "00000000-0000-0000-0000-000000319a01"
ORG_B = "00000000-0000-0000-0000-000000319b01"
SITE_A1 = "00000000-0000-0000-0000-000000319a11"
SITE_B1 = "00000000-0000-0000-0000-000000319b11"
HASH = "$argon2id$v=19$m=65536,t=3,p=4$placeholder"

USERS = {
    "global_admin": ("au319.global@test", "ADMIN", "GLOBAL", None),
    "org_a_admin": ("au319.orga.admin@test", "ADMIN", "ORGANIZATION", ORG_A),
    "org_b_admin": ("au319.orgb.admin@test", "ADMIN", "ORGANIZATION", ORG_B),
    "org_a_operator": ("au319.orga.operator@test", "OPERATOR", "ORGANIZATION", ORG_A),
    "target": ("au319.target@test", "VIEWER", "ORGANIZATION", ORG_B),
}


@pytest.fixture(scope="module", autouse=True)
def seed() -> dict[str, int]:
    ids: dict[str, int] = {}
    with psycopg.connect(CONNINFO) as conn, conn.cursor() as cur:
        for org, code in ((ORG_A, "AU319_A"), (ORG_B, "AU319_B")):
            cur.execute(
                "INSERT INTO metadata.organizations (id, name, code) VALUES (%s, %s, %s) ON CONFLICT (id) DO NOTHING",
                (org, code, code),
            )
        for site, org, code in ((SITE_A1, ORG_A, "AU319_A1"), (SITE_B1, ORG_B, "AU319_B1")):
            cur.execute(
                "INSERT INTO metadata.sites (id, organization_id, code, name, timezone) "
                "VALUES (%s, %s, %s, %s, 'Asia/Kolkata') ON CONFLICT (id) DO NOTHING",
                (site, org, code, code),
            )
        for key, (username, role, scope, org) in USERS.items():
            cur.execute(
                """
                INSERT INTO admin.portal_users
                    (username, display_name, email, password_hash, role_code, organization_id, access_scope_mode, created_by)
                VALUES (%s, %s, %s, %s, %s, %s, %s, 'audit-history-319-test')
                ON CONFLICT (username) DO NOTHING
                """,
                (username, key, username.replace("@test", "@example.com"), HASH, role, org, scope),
            )
            cur.execute("SELECT portal_user_id FROM admin.portal_users WHERE username = %s", (username,))
            ids[key] = cur.fetchone()[0]
        conn.commit()
    return ids


@pytest.fixture
def cur():
    with psycopg.connect(CONNINFO) as conn, conn.cursor() as cursor:
        try:
            yield cursor
        finally:
            conn.rollback()


def _as_app(cur, sql: str, params: tuple = ()):
    cur.execute("SET LOCAL ROLE ems_app")
    cur.execute(sql, params)
    rows = cur.fetchall() if cur.description else None
    cur.execute("RESET ROLE")
    return rows


def _history(cur, actor: int, target: int, limit: int | None = 50) -> list[dict]:
    rows = _as_app(
        cur,
        "SELECT event_type, actor_portal_user_id, actor_display_name, actor_is_staff, "
        "previous_role_code, new_role_code, event_payload FROM admin.list_manageable_portal_user_audit(%s, %s, %s)",
        (actor, target, limit),
    )
    keys = ("event", "actor_id", "actor_name", "actor_is_staff", "previous_role", "new_role", "payload")
    return [dict(zip(keys, row)) for row in rows]


@pytest.fixture
def moved_target(cur, seed) -> int:
    """The target's history: changed in org B by its admin, then moved to org A
    (SELECTED_SITES, site A1) by staff, then changed in org A by its admin."""

    target = seed["target"]
    _as_app(cur, "SELECT admin.change_managed_portal_user_role(%s, %s, 'OPERATOR')", (seed["org_b_admin"], target))
    _as_app(
        cur,
        "SELECT admin.set_managed_portal_user_access_scope(%s, %s, 'SELECTED_SITES', %s, %s)",
        (seed["global_admin"], target, ORG_A, [SITE_A1]),
    )
    _as_app(cur, "SELECT admin.change_managed_portal_user_role(%s, %s, 'VIEWER')", (seed["org_a_admin"], target))
    return target


def test_staff_see_the_whole_history_with_ids_and_names(cur, seed, moved_target):
    history = _history(cur, seed["global_admin"], moved_target)
    assert [h["event"] for h in history] == ["USER_ROLE_CHANGED", "USER_SCOPE_CHANGED", "USER_ROLE_CHANGED"]
    assert [h["actor_name"] for h in history] == ["org_a_admin", "global_admin", "org_b_admin"]
    scope_change = history[1]
    assert scope_change["payload"]["new_organization_id"] == ORG_A
    assert scope_change["payload"]["previous_organization_id"] == ORG_B
    assert scope_change["payload"]["new_site_ids"] == [SITE_A1]
    assert scope_change["actor_is_staff"] is True


def test_tenant_admins_see_only_their_organizations_rows_without_ids(cur, seed, moved_target):
    history = _history(cur, seed["org_a_admin"], moved_target)
    # The org-B role change (before the move) is not visible to org A.
    assert [h["event"] for h in history] == ["USER_ROLE_CHANGED", "USER_SCOPE_CHANGED"]
    for row in history:
        for key in ("previous_organization_id", "new_organization_id", "previous_site_ids", "new_site_ids",
                    "organization_id", "site_ids"):
            assert key not in row["payload"]
    # Scope mode is still visible.
    assert history[1]["payload"]["new_access_scope_mode"] == "SELECTED_SITES"
    # Its own change is named; the staff actor is not (outside its scope), only flagged.
    assert history[0]["actor_name"] == "org_a_admin" and history[0]["actor_id"] == seed["org_a_admin"]
    assert history[1]["actor_name"] is None and history[1]["actor_id"] is None and history[1]["actor_is_staff"] is True


def test_a_target_outside_the_scope_returns_nothing(cur, seed, moved_target):
    # The target is now in org A: org B's administrator can no longer see any of it,
    # not even the row it wrote itself.
    assert _history(cur, seed["org_b_admin"], moved_target) == []
    # Staff are outside every tenant administrator's scope.
    assert _history(cur, seed["org_a_admin"], seed["global_admin"]) == []
    # Unknown target.
    assert _history(cur, seed["global_admin"], 987654321) == []


@pytest.mark.parametrize("actor_key", ["org_a_operator"])
def test_non_administrators_are_refused(cur, seed, moved_target, actor_key):
    cur.execute("SAVEPOINT s")
    with pytest.raises(errors.InsufficientPrivilege):
        _history(cur, seed[actor_key], moved_target)
    cur.execute("ROLLBACK TO SAVEPOINT s")


def test_inactive_administrators_are_refused(cur, seed, moved_target):
    cur.execute("UPDATE admin.portal_users SET is_active = FALSE WHERE portal_user_id = %s", (seed["org_a_admin"],))
    cur.execute("SAVEPOINT s")
    with pytest.raises(errors.InsufficientPrivilege):
        _history(cur, seed["org_a_admin"], moved_target)
    cur.execute("ROLLBACK TO SAVEPOINT s")


def test_limit_is_clamped_and_newest_first(cur, seed, moved_target):
    assert len(_history(cur, seed["global_admin"], moved_target, 0)) == 1
    assert len(_history(cur, seed["global_admin"], moved_target, -5)) == 1
    assert len(_history(cur, seed["global_admin"], moved_target, None)) == 3
    assert len(_history(cur, seed["global_admin"], moved_target, 100000)) == 3
    newest = _history(cur, seed["global_admin"], moved_target, 1)[0]
    assert newest["actor_name"] == "org_a_admin" and newest["new_role"] == "VIEWER"


def test_payloads_are_redacted(cur, seed):
    cur.execute(
        "INSERT INTO admin.portal_user_audit (actor_portal_user_id, target_portal_user_id, organization_id, "
        "event_type, event_payload) VALUES (%s, %s, %s, 'TEST_EVENT', %s)",
        (seed["global_admin"], seed["org_a_operator"], ORG_A,
         psycopg.types.json.Jsonb({"password": "secret-value", "nested": {"api_key": "k", "keep": 1}})),
    )
    [row] = [h for h in _history(cur, seed["global_admin"], seed["org_a_operator"]) if h["event"] == "TEST_EVENT"]
    assert row["payload"] == {"password": "[REDACTED]", "nested": {"api_key": "[REDACTED]", "keep": 1}}


def test_function_properties_and_grants(cur):
    cur.execute(
        "SELECT p.prosecdef, p.provolatile, pg_get_userbyid(p.proowner), p.proconfig "
        "FROM pg_proc p WHERE p.oid = %s::regprocedure",
        (FN,),
    )
    secdef, volatility, owner, config = cur.fetchone()
    assert secdef is True and volatility == "s" and owner == "ems_admin"
    assert config == ["search_path=pg_catalog, admin"]
    cur.execute(
        "SELECT r, has_function_privilege(r, %s, 'EXECUTE') FROM unnest(ARRAY['public','ems_app','ems_customer_api','ems_readonly']) r "
        "WHERE r = 'public' OR EXISTS (SELECT 1 FROM pg_roles WHERE rolname = r)",
        (FN,),
    )
    grants = dict(cur.fetchall())
    assert grants.pop("ems_app") is True
    assert not any(grants.values()), grants
    cur.execute("SELECT has_table_privilege('ems_app', 'admin.portal_user_audit', 'SELECT')")
    assert cur.fetchone()[0] is False


def test_ems_app_cannot_read_the_audit_table_directly(cur):
    cur.execute("SAVEPOINT s")
    with pytest.raises(errors.InsufficientPrivilege):
        _as_app(cur, "SELECT count(*) FROM admin.portal_user_audit")
    cur.execute("ROLLBACK TO SAVEPOINT s")
