from pathlib import Path
import json

ROOT = Path(__file__).resolve().parents[2]

MIGRATION = (
    ROOT
    / "postgres"
    / "migrations"
    / "027_reduce_demand_finalization_grace.sql"
)

DASHBOARD = (
    ROOT
    / "grafana"
    / "dashboards"
    / "core"
    / "asset-overview.json"
)


def test_demand_finalization_grace_is_five_minutes():
    sql = MIGRATION.read_text()

    assert "refresh_demand_analytics" in sql

    assert (
        "INTERVAL '5 minutes'" in sql
        or "interval '5 minutes'" in sql
        or "INTERVAL '00:05:00'" in sql
        or "interval '00:05:00'" in sql
    )

    assert "INTERVAL '10 minutes'" not in sql
    assert "interval '10 minutes'" not in sql
    assert "INTERVAL '00:10:00'" not in sql
    assert "interval '00:10:00'" not in sql


def test_latest_demand_card_uses_last_finalized_valid_demand():
    dashboard = json.loads(DASHBOARD.read_text())

    panel = next(
        p for p in dashboard["panels"]
        if p.get("id") == 201
    )

    sql = panel["targets"][0]["rawSql"]

    assert "latest_valid_demand_kw" in sql
    assert "current_demand_value" not in sql

    elements = panel["options"]["root"]["elements"]

    fixed_text = {
        e.get("config", {})
         .get("text", {})
         .get("fixed")
        for e in elements
    }

    field_text = {
        e.get("config", {})
         .get("text", {})
         .get("field")
        for e in elements
    }

    assert "Latest Demand (kW)" in fixed_text
    assert "Latest Demand" in field_text
