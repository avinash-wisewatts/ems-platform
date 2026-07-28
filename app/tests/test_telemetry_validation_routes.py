from pathlib import Path

MAIN=Path("app/src/main.py").read_text()
NAV=Path("app/src/admin_navigation.py").read_text()
TEMPLATE=Path("app/src/templates/telemetry_validation.html").read_text()

def test_route_navigation_and_filters_exist():
    assert '"/administration/telemetry-validation"' in MAIN
    assert '"/administration/telemetry-validation"' in NAV
    assert 'active_navigation_key = "telemetry-validation"' in MAIN
    for field in ("organization_id","site_id","telemetry_state"):
        assert f'name="{field}"' in TEMPLATE

def test_minimum_columns_exist():
    for label in ("Device","Gateway","Site","Associated asset","Configuration state","Telemetry state","Latest source timestamp","Latest received timestamp","Profile validation"):
        assert label in TEMPLATE
