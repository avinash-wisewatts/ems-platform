import json
from pathlib import Path


DASHBOARD = (
    Path(__file__).resolve().parents[2]
    / "grafana"
    / "dashboards"
    / "core"
    / "asset-overview.json"
)


def load_dashboard():
    return json.loads(DASHBOARD.read_text())


def test_asset_identity_is_one_full_width_canvas():
    dashboard = load_dashboard()

    panel = next(
        p for p in dashboard["panels"]
        if p.get("id") == 31
    )

    assert panel["type"] == "canvas"
    assert panel["gridPos"] == {
        "x": 0,
        "y": 2,
        "w": 24,
        "h": 3,
    }

    assert not any(
        p.get("id") == 41
        for p in dashboard["panels"]
    )


def test_asset_identity_canvas_preserves_left_identity_fields():
    dashboard = load_dashboard()

    panel = next(
        p for p in dashboard["panels"]
        if p.get("id") == 31
    )

    elements = {
        e["name"]: e
        for e in panel["options"]["root"]["elements"]
    }

    assert elements["asset-name"]["config"]["text"]["field"] == "Asset"
    assert elements["type-value"]["config"]["text"]["field"] == "Type"
    assert elements["location-value"]["config"]["text"]["field"] == "Location"
    assert elements["hierarchy-value"]["config"]["text"]["field"] == "Hierarchy"


def test_asset_status_lines_share_one_right_edge():
    dashboard = load_dashboard()

    panel = next(
        p for p in dashboard["panels"]
        if p.get("id") == 31
    )

    elements = {
        e["name"]: e
        for e in panel["options"]["root"]["elements"]
    }

    # last-seen-line is no longer rendered as its own canvas element (see
    # test_asset_last_seen_uses_single_query_no_live_stream); the three
    # status lines that remain must still share one right edge.
    names = (
        "lifecycle-line",
        "telemetry-line",
        "instrumentation-line",
    )

    right_edges = set()

    for name in names:
        element = elements[name]

        assert element["type"] == "metric-value"
        assert element["config"]["align"] == "right"

        placement = element["placement"]

        right_edges.add(
            placement["left"] + placement["width"]
        )

    assert len(right_edges) == 1


def test_asset_status_is_rendered_as_complete_single_lines():
    dashboard = load_dashboard()

    panel = next(
        p for p in dashboard["panels"]
        if p.get("id") == 31
    )

    sql = panel["targets"][0]["rawSql"]

    # "Last Seen Line" is still computed by the query (raw data stays
    # available) even though it is no longer bound to a canvas element --
    # see test_asset_last_seen_uses_single_query_no_live_stream.
    assert 'AS "Lifecycle Line"' in sql
    assert 'AS "Telemetry Line"' in sql
    assert 'AS "Last Seen Line"' in sql
    assert 'AS "Instrumentation Line"' in sql

    elements = {
        e["name"]: e
        for e in panel["options"]["root"]["elements"]
    }

    assert (
        elements["lifecycle-line"]["config"]["text"]["field"]
        == "Lifecycle Line"
    )
    assert (
        elements["telemetry-line"]["config"]["text"]["field"]
        == "Telemetry Line"
    )
    assert (
        elements["instrumentation-line"]["config"]["text"]["field"]
        == "Instrumentation Line"
    )
    assert "last-seen-line" not in elements


def test_asset_last_seen_uses_single_query_no_live_stream():
    # The dual-datasource live-stream design (a separate
    # wisewatts-live-datasource target feeding a dedicated
    # "last-seen-line" element) has been removed. The canvas now runs a
    # single postgres query (refId A) computing "Last Seen Line" as
    # ordinary raw/receipt-based data; no live-stream target and no
    # bound canvas element for it exist.
    dashboard = load_dashboard()

    panel = next(
        p for p in dashboard["panels"]
        if p.get("id") == 31
    )

    assert panel["datasource"] == {
        "type": "grafana-postgresql-datasource",
        "uid": "ems-timescaledb",
    }

    targets = {
        target["refId"]: target
        for target in panel["targets"]
    }

    assert set(targets) == {"A"}

    assert (
        targets["A"]["datasource"]["uid"]
        == "ems-timescaledb"
    )

    assert '"Last Seen Line"' in targets["A"]["rawSql"]

    elements = {
        e["name"]: e
        for e in panel["options"]["root"]["elements"]
    }

    assert "last-seen-line" not in elements
