"""MVP-7 Basic Alerts -- static SQL contract checks (ADR-016/ADR-017).

The lifecycle state machine (migration 239, analytics.evaluate_alerts) is
PL/pgSQL and cannot be exercised without a live TimescaleDB instance, which
is not available in this environment (same limitation already documented
by test_analytics_api_v1_energy_typical_reference_routes.py for migration
236, and the same reason this repository's other *_contract.py files for
SQL-only logic -- e.g. test_demand_calculation_processor_contract.py --
are static/string-based rather than executing the SQL). These tests
instead prove the migration files contain the specific structural and
numeric properties ADR-016/ADR-017 require, so a future edit cannot
silently drop them.

NOT covered here, and not completed in this implementation pass --
flagged, not silently skipped: a true cross-language parity harness that
executes analytics.evaluate_energy_attention_materiality against a live
database and compares its classification, row for row, against
web/src/attention/energyAttention.ts for the same fixture inputs. ADR-017
names this as a required precondition before the job may be relied on in
production. This gap should be closed via the CI database/migration
integration job (which does have live TimescaleDB access) before this
feature is promoted beyond staging validation.
"""

from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SCHEMA_MIGRATION = ROOT / "postgres/migrations/238_mvp7_alert_evaluation.sql"
FUNCTIONS_MIGRATION = ROOT / "postgres/migrations/239_mvp7_alert_evaluation_functions.sql"
JOB_REGISTRATION = ROOT / "postgres/jobs/238_alert_evaluation_job.sql"


def _schema_sql() -> str:
    return SCHEMA_MIGRATION.read_text()


def _functions_sql() -> str:
    return FUNCTIONS_MIGRATION.read_text()


def test_alerts_table_has_the_three_states_and_no_duplicate_active_guard():
    sql = _schema_sql()
    assert "CHECK (state IN ('ACTIVE', 'RESOLVED', 'ENDED'))" in sql
    # ADR-016 decision 3 / "do not create duplicate occurrences" enforced at
    # the database level, not only in job logic.
    assert "ux_alerts_one_active_per_condition" in sql
    assert "WHERE state = 'ACTIVE'" in sql


def test_alerts_state_field_consistency_constraint_present():
    sql = _schema_sql()
    # Ended is never Resolved -- ADR-016 decision 7/17.
    assert "ck_alerts_state_fields" in sql
    assert "ended_at IS NOT NULL AND ended_reason IS NOT NULL AND resolved_at IS NULL" in sql


def test_alerts_space_asset_are_reserved_not_required():
    sql = _schema_sql()
    assert "space_id            UUID REFERENCES metadata.spaces(id)" in sql
    assert "asset_id            UUID REFERENCES metadata.assets(id)" in sql
    # Neither is NOT NULL -- reserved for a not-yet-built Space/Asset
    # Attention condition, per the Space/Asset reconciliation (ADR-017).


def test_candidate_table_is_internal_and_requires_alert_id_only_when_watching_clear():
    sql = _schema_sql()
    assert "alert_evaluation_candidates" in sql
    assert "ck_alert_evaluation_candidates_clear_has_alert" in sql
    assert "REVOKE ALL ON TABLE analytics.alert_evaluation_candidates FROM PUBLIC" in sql


def test_materiality_function_matches_adr_010_exactly():
    """The single-source-of-truth arrangement (ADR-017) requires this
    function to replicate web/src/attention/materiality-policy.ts +
    energyAttention.ts exactly: threshold 15, epsilon 1e-9, inclusive
    both directions."""
    sql = _functions_sql()
    assert "v_threshold        CONSTANT NUMERIC := 15;" in sql
    assert "v_epsilon          CONSTANT NUMERIC := 1e-9;" in sql
    assert "v_deviation >= v_threshold - v_epsilon" in sql
    assert "v_deviation <= -v_threshold + v_epsilon" in sql
    assert "v_min_eligible     CONSTANT INT := 5;" in sql  # TYPICAL_REFERENCE_MIN_ELIGIBLE_PERIODS


