"""Migration 315 -- controlled portal user management, against the disposable
ems_test database.

Every function is called as ems_app (SET LOCAL ROLE), the role the
Administration App uses; each test runs in one rolled-back transaction except
the provisioning test, which commits a uniquely named account like the real
command does.

- self-protection: no own role / scope / status change, no own password reset;
- scope containment: a tenant administrator cannot touch, move or list a user
  of another organization or a GLOBAL user (the access-scope change used to
  check only the requested scope);
- details edit, password reset (Argon2id only, lockout cleared) and own-password
  change are audited without any hash;
- grants: ems_app only; never PUBLIC or ems_customer_api;
- the role catalogue is exactly ADMIN / OPERATOR / VIEWER;
- the initial-administrator command creates an ADMIN / GLOBAL account through
  admin.create_managed_portal_user and never touches an existing one.
"""

from __future__ import annotations

import asyncio
import io
import os
import secrets
import threading
import time

import psycopg
import pytest
from psycopg import errors

from src.auth.authorization import PortalRole
from src.auth.security import hash_portal_password, verify_portal_password

CONNINFO = (
    f"host={os.environ['EMS_APP_DB_HOST']} "
    f"port={os.environ['EMS_APP_DB_PORT']} "
    f"dbname={os.environ['EMS_APP_DB_NAME']} "
    f"user={os.environ['EMS_APP_DB_USER']} "
    f"password={os.environ['EMS_APP_DB_PASSWORD']}"
)
APP = "ems_app"
ORG_A = "00000000-0000-0000-0000-000000315a01"
ORG_B = "00000000-0000-0000-0000-000000315b01"
SITE_A1 = "00000000-0000-0000-0000-000000315a11"
SITE_A2 = "00000000-0000-0000-0000-000000315a12"
SITE_B1 = "00000000-0000-0000-0000-000000315b11"
HASH = "$argon2id$v=19$m=65536,t=3,p=4$placeholder"

USERS = {
    # key: (username, role, scope, org, sites)
    "global_admin": ("um315.global@test", "ADMIN", "GLOBAL", None, ()),
    "org_a_admin": ("um315.orga.admin@test", "ADMIN", "ORGANIZATION", ORG_A, ()),
    "org_a_admin_2": ("um315.orga.admin2@test", "ADMIN", "ORGANIZATION", ORG_A, ()),
    "sites_a_admin": ("um315.sitesa.admin@test", "ADMIN", "SELECTED_SITES", ORG_A, (SITE_A1,)),
    "org_a_viewer": ("um315.orga.viewer@test", "VIEWER", "ORGANIZATION", ORG_A, ()),
    "org_b_viewer": ("um315.orgb.viewer@test", "VIEWER", "ORGANIZATION", ORG_B, ()),
    "global_viewer": ("um315.global.viewer@test", "VIEWER", "GLOBAL", None, ()),
}

FUNCTIONS = (
    "admin.change_managed_portal_user_role(bigint, bigint, text)",
    "admin.set_managed_portal_user_active(bigint, bigint, boolean)",
    "admin.set_managed_portal_user_access_scope(bigint, bigint, text, uuid, uuid[])",
    "admin.update_managed_portal_user_details(bigint, bigint, text, text)",
    "admin.reset_managed_portal_user_password(bigint, bigint, text)",
    "admin.change_own_portal_user_password(bigint, text)",
)


