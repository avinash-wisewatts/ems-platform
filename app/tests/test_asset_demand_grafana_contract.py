from pathlib import Path
import json

ROOT = Path(__file__).resolve().parents[2]
MIGRATION = ROOT / "postgres/migrations/014_asset_demand_grafana_contract.sql"
MIRROR = ROOT / "postgres/ddl/133_asset_demand_grafana_contract.sql"
DASHBOARD = ROOT / "grafana/dashboards/core/asset-overview.json"


def test_asset_demand_grafana_migration_and_mirror_match():
    sql = MIGRATION.read_text()

    assert sql == MIRROR.read_text()
    assert "analytics.v_grafana_asset_demand_state" in sql
    assert "analytics.v_grafana_asset_demand_intervals" in sql
    assert "analytics.resolve_demand_capability" in sql
    assert "analytics.demand_state" in sql
    assert "analytics.demand_intervals" in sql
    assert "grafana_reader" in sql


def test_asset_overview_uses_canonical_demand_contracts():
    dashboard = json.loads(DASHBOARD.read_text())

    panels = {
        panel["title"]: panel
        for panel in dashboard["panels"]
        if panel.get("title")
    }

    context = panels["Demand Context"]
    context_sql = context["targets"][0]["rawSql"]

    assert "get_grafana_asset_demand_summary" in context_sql
    assert "latest_valid_demand_kw" in context_sql
    assert "active_power_kw" not in context_sql

    profile = panels["Demand Profile"]
    profile_sql = profile["targets"][0]["rawSql"]

    assert "v_grafana_asset_demand_intervals" in profile_sql
    assert "quality_status = 'VALID'" in profile_sql

    history = panels["Demand Quality History"]
    history_sql = history["targets"][0]["rawSql"]

    assert "v_grafana_asset_demand_intervals" in history_sql
    assert "quality_status" in history_sql

    assert "Demand Context" in panels


def test_asset_identity_surfaces_demand_semantics():
    dashboard = json.loads(DASHBOARD.read_text())

    demand_context = next(
        panel
        for panel in dashboard["panels"]
        if panel["title"] == "Demand Context"
    )

    sql = demand_context["targets"][0]["rawSql"]

    assert "demand_basis" in sql
    assert "selected_method" in sql
    assert "display_status" in sql
    assert "source_device_name" in sql
