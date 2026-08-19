import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
DASHBOARD = ROOT / "grafana/dashboards/core/asset-overview.json"
MIGRATION = ROOT / "postgres/migrations/015_asset_dashboard_v1_contract.sql"


def _dashboard():
    return json.loads(DASHBOARD.read_text())


def _canvas_fixed_text(panel):
    values = []

    root = panel.get("options", {}).get("root", {})
    for element in root.get("elements", []):
        text = element.get("config", {}).get("text", {})
        if text.get("mode") == "fixed":
            values.append(text.get("fixed", ""))

    return values


def test_asset_dashboard_is_current_full_asset_overview():
    d = _dashboard()

    assert d["uid"] == "ems-asset-overview"

    titles = {p.get("title") for p in d["panels"]}

    required = {
        "Active Power Trend",
        "Demand Profile",
        "Energy Consumption Trend",
        "Energy Consumption & Performance",
        "Voltage Trend",
        "Current Trend",
        "Power Factor & Frequency",
        "Current THD",
        "Assigned Devices",
        "Demand Context",
        "Demand Quality History",
        "Active Alarms",
    }

    assert required.issubset(titles)

    first = d["panels"][0]

    # The compact header is now a Canvas card, not a table panel.
    assert first["type"] == "canvas"
    assert first["title"] == ""

    header_sql = first["targets"][0]["rawSql"]

    for label in (
        "Asset",
        "Type",
        "Location",
        "Hierarchy",
        "Lifecycle Line",
        "Telemetry Line",
        "Last Seen Line",
        "Instrumentation Line",
    ):
        assert f'AS "{label}"' in header_sql

    # Compact electrical summary must contain the current Canvas cards.
    canvas_labels = {
        fixed
        for panel in d["panels"]
        if panel.get("type") == "canvas"
        for fixed in _canvas_fixed_text(panel)
    }

    assert "Frequency (Hz)" in canvas_labels
    assert "Active Power (kW)" in canvas_labels
    assert "Total Energy (kWh)" in canvas_labels

    assert len(d["panels"]) >= 18


def test_dashboard_never_uses_instantaneous_power_as_demand():
    text = DASHBOARD.read_text()

    assert 'active_power_kw AS \\"Current demand\\"' not in text
    assert 'active_power_kw AS \\"Peak demand\\"' not in text

    assert "analytics.get_grafana_asset_demand_summary" in text
    assert "analytics.v_grafana_asset_demand_intervals" in text


def test_active_power_canvas_uses_live_telemetry_not_demand_semantics():
    d = _dashboard()

    panel = next(
        p for p in d["panels"]
        if p.get("id") == 140
    )

    target = panel["targets"][0]

    assert target["datasource"]["type"] == "wisewatts-live-datasource"
    assert target["assetId"] == "$asset_id"

    points = {
        p.strip()
        for p in target["logicalPoints"].split(",")
    }

    assert points == {
        "ACTIVE_POWER_TOTAL",
        "ACTIVE_POWER_L1",
        "ACTIVE_POWER_L2",
        "ACTIVE_POWER_L3",
    }


def test_dashboard_keeps_deferred_metrics_out_of_v1():
    titles = "\n".join(
        p.get("title", "")
        for p in _dashboard()["panels"]
    )

    for deferred in (
        "Carbon",
        "Cost",
        "Health Score",
        "Energy Intensity",
    ):
        assert deferred not in titles


def test_asset_dashboard_migration_exposes_semantic_views():
    sql = MIGRATION.read_text()

    for view in (
        "analytics.v_grafana_asset_electrical_samples",
        "analytics.v_grafana_asset_energy_intervals",
        "analytics.v_grafana_asset_health_history",
    ):
        assert f"CREATE OR REPLACE VIEW {view}" in sql
        assert f"GRANT SELECT ON {view}" in sql

    assert "relationship_type = 'PRIMARY_METER'" in sql
    assert "does not infer run/idle/off" in sql