@pytest.fixture(scope="module", autouse=True)
def seed() -> dict[str, int]:
    ids: dict[str, int] = {}
    with psycopg.connect(CONNINFO) as conn, conn.cursor() as cur:
        for org, code in ((ORG_A, "UM315_A"), (ORG_B, "UM315_B")):
            cur.execute(
                "INSERT INTO metadata.organizations (id, name, code) VALUES (%s, %s, %s) ON CONFLICT (id) DO NOTHING",
                (org, code, code),
            )
        for site, org, code in ((SITE_A1, ORG_A, "UM315_A1"), (SITE_A2, ORG_A, "UM315_A2"), (SITE_B1, ORG_B, "UM315_B1")):
            cur.execute(
                "INSERT INTO metadata.sites (id, organization_id, code, name, timezone) "
                "VALUES (%s, %s, %s, %s, 'Asia/Kolkata') ON CONFLICT (id) DO NOTHING",
                (site, org, code, code),
            )
        for key, (username, role, scope, org, sites) in USERS.items():
            cur.execute(
                """
                INSERT INTO admin.portal_users
                    (username, display_name, email, password_hash, role_code, organization_id, access_scope_mode, created_by)
                VALUES (%s, %s, %s, %s, %s, %s, %s, 'user-management-315-test')
                ON CONFLICT (username) DO NOTHING
                """,
                (username, key, username.replace("@test", "@example.com"), HASH, role, org, scope),
            )
            cur.execute("SELECT portal_user_id FROM admin.portal_users WHERE username = %s", (username,))
            ids[key] = cur.fetchone()[0]
            for site in sites:
                cur.execute(
                    "INSERT INTO admin.portal_user_site_access (portal_user_id, site_id, created_by_portal_user_id) "
                    "VALUES (%s, %s, %s) ON CONFLICT DO NOTHING",
                    (ids[key], site, ids[key]),
                )
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
    # On an error the transaction is aborted; _refused's ROLLBACK TO SAVEPOINT
    # also undoes this SET LOCAL ROLE, so RESET only on success.
    cur.execute(f"SET LOCAL ROLE {APP}")
    cur.execute(sql, params)
    rows = cur.fetchall() if cur.description else None
    cur.execute("RESET ROLE")
    return rows


def _refused(cur, sql: str, params: tuple, sqlstate: str = "42501") -> str:
    cur.execute("SAVEPOINT refused")
    with pytest.raises(errors.Error) as raised:
        _as_app(cur, sql, params)
    cur.execute("ROLLBACK TO SAVEPOINT refused")
    assert raised.value.sqlstate == sqlstate, raised.value
    return raised.value.diag.message_primary


def _user(cur, portal_user_id: int) -> dict:
    cur.execute(
        "SELECT role_code, access_scope_mode, organization_id::text, is_active, display_name, email, "
        "password_hash, failed_login_count, locked_until "
        "FROM admin.portal_users WHERE portal_user_id = %s",
        (portal_user_id,),
    )
    keys = ("role", "scope", "org", "active", "display_name", "email", "hash", "failures", "locked_until")
    return dict(zip(keys, cur.fetchone()))


def _audit(cur, target: int) -> list[tuple]:
    cur.execute(
        "SELECT event_type, actor_portal_user_id, event_payload::text FROM admin.portal_user_audit "
        "WHERE target_portal_user_id = %s AND created_at >= now() ORDER BY created_at",
        (target,),
    )
    return cur.fetchall()


# --- grants / catalogue ---------------------------------------------------------------------


def test_function_grants_are_ems_app_only(cur) -> None:
    for signature in FUNCTIONS:
        cur.execute("SELECT has_function_privilege('ems_app', %s, 'EXECUTE')", (signature,))
        assert cur.fetchone()[0] is True, signature
        cur.execute(
            "SELECT EXISTS (SELECT 1 FROM pg_proc p CROSS JOIN LATERAL aclexplode(COALESCE(p.proacl, acldefault('f', p.proowner))) a "
            "WHERE p.oid = %s::regprocedure AND a.grantee = 0)",
            (signature,),
        )
        assert cur.fetchone()[0] is False, f"PUBLIC can execute {signature}"
        cur.execute("SELECT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'ems_customer_api')")
        if cur.fetchone()[0]:
            cur.execute("SELECT has_function_privilege('ems_customer_api', %s, 'EXECUTE')", (signature,))
            assert cur.fetchone()[0] is False, f"ems_customer_api can execute {signature}"


def test_role_catalogue_matches_the_application(cur) -> None:
    cur.execute("SELECT role_code FROM config.portal_role_definitions ORDER BY sort_order")
    assert [r[0] for r in cur.fetchall()] == [r.value for r in PortalRole]


