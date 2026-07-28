from pathlib import Path

ROOT=Path(__file__).resolve().parents[2]
MAIN=(ROOT/"app/src/main.py").read_text()
TEMPLATE=(ROOT/"app/src/templates/gateways.html").read_text()
SERVICE=(ROOT/"app/src/gateway_management_service.py").read_text()

def test_gateway_commissioning_route_and_service_use_database_contract():
    assert '"/administration/gateways/{gateway_id}/commission"' in MAIN
    assert "await commission_gateway(" in MAIN
    assert "admin.commission_gateway" in SERVICE

def test_gateway_page_consumes_shared_readiness_and_exposes_action():
    assert 'entity_type="GATEWAY"' in MAIN
    assert "gateway_readiness" in MAIN
    assert "Commission gateway" in TEMPLATE
    assert "/commission" in TEMPLATE
