import json
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]

DASHBOARD = (
    ROOT
    / "grafana"
    / "dashboards"
    / "core"
    / "asset-overview.json"
)


def _variables():
    dashboard = json.loads(DASHBOARD.read_text())
    return dashboard["templating"]["list"]


def test_asset_selector_order_is_site_location_type_asset():
    names = [v["name"] for v in _variables()]

    assert names.index("site_id") < names.index("location_key")
    assert names.index("location_key") < names.index("asset_type_id")
    assert names.index("asset_type_id") < names.index("asset_id")


def test_location_selector_is_tenant_and_site_scoped():
    location = next(
        v for v in _variables()
        if v["name"] == "location_key"
    )

    query = location["query"]

    assert location["label"] == "Location"
    assert location["includeAll"] is True
    assert location["allValue"] == "__all"

    assert "analytics.v_grafana_asset_selector" in query
    assert "grafana_org_id = ${__org.id}" in query
    assert "$site_id" in query
    assert "location_path AS __text" in query
    assert "location_key AS __value" in query


def test_asset_type_selector_cascades_from_location():
    asset_type = next(
        v for v in _variables()
        if v["name"] == "asset_type_id"
    )

    query = asset_type["query"]

    assert asset_type["label"] == "Asset Type"
    assert asset_type["includeAll"] is True
    assert asset_type["allValue"] == "__all"

    assert "analytics.v_grafana_asset_selector" in query
    assert "$site_id" in query
    assert "${location_key:raw}" in query
    assert "asset_type_id::text AS __value" in query


def test_asset_selector_cascades_from_location_and_type():
    asset = next(
        v for v in _variables()
        if v["name"] == "asset_id"
    )

    query = asset["query"]

    assert asset["label"] == "Asset"
    assert asset["includeAll"] is False

    assert "analytics.v_grafana_asset_selector" in query
    assert "$site_id" in query
    assert "${location_key:raw}" in query
    assert "${asset_type_id:raw}" in query

    # Asset identity remains UUID-based.
    assert "asset_id::text AS __value" in query
