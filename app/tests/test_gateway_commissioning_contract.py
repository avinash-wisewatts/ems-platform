from pathlib import Path

ROOT=Path(__file__).resolve().parents[2]
SQL=(ROOT/"postgres/archive/prebaseline_20260807/migrations/123_gateway_commissioning_action.sql").read_text()

def test_gateway_commissioning_requires_identity_model_and_online_connectivity():
    assert "GATEWAY_IDENTITY_MISSING" in SQL
    assert "GATEWAY_MODEL_MISSING" in SQL
    assert "GATEWAY_NEVER_SEEN" in SQL
    assert "GATEWAY_CONNECTIVITY_OFFLINE" in SQL
    assert "gateway_connectivity_policy" in SQL

def test_gateway_commissioning_does_not_require_devices_and_is_audited():
    assert "'devices_required',FALSE" in SQL
    assert "COMMISSION_GATEWAY" in SQL
    assert "onboarding_audit" in SQL
    assert "EXISTS (SELECT 1 FROM metadata.devices" not in SQL

def test_gateway_active_lifecycle_is_controlled():
    assert "'REGISTERED','COMMISSIONING','ACTIVE','INACTIVE','DECOMMISSIONED'" in SQL
    assert "SET lifecycle_status='ACTIVE'" in SQL
