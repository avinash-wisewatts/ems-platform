from pathlib import Path
import json

ROOT = Path(__file__).resolve().parents[2]
MIGRATION = ROOT / "postgres/migrations/019_asset_dashboard_consolidated_read_path_fix.sql"
DDL = ROOT / "postgres/ddl/138_asset_dashboard_consolidated_read_path_fix.sql"
DASHBOARD = ROOT / "grafana/dashboards/core/asset-overview.json"


def _dashboard():
    return json.loads(DASHBOARD.read_text())


def _panels_by_title():
    return {
        p["title"]: p
        for p in _dashboard()["panels"]
        if p.get("title")
    }


def _panel_by_id(panel_id):
    return next(
        p for p in _dashboard()["panels"]
        if p.get("id") == panel_id
    )


def test_019_migration_matches_canonical_mirror():
    assert MIGRATION.exists()
    assert DDL.exists()
    assert MIGRATION.read_text() == DDL.read_text()


def test_019_keeps_config_private_and_exposes_parameterized_read_contracts():
    sql = MIGRATION.read_text().lower()

    assert "security definer" in sql
    assert "get_grafana_asset_telemetry_context" in sql
    assert "get_grafana_asset_demand_summary" in sql
    assert "get_grafana_asset_energy_intervals" in sql

    assert "grant usage on schema config" not in sql
    assert "grant select on all tables in schema config" not in sql

    assert "energy_measurements_device_bucket_start_idx" in sql


def test_asset_dashboard_energy_panels_use_parameterized_asset_read_contract():
    panels = _panels_by_title()

    # Total Energy is now the compact Canvas summary card.
    total_energy = _panel_by_id(39)
    sql = total_energy["targets"][0]["rawSql"]

    assert "get_grafana_asset_energy_intervals" in sql
    assert "v_grafana_asset_energy_intervals" not in sql
    assert "v_energy_consumption_1min" not in sql
    assert "v_energy_consumption_5min" not in sql
    assert "v_energy_consumption_15min" not in sql

    # Energy Consumption Trend now reads through the canonical energy
    # reader directly (fixed native/strict resolution) rather than the
    # dynamic-routing single-asset wrapper.
    sql = panels["Energy Consumption Trend"]["targets"][0]["rawSql"]
    assert "get_canonical_energy_read" in sql
    assert "'native'" in sql
    assert "'strict'" in sql
    assert "v_grafana_asset_energy_intervals" not in sql
    assert "v_energy_consumption_1min" not in sql
    assert "v_energy_consumption_5min" not in sql
    assert "v_energy_consumption_15min" not in sql

    # Client-facing energy performance uses one consolidated Canvas
    # query for Total Energy, Previous Period and Change. Do not
    # reintroduce three duplicate executions of the single-asset energy
    # interval function across separate panels. (Panel 211 is no longer
    # this panel -- it's now the unrelated "Equipment / Condition
    # Metrics" row header, and ids 212/213 were reused by unrelated
    # condition-metrics/alarms panels, so this checks the function's
    # total call count across the whole dashboard instead of pinning to
    # ids that have since been reassigned.)
    dashboard = _dashboard()

    def _walk(panels):
        for p in panels:
            yield p
            if "panels" in p:
                yield from _walk(p["panels"])

    energy_targets = [
        target
        for panel in _walk(dashboard["panels"])
        for target in panel.get("targets", [])
        if "get_grafana_asset_energy_intervals" in target.get("rawSql", "")
    ]

    assert len(energy_targets) == 1

    sql = energy_targets[0]["rawSql"]
    assert "v_grafana_asset_energy_intervals" not in sql

    assert '"Total Energy"' in sql
    assert '"Previous Period"' in sql
    assert '"Change Signed"' in sql


def test_asset_dashboard_uses_explicit_fast_demand_and_connectivity_contracts():
    panels = _panels_by_title()

    # The former Demand status / Current demand stat panels were consolidated
    # into Demand Context. Demand Context is the canonical summary surface.
    sql = panels["Demand Context"]["targets"][0]["rawSql"]
    assert "get_grafana_asset_demand_summary" in sql
    assert "display_status" in sql
    assert "latest_valid_demand_kw" in sql

    header = _dashboard()["panels"][0]
    telemetry_sql = header["targets"][0]["rawSql"]

    assert "get_grafana_asset_connectivity_context" in telemetry_sql
    assert "get_grafana_asset_telemetry_context" not in telemetry_sql


def test_automatic_asset_policy_is_defensively_backfilled():
    sql = MIGRATION.read_text()
    assert "'ASSET'" in sql
    assert "'ACTIVE_POWER_KW'" in sql
    assert "900" in sql
    assert "NOT EXISTS" in sql
