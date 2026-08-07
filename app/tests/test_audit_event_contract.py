from pathlib import Path

SQL = Path("postgres/archive/prebaseline_20260807/migrations/126_audit_lifecycle_safety.sql").read_text()


def test_generic_audit_event_contract():
    assert "CREATE TABLE IF NOT EXISTS admin.audit_events" in SQL
    for field in (
        "transaction_id", "organization_id", "site_id", "actor_portal_user_id",
        "actor_role", "action", "entity_type", "entity_id", "previous_values",
        "new_values", "result", "failure_reason", "occurred_at",
    ):
        assert field in SQL
    assert "CREATE OR REPLACE FUNCTION admin.write_audit_event" in SQL
    assert "CREATE OR REPLACE FUNCTION admin.redact_audit_json" in SQL
    assert "[REDACTED]" in SQL


def test_audit_access_is_tenant_scoped():
    assert "CREATE OR REPLACE FUNCTION admin.list_accessible_audit_events" in SQL
    assert "admin.portal_user_can_access_site" in SQL
    assert "actor.organization_id" in SQL
    assert "REVOKE ALL ON admin.audit_events FROM PUBLIC, ems_app" in SQL
    assert "REVOKE ALL ON FUNCTION admin.write_audit_event(UUID,BIGINT,TEXT,TEXT,UUID,UUID,UUID,JSONB,JSONB,TEXT,TEXT) FROM PUBLIC, ems_app" in SQL
    assert "GRANT EXECUTE ON FUNCTION admin.write_audit_event" not in SQL


def test_failed_and_rejected_events_are_supported():
    assert "('SUCCEEDED','FAILED','REJECTED')" in SQL
    assert "failure_reason" in SQL
