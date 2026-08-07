from pathlib import Path
SQL=(Path(__file__).parents[2]/"postgres/archive/prebaseline_20260807/migrations/150_three_role_scope_model.sql").read_text()

def test_queue_covers_required_issue_sources():
    for value in ("UNASSIGNED_DEVICE","UNMAPPED_TELEMETRY","MISSING_PRIMARY_METER","INVALID_PROFILE","INCOMPLETE_LOCATION","FAILED_GRAFANA_PROVISIONING"):
        assert value in SQL

def test_queue_is_tenant_safe_and_least_privilege():
    assert "portal_user_can_access_site" in SQL
    assert "a.role_code = 'ADMIN'" in SQL
    assert "a.access_scope_mode = 'GLOBAL'" in SQL
    assert "SECURITY DEFINER" in SQL
    assert "REVOKE ALL ON FUNCTION" in SQL
    assert "GRANT EXECUTE" in SQL