# --- self-protection ---------------------------------------------------------------------------


def test_no_one_changes_their_own_role_scope_or_status(cur, seed) -> None:
    me = seed["global_admin"]
    assert "own role" in _refused(cur, "SELECT admin.change_managed_portal_user_role(%s, %s, 'VIEWER')", (me, me))
    assert "own account status" in _refused(cur, "SELECT admin.set_managed_portal_user_active(%s, %s, FALSE)", (me, me))
    assert "own access scope" in _refused(
        cur, "SELECT admin.set_managed_portal_user_access_scope(%s, %s, 'ORGANIZATION', %s, '{}')", (me, me, ORG_A)
    )
    assert "own password" in _refused(cur, "SELECT admin.reset_managed_portal_user_password(%s, %s, %s)", (me, me, HASH))
    assert _user(cur, me)["role"] == "ADMIN" and _user(cur, me)["active"] is True


# --- tenant isolation / scope containment -----------------------------------------------------------


def test_tenant_admin_lists_only_their_organization(cur, seed) -> None:
    rows = _as_app(cur, "SELECT portal_user_id FROM admin.list_manageable_portal_users(%s)", (seed["org_a_admin"],))
    listed = {r[0] for r in rows}
    assert {seed["org_a_viewer"], seed["sites_a_admin"]} <= listed
    assert not listed & {seed["org_b_viewer"], seed["global_viewer"], seed["global_admin"]}


def test_tenant_admin_cannot_pull_another_tenants_user_into_their_organization(cur, seed) -> None:
    """The defect migration 315 fixes: only the NEW scope used to be checked."""

    for victim in ("org_b_viewer", "global_viewer", "global_admin"):
        _refused(
            cur,
            "SELECT admin.set_managed_portal_user_access_scope(%s, %s, 'ORGANIZATION', %s, '{}')",
            (seed["org_a_admin"], seed[victim], ORG_A),
        )
        assert _user(cur, seed[victim])["org"] != ORG_A


def test_tenant_admin_cannot_touch_users_outside_their_scope(cur, seed) -> None:
    actor, victim = seed["org_a_admin"], seed["org_b_viewer"]
    _refused(cur, "SELECT admin.change_managed_portal_user_role(%s, %s, 'ADMIN')", (actor, victim))
    _refused(cur, "SELECT admin.set_managed_portal_user_active(%s, %s, FALSE)", (actor, victim))
    _refused(cur, "SELECT admin.update_managed_portal_user_details(%s, %s, 'X', 'x@example.com')", (actor, victim))
    _refused(cur, "SELECT admin.reset_managed_portal_user_password(%s, %s, %s)", (actor, victim, HASH))
    after = _user(cur, victim)
    assert (after["role"], after["active"], after["display_name"]) == ("VIEWER", True, "org_b_viewer")


def test_selected_sites_admin_cannot_widen_access(cur, seed) -> None:
    actor = seed["sites_a_admin"]
    # A user on site A1 only, which the actor also holds: manageable.
    target = _as_app(
        cur,
        "SELECT admin.create_managed_portal_user(%s, 'um315.tmp@test', 'Tmp', 'um315.tmp@example.com', %s, "
        "'VIEWER', 'SELECTED_SITES', %s, %s)",
        (actor, HASH, ORG_A, [SITE_A1]),
    )[0][0]
    _refused(
        cur,
        "SELECT admin.set_managed_portal_user_access_scope(%s, %s, 'SELECTED_SITES', %s, %s)",
        (actor, target, ORG_A, [SITE_A1, SITE_A2]),
    )
    _refused(
        cur,
        "SELECT admin.set_managed_portal_user_access_scope(%s, %s, 'ORGANIZATION', %s, '{}')",
        (actor, target, ORG_A),
    )


