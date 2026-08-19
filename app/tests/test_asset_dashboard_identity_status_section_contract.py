import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
DASHBOARD = ROOT / "grafana/dashboards/core/asset-overview.json"
CONNECTIVITY_MIGRATION = ROOT / "postgres/migrations/021_asset_raw_connectivity_context.sql"


def _dashboard():
    return json.loads(DASHBOARD.read_text())


def test_identity_status_is_one_compact_header_table_without_section_or_tile_sprawl():
    # The compact header is now a Canvas card (id 31), not a table panel
    # -- it renders labeled fields and right-aligned status lines instead
    # of table rows/columns, so table-specific options (showHeader,
    # cellHeight) no longer apply.
    d = _dashboard()
    first = d["panels"][0]
    assert first["type"] == "canvas"
    assert first["title"] == ""
    assert first["gridPos"] == {"x": 0, "y": 2, "w": 24, "h": 3}

    # A small live-datasource indicator tile now legitimately coexists at
    # y=0 (above the canvas, not a competing copy of it) -- what "no
    # sprawl" must still guarantee is that nothing else duplicates the
    # canvas's own full-width identity/status row.
    same_row_duplicates = [
        p for p in d["panels"]
        if p is not first
        and p.get("gridPos", {}) == first["gridPos"]
    ]
    assert same_row_duplicates == []


def test_compact_header_returns_one_row_with_profile_status_and_instrumentation():
    panel = _dashboard()["panels"][0]
    sql = panel["targets"][0]["rawSql"]
    for expected in (
        'AS "Asset"',
        'AS "Type"',
        'AS "Location"',
        'AS "Hierarchy"',
        'AS "Lifecycle Line"',
        'AS "Telemetry Line"',
        'AS "Last Seen Line"',
        'AS "Instrumentation Line"',
    ):
        assert expected in sql

    assert "analytics.v_grafana_asset_identity_context" in sql
    assert "analytics.get_grafana_asset_connectivity_context" in sql
    assert "analytics.v_grafana_asset_devices" in sql
    assert "relationship_type = 'PRIMARY_METER'" in sql


def test_header_connectivity_is_raw_receipt_based_not_normalization_freshness():
    sql = CONNECTIVITY_MIGRATION.read_text()
    assert "telemetry.device_raw_receipt_state" in sql
    assert "latest_raw_received_at" in sql
    assert "latest_raw_source_timestamp" in sql
    assert "'DELAYED'" in sql
    assert "'SILENT'" in sql
    assert "'RECEIVING'" in sql
    assert "telemetry.device_telemetry_state" not in sql


def test_operating_state_is_not_inferred_in_identity_header():
    sql = _dashboard()["panels"][0]["targets"][0]["rawSql"]
    assert 'AS "Operating state"' not in sql
    assert 'AS "Operating status"' not in sql
