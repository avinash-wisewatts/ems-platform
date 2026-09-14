"""MVP-7 Basic Alerts -- static SQL contract checks for migration 241
(transaction-control fix for analytics.evaluate_alerts()).

Same convention as test_alert_evaluation_contract.py / test_alert_date_
filter_state_keying_contract.py: static/structural checks only. The
live-execution proof that this fix actually works lives in
scripts/test/assert_mvp7_alert_evaluation_job_executes.sh, which runs
against a real disposable TimescaleDB instance in CI -- exactly the
coverage this static file cannot provide (it cannot tell whether a COMMIT
is *legal* at the procedure's security context, only whether the source
text has the properties known to make it illegal).
"""

from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
FIX_MIGRATION = ROOT / "postgres/migrations/241_mvp7_alert_evaluation_transaction_control_fix.sql"
FUNCTIONS_MIGRATION = ROOT / "postgres/migrations/239_mvp7_alert_evaluation_functions.sql"
JOB_REGISTRATION = ROOT / "postgres/jobs/238_alert_evaluation_job.sql"
MANIFEST = ROOT / "postgres/restructure_manifest.csv"


def _fix_sql() -> str:
    return FIX_MIGRATION.read_text()


def test_migration_241_is_registered_in_the_deploy_manifest():
    """Regression guard for the exact deployment gap caught twice already
    in this MVP-7 corrective effort (migrations 238/239, then rediscovered
    conceptually for every new migration since): scripts/apply_migrations.sh
    selects EXCLUSIVELY from postgres/restructure_manifest.csv's
    target_category=migration rows."""
    manifest_text = MANIFEST.read_text()
    assert "241_mvp7_alert_evaluation_transaction_control_fix.sql,migration," in manifest_text


def test_migration_239_is_not_modified():
    """This fix must land as a NEW migration, never by editing an
    already-applied one -- apply_migrations.sh hard-fails on a checksum
    mismatch, and staging has 239 applied. Regression guard: 239's
    evaluate_alerts() definition must still declare SECURITY DEFINER and
    the SET clause exactly as originally applied (unchanged on disk);
    migration 241 is what removes them, via CREATE OR REPLACE, not an
    edit to this file."""
    sql = FUNCTIONS_MIGRATION.read_text()
    assert "CREATE OR REPLACE PROCEDURE analytics.evaluate_alerts()\nLANGUAGE plpgsql\nSECURITY DEFINER\nSET search_path TO pg_catalog, analytics, admin\n" in sql


def test_evaluate_alerts_no_longer_security_definer_or_set_clause():
    """The actual fix: migration 241's CREATE OR REPLACE must NOT carry
    forward SECURITY DEFINER or the SET search_path clause -- either alone
    is sufficient to make the per-site/retention COMMIT statements illegal
    (confirmed by isolated reproduction; nesting was not the cause)."""
    sql = _fix_sql()
    body_start = sql.index("CREATE OR REPLACE PROCEDURE analytics.evaluate_alerts()")
    body_end = sql.index("$procedure$;", body_start)
    body = sql[body_start:body_end]
    assert "SECURITY DEFINER" not in body
    assert "SET search_path" not in body
    # Confirms this is the real header (LANGUAGE plpgsql immediately
    # followed by the function body opener), not an accidental match.
    assert "CREATE OR REPLACE PROCEDURE analytics.evaluate_alerts()\nLANGUAGE plpgsql\nAS $procedure$\n" in sql


def test_commit_statements_preserved_unchanged():
    """The fix must not remove or relocate the COMMIT statements
    themselves -- only the two properties that made them illegal. Per-site
    durability (ADR-016/ADR-017) is unchanged. Scoped to the procedure
    body -- the migration file itself has one further wrapping COMMIT for
    its own transaction, which is not part of this count."""
    sql = _fix_sql()
    body_start = sql.index("CREATE OR REPLACE PROCEDURE analytics.evaluate_alerts()")
    body_end = sql.index("$procedure$;", body_start)
    body = sql[body_start:body_end]
    assert body.count("COMMIT;") == 2


def test_body_is_otherwise_byte_identical_to_migration_239():
    """Beyond the two removed lines, this must be the exact same procedure
    -- same lifecycle logic, same comments, same qualification/resolution/
    retention windows. Compares the DECLARE...END; block, which is
    identical in both migrations by construction."""
    fix_sql = _fix_sql()
    orig_sql = FUNCTIONS_MIGRATION.read_text()

    fix_start = fix_sql.index("CREATE OR REPLACE PROCEDURE analytics.evaluate_alerts()")
    orig_start = orig_sql.index("CREATE OR REPLACE PROCEDURE analytics.evaluate_alerts()")
    fix_body = fix_sql[fix_sql.index("DECLARE", fix_start) : fix_sql.index("$procedure$;", fix_start)]
    orig_body = orig_sql[orig_sql.index("DECLARE", orig_start) : orig_sql.index("$procedure$;", orig_start)]
    assert fix_body == orig_body


def test_run_alert_evaluation_job_and_job_registration_untouched():
    """Explicit scope guard: this migration must not touch
    analytics.run_alert_evaluation_job, and the job registration SQL file
    must be untouched by this corrective pass."""
    sql = _fix_sql()
    assert "PROCEDURE analytics.run_alert_evaluation_job" not in sql
    assert "FUNCTION analytics.evaluate_energy_attention_materiality" not in sql
    assert "FUNCTION analytics.get_portal_site_alerts" not in sql
    assert "FUNCTION analytics.get_portal_alert_detail" not in sql

    job_sql = JOB_REGISTRATION.read_text()
    assert "SECURITY DEFINER" not in job_sql  # never had it; confirms no accidental change here either
    assert "add_job" in job_sql and "alter_job" in job_sql  # unchanged structure from the prior corrective pass


def test_ownership_and_grants_preserved():
    sql = _fix_sql()
    assert "ALTER PROCEDURE analytics.evaluate_alerts() OWNER TO ems_admin;" in sql
    assert "REVOKE ALL ON PROCEDURE analytics.evaluate_alerts() FROM PUBLIC;" in sql
