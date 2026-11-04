"""Migration 317: ems_readonly least privilege on schema admin.

ems_readonly is the operators' read-only investigation login. On production
(read-only inventory 2026-11-04) it still holds, after 316, EXECUTE on 87
admin functions (44 SECURITY DEFINER writes) and SELECT on every admin
relation including admin.portal_users.password_hash. Staging and the test
database have none of that, so every test below first reproduces
production's grants inside a rolled-back transaction on the disposable
ems_test database (conftest.py), then applies 317 and checks both what is
revoked and what must be retained.
"""
import csv
from pathlib import Path

import psycopg
import pytest

from tests.test_asset_energy_tier_read import CONNINFO

REPO = Path(__file__).resolve().parents[2]
MIGRATION = REPO / "postgres" / "migrations" / "317_ems_readonly_admin_least_privilege.sql"
MIGRATION_SQL = MIGRATION.read_text(encoding="utf-8")

# Production, 2026-11-04: admin functions ems_readonly can EXECUTE after 316.
PRODUCTION_ADMIN_FUNCTIONS = (
    "apply_grafana_reconciliation_mapping", "assign_device_to_asset", "assign_site_energy_meter_role",
    "commission_asset", "commission_device", "commission_gateway",
    "create_asset", "create_building", "create_device",
    "create_floor", "create_gateway", "create_organization",
    "create_organization_workspace", "create_site", "create_site_workspace",
    "create_space", "device_point_actor_can_access_site", "device_point_actor_has_permission",
    "device_point_actor_username", "get_asset_workspace", "get_device_workspace",
    "get_gateway_workspace", "get_grafana_provisioning", "get_grafana_reconciliation_context",
    "get_location_workspace", "get_onboarding_draft", "get_organization_workspace",
    "get_portal_asset_live_state", "get_site_demand_policy", "get_site_demand_readiness",
    "get_site_telemetry_capture_interval", "get_site_workspace", "get_submitted_onboarding_result",
    "lifecycle_dependencies", "list_accessible_asset_device_relationships", "list_accessible_asset_meter_coverage",
    "list_accessible_assets", "list_accessible_audit_events", "list_accessible_commissioning_readiness",
    "list_accessible_device_telemetry_availability", "list_accessible_devices", "list_accessible_gateways",
    "list_accessible_physical_locations", "list_accessible_reconciliation_queue", "list_accessible_site_energy_meter_roles",
    "list_accessible_sites", "list_device_point_configuration", "list_grafana_provisioning_status",
    "list_live_asset_ids_for_device", "list_manageable_sites", "list_site_asset_types",
    "log_onboarding_event", "mark_grafana_provisioning_complete", "mark_grafana_provisioning_failed",
    "mark_grafana_provisioning_pending", "onboard_energy_asset", "onboard_energy_asset_legacy_upsert",
    "portal_user_can_access_asset", "portal_user_can_access_site", "portal_user_has_permission",
    "recommend_available_identifier", "redact_audit_json", "remove_asset_device_relationship",
    "replace_asset_primary_meter", "reset_device_point_configuration", "save_onboarding_draft_step",
    "set_device_operational_policy", "set_site_demand_policy", "set_site_sub_sector",
    "set_site_telemetry_capture_interval", "submit_onboarding_draft", "transition_entity_lifecycle",
    "update_asset", "update_asset_device_relationship_metadata", "update_asset_workspace",
    "update_device_lifecycle", "update_device_point_configuration", "update_device_workspace",
    "update_gateway_lifecycle", "update_gateway_workspace", "update_location_workspace",
    "update_organization_workspace", "update_site_workspace", "validate_lifecycle_transition",
    "validate_onboarding_asset_relationship", "validate_onboarding_field", "write_audit_event",
)
PUBLIC_ADMIN_FUNCTION = "list_accessible_asset_device_relationships"   # PUBLIC-executable; app relies on it (308)
# Non-admin volatile SECURITY DEFINER routines ems_readonly can EXECUTE on production: out of 317's scope.
OUT_OF_SCOPE_ROUTINE = "analytics.refresh_energy_consumption_15min(timestamp with time zone,timestamp with time zone)"
SCHEMAS = ("admin", "analytics", "config", "metadata", "public", "telemetry")


