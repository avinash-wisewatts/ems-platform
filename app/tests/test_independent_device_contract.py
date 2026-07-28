from pathlib import Path
ROOT=Path(__file__).resolve().parents[2]
SQL=(ROOT/'postgres/migrations/117_independent_device_inventory.sql').read_text()
def test_device_creation_requires_no_asset():
    assert 'admin.create_device' in SQL
    assert 'p_asset_id' not in SQL
def test_tenant_site_and_location_are_gateway_safe():
    assert 'Device organization must match its gateway' in SQL
    assert 'gateway site' in SQL
def test_profile_category_compatibility_is_declarative():
    assert 'config.device_profile_categories' in SQL
    assert 'not compatible with the selected category' in SQL
def test_gateway_location_is_only_explicitly_reused():
    assert 'p_use_gateway_location' in SQL
    assert "'GATEWAY_EXPLICIT'" in SQL
def test_creation_is_audited():
    assert 'CREATE_DEVICE' in SQL and 'onboarding_audit' in SQL
