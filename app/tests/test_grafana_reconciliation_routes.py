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


def test_reconciliation_result_is_actually_rendered():
    """
    Regression test: the reconciliation route has always computed
    result["grafana_reconciliation"], but organizations.html previously had
    no markup referencing it at all -- an HTTP 200 communicated nothing
    about what actually happened. This pins the observability fix.
    """
    organizations_html = (
        SOURCE_ROOT / "templates" / "organizations.html"
    ).read_text()

    assert "grafana_reconciliation" in organizations_html
    assert "datasource_action" in organizations_html
    assert "reconciliation.success" in organizations_html


def test_reconciliation_rendering_never_references_secret_fields():
    """No password/secureJsonData field name is ever written into the
    reconciliation result markup -- the result dict itself never contains
    one (see GrafanaClient.provision_organization()), and this guards
    against a future change accidentally adding one to the template."""
    organizations_html = (
        SOURCE_ROOT / "templates" / "organizations.html"
    ).read_text()

    assert "secureJsonData" not in organizations_html
    assert "datasource_password" not in organizations_html
    assert "reconciliation.password" not in organizations_html
