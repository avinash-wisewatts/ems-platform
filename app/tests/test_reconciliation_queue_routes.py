from pathlib import Path
MAIN=(Path(__file__).parents[1]/"src/main.py").read_text()
TEMPLATE=(Path(__file__).parents[1]/"src/templates/reconciliation_queue.html").read_text()
NAV=(Path(__file__).parents[1]/"src/admin_navigation.py").read_text()

def test_route_template_and_navigation_exist():
    assert '"/administration/reconciliation"' in MAIN
    assert 'name="reconciliation_queue.html"' in MAIN
    assert "Reconciliation queue" in TEMPLATE
    assert 'NavigationItem("reconciliation"' in NAV