def test_tenant_admin_manages_their_own_organization(cur, seed) -> None:
    actor, target = seed["org_a_admin"], seed["org_a_viewer"]
    _as_app(cur, "SELECT admin.set_managed_portal_user_access_scope(%s, %s, 'SELECTED_SITES', %s, %s)",
            (actor, target, ORG_A, [SITE_A2]))
    _as_app(cur, "SELECT admin.change_managed_portal_user_role(%s, %s, 'OPERATOR')", (actor, target))
    _as_app(cur, "SELECT admin.set_managed_portal_user_active(%s, %s, FALSE)", (actor, target))
    after = _user(cur, target)
    assert (after["role"], after["scope"], after["active"]) == ("OPERATOR", "SELECTED_SITES", False)
    events = [e[0] for e in _audit(cur, target)]
    assert events == ["USER_SCOPE_CHANGED", "USER_ROLE_CHANGED", "USER_STATUS_CHANGED"]


def test_unknown_target_is_refused(cur, seed) -> None:
    _refused(cur, "SELECT admin.set_managed_portal_user_active(%s, %s, FALSE)", (seed["global_admin"], 999_999_999))


# --- details / passwords -------------------------------------------------------------------------------


def test_details_edit_is_audited_and_a_no_op_is_not(cur, seed) -> None:
    actor, target = seed["global_admin"], seed["org_b_viewer"]
    _as_app(cur, "SELECT admin.update_managed_portal_user_details(%s, %s, ' New  Name ', 'new@example.com')", (actor, target))
    after = _user(cur, target)
    assert (after["display_name"], after["email"]) == ("New  Name", "new@example.com")
    _as_app(cur, "SELECT admin.update_managed_portal_user_details(%s, %s, 'New  Name', 'new@example.com')", (actor, target))
    events = _audit(cur, target)
    assert [e[0] for e in events] == ["USER_DETAILS_CHANGED"]
    assert "new@example.com" in events[0][2]
    assert "Full name is required" in _refused(
        cur, "SELECT admin.update_managed_portal_user_details(%s, %s, '  ', NULL)", (actor, target), "22023"
    )


def test_duplicate_email_is_a_unique_violation(cur, seed) -> None:
    taken = USERS["org_a_viewer"][0].replace("@test", "@example.com")
    cur.execute("SAVEPOINT dup")
    with pytest.raises(errors.UniqueViolation) as raised:
        _as_app(cur, "SELECT admin.update_managed_portal_user_details(%s, %s, 'X', %s)",
                (seed["global_admin"], seed["org_b_viewer"], taken.upper()))
    cur.execute("ROLLBACK TO SAVEPOINT dup")
    assert "email" in raised.value.diag.constraint_name


def test_duplicate_username_is_a_unique_violation(cur, seed) -> None:
    cur.execute("SAVEPOINT dup")
    with pytest.raises(errors.UniqueViolation) as raised:
        _as_app(
            cur,
            "SELECT admin.create_managed_portal_user(%s, %s, 'Dup', 'dup315@example.com', %s, 'VIEWER', 'ORGANIZATION', %s, '{}')",
            (seed["global_admin"], USERS["org_a_viewer"][0].upper(), HASH, ORG_A),
        )
    cur.execute("ROLLBACK TO SAVEPOINT dup")
    assert raised.value.diag.constraint_name == "ux_portal_users_username"


def test_password_reset_requires_argon2id_clears_lockout_and_audits_no_hash(cur, seed) -> None:
    actor, target = seed["org_a_admin"], seed["org_a_viewer"]
    cur.execute(
        "UPDATE admin.portal_users SET failed_login_count = 5, locked_until = now() + interval '1 hour' WHERE portal_user_id = %s",
        (target,),
    )
    _refused(cur, "SELECT admin.reset_managed_portal_user_password(%s, %s, 'plaintext-password')", (actor, target), "22023")

    new_hash = hash_portal_password("Reset-Password-315")
    _as_app(cur, "SELECT admin.reset_managed_portal_user_password(%s, %s, %s)", (actor, target, new_hash))
    after = _user(cur, target)
    assert verify_portal_password(after["hash"], "Reset-Password-315")
    assert after["failures"] == 0 and after["locked_until"] is None
    [(event, audit_actor, payload)] = _audit(cur, target)
    assert (event, audit_actor) == ("USER_PASSWORD_RESET", actor)
    assert "argon2" not in payload and new_hash not in payload


