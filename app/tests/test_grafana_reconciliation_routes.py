from pathlib import Path


SOURCE_ROOT = Path(__file__).parents[1] / "src"
MAIN = (SOURCE_ROOT / "main.py").read_text()
AUTH = (SOURCE_ROOT / "auth" / "authorization.py").read_text()

TEMPLATES = "\n".join(
    template.read_text()
    for template in (SOURCE_ROOT / "templates").glob("*.html")
)


def test_reconciliation_route_and_action_exist():
    assert (
        '"/administration/organizations/'
        '{organization_id}/grafana/reconcile"'
    ) in MAIN

    assert 'path.endswith("/grafana/reconcile")' in AUTH

    assert "/grafana/reconcile" in TEMPLATES
    assert "Reconcile" in TEMPLATES