@pytest.fixture
def tx():
    with psycopg.connect(CONNINFO) as c:
        yield c
        c.rollback()


def _admin_routines(tx, names=None):
    rows = tx.execute(
        "SELECT p.oid::regprocedure::text, p.proname FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace"
        " WHERE n.nspname = 'admin' ORDER BY 1"
    ).fetchall()
    return [sig for sig, name in rows if names is None or name in names]


def _production_state(tx):
    """ems_readonly's production grants as of 2026-11-04 (after 316)."""
    tx.execute(f"GRANT USAGE ON SCHEMA {', '.join(SCHEMAS)} TO ems_readonly")
    routines = _admin_routines(tx, set(PRODUCTION_ADMIN_FUNCTIONS))
    assert len(routines) == len(PRODUCTION_ADMIN_FUNCTIONS)
    for signature in routines:
        tx.execute(f"GRANT EXECUTE ON FUNCTION {signature} TO ems_readonly")
    tx.execute("GRANT SELECT ON ALL TABLES IN SCHEMA admin TO ems_readonly")
    tx.execute("GRANT SELECT ON SEQUENCE admin.portal_users_portal_user_id_seq TO ems_readonly")
    tx.execute(f"GRANT EXECUTE ON FUNCTION {OUT_OF_SCOPE_ROUTINE} TO ems_readonly")
    return routines


def _apply(tx, sql=MIGRATION_SQL):
    tx.execute(sql)


def _readonly_executable_admin(tx):
    return {sig for sig in _admin_routines(tx)
            if tx.execute("SELECT has_function_privilege('ems_readonly', %s::regprocedure, 'EXECUTE')", (sig,)).fetchone()[0]}


def _relation_snapshot(tx, role):
    """SELECT privilege of role on every non-system relation except admin.portal_users."""
    return dict(tx.execute(
        "SELECT c.oid::regclass::text, has_table_privilege(%s, c.oid, 'SELECT')"
        " FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace"
        " WHERE c.relkind IN ('r','p','v','m','f')"
        "   AND n.nspname NOT LIKE 'pg\\_%%' AND n.nspname NOT LIKE '\\_timescaledb%%'"
        "   AND n.nspname NOT LIKE 'timescaledb%%' AND n.nspname <> 'information_schema'"
        "   AND c.oid <> 'admin.portal_users'::regclass",
        (role,),
    ).fetchall())


def _acl_snapshot(tx):
    """Every ACL in the database except ems_readonly's entries on admin routines and portal_users."""
    routines = tx.execute(
        "SELECT p.oid::regprocedure::text,"
        "       ARRAY(SELECT a::text FROM unnest(coalesce(p.proacl, acldefault('f', p.proowner))) a"
        "             WHERE n.nspname <> 'admin' OR a::text NOT LIKE 'ems_readonly=%%' ORDER BY 1)"
        " FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace"
        " WHERE n.nspname NOT LIKE 'pg\\_%%' AND n.nspname <> 'information_schema'"
        "   AND n.nspname NOT LIKE '\\_timescaledb%%' AND n.nspname NOT LIKE 'timescaledb%%'"
    ).fetchall()
    relations = tx.execute(
        "SELECT c.oid::regclass::text, c.relacl::text FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace"
        " WHERE c.relkind IN ('r','p','v','m','f','S')"
        "   AND n.nspname NOT LIKE 'pg\\_%%' AND n.nspname NOT LIKE '\\_timescaledb%%'"
        "   AND n.nspname NOT LIKE 'timescaledb%%' AND n.nspname <> 'information_schema'"
        "   AND c.oid NOT IN ('admin.portal_users'::regclass, 'admin.portal_users_portal_user_id_seq'::regclass)"
    ).fetchall()
    schemas = tx.execute("SELECT nspname, nspacl::text FROM pg_namespace").fetchall()
    return dict(routines), dict(relations), dict(schemas)