def test_own_password_change_is_audited(cur, seed) -> None:
    me = seed["org_a_viewer"]
    new_hash = hash_portal_password("Own-Password-315!")
    _as_app(cur, "SELECT admin.change_own_portal_user_password(%s, %s)", (me, new_hash))
    assert verify_portal_password(_user(cur, me)["hash"], "Own-Password-315!")
    [(event, audit_actor, payload)] = _audit(cur, me)
    assert (event, audit_actor, payload) == ("USER_PASSWORD_CHANGED", me, "{}")
    cur.execute("UPDATE admin.portal_users SET is_active = FALSE WHERE portal_user_id = %s", (me,))
    _refused(cur, "SELECT admin.change_own_portal_user_password(%s, %s)", (me, new_hash))


# --- initial administrator provisioning (real database, committed) -------------------------------------


def test_initial_administrator_provisioning_end_to_end(seed, tmp_path) -> None:
    import src.provision_portal_admin as provisioning
    from src.database import close_database_pool, open_database_pool

    username = f"prov315_{secrets.token_hex(4)}"
    password_file = tmp_path / "initial_password.txt"

    async def run(**kwargs) -> int:
        await open_database_pool()
        try:
            return await provisioning.provision(
                username=username, display_name="EMS Administrator", email=f"{username}@example.com",
                actor_username=USERS["global_admin"][0], out=io.StringIO(), err=io.StringIO(), **kwargs,
            )
        finally:
            await close_database_pool()

    assert asyncio.run(run(password_file=str(password_file))) == provisioning.EXIT_CREATED
    password = password_file.read_text(encoding="utf-8").strip()

    with psycopg.connect(CONNINFO) as conn, conn.cursor() as cur:
        cur.execute(
            "SELECT portal_user_id, role_code, access_scope_mode, organization_id, is_active, password_hash "
            "FROM admin.portal_users WHERE username = %s",
            (username,),
        )
        portal_user_id, role, scope, org, active, stored_hash = cur.fetchone()
        assert (role, scope, org, active) == ("ADMIN", "GLOBAL", None, True)
        assert stored_hash.startswith("$argon2id$") and verify_portal_password(stored_hash, password)
        cur.execute(
            "SELECT event_type, actor_portal_user_id, event_payload::text FROM admin.portal_user_audit WHERE target_portal_user_id = %s",
            (portal_user_id,),
        )
        [(event, actor, payload)] = cur.fetchall()
        assert (event, actor) == ("USER_CREATED", seed["global_admin"])
        assert password not in payload and "argon2" not in payload

    # A second run never resets or re-activates the existing account.
    assert asyncio.run(run(password_file=str(tmp_path / "second.txt"))) == provisioning.EXIT_EXISTS
    assert not (tmp_path / "second.txt").exists()
    with psycopg.connect(CONNINFO) as conn, conn.cursor() as cur:
        cur.execute("SELECT password_hash FROM admin.portal_users WHERE username = %s", (username,))
        assert cur.fetchone()[0] == stored_hash


# --- another administrator's password: WiseWatts staff only -----------------------------------


def _peer_admin(cur, *, scope: str = "ORGANIZATION", sites: tuple[str, ...] = ()) -> int:
    """An extra ADMIN in organization A, inside this test's (rolled-back) transaction."""

    cur.execute(
        """
        INSERT INTO admin.portal_users
            (username, display_name, email, password_hash, role_code, organization_id, access_scope_mode, created_by)
        VALUES (%s, 'peer admin', NULL, %s, 'ADMIN', %s, %s, 'user-management-315-test')
        RETURNING portal_user_id
        """,
        (f"um315.peer.{secrets.token_hex(4)}@test", HASH, ORG_A, scope),
    )
    peer = cur.fetchone()[0]
    for site in sites:
        cur.execute(
            "INSERT INTO admin.portal_user_site_access (portal_user_id, site_id, created_by_portal_user_id) VALUES (%s, %s, %s)",
            (peer, site, peer),
        )
    return peer


