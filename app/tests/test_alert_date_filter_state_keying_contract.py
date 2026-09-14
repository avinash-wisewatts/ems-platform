"""MVP-7 Basic Alerts -- static SQL contract checks for migration 240
(ADR-016 decision 48: date-range filtering keyed to triggered time for
Active, resolved time for Resolved, ended time for Ended).

Same convention as test_alert_evaluation_contract.py: PL/pgSQL cannot be
exercised without a live TimescaleDB instance, not available in this
environment, so these assert the migration file's specific structural
properties rather than executing it.
"""

from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
DATE_FILTER_MIGRATION = ROOT / "postgres/migrations/240_mvp7_alert_date_filter_state_keying.sql"
FUNCTIONS_MIGRATION = ROOT / "postgres/migrations/239_mvp7_alert_evaluation_functions.sql"
MANIFEST = ROOT / "postgres/restructure_manifest.csv"


def _sql() -> str:
    return DATE_FILTER_MIGRATION.read_text()


def test_migration_240_is_registered_in_the_deploy_manifest():
    """Regression guard for the exact deployment gap caught and fixed in
    the previous MVP-7 corrective pass (migrations 238/239 silently
    skipped because scripts/apply_migrations.sh selects EXCLUSIVELY from
    postgres/restructure_manifest.csv's target_category=migration rows).
    Applies equally here."""
    manifest_text = MANIFEST.read_text()
    assert "240_mvp7_alert_date_filter_state_keying.sql,migration," in manifest_text


def test_migration_239_is_not_modified():
    """This corrective fix must land as a NEW migration, never by editing
    an already-applied one (apply_migrations.sh hard-fails on a checksum
    mismatch for a migration already recorded in admin.schema_migrations
    -- staging has 239 applied). Regression guard: 239's own date-filter
    lines must remain exactly as originally applied."""
    sql = FUNCTIONS_MIGRATION.read_text()
    assert "AND (p_from IS NULL OR a.triggered_at >= p_from)" in sql
    assert "AND (p_to IS NULL OR a.triggered_at < p_to)" in sql


def test_active_date_filter_keys_on_triggered_at():
    sql = _sql()
    assert "OR (a.state = 'ACTIVE'   AND a.triggered_at >= p_from)" in sql
    assert "OR (a.state = 'ACTIVE'   AND a.triggered_at < p_to)" in sql


def test_resolved_date_filter_keys_on_resolved_at():
    sql = _sql()
    assert "OR (a.state = 'RESOLVED' AND a.resolved_at  >= p_from)" in sql
    assert "OR (a.state = 'RESOLVED' AND a.resolved_at  < p_to)" in sql


def test_ended_date_filter_keys_on_ended_at():
    sql = _sql()
    assert "OR (a.state = 'ENDED'    AND a.ended_at      >= p_from)" in sql
    assert "OR (a.state = 'ENDED'    AND a.ended_at      < p_to)" in sql


def test_date_filter_no_longer_keys_unconditionally_on_triggered_at():
    """The defect this migration fixes: a single triggered_at comparison
    applied regardless of state must be gone from the new definition."""
    sql = _sql()
    assert "AND (p_from IS NULL OR a.triggered_at >= p_from)" not in sql
    assert "AND (p_to IS NULL OR a.triggered_at < p_to)" not in sql


def test_infinite_scroll_cursor_and_ordering_remain_triggered_at_based():
    """p_before and ORDER BY are a pagination concern, not the ADR-016
    decision 48 date-range filter -- deliberately unchanged."""
    sql = _sql()
    assert "AND (p_before IS NULL OR a.triggered_at < p_before)" in sql
    assert "ORDER BY a.triggered_at DESC" in sql


def test_get_portal_alert_detail_is_untouched():
    """Single-row lookup by alert_id -- no p_from/p_to to correct. This
    migration must not redefine it (the header comment's prose mention of
    the name is fine; a CREATE/ALTER/REVOKE/GRANT touching it is not)."""
    sql = _sql()
    assert "FUNCTION analytics.get_portal_alert_detail" not in sql


def test_signature_and_return_shape_are_unchanged():
    """CREATE OR REPLACE FUNCTION must keep the exact same argument list
    and RETURNS TABLE shape as migration 239 -- changing either would be a
    breaking change to the Analytics API's underlying contract, which this
    fix must not make."""
    sql = _sql()
    assert (
        "CREATE OR REPLACE FUNCTION analytics.get_portal_site_alerts\n(\n"
        "    p_portal_user_id BIGINT,\n"
        "    p_site_id        UUID,\n"
        "    p_state          TEXT DEFAULT NULL,     -- ACTIVE | RESOLVED | ENDED | NULL (any)\n"
        "    p_condition_key  TEXT DEFAULT NULL,\n"
        "    p_from           TIMESTAMPTZ DEFAULT NULL,\n"
        "    p_to             TIMESTAMPTZ DEFAULT NULL,\n"
        "    p_limit          INT DEFAULT 50,\n"
        "    p_before         TIMESTAMPTZ DEFAULT NULL"
    ) in sql


def test_tenant_boundary_and_grants_preserved():
    """ADR-007 Analytics API boundary / authorization must survive the
    replace: same tenant check, same SECURITY DEFINER/STABLE/search_path,
    same ownership/grant pattern as every other function in this schema."""
    sql = _sql()
    assert "IF NOT admin.portal_user_can_access_site(p_portal_user_id, p_site_id) THEN" in sql
    assert "STABLE" in sql
    assert "SECURITY DEFINER" in sql
    assert "SET search_path TO pg_catalog, analytics, admin" in sql
    fn = "analytics.get_portal_site_alerts(BIGINT, UUID, TEXT, TEXT, TIMESTAMPTZ, TIMESTAMPTZ, INT, TIMESTAMPTZ)"
    assert f"ALTER FUNCTION {fn} OWNER TO ems_admin;" in sql
    assert f"REVOKE ALL ON FUNCTION {fn} FROM PUBLIC;" in sql
    assert f"GRANT EXECUTE ON FUNCTION {fn} TO ems_app;" in sql