def _refused(tx, statement, params=()):
    tx.execute("SAVEPOINT probe")
    tx.execute("SET LOCAL ROLE ems_readonly")
    try:
        with pytest.raises(psycopg.errors.InsufficientPrivilege):
            tx.execute(statement, params)
    finally:
        tx.execute("ROLLBACK TO SAVEPOINT probe")


def _allowed(tx, statement, params=()):
    tx.execute("SAVEPOINT probe")
    tx.execute("SET LOCAL ROLE ems_readonly")
    try:
        tx.execute(statement, params).fetchall()
    finally:
        tx.execute("ROLLBACK TO SAVEPOINT probe")


# --------------------------------------------------------------------------- revoked


def test_the_production_state_is_reproduced(tx):
    routines = _production_state(tx)
    assert len(routines) == 87
    assert _readonly_executable_admin(tx) >= set(routines)
    assert tx.execute(
        "SELECT has_column_privilege('ems_readonly', 'admin.portal_users', 'password_hash', 'SELECT')"
    ).fetchone()[0] is True
    _allowed(tx, "SELECT count(password_hash) FROM admin.portal_users")


def test_ems_readonly_executes_no_admin_routine_beyond_public(tx):
    _production_state(tx)
    _apply(tx)
    remaining = _readonly_executable_admin(tx)
    public = {sig for sig in remaining
              if tx.execute("SELECT has_function_privilege('public', %s::regprocedure, 'EXECUTE')", (sig,)).fetchone()[0]}
    assert remaining == public
    assert {sig.split("(")[0] for sig in public} == {f"admin.{PUBLIC_ADMIN_FUNCTION}"}
    explicit = tx.execute(
        "SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace,"
        " LATERAL aclexplode(p.proacl) a WHERE n.nspname = 'admin' AND a.grantee = 'ems_readonly'::regrole"
    ).fetchone()[0]
    assert explicit == 0


@pytest.mark.parametrize("name", ["create_site", "commission_device", "write_audit_event",
                                  "update_organization_workspace", "mark_grafana_provisioning_complete",
                                  "list_accessible_sites", "get_site_workspace", "portal_user_has_permission"])
def test_ems_readonly_calls_are_refused(tx, name):
    _production_state(tx)
    _apply(tx)
    signature = _admin_routines(tx, {name})[0]
    arg_count = tx.execute("SELECT pronargs FROM pg_proc WHERE oid = %s::regprocedure", (signature,)).fetchone()[0]
    _refused(tx, f"SELECT admin.{name}({', '.join(['NULL'] * arg_count)})")


def test_portal_users_is_not_readable_at_all(tx):
    _production_state(tx)
    _apply(tx)
    for column in ("password_hash", "email", "username", "portal_user_id"):
        assert tx.execute(
            "SELECT has_column_privilege('ems_readonly', 'admin.portal_users', %s, 'SELECT')", (column,)
        ).fetchone()[0] is False, column
    assert tx.execute(
        "SELECT has_table_privilege('ems_readonly', 'admin.portal_users',"
        " 'SELECT, INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER')"
    ).fetchone()[0] is False
    assert tx.execute(
        "SELECT has_sequence_privilege('ems_readonly', 'admin.portal_users_portal_user_id_seq', 'USAGE, SELECT, UPDATE')"
    ).fetchone()[0] is False
    _refused(tx, "SELECT password_hash FROM admin.portal_users")
    _refused(tx, "SELECT email FROM admin.portal_users")
    _refused(tx, "SELECT count(*) FROM admin.portal_users")


def test_a_column_level_grant_on_portal_users_is_also_removed(tx):
    _production_state(tx)
    tx.execute("REVOKE SELECT ON admin.portal_users FROM ems_readonly")
    tx.execute("GRANT SELECT (password_hash, email) ON admin.portal_users TO ems_readonly")
    _apply(tx)
    assert tx.execute(
        "SELECT has_any_column_privilege('ems_readonly', 'admin.portal_users', 'SELECT')"
    ).fetchone()[0] is False


