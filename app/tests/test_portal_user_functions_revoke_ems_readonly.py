"""Migration 316: ems_readonly loses EXECUTE on the portal-user management and
authentication functions (production privilege exposure, 2026-11-04).

On production ems_readonly holds bulk pre-baseline EXECUTE grants; these
functions are SECURITY DEFINER and take the acting portal user as an
argument, so that role could create users, change roles / scope / status,
reset passwords, read password hashes or drive the lockout. Staging and the
test database have no such grant, so each test first reproduces production's
state inside a rolled-back transaction on the disposable ems_test database
(conftest.py), then re-runs the migration.
"""
import csv
from pathlib import Path

import psycopg
import pytest

from tests.test_asset_energy_tier_read import CONNINFO

REPO = Path(__file__).resolve().parents[2]
MIGRATION = REPO / "postgres" / "migrations" / "316_portal_user_functions_revoke_ems_readonly.sql"

APP_FUNCTIONS = (
    "admin.create_managed_portal_user(bigint,text,text,text,text,text,text,uuid,uuid[])",
    "admin.change_managed_portal_user_role(bigint,bigint,text)",
    "admin.set_managed_portal_user_active(bigint,bigint,boolean)",
    "admin.set_managed_portal_user_access_scope(bigint,bigint,text,uuid,uuid[])",
    "admin.update_managed_portal_user_details(bigint,bigint,text,text)",
    "admin.reset_managed_portal_user_password(bigint,bigint,text)",
    "admin.change_own_portal_user_password(bigint,text)",
    "admin.list_manageable_portal_users(bigint)",
    "admin.get_portal_user_for_authentication(text)",
    "admin.record_portal_login_failure(bigint)",
    "admin.record_portal_login_success(bigint)",
)
INTERNAL_FUNCTIONS = (
    "admin.portal_user_scope_contains_user(bigint,bigint)",
    "admin.enforce_portal_user_site_scope()",
    "admin.validate_portal_user_site_assignment()",
)
FUNCTIONS = APP_FUNCTIONS + INTERNAL_FUNCTIONS
# An admin function outside 316's scope: an ems_readonly grant on it must survive.
UNRELATED = "admin.list_accessible_sites(bigint)"


@pytest.fixture
def tx():
    with psycopg.connect(CONNINFO) as c:
        yield c
        c.rollback()


def _can(tx, role, signature):
    return tx.execute(
        "SELECT has_function_privilege(%s, %s::regprocedure, 'EXECUTE')", (role, signature)
    ).fetchone()[0]


def _acl(tx, signature):
    return tx.execute(
        "SELECT coalesce(proacl, acldefault('f', proowner))::text[] FROM pg_proc WHERE oid = %s::regprocedure",
        (signature,),
    ).fetchone()[0]


def _production_state(tx):
    """Production's grants (2026-11-04): ems_readonly has USAGE on admin and
    executes all of them."""
    tx.execute("GRANT USAGE ON SCHEMA admin TO ems_readonly")
    for signature in FUNCTIONS + (UNRELATED,):
        tx.execute(f"GRANT EXECUTE ON FUNCTION {signature} TO ems_readonly")
    assert all(_can(tx, "ems_readonly", s) for s in FUNCTIONS)


def _apply(tx):
    tx.execute(MIGRATION.read_text(encoding="utf-8"))


@pytest.mark.parametrize("signature", FUNCTIONS)
def test_ems_readonly_cannot_execute(tx, signature):
    assert _can(tx, "ems_readonly", signature) is False
    owner = tx.execute(
        "SELECT pg_get_userbyid(proowner) FROM pg_proc WHERE oid = %s::regprocedure", (signature,)
    ).fetchone()[0]
    assert owner == "ems_admin"


@pytest.mark.parametrize("signature", APP_FUNCTIONS)
def test_application_keeps_execute(tx, signature):
    assert _can(tx, "ems_app", signature) is True


def test_production_state_is_revoked_and_nothing_else_changes(tx):
    _production_state(tx)
    other_before = {
        s: sorted(a for a in _acl(tx, s) if not a.startswith("ems_readonly=")) for s in FUNCTIONS
    }
    bodies_before = tx.execute(
        "SELECT md5(string_agg(md5(prosrc) || prosecdef::text || coalesce(proconfig::text, ''), ',' ORDER BY oid))"
        " FROM pg_proc WHERE oid = ANY(%s::regprocedure[])",
        (list(FUNCTIONS),),
    ).fetchone()[0]

    _apply(tx)

    for signature in FUNCTIONS:
        assert _can(tx, "ems_readonly", signature) is False, signature
        assert sorted(_acl(tx, signature)) == other_before[signature], signature
    for signature in APP_FUNCTIONS:
        assert _can(tx, "ems_app", signature) is True, signature
    assert tx.execute(
        "SELECT md5(string_agg(md5(prosrc) || prosecdef::text || coalesce(proconfig::text, ''), ',' ORDER BY oid))"
        " FROM pg_proc WHERE oid = ANY(%s::regprocedure[])",
        (list(FUNCTIONS),),
    ).fetchone()[0] == bodies_before
    # Out of scope: left exactly as it was.
    assert _can(tx, "ems_readonly", UNRELATED) is True