def test_materiality_function_does_not_call_the_portal_scoped_wrapper():
    """Deliberate: the portal-scoped analytics.get_portal_site_energy_typical_reference
    requires a portal_user_id the unattended job does not have. See this
    migration's header comment for the reasoning."""
    sql = _functions_sql()
    assert "FROM analytics.get_portal_site_energy_typical_reference(" not in sql
    assert "CALL analytics.get_portal_site_energy_typical_reference(" not in sql


def test_evaluation_uses_most_recent_completed_day_not_today_so_far():
    """Implementation-discovered consequence of migration 236's whole-day
    constraint (already documented by ADR-015) -- not a new product
    decision. See this migration's header note."""
    sql = _functions_sql()
    assert "((p_as_of AT TIME ZONE v_site_timezone)::DATE) - 1" in sql


def test_lifecycle_procedure_has_qualification_resolution_and_retry_windows():
    sql = _functions_sql()
    assert "v_qualification_window   CONSTANT INTERVAL := INTERVAL '5 minutes';" in sql
    assert "v_resolution_window       CONSTANT INTERVAL := INTERVAL '1 minute';" in sql
    # 30 minutes from qualification = since + 5 + 30 = 35 minutes from since.
    assert "v_persistence_retry_limit  CONSTANT INTERVAL := INTERVAL '35 minutes';" in sql


def test_lifecycle_procedure_does_not_rely_on_found_across_statements():
    """Regression guard for the FOUND-scoping bug caught and fixed during
    this implementation: FOUND is reassigned by every SQL statement, so
    v_active_alert lookups must use an explicit NULL check instead."""
    sql = _functions_sql()
    assert "IF FOUND AND v_active_alert" not in sql
    assert "v_active_alert.alert_id IS NOT NULL" in sql


def test_configuration_transition_ends_not_resolves():
    sql = _functions_sql()
    assert "Attention condition configuration changed" in sql
    assert "state = 'ENDED'" in sql


def test_retention_is_state_conditional_not_a_hypertable_policy():
    """Deviation from ADR-017's original assumption, discovered during
    implementation: retention is state-conditional (90 days from
    resolved_at/ended_at; Active never expires), which a hypertable
    chunk-drop retention policy cannot express. See this migration's
    header note."""
    sql = _functions_sql()
    assert "state = 'RESOLVED' AND resolved_at < v_now - INTERVAL '90 days'" in sql
    assert "state = 'ENDED' AND ended_at < v_now - INTERVAL '90 days'" in sql
    assert "add_retention_policy" not in _schema_sql()


def test_recurrence_is_derived_never_a_stored_counter():
    sql = _functions_sql()
    assert "previous_occurrence_count" in sql
    assert "SELECT COUNT(*) FROM analytics.alerts AS prev" in sql
    # No column on the table itself stores this.
    assert "previous_occurrence_count" not in _schema_sql()


def test_read_functions_enforce_tenant_boundary_via_existing_function():
    sql = _functions_sql()
    assert sql.count("admin.portal_user_can_access_site(p_portal_user_id") >= 2


def test_read_functions_follow_the_revoke_grant_ownership_pattern():
    sql = _functions_sql()
    for fn in (
        "analytics.evaluate_energy_attention_materiality(UUID, TIMESTAMPTZ)",
        "analytics.get_portal_site_alerts(BIGINT, UUID, TEXT, TEXT, TIMESTAMPTZ, TIMESTAMPTZ, INT, TIMESTAMPTZ)",
        "analytics.get_portal_alert_detail(BIGINT, UUID)",
    ):
        assert f"ALTER FUNCTION {fn} OWNER TO ems_admin;" in sql
        assert f"REVOKE ALL ON FUNCTION {fn} FROM PUBLIC;" in sql
        assert f"GRANT EXECUTE ON FUNCTION {fn} TO ems_app;" in sql


def test_job_registered_every_minute_matching_qualification_granularity():
    sql = JOB_REGISTRATION.read_text()
    assert "run_alert_evaluation_job" in sql
    assert "INTERVAL '1 minute'" in sql
    assert "max_retries" in sql


def test_job_wrapper_delegates_to_evaluate_alerts():
    sql = _functions_sql()
    assert "CALL analytics.evaluate_alerts();" in sql
