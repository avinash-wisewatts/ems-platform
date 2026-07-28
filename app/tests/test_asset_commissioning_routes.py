from pathlib import Path

MAIN = Path('app/src/main.py').read_text()
TEMPLATE = Path('app/src/templates/assets.html').read_text()
SERVICE = Path('app/src/asset_management_service.py').read_text()


def test_asset_commissioning_route_is_present():
    assert '"/administration/assets/{asset_id}/commission"' in MAIN
    assert 'await commission_asset(' in MAIN


def test_asset_page_uses_readiness_service():
    assert 'list_accessible_commissioning_readiness' in MAIN
    assert 'asset_readiness' in MAIN
    assert 'readiness.blocking_reason_codes' in TEMPLATE
    assert 'Commission asset' in TEMPLATE


def test_service_calls_database_contract():
    assert 'admin.list_accessible_commissioning_readiness' in SERVICE
    assert 'admin.commission_asset' in SERVICE