def test_tenant_admin_cannot_reset_a_peer_administrators_password(cur, seed) -> None:
    peer = _peer_admin(cur)
    before = _user(cur, peer)["hash"]
    message = _refused(
        cur, "SELECT admin.reset_managed_portal_user_password(%s, %s, %s)", (seed["org_a_admin"], peer, hash_portal_password("Peer-Reset-315!"))
    )
    assert "staff administrators" in message
    assert _user(cur, peer)["hash"] == before
    assert _audit(cur, peer) == []


def test_selected_sites_admin_cannot_reset_a_peer_administrators_password(cur, seed) -> None:
    peer = _peer_admin(cur, scope="SELECTED_SITES", sites=(SITE_A1,))
    _refused(
        cur, "SELECT admin.reset_managed_portal_user_password(%s, %s, %s)", (seed["sites_a_admin"], peer, hash_portal_password("Peer-Reset-315!"))
    )


def test_staff_admin_resets_another_administrators_password(cur, seed) -> None:
    peer = _peer_admin(cur)
    _as_app(cur, "SELECT admin.reset_managed_portal_user_password(%s, %s, %s)", (seed["global_admin"], peer, hash_portal_password("Peer-Reset-315!")))
    assert verify_portal_password(_user(cur, peer)["hash"], "Peer-Reset-315!")
    [(event, actor, _payload)] = _audit(cur, peer)
    assert (event, actor) == ("USER_PASSWORD_RESET", seed["global_admin"])


def test_tenant_admin_still_resets_non_administrators(cur, seed) -> None:
    _as_app(
        cur,
        "SELECT admin.reset_managed_portal_user_password(%s, %s, %s)",
        (seed["org_a_admin"], seed["org_a_viewer"], hash_portal_password("Viewer-Reset-315!")),
    )


def test_no_hash_or_password_material_ever_reaches_the_audit_trail(cur, seed) -> None:
    actor, target = seed["global_admin"], seed["org_a_viewer"]
    reset_hash = hash_portal_password("Audit-Check-Reset-1")
    own_hash = hash_portal_password("Audit-Check-Own-22")
    _as_app(cur, "SELECT admin.reset_managed_portal_user_password(%s, %s, %s)", (actor, target, reset_hash))
    _as_app(cur, "SELECT admin.change_own_portal_user_password(%s, %s)", (target, own_hash))
    _as_app(cur, "SELECT admin.update_managed_portal_user_details(%s, %s, 'Audit Check', NULL)", (actor, target))
    cur.execute(
        "SELECT event_payload::text, coalesce(previous_role_code, ''), coalesce(new_role_code, '') "
        "FROM admin.portal_user_audit WHERE target_portal_user_id = %s",
        (target,),
    )
    for row in cur.fetchall():
        text = " ".join(row)
        assert "argon2" not in text and "$" not in text
        assert "Audit-Check" not in text


# --- concurrency: the scope check runs on locked, committed state -------------------------------


def _wait_until_blocked(pid: int, timeout: float = 10.0) -> None:
    deadline = time.monotonic() + timeout
    with psycopg.connect(CONNINFO, autocommit=True) as observer, observer.cursor() as watch:
        while time.monotonic() < deadline:
            watch.execute("SELECT wait_event_type FROM pg_stat_activity WHERE pid = %s", (pid,))
            row = watch.fetchone()
            if row and row[0] == "Lock":
                return
            time.sleep(0.05)
    raise AssertionError("the second administrator's call never waited on the row lock")


def _restore_scope(portal_user_id: int, org: str) -> None:
    with psycopg.connect(CONNINFO) as conn, conn.cursor() as c:
        c.execute("DELETE FROM admin.portal_user_site_access WHERE portal_user_id = %s", (portal_user_id,))
        c.execute(
            "UPDATE admin.portal_users SET organization_id = %s, access_scope_mode = 'ORGANIZATION', role_code = 'VIEWER' "
            "WHERE portal_user_id = %s",
            (org, portal_user_id),
        )
        conn.commit()


