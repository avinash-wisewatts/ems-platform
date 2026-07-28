from pathlib import Path

MAIN = Path("app/src/main.py").read_text()
NAV = Path("app/src/admin_navigation.py").read_text()
TEMPLATE = Path("app/src/templates/commissioning.html").read_text()


def test_dashboard_route_and_navigation_exist():
    assert '"/administration/commissioning"' in MAIN
    assert '"/administration/commissioning"' in NAV
    assert 'active_navigation_key = "commissioning"' in MAIN


def test_dashboard_has_required_filters_groups_and_correction_links():
    for token in ("organization_id", "site_id", "entity_type"):
        assert f'name="{token}"' in TEMPLATE
    for status in ("NOT_STARTED", "IN_PROGRESS", "BLOCKED", "READY", "COMMISSIONED", "FAILED"):
        assert status in (MAIN + TEMPLATE + Path("app/src/commissioning_dashboard_service.py").read_text())
    assert "correction_href" in TEMPLATE
