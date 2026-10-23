"""Migration 308 (parity audit 2026-10-23, H10): PUBLIC loses EXECUTE on six
SECURITY DEFINER routines -- four energy / environment tier job procedures
and two trigger functions -- so an arbitrary login can no longer run them as
ems_admin. Jobs run as their owner and trigger functions are not EXECUTE-
checked when a trigger fires, so callers are unaffected.

Behaviour is checked with a throwaway role created inside a rolled-back
transaction on the disposable ems_test database (conftest.py).
"""
from pathlib import Path

import psycopg
import pytest

from tests.test_asset_energy_tier_read import CONNINFO

REPO = Path(__file__).resolve().parents[2]
MIGRATION = REPO / "postgres" / "migrations" / "308_security_definer_job_routines_revoke_public.sql"

JOB_PROCEDURES = (
    "analytics.run_energy_consumption_15min_job(integer,jsonb)",
    "analytics.run_energy_consumption_hourly_job(integer,jsonb)",
    "analytics.run_energy_consumption_daily_job(integer,jsonb)",
    "telemetry.run_environment_daily_job(integer,jsonb)",
)
TRIGGER_FUNCTIONS = (
    "config.ensure_asset_demand_policy_for_site()",
    "telemetry.set_energy_measurement_asset_id()",
)
ROUTINES = JOB_PROCEDURES + TRIGGER_FUNCTIONS
PROBE = "mig308_probe"


@pytest.fixture
def tx():
    with psycopg.connect(CONNINFO) as c:
        yield c
        c.rollback()


@pytest.fixture
def probe(tx):
    """A login-less role with schema USAGE only, standing in for any database user."""
    tx.execute(f"CREATE ROLE {PROBE} NOLOGIN")
    tx.execute(f"GRANT USAGE ON SCHEMA analytics, telemetry, config, metadata TO {PROBE}")
    return tx


@pytest.mark.parametrize("routine", ROUTINES)
def test_public_cannot_execute(tx, routine):
    oid = tx.execute("SELECT %s::regprocedure::oid", (routine,)).fetchone()[0]
    assert tx.execute("SELECT has_function_privilege('public', %s, 'EXECUTE')", (oid,)).fetchone()[0] is False
    secdef, owner = tx.execute(
        "SELECT prosecdef, pg_get_userbyid(proowner) FROM pg_proc WHERE oid = %s", (oid,)
    ).fetchone()
    assert secdef is True and owner == "ems_admin"
    assert tx.execute("SELECT has_function_privilege('ems_admin', %s, 'EXECUTE')", (oid,)).fetchone()[0] is True


@pytest.mark.parametrize("routine", JOB_PROCEDURES)
def test_other_role_cannot_call_job(probe, routine):
    name = routine.split("(")[0]
    probe.execute(f"SET LOCAL ROLE {PROBE}")
    with pytest.raises(psycopg.errors.InsufficientPrivilege):
        probe.execute(f"CALL {name}(0, '{{}}'::jsonb)")


def test_trigger_still_fires_for_a_role_without_execute(probe):
    """metadata.sites' SECURITY DEFINER trigger runs for an inserting role that
    has no EXECUTE on the trigger function."""
    org = probe.execute(
        "INSERT INTO metadata.organizations (name, code) VALUES ('Mig 308 Org', 'MIG308_ORG') RETURNING id"
    ).fetchone()[0]
    probe.execute(f"GRANT INSERT, SELECT ON metadata.sites TO {PROBE}")
    probe.execute(f"SET LOCAL ROLE {PROBE}")
    probe.execute(
        "INSERT INTO metadata.sites (organization_id, name, code) VALUES (%s, 'Mig 308 Site', 'MIG308_SITE')", (org,)
    )
    probe.execute("RESET ROLE")
    assert probe.execute(
        "SELECT count(*) FROM metadata.sites WHERE organization_id = %s", (org,)
    ).fetchone()[0] == 1


def test_mutation_public_grant_is_detected(tx):
    """The check above is not vacuous: re-granting PUBLIC flips it."""
    oid = tx.execute("SELECT %s::regprocedure::oid", (JOB_PROCEDURES[0],)).fetchone()[0]
    tx.execute(f"GRANT EXECUTE ON PROCEDURE {JOB_PROCEDURES[0]} TO PUBLIC")
    assert tx.execute("SELECT has_function_privilege('public', %s, 'EXECUTE')", (oid,)).fetchone()[0] is True


def test_migration_reapplies_cleanly(tx):
    """Staging already had PUBLIC removed; re-running is a no-op that keeps
    every named grant (its postcondition raises otherwise)."""
    tx.execute(MIGRATION.read_text(encoding="utf-8"))


def test_migration_reapplies_from_default_acl(tx):
    """Production state: default ACL plus an extra named grant (ems_readonly)."""
    for routine in ROUTINES:
        kind = "PROCEDURE" if routine in JOB_PROCEDURES else "FUNCTION"
        tx.execute(f"GRANT EXECUTE ON {kind} {routine} TO PUBLIC, ems_readonly")
    tx.execute(MIGRATION.read_text(encoding="utf-8"))
    for routine in ROUTINES:
        oid = tx.execute("SELECT %s::regprocedure::oid", (routine,)).fetchone()[0]
        assert tx.execute("SELECT has_function_privilege('public', %s, 'EXECUTE')", (oid,)).fetchone()[0] is False
        assert tx.execute("SELECT has_function_privilege('ems_readonly', %s, 'EXECUTE')", (oid,)).fetchone()[0] is True


def test_scope_excludes_routines_the_app_relies_on():
    sql = MIGRATION.read_text(encoding="utf-8")
    revokes = [line for line in sql.splitlines() if line.startswith("REVOKE ")]
    assert len(revokes) == 6
    assert not any("list_accessible_asset_device_relationships" in r or "resolve_primary_asset_id" in r for r in revokes)
    assert "GRANT " not in "\n".join(line for line in sql.splitlines() if not line.startswith("--"))


def test_manifest_registers_308_after_307():
    import csv

    rows = list(csv.DictReader((REPO / "postgres" / "restructure_manifest.csv").read_text(encoding="utf-8").splitlines()))
    files = [r["source_file"] for r in rows if r["target_category"] == "migration"]
    assert files[-1] == MIGRATION.name
    assert files[-2] == "307_energy_consumption_views_total_register_semantics.sql"