# --------------------------------------------------------------------------- retained


def test_every_other_privilege_is_unchanged(tx):
    _production_state(tx)
    before = _acl_snapshot(tx)
    _apply(tx)
    assert _acl_snapshot(tx) == before


def test_ems_readonly_keeps_its_read_access_elsewhere(tx):
    _production_state(tx)
    before = _relation_snapshot(tx, "ems_readonly")
    _apply(tx)
    after = _relation_snapshot(tx, "ems_readonly")
    assert after == before
    # Analytics / telemetry objects granted to ems_readonly by migrations, and other admin views.
    for relation in ("analytics.v_gateway_connectivity", "analytics.pipeline_reconciliation_log",
                     "telemetry.v_environment_measurements_route", "config.device_point_configuration", "admin.v_sites", "admin.portal_user_audit",
                     "admin.schema_migrations"):
        assert after[relation] is True, relation
    _allowed(tx, "SELECT count(*) FROM analytics.v_gateway_connectivity")
    _allowed(tx, "SELECT count(*) FROM admin.v_sites")
    _allowed(tx, "SELECT count(*) FROM admin.schema_migrations")


@pytest.mark.parametrize("role", ["ems_app", "ems_customer_api", "grafana_reader", "telegraf_writer", "ems_investigator"])
def test_other_roles_keep_every_privilege(tx, role):
    if not tx.execute("SELECT count(*) FROM pg_roles WHERE rolname = %s", (role,)).fetchone()[0]:
        pytest.skip(f"{role} does not exist here")
    _production_state(tx)
    relations_before = _relation_snapshot(tx, role)
    portal_users_before = tx.execute(
        "SELECT has_table_privilege(%s, 'admin.portal_users', 'SELECT')", (role,)).fetchone()[0]
    routines_before = {sig: tx.execute("SELECT has_function_privilege(%s, %s::regprocedure, 'EXECUTE')",
                                       (role, sig)).fetchone()[0] for sig in _admin_routines(tx)}
    _apply(tx)
    assert _relation_snapshot(tx, role) == relations_before
    assert tx.execute("SELECT has_table_privilege(%s, 'admin.portal_users', 'SELECT')",
                      (role,)).fetchone()[0] == portal_users_before
    assert {sig: tx.execute("SELECT has_function_privilege(%s, %s::regprocedure, 'EXECUTE')",
                            (role, sig)).fetchone()[0] for sig in _admin_routines(tx)} == routines_before


def test_the_application_keeps_its_portal_user_functions(tx):
    _production_state(tx)
    _apply(tx)
    for signature in (
        "admin.get_portal_user_for_authentication(text)",
        "admin.list_manageable_portal_users(bigint)",
        "admin.reset_managed_portal_user_password(bigint,bigint,text)",
        "admin.list_accessible_sites(bigint)",
        "admin.create_site(bigint,uuid,text,text,text,text)",
    ):
        assert tx.execute("SELECT has_function_privilege('ems_app', %s::regprocedure, 'EXECUTE')",
                          (signature,)).fetchone()[0] is True, signature


def test_routines_outside_admin_are_out_of_scope(tx):
    _production_state(tx)
    _apply(tx)
    assert tx.execute(f"SELECT has_function_privilege('ems_readonly', '{OUT_OF_SCOPE_ROUTINE}', 'EXECUTE')"
                      ).fetchone()[0] is True


def test_reapplying_is_a_noop(tx):
    _production_state(tx)
    _apply(tx)
    after_first = (_acl_snapshot(tx), _readonly_executable_admin(tx))
    tx.execute("DROP TABLE IF EXISTS migration_317_routines_before, migration_317_relations_before,"
               " migration_317_schemas_before")
    _apply(tx)
    assert (_acl_snapshot(tx), _readonly_executable_admin(tx)) == after_first


