"""Migration 318: ems_readonly loses EXECUTE on the ten write-capable
SECURITY DEFINER routines outside schema admin (production inventory
2026-11-04), keeping its read-only access.

Staging and test grant ems_readonly none of them, so each test reproduces
production's grants inside a rolled-back transaction on the disposable
ems_test database (conftest.py) before applying 318.
"""
import csv
from pathlib import Path

import psycopg
import pytest

from tests.test_asset_energy_tier_read import CONNINFO

REPO = Path(__file__).resolve().parents[2]
MIGRATION = REPO / "postgres" / "migrations" / "318_ems_readonly_write_routines_revoke.sql"
MIGRATION_SQL = MIGRATION.read_text(encoding="utf-8")

TS2 = "timestamp with time zone,timestamp with time zone"
REFRESHES = (
    f"analytics.refresh_energy_consumption_1min({TS2})",
    f"analytics.refresh_energy_consumption_5min({TS2})",
    f"analytics.refresh_energy_consumption_15min({TS2})",
    f"analytics.refresh_energy_consumption_hourly({TS2})",
    f"analytics.refresh_energy_consumption_daily({TS2})",
    f"telemetry.refresh_environment_daily({TS2})",
)
INGEST = "telemetry.ingest_live_rtdata(text,jsonb,timestamp with time zone)"
TRIGGER_FUNCTIONS = (
    "config.ensure_asset_demand_policy_for_site()",
    "telemetry.capture_telegraf_mqtt_insert()",
    "telemetry.set_energy_measurement_asset_id()",
)
TARGETS = REFRESHES + (INGEST,) + TRIGGER_FUNCTIONS
# Read-only access ems_readonly must keep.
STABLE_FUNCTION = "analytics.get_analytics_energy_resolution_floors()"
READ_RELATIONS = ("analytics.v_gateway_connectivity", "analytics.pipeline_reconciliation_log",
                  "telemetry.v_environment_measurements_route", "config.device_point_configuration",
                  "admin.v_sites")
# A write-capable routine NOT in 318's reviewed list (used to prove the precheck).
UNREVIEWED = "analytics.reconcile_demand_intervals(integer,jsonb)"
SCHEMAS = ("analytics", "config", "metadata", "telemetry", "admin")


@pytest.fixture
def tx():
    with psycopg.connect(CONNINFO) as c:
        yield c
        c.rollback()


def _can(tx, role, signature):
    return tx.execute("SELECT has_function_privilege(%s, %s::regprocedure, 'EXECUTE')",
                      (role, signature)).fetchone()[0]


def _production_state(tx):
    tx.execute(f"GRANT USAGE ON SCHEMA {', '.join(SCHEMAS)} TO ems_readonly")
    for signature in TARGETS + (STABLE_FUNCTION,):
        tx.execute(f"GRANT EXECUTE ON FUNCTION {signature} TO ems_readonly")
    for relation in READ_RELATIONS:
        tx.execute(f"GRANT SELECT ON {relation} TO ems_readonly")
    assert all(_can(tx, "ems_readonly", s) for s in TARGETS)


def _apply(tx, sql=MIGRATION_SQL):
    tx.execute(sql)


def _snapshot(tx):
    routines = tx.execute(
        "SELECT p.oid::regprocedure::text,"
        "       ARRAY(SELECT a::text FROM unnest(coalesce(p.proacl, acldefault('f', p.proowner))) a"
        "             WHERE NOT (p.oid::regprocedure::text = ANY(%s) AND a::text LIKE 'ems_readonly=%%') ORDER BY 1),"
        "       md5(p.prosrc), p.prosecdef, p.provolatile"
        " FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace"
        " WHERE n.nspname NOT LIKE 'pg\\_%%' AND n.nspname <> 'information_schema'"
        "   AND n.nspname NOT LIKE '\\_timescaledb%%' AND n.nspname NOT LIKE 'timescaledb%%'",
        (list(TARGETS),),
    ).fetchall()
    relations = tx.execute(
        "SELECT c.oid::regclass::text, c.relacl::text,"
        "       ARRAY(SELECT a.attname || ':' || coalesce(a.attacl::text, '') FROM pg_attribute a"
        "             WHERE a.attrelid = c.oid AND a.attnum > 0 AND NOT a.attisdropped ORDER BY a.attnum)"
        " FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace"
        " WHERE c.relkind IN ('r','p','v','m','f','S')"
        "   AND n.nspname NOT LIKE 'pg\\_%%' AND n.nspname NOT LIKE '\\_timescaledb%%'"
        "   AND n.nspname NOT LIKE 'timescaledb%%' AND n.nspname <> 'information_schema'"
    ).fetchall()
    schemas = tx.execute("SELECT nspname, nspacl::text FROM pg_namespace").fetchall()
    return {r[0]: r[1:] for r in routines}, {r[0]: r[1:] for r in relations}, dict(schemas)


