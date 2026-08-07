from pathlib import Path

SQL = Path('postgres/archive/prebaseline_20260807/migrations/122_commissioning_readiness_asset_action.sql').read_text()


def test_unified_readiness_view_and_scope_function_exist():
    assert 'CREATE OR REPLACE VIEW analytics.v_commissioning_readiness' in SQL
    assert 'admin.list_accessible_commissioning_readiness' in SQL
    assert 'admin.portal_user_can_access_site' in SQL


def test_readiness_contract_has_required_outputs():
    for token in ('entity_id', 'lifecycle_status', 'commissioning_status', 'is_ready', 'blocking_reason_codes', 'warning_reason_codes'):
        assert token in SQL


def test_asset_policy_rules_are_declarative():
    assert "DIRECT_METER_REQUIRED" in SQL
    assert "QUALIFYING_PRIMARY_METER_REQUIRED" in SQL
    assert "DESCENDANT_COVERAGE_ALLOWED" in SQL
    assert "NOT_REQUIRED" in SQL
    assert "analytics.v_asset_meter_coverage_configuration" in SQL


def test_asset_commissioning_consumes_readiness_and_audits():
    assert 'CREATE OR REPLACE FUNCTION admin.commission_asset' in SQL
    assert 'FROM analytics.v_commissioning_readiness' in SQL
    assert "'operation', 'COMMISSION_ASSET'" in SQL
    assert "SET lifecycle_status = 'ACTIVE', status = 'active'" in SQL