def test_customer_api_grants_are_kept(tx):
    if not tx.execute("SELECT count(*) FROM pg_roles WHERE rolname = 'ems_customer_api'").fetchone()[0]:
        pytest.skip("ems_customer_api is staging/test only")
    before = {s: _can(tx, "ems_customer_api", s) for s in FUNCTIONS}
    _production_state(tx)
    _apply(tx)
    assert {s: _can(tx, "ems_customer_api", s) for s in FUNCTIONS} == before
    assert before["admin.get_portal_user_for_authentication(text)"] is True


def test_ems_readonly_cannot_call_after_the_migration(tx):
    _production_state(tx)
    _apply(tx)
    actor = tx.execute(
        "SELECT min(portal_user_id) FROM admin.portal_users WHERE is_active AND role_code = 'ADMIN'"
        " AND access_scope_mode = 'GLOBAL'"
    ).fetchone()[0]
    assert actor is not None
    tx.execute("SAVEPOINT s")
    tx.execute("SET LOCAL ROLE ems_readonly")
    for statement in (
        "SELECT admin.change_managed_portal_user_role(%s, %s, 'VIEWER')",
        "SELECT admin.reset_managed_portal_user_password(%s, %s, '$argon2id$placeholder')",
    ):
        with pytest.raises(psycopg.errors.InsufficientPrivilege):
            tx.execute(statement, (actor, actor))
        tx.execute("ROLLBACK TO SAVEPOINT s")
        tx.execute("SET LOCAL ROLE ems_readonly")
    with pytest.raises(psycopg.errors.InsufficientPrivilege):
        tx.execute("SELECT * FROM admin.get_portal_user_for_authentication('nobody')")
    tx.execute("ROLLBACK TO SAVEPOINT s")


def test_the_check_is_not_vacuous(tx):
    """Before the migration, production's grant really lets ems_readonly past
    the privilege check (the call then fails on the function's own rules)."""
    _production_state(tx)
    tx.execute("SAVEPOINT s")
    tx.execute("SET LOCAL ROLE ems_readonly")
    tx.execute("SELECT admin.portal_user_scope_contains_user(1, 1)")
    tx.execute("ROLLBACK TO SAVEPOINT s")


def test_postcondition_refuses_if_the_application_lost_a_grant(tx):
    tx.execute("REVOKE EXECUTE ON FUNCTION admin.list_manageable_portal_users(bigint) FROM ems_app")
    with pytest.raises(psycopg.errors.RaiseException, match="ems_app cannot execute"):
        _apply(tx)


def test_migration_reapplies_cleanly(tx):
    """Staging and test: no ems_readonly grant, so re-running it (the test
    database already holds 316) is a no-op."""
    acl_before = {s: sorted(_acl(tx, s)) for s in FUNCTIONS}
    _apply(tx)
    assert {s: sorted(_acl(tx, s)) for s in FUNCTIONS} == acl_before


def test_migration_only_revokes_from_ems_readonly():
    code = "\n".join(line for line in MIGRATION.read_text(encoding="utf-8").splitlines()
                     if not line.lstrip().startswith("--"))
    assert "GRANT " not in code
    assert code.count("REVOKE EXECUTE ON FUNCTION %s FROM ems_readonly") == 1
    assert "REVOKE" not in code.replace("REVOKE EXECUTE ON FUNCTION %s FROM ems_readonly", "")
    for signature in FUNCTIONS:
        assert f"'{signature}'" in code, signature


def test_manifest_registers_316_after_315_and_production_scoped():
    rows = list(csv.DictReader((REPO / "postgres" / "restructure_manifest.csv").read_text(encoding="utf-8").splitlines()))
    files = [r["source_file"] for r in rows if r["target_category"] == "migration"]
    index = files.index(MIGRATION.name)
    assert files[index - 1] == "315_portal_user_management_hardening.sql"
    assert files.count(MIGRATION.name) == 1
    scope = (REPO / "postgres" / "migration_environment_scope.csv").read_text(encoding="utf-8")
    assert "316_" not in scope and "315_" not in scope