def _as_readonly(tx, statement, params=(), refused=True):
    tx.execute("SAVEPOINT probe")
    tx.execute("SET LOCAL ROLE ems_readonly")
    try:
        if refused:
            with pytest.raises(psycopg.errors.InsufficientPrivilege):
                tx.execute(statement, params)
        else:
            tx.execute(statement, params).fetchall()
    finally:
        tx.execute("ROLLBACK TO SAVEPOINT probe")


# --------------------------------------------------------------------------- revoked


@pytest.mark.parametrize("signature", TARGETS)
def test_ems_readonly_loses_execute(tx, signature):
    _production_state(tx)
    _apply(tx)
    assert _can(tx, "ems_readonly", signature) is False
    assert tx.execute(
        "SELECT count(*) FROM aclexplode((SELECT proacl FROM pg_proc WHERE oid = %s::regprocedure)) a"
        " WHERE a.grantee = 'ems_readonly'::regrole", (signature,)).fetchone()[0] == 0


@pytest.mark.parametrize("signature", REFRESHES)
def test_refresh_calls_are_refused(tx, signature):
    _production_state(tx)
    _apply(tx)
    name = signature.split("(")[0]
    _as_readonly(tx, f"SELECT {name}(now() - interval '1 minute', now())")


def test_live_ingest_call_is_refused(tx):
    _production_state(tx)
    _apply(tx)
    _as_readonly(tx, "SELECT telemetry.ingest_live_rtdata('probe/topic', '{}'::jsonb, now())")


# --------------------------------------------------------------------------- retained


def test_every_other_privilege_is_unchanged(tx):
    _production_state(tx)
    before = _snapshot(tx)
    _apply(tx)
    assert _snapshot(tx) == before


def test_ems_readonly_keeps_read_only_access(tx):
    _production_state(tx)
    _apply(tx)
    assert _can(tx, "ems_readonly", STABLE_FUNCTION) is True
    _as_readonly(tx, f"SELECT * FROM {STABLE_FUNCTION.replace('()', '()')}", refused=False)
    for relation in READ_RELATIONS:
        assert tx.execute("SELECT has_table_privilege('ems_readonly', %s, 'SELECT')", (relation,)).fetchone()[0], relation
        _as_readonly(tx, f"SELECT count(*) FROM {relation}", refused=False)


def test_live_telemetry_keeps_its_ingest_path(tx):
    _production_state(tx)
    _apply(tx)
    assert _can(tx, "ems_app", INGEST) is True


def test_trigger_still_fires_for_a_role_without_execute(tx):
    """config.ensure_asset_demand_policy_for_site() fires on metadata.sites
    inserts by a role that has no EXECUTE on it (triggers are not
    EXECUTE-checked), so revoking it cannot break an inserting role."""
    _production_state(tx)
    _apply(tx)
    tx.execute("CREATE ROLE mig318_probe NOLOGIN")
    tx.execute("GRANT USAGE ON SCHEMA metadata, config TO mig318_probe")
    org = tx.execute(
        "INSERT INTO metadata.organizations (name, code) VALUES ('Mig 318 Org', 'MIG318_ORG') RETURNING id"
    ).fetchone()[0]
    tx.execute("GRANT INSERT, SELECT ON metadata.sites TO mig318_probe")
    assert _can(tx, "mig318_probe", "config.ensure_asset_demand_policy_for_site()") is False
    tx.execute("SET LOCAL ROLE mig318_probe")
    tx.execute("INSERT INTO metadata.sites (organization_id, name, code) VALUES (%s, 'Mig 318 Site', 'MIG318_SITE')",
               (org,))
    tx.execute("RESET ROLE")
    assert tx.execute("SELECT count(*) FROM metadata.sites WHERE organization_id = %s", (org,)).fetchone()[0] == 1


def test_staging_and_test_state_is_a_noop(tx):
    before = _snapshot(tx)
    _apply(tx)
    assert _snapshot(tx) == before


def test_reapplying_is_a_noop(tx):
    _production_state(tx)
    _apply(tx)
    after_first = _snapshot(tx)
    tx.execute("DROP TABLE IF EXISTS migration_318_routines, migration_318_routines_before,"
               " migration_318_relations_before, migration_318_schemas_before")
    _apply(tx)
    assert _snapshot(tx) == after_first


