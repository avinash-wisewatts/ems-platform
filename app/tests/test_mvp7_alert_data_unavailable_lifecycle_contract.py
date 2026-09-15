"""MVP-7 Basic Alerts -- static SQL contract checks for migration 242
(ADR-016 section 4/7 amendment, 2026-09-15: data-unavailable-while-Active
messaging and the recovery-while-still-material -> Ended transition,
Option B, a second distinct Ended cause alongside migration 239's
configuration-transition cause).

Same convention as test_alert_evaluation_contract.py / test_alert_
evaluation_transaction_control_fix_contract.py: static/structural checks
only -- this file cannot tell whether the new PL/pgSQL branches actually
execute correctly, only whether the source text has the specific shape
this migration requires. The live-execution proof lives in
scripts/test/assert_mvp7_alert_data_unavailable_lifecycle_executes.sh,
which runs the full data-unavailable -> recovery -> Ended -> fresh-
qualification -> new-Active sequence against a real disposable TimescaleDB
instance.
"""

from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
MIGRATION = ROOT / "postgres/migrations/242_mvp7_alert_data_unavailable_lifecycle.sql"
MANIFEST = ROOT / "postgres/restructure_manifest.csv"


def _sql() -> str:
    return MIGRATION.read_text()


def _procedure_body() -> str:
    sql = _sql()
    start = sql.index("CREATE OR REPLACE PROCEDURE analytics.evaluate_alerts()")
    end = sql.index("$procedure$;", start)
    return sql[start:end]


def test_migration_242_is_registered_in_the_deploy_manifest():
    """Regression guard for the exact deployment gap this MVP-7 corrective
    effort already caught twice for earlier migrations (238/239, then
    241): scripts/apply_migrations.sh selects EXCLUSIVELY from
    postgres/restructure_manifest.csv's target_category=migration rows."""
    manifest_text = MANIFEST.read_text()
    assert "242_mvp7_alert_data_unavailable_lifecycle.sql,migration," in manifest_text


def test_new_columns_and_constraints_present():
    sql = _sql()
    assert "ADD COLUMN IF NOT EXISTS data_unavailable BOOLEAN NOT NULL DEFAULT FALSE" in sql
    assert "ADD COLUMN IF NOT EXISTS ended_reason_code TEXT" in sql
    assert "ended_reason_code IS NULL OR ended_reason_code IN ('CONFIGURATION_CHANGED', 'DATA_UNAVAILABLE')" in sql
    assert "NOT data_unavailable OR state = 'ACTIVE'" in sql
    # The state/field-consistency constraint must now also require a code
    # when Ended, matching the existing free-text ended_reason requirement.
    assert "ended_reason IS NOT NULL AND ended_reason_code IS NOT NULL AND resolved_at IS NULL" in sql


def test_existing_ended_rows_backfilled_before_constraint_added():
    """The NOT-NULL-when-Ended requirement on ended_reason_code must not be
    added before any pre-existing Ended row (necessarily caused only by a
    configuration transition, under pre-migration-242 code) is backfilled --
    otherwise the ALTER TABLE ADD CONSTRAINT itself would fail against any
    environment that already has Ended rows."""
    sql = _sql()
    backfill_idx = sql.index("UPDATE analytics.alerts")
    constraint_idx = sql.index("DROP CONSTRAINT ck_alerts_state_fields")
    assert backfill_idx < constraint_idx
    backfill_stmt = sql[backfill_idx : sql.index(";", backfill_idx)]
    assert "ended_reason_code = 'CONFIGURATION_CHANGED'" in backfill_stmt
    assert "WHERE state = 'ENDED' AND ended_reason_code IS NULL" in backfill_stmt


def test_evaluate_alerts_still_not_security_definer_or_set_clause():
    """Regression guard: migration 242's CREATE OR REPLACE must not
    reintroduce SECURITY DEFINER / SET search_path -- migration 241 fixed
    exactly this defect (PostgreSQL forbids the COMMIT statements below
    inside a procedure with either property, in any calling context)."""
    body = _procedure_body()
    assert "SECURITY DEFINER" not in body
    assert "SET search_path" not in body
    assert "CREATE OR REPLACE PROCEDURE analytics.evaluate_alerts()\nLANGUAGE plpgsql\nAS $procedure$\n" in _sql()


