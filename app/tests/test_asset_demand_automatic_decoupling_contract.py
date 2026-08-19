from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
MIGRATION = ROOT / 'postgres/migrations/017_asset_demand_automatic_decoupling.sql'
DDL = ROOT / 'postgres/ddl/136_asset_demand_automatic_decoupling.sql'


def test_017_migration_and_canonical_mirror_match():
    assert MIGRATION.exists()
    assert DDL.exists()
    assert MIGRATION.read_text() == DDL.read_text()


def test_asset_demand_is_automatic_and_site_demand_remains_opt_in():
    sql = MIGRATION.read_text()
    assert "policy_scope IN ('SITE','ASSET')" in sql
    assert "NEW.policy_scope = 'ASSET'" in sql
    assert "NEW.is_enabled := TRUE" in sql
    assert "NEW.demand_interval_seconds := 900" in sql
    assert "NEW.demand_basis := 'ACTIVE_POWER_KW'" in sql
    assert "ad.relationship_type = 'PRIMARY_METER'" in sql
    assert "THEN 'NO_PRIMARY_METER'" in sql
    assert "rq.scope_type = 'SITE' AND NOT p.is_enabled" in sql
    assert "rq.scope_type = 'ASSET' THEN COALESCE(r.capability_ready, FALSE)" in sql


def test_site_policy_mutations_do_not_touch_asset_policy_rows():
    sql = MIGRATION.read_text()
    fn = sql.split('CREATE OR REPLACE FUNCTION admin.set_site_demand_policy(', 1)[1]
    fn = fn.split('-- ---------------------------------------------------------------------------\n-- 6.', 1)[0]
    assert fn.count("p.policy_scope = 'SITE'") >= 3
    assert "'SITE',\n        p_is_enabled" in fn


def test_refresh_processor_runs_asset_scope_without_site_enable_gate():
    sql = MIGRATION.read_text()
    proc = sql.split('CREATE OR REPLACE PROCEDURE analytics.refresh_demand_analytics(', 1)[1]
    assert "DELETE FROM analytics.demand_state" in proc
    assert "scope_type = 'SITE'" in proc
    assert "SELECT 'ASSET'::TEXT" in proc
    assert "v_asset_policy.policy_id" in proc
    assert "ad.relationship_type = 'PRIMARY_METER'" in proc
