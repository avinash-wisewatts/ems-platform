from pathlib import Path
SQL=(Path(__file__).parents[2]/"postgres/migrations/150_three_role_scope_model.sql").read_text()

def test_reconciliation_contract_is_audited_and_safe():
    assert "get_grafana_reconciliation_context" in SQL
    assert "apply_grafana_reconciliation_mapping" in SQL
    assert "RECONCILE_GRAFANA_TENANT" in SQL
    assert "admin.write_audit_event" in SQL
    assert "Automatic cross-tenant reassignment is prohibited" in SQL
    assert "Automatic Grafana tenant reassignment is prohibited" in SQL

def test_reconciliation_is_platform_admin_only():
    assert "v_role IS DISTINCT FROM 'ADMIN'" in SQL
    assert "v_scope_mode IS DISTINCT FROM 'GLOBAL'" in SQL