def test_commit_placement_unchanged():
    """Same invariant migration 241 established: exactly 2 COMMIT
    statements in the procedure body (per-site, then retention), never
    inside the exception-guarded block, never behind a CONTINUE."""
    sql = _sql()
    body = _procedure_body()
    assert body.count("COMMIT;") == 2
    start = sql.index("FOR v_site IN")
    exception_idx = sql.index("EXCEPTION WHEN OTHERS THEN", start)
    end_idx = sql.index("END;", exception_idx)
    guarded_block = sql[start:end_idx]
    assert "COMMIT;" not in guarded_block
    assert "ROLLBACK;" not in guarded_block
    assert "CONTINUE;" not in sql


def test_data_unavailable_flagged_on_insufficient_data():
    """The core of the messaging fix: an Active alert's data_unavailable
    must be set TRUE the moment a run observes NOT has_sufficient_data for
    its site+condition -- a targeted, no-op-when-no-match UPDATE, not a
    blanket one."""
    sql = _sql()
    idx = sql.index("IF NOT v_eval.has_sufficient_data THEN")
    scope = sql[idx : sql.index("ELSE", idx)]
    assert "SET data_unavailable = TRUE, last_evaluated_at = v_now" in scope
    assert "WHERE site_id = v_site.id" in scope
    assert "AND condition_key = v_eval.condition_key" in scope
    assert "AND state = 'ACTIVE'" in scope


def test_recovery_while_still_material_ends_not_continues():
    """The core of the transition fix: an Active alert whose data_unavailable
    flag is set, once the condition is observed material again, must be
    ENDED with the controlled DATA_UNAVAILABLE reason code -- not silently
    continued via a last_evaluated_at-only refresh."""
    sql = _sql()
    idx = sql.index("data-unavailable-recovery-while-still-")
    scope = sql[idx : sql.index("IF v_eval.is_material THEN", idx)]
    assert "v_active_alert.data_unavailable" in scope
    assert "AND v_eval.is_material THEN" in scope
    assert "state = 'ENDED'" in scope
    assert "ended_reason_code = 'DATA_UNAVAILABLE'" in scope
    assert "data_unavailable = FALSE" in scope
    assert "SELECT * INTO v_active_alert FROM analytics.alerts WHERE FALSE;" in scope


def test_recovery_while_not_material_is_unaffected():
    """Negative/guard requirement: the new Ended path must be gated on
    v_eval.is_material so recovery while the condition is NOT material still
    reaches the existing, unmodified normal resolution path -- not
    accidentally short-circuited into Ended."""
    sql = _sql()
    idx = sql.index("data-unavailable-recovery-while-still-")
    scope = sql[idx : sql.index("IF v_eval.is_material THEN", idx)]
    # The check must require is_material=TRUE to fire -- confirms the guard
    # exists syntactically as part of the same IF condition, not merely
    # mentioned in a comment.
    assert "AND v_active_alert.data_unavailable\n                   AND v_eval.is_material THEN" in scope


def test_configuration_transition_also_gets_controlled_reason_code():
    """The pre-existing configuration-transition Ended cause (migration 239)
    must be retrofitted with the new controlled code, alongside its
    existing free-text reason -- both Ended causes must be code-
    distinguishable, not just the new one."""
    sql = _sql()
    idx = sql.index("Attention condition configuration changed")
    scope = sql[idx : idx + 400]
    assert "ended_reason_code = 'CONFIGURATION_CHANGED'" in scope
    assert "data_unavailable = FALSE" in scope