def test_a_concurrent_move_out_of_the_tenant_cannot_be_overridden(seed) -> None:
    """Staff move org A's viewer to org B while org A's admin edits the same user.

    The tenant admin's call waits for the row lock and then re-checks scope on
    the committed state: the user is now in org B, so it is refused (before
    315's ordering it passed the check on the old state and then wrote).
    """

    target = seed["org_a_viewer"]
    outcome: dict[str, object] = {}
    try:
        with psycopg.connect(CONNINFO) as staff, staff.cursor() as s:
            s.execute(f"SET LOCAL ROLE {APP}")
            s.execute(
                "SELECT admin.set_managed_portal_user_access_scope(%s, %s, 'ORGANIZATION', %s, ARRAY[]::uuid[])",
                (seed["global_admin"], target, ORG_B),
            )

            tenant = psycopg.connect(CONNINFO)
            tenant_pid = tenant.info.backend_pid

            def tenant_edit() -> None:
                try:
                    with tenant.cursor() as t:
                        t.execute("SET statement_timeout = '20s'")
                        t.execute(f"SET ROLE {APP}")
                        t.execute(
                            "SELECT admin.set_managed_portal_user_access_scope(%s, %s, 'ORGANIZATION', %s, ARRAY[]::uuid[])",
                            (seed["org_a_admin"], target, ORG_A),
                        )
                    tenant.commit()
                    outcome["result"] = "changed"
                except errors.Error as exc:
                    tenant.rollback()
                    outcome["result"] = exc.sqlstate

            worker = threading.Thread(target=tenant_edit)
            worker.start()
            _wait_until_blocked(tenant_pid)
            staff.commit()
            worker.join(timeout=30)
            tenant.close()

        assert outcome.get("result") == "42501"
        with psycopg.connect(CONNINFO) as conn, conn.cursor() as c:
            c.execute("SELECT organization_id::text FROM admin.portal_users WHERE portal_user_id = %s", (target,))
            assert c.fetchone()[0] == ORG_B
    finally:
        _restore_scope(target, ORG_A)


def test_two_administrators_acting_on_each_other_do_not_deadlock(seed) -> None:
    """Both calls lock the same two rows in id order: they serialize, never 40P01."""

    first, second = seed["org_a_admin"], seed["org_a_admin_2"]
    results: dict[str, object] = {}
    try:
        with psycopg.connect(CONNINFO) as a, a.cursor() as ca:
            ca.execute(f"SET LOCAL ROLE {APP}")
            ca.execute("SELECT admin.update_managed_portal_user_details(%s, %s, 'renamed by first', NULL)", (first, second))

            b = psycopg.connect(CONNINFO)
            b_pid = b.info.backend_pid

            def other_direction() -> None:
                try:
                    with b.cursor() as cb:
                        cb.execute("SET statement_timeout = '20s'")
                        cb.execute(f"SET ROLE {APP}")
                        cb.execute(
                            "SELECT admin.update_managed_portal_user_details(%s, %s, 'renamed by second', NULL)",
                            (second, first),
                        )
                    b.commit()
                    results["b"] = "ok"
                except errors.Error as exc:
                    b.rollback()
                    results["b"] = exc.sqlstate

            worker = threading.Thread(target=other_direction)
            worker.start()
            _wait_until_blocked(b_pid)
            a.commit()
            worker.join(timeout=30)
            b.close()
        assert results.get("b") == "ok"
    finally:
        with psycopg.connect(CONNINFO) as conn, conn.cursor() as c:
            c.execute("UPDATE admin.portal_users SET display_name = 'org_a_admin' WHERE portal_user_id = %s", (first,))
            c.execute("UPDATE admin.portal_users SET display_name = 'org_a_admin_2' WHERE portal_user_id = %s", (second,))
            conn.commit()