# --------------------------------------------------------------------------- the checks are real


def test_precheck_refuses_an_unreviewed_write_routine(tx):
    _production_state(tx)
    tx.execute(f"GRANT EXECUTE ON PROCEDURE {UNREVIEWED} TO ems_readonly")
    with pytest.raises(psycopg.errors.RaiseException, match="unreviewed write-capable"):
        _apply(tx)


def test_precheck_refuses_a_role_membership(tx):
    # An inherited grant would escape the explicit-ACL checks: stop instead.
    _production_state(tx)
    tx.execute("CREATE ROLE migration_318_inherited NOLOGIN")
    tx.execute(f"GRANT EXECUTE ON PROCEDURE {UNREVIEWED} TO migration_318_inherited")
    tx.execute("GRANT migration_318_inherited TO ems_readonly")
    with pytest.raises(psycopg.errors.RaiseException, match="member of role"):
        _apply(tx)


def test_precheck_requires_317(tx):
    tx.execute("GRANT USAGE ON SCHEMA admin TO ems_readonly")
    tx.execute("GRANT EXECUTE ON FUNCTION admin.list_accessible_sites(bigint) TO ems_readonly")
    with pytest.raises(psycopg.errors.RaiseException, match="317 is not applied"):
        _apply(tx)


def test_precheck_refuses_a_target_that_is_no_longer_security_definer(tx):
    tx.execute(f"ALTER FUNCTION analytics.refresh_energy_consumption_1min({TS2}) SECURITY INVOKER")
    with pytest.raises(psycopg.errors.RaiseException, match="not SECURITY DEFINER"):
        _apply(tx)


def test_mutant_without_the_revoke_is_caught(tx):
    _production_state(tx)
    mutant = MIGRATION_SQL.replace(
        "EXECUTE format('REVOKE EXECUTE ON FUNCTION %s FROM ems_readonly', to_regprocedure(v_signature));", "NULL;")
    assert mutant != MIGRATION_SQL
    with pytest.raises(psycopg.errors.RaiseException, match="ems_readonly still executes"):
        _apply(tx, mutant)


def test_mutant_revoking_a_read_function_is_caught(tx):
    _production_state(tx)
    revoke = "        EXECUTE format('REVOKE EXECUTE ON FUNCTION %s FROM ems_readonly', to_regprocedure(v_signature));"
    mutant = MIGRATION_SQL.replace(
        revoke, revoke + f"\n        REVOKE EXECUTE ON FUNCTION {STABLE_FUNCTION} FROM ems_readonly;")
    assert mutant != MIGRATION_SQL
    with pytest.raises(psycopg.errors.RaiseException, match="another grant"):
        _apply(tx, mutant)


def test_mutant_touching_ems_app_is_caught(tx):
    _production_state(tx)
    mutant = MIGRATION_SQL.replace(
        "        EXECUTE format('REVOKE EXECUTE ON FUNCTION %s FROM ems_readonly', to_regprocedure(v_signature));",
        "        EXECUTE format('REVOKE EXECUTE ON FUNCTION %s FROM ems_readonly', to_regprocedure(v_signature));\n"
        "        EXECUTE format('REVOKE EXECUTE ON FUNCTION %s FROM ems_app', to_regprocedure(v_signature));")
    assert mutant != MIGRATION_SQL
    with pytest.raises(psycopg.errors.RaiseException, match="another grant"):
        _apply(tx, mutant)


# --------------------------------------------------------------------------- static / registry


def test_migration_only_revokes_from_ems_readonly():
    code = "\n".join(line for line in MIGRATION_SQL.splitlines() if not line.lstrip().startswith("--"))
    assert "GRANT " not in code
    assert [line.strip() for line in code.splitlines() if "REVOKE" in line] == [
        "EXECUTE format('REVOKE EXECUTE ON FUNCTION %s FROM ems_readonly', to_regprocedure(v_signature));"]
    for signature in TARGETS:
        assert f"('{signature}')" in code, signature


def test_manifest_registers_318_after_317_and_production_scoped():
    rows = list(csv.DictReader((REPO / "postgres" / "restructure_manifest.csv").read_text(encoding="utf-8").splitlines()))
    files = [r["source_file"] for r in rows if r["target_category"] == "migration"]
    index = files.index(MIGRATION.name)
    assert files[index - 1] == "317_ems_readonly_admin_least_privilege.sql"
    assert files.count(MIGRATION.name) == 1
    assert "318_" not in (REPO / "postgres" / "migration_environment_scope.csv").read_text(encoding="utf-8")