def test_data_unavailable_cleared_on_normal_active_refresh_and_on_resolution():
    """data_unavailable must be explicitly cleared (not left stale) on every
    path that either (a) evaluates an Active alert normally with sufficient
    data, or (b) transitions it to RESOLVED -- required by the
    ck_alerts_data_unavailable_active_only constraint, and semantically
    required so the flag never lies about current state."""
    sql = _sql()
    already_active_idx = sql.index("Already Active under the same condition")
    already_active_scope = sql[already_active_idx : already_active_idx + 700]
    assert "data_unavailable = FALSE" in already_active_scope

    resolved_idx = sql.index("SET state = 'RESOLVED',")
    resolved_scope = sql[resolved_idx : resolved_idx + 300]
    assert "data_unavailable = FALSE" in resolved_scope


def test_qualification_resolution_persistence_retry_windows_unchanged():
    """Explicit scope guard: the existing timing constants and their use
    must be untouched by this migration."""
    sql = _sql()
    assert "v_gap_tolerance          CONSTANT INTERVAL := INTERVAL '3 minutes';" in sql
    assert "v_qualification_window   CONSTANT INTERVAL := INTERVAL '5 minutes';" in sql
    assert "v_resolution_window       CONSTANT INTERVAL := INTERVAL '1 minute';" in sql
    assert "v_persistence_retry_limit  CONSTANT INTERVAL := INTERVAL '35 minutes';" in sql


def test_active_alert_cleared_via_safe_reselect_not_bare_null_assignment():
    """Regression guard for a real defect this migration's own live-
    execution test discovered: `v_active_alert := NULL;` on a bare
    PL/pgSQL RECORD variable reverts it to PostgreSQL's "not yet assigned"
    state, and any subsequent field access then raises "record ... is not
    assigned yet". Confirmed live (isolated DO block reproduction) that a
    zero-row `SELECT * INTO ... WHERE FALSE` is safe where a bare NULL
    assignment is not. Both the pre-existing configuration-transition
    branch and the new data-unavailable-recovery branch must use the safe
    form, and neither may use the unsafe one. Scoped to the procedure BODY
    only -- the unsafe form is deliberately still quoted in this
    migration's own explanatory header comment, describing the bug it
    fixes."""
    body = _procedure_body()
    assert "v_active_alert := NULL;" not in body
    assert body.count("SELECT * INTO v_active_alert FROM analytics.alerts WHERE FALSE;") == 2


def test_run_alert_evaluation_job_untouched():
    """This migration must not redefine the job wrapper -- only
    evaluate_alerts() and the two portal read functions."""
    sql = _sql()
    assert "PROCEDURE analytics.run_alert_evaluation_job" not in sql


def test_portal_read_functions_dropped_before_recreation():
    """PostgreSQL forbids CREATE OR REPLACE from changing an existing
    function's RETURNS TABLE row shape -- discovered live against the
    disposable test database while validating this migration. Both read
    functions must be explicitly DROPped first."""
    sql = _sql()
    assert "DROP FUNCTION IF EXISTS analytics.get_portal_site_alerts(BIGINT, UUID, TEXT, TEXT, TIMESTAMPTZ, TIMESTAMPTZ, INT, TIMESTAMPTZ);" in sql
    assert "DROP FUNCTION IF EXISTS analytics.get_portal_alert_detail(BIGINT, UUID);" in sql


def test_portal_read_functions_expose_new_columns():
    sql = _sql()
    list_start = sql.index("CREATE FUNCTION analytics.get_portal_site_alerts")
    detail_start = sql.index("CREATE FUNCTION analytics.get_portal_alert_detail")
    list_scope = sql[list_start:detail_start]
    detail_scope = sql[detail_start:]
    for scope in (list_scope, detail_scope):
        assert "ended_reason_code" in scope
        assert "data_unavailable" in scope
        assert "a.ended_reason_code, a.data_unavailable" in scope


def test_ownership_and_grants_preserved():
    sql = _sql()
    assert "ALTER PROCEDURE analytics.evaluate_alerts() OWNER TO ems_admin;" in sql
    assert "REVOKE ALL ON PROCEDURE analytics.evaluate_alerts() FROM PUBLIC;" in sql
    assert "GRANT EXECUTE ON FUNCTION analytics.get_portal_site_alerts" in sql
    assert "GRANT EXECUTE ON FUNCTION analytics.get_portal_alert_detail" in sql