def test_staging_and_test_state_is_a_noop(tx):
    before = (_acl_snapshot(tx), _readonly_executable_admin(tx))
    _apply(tx)
    assert (_acl_snapshot(tx), _readonly_executable_admin(tx)) == before


# --------------------------------------------------------------------------- the checks are real


def test_precondition_requires_316(tx):
    tx.execute("GRANT USAGE ON SCHEMA admin TO ems_readonly")
    tx.execute("GRANT EXECUTE ON FUNCTION admin.reset_managed_portal_user_password(bigint,bigint,text) TO ems_readonly")
    with pytest.raises(psycopg.errors.RaiseException, match="316 is not applied"):
        _apply(tx)


def test_mutant_without_the_routine_revoke_is_caught(tx):
    _production_state(tx)
    mutant = MIGRATION_SQL.replace("EXECUTE format('REVOKE EXECUTE ON ROUTINE %s FROM ems_readonly', v_routine);", "NULL;")
    assert mutant != MIGRATION_SQL
    with pytest.raises(psycopg.errors.RaiseException, match="ems_readonly still executes"):
        _apply(tx, mutant)


def test_mutant_without_the_portal_users_revoke_is_caught(tx):
    _production_state(tx)
    mutant = MIGRATION_SQL.replace("REVOKE ALL ON TABLE admin.portal_users FROM ems_readonly;", "")
    assert mutant != MIGRATION_SQL
    with pytest.raises(psycopg.errors.RaiseException, match="can still access admin.portal_users"):
        _apply(tx, mutant)


def test_mutant_with_collateral_damage_is_caught(tx):
    _production_state(tx)
    mutant = MIGRATION_SQL.replace(
        "REVOKE ALL ON TABLE admin.portal_users FROM ems_readonly;",
        "REVOKE ALL ON TABLE admin.portal_users FROM ems_readonly;\n    REVOKE SELECT ON admin.v_sites FROM ems_readonly;")
    with pytest.raises(psycopg.errors.RaiseException, match="table / column privileges changed"):
        _apply(tx, mutant)


def test_mutant_touching_another_role_is_caught(tx):
    _production_state(tx)
    mutant = MIGRATION_SQL.replace(
        "REVOKE ALL ON TABLE admin.portal_users FROM ems_readonly;",
        "REVOKE ALL ON TABLE admin.portal_users FROM ems_readonly;\n"
        "    REVOKE EXECUTE ON FUNCTION admin.list_accessible_sites(bigint) FROM ems_app;")
    with pytest.raises(psycopg.errors.RaiseException, match="another grant"):
        _apply(tx, mutant)


# --------------------------------------------------------------------------- static / registry


def test_migration_only_revokes_from_ems_readonly():
    code = "\n".join(line for line in MIGRATION_SQL.splitlines() if not line.lstrip().startswith("--"))
    assert "GRANT " not in code
    revokes = [line.strip() for line in code.splitlines() if "REVOKE" in line]
    assert revokes == [
        "EXECUTE format('REVOKE EXECUTE ON ROUTINE %s FROM ems_readonly', v_routine);",
        "REVOKE ALL ON TABLE admin.portal_users FROM ems_readonly;",
        "REVOKE ALL ON SEQUENCE admin.portal_users_portal_user_id_seq FROM ems_readonly;",
    ]


def test_manifest_registers_317_after_316_and_production_scoped():
    rows = list(csv.DictReader((REPO / "postgres" / "restructure_manifest.csv").read_text(encoding="utf-8").splitlines()))
    files = [r["source_file"] for r in rows if r["target_category"] == "migration"]
    index = files.index(MIGRATION.name)
    assert files[index - 1] == "316_portal_user_functions_revoke_ems_readonly.sql"
    assert files.count(MIGRATION.name) == 1
    scope = (REPO / "postgres" / "migration_environment_scope.csv").read_text(encoding="utf-8")
    assert "317_" not in scope
