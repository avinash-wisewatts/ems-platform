import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
DASHBOARD_DIR = ROOT / "grafana" / "dashboards" / "core"
EXPECTED = {
 "ems-org-overview","ems-site-overview","ems-area-overview","ems-asset-overview",
 "ems-device-diagnostics","ems-analytics-explorer","ems-alarms",
}

def test_universal_grafana_mvp_dashboards_are_valid_and_tenant_filtered():
    files = sorted(DASHBOARD_DIR.glob("*.json"))
    assert {json.loads(p.read_text())["uid"] for p in files} == EXPECTED
    for path in files:
        dashboard = json.loads(path.read_text())
        assert dashboard["editable"] is False
        assert dashboard["schemaVersion"] >= 39
        for panel in dashboard.get("panels", []):
            for target in panel.get("targets", []):
                sql = target.get("rawSql", "")
                if "analytics.v_grafana_" in sql:
                    assert "${__org.id}" in sql, f"Missing tenant filter in {path.name}: {panel.get('title')}"
