import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
MIGRATION = ROOT / "postgres/migrations/016_asset_dashboard_runtime_fix.sql"
DASHBOARD = ROOT / "grafana/dashboards/core/asset-overview.json"


def test_runtime_fix_keeps_config_private_but_uses_owner_rights_resolvers():
    sql = MIGRATION.read_text()

    for sig in (
        "config.resolve_device_demand_method(UUID, TEXT, INTEGER)",
        "analytics.resolve_demand_capability(UUID, TEXT, UUID, TIMESTAMPTZ)",
        "telemetry.resolve_site_capture_bucket(UUID, TIMESTAMPTZ)",
    ):
        assert f"ALTER FUNCTION {sig}\n    SECURITY DEFINER;" in sql
        assert "GRANT USAGE ON SCHEMA config TO grafana_reader" not in sql


def test_asset_device_and_alarm_views_use_compact_telemetry_state():
    sql = MIGRATION.read_text()

    assert "analytics.v_device_telemetry_availability" in sql
    assert "JOIN analytics.v_grafana_devices" not in sql
    assert "FROM analytics.v_grafana_devices" not in sql

    sql_without_comments = "\n".join(
        line for line in sql.splitlines()
        if not line.lstrip().startswith("--")
    )

    assert "normalized_points" not in sql_without_comments


def test_default_asset_dashboard_does_not_show_unsupported_operating_panels():
    d = json.loads(DASHBOARD.read_text())
    titles = {p.get("title") for p in d["panels"]}

    assert "Demand Context" in titles

    assert "Operating state" not in titles
    assert "Operating State Timeline" not in titles
    assert "Utilization / Runtime" not in titles

    assert d["editable"] is False


def test_demand_context_explains_current_demand_state():
    d = json.loads(DASHBOARD.read_text())

    panel = next(
        p for p in d["panels"]
        if p.get("title") == "Demand Context"
    )

    sql = panel["targets"][0]["rawSql"]

    assert "get_grafana_asset_demand_summary" in sql
    assert "display_status" in sql
    assert "latest_valid_demand_kw" in sql
    assert "coverage_percent" in sql
