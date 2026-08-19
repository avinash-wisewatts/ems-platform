import json
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]

DASHBOARD = (
    ROOT
    / "grafana"
    / "dashboards"
    / "core"
    / "analytics-explorer.json"
)


def _dashboard():
    return json.loads(DASHBOARD.read_text())


def _panel(panel_id):
    return next(
        p for p in _dashboard()["panels"]
        if p["id"] == panel_id
    )


def test_analytics_explorer_never_uses_sqlstring_for_multiselects():
    sql = _panel(5)["targets"][0]["rawSql"]

    assert "${Asset:sqlstring}" not in sql
    assert "${Metric:sqlstring}" not in sql


def test_analytics_explorer_uses_safeguarded_explorer_intervals_contract():
    sql = _panel(5)["targets"][0]["rawSql"]

    assert "analytics.get_grafana_explorer_intervals" in sql
    assert "${Asset:singlequote}" in sql
    assert "${Metric:singlequote}" in sql
    assert "::uuid[]" in sql
    assert "::text[]" in sql


def test_analytics_explorer_resolves_readable_legend_labels():
    # The function only returns asset_id/logical_point_id UUIDs -- the
    # panel must resolve human-readable names via the grafana_reader-
    # granted selector views rather than showing raw GUIDs in the legend.
    sql = _panel(5)["targets"][0]["rawSql"]

    assert "analytics.v_grafana_asset_selector" in sql
    assert "analytics.v_grafana_asset_point_selector" in sql


def test_analytics_explorer_has_no_legacy_panels_or_short_history_usage():
    # The legacy Selected-point trends / Selection summary / Point
    # catalogue panels and their get_grafana_short_history queries were
    # retired once the safeguarded explorer panel (id 5) replaced them.
    # Site/Location/AssetType were later restored as optional drill-down
    # narrowing filters feeding the Asset dropdown -- they are not a
    # revival of the old required/blocking site_id chain. The status
    # banner (id 6) was added and then removed again, and the EMS
    # Navigation text panel (id 1) plus its dashboard-level link were
    # removed too -- panel 5 is now the dashboard's only panel.
    d = _dashboard()

    panel_ids = {p["id"] for p in d["panels"]}
    assert panel_ids == {5}

    dashboard_text = json.dumps(d)
    assert "get_grafana_short_history" not in dashboard_text


def test_cascading_variables_precede_asset_and_metric():
    names = [v["name"] for v in _dashboard()["templating"]["list"]]

    assert names == ["Site", "Location", "AssetType", "Asset", "Metric"]


def test_site_location_asset_type_are_optional_single_select_narrowing_filters():
    # Unlike the retired site_id variable (required by
    # get_grafana_short_history), Site/Location/AssetType are pure UX
    # narrowing aids for the Asset dropdown -- get_grafana_explorer_intervals
    # never takes a site_id. All three must default to "no filter", not
    # block anything.
    d = _dashboard()

    for name, sentinel_text in (
        ("Site", "— All sites —"),
        ("Location", "— All locations —"),
        ("AssetType", "— All asset types —"),
    ):
        variable = next(
            v for v in d["templating"]["list"]
            if v["name"] == name
        )
        assert variable["multi"] is False
        assert variable["includeAll"] is False
        assert variable["current"] == {
            "selected": True,
            "text": sentinel_text,
            "value": "",
        }
        assert f"'{sentinel_text}' AS __text, '' AS __value" in variable["query"]


def test_asset_query_cascades_through_site_location_asset_type():
    variable = next(
        v for v in _dashboard()["templating"]["list"]
        if v["name"] == "Asset"
    )
    query = variable["query"]

    assert "analytics.v_grafana_asset_selector" in query
    assert "${Site:raw}" in query
    assert "${Location:raw}" in query
    assert "${AssetType:raw}" in query


def test_location_cascades_from_site_and_asset_type_cascades_from_both():
    d = _dashboard()

    location = next(
        v for v in d["templating"]["list"] if v["name"] == "Location"
    )
    assert "${Site:raw}" in location["query"]

    asset_type = next(
        v for v in d["templating"]["list"] if v["name"] == "AssetType"
    )
    assert "${Site:raw}" in asset_type["query"]
    assert "${Location:raw}" in asset_type["query"]


def test_panel_5_does_not_reference_cascading_filter_variables():
    # Directive: Panel 5's SQL must stay untouched -- it only ever
    # consumes the final ${Asset:singlequote} / ${Metric:singlequote}
    # arrays, never Site/Location/AssetType directly.
    sql = _panel(5)["targets"][0]["rawSql"]

    assert "${Site" not in sql
    assert "${Location" not in sql
    assert "${AssetType" not in sql


def test_safeguarded_panel_is_full_width_at_the_top():
    # The status banner (id 6) and the EMS Navigation panel/link (id 1)
    # were both added and later removed -- panel 5 is the dashboard's
    # only panel, occupying the full top of the grid.
    panel = _panel(5)
    grid = panel["gridPos"]

    assert grid["x"] == 0
    assert grid["y"] == 0
    assert grid["w"] == 24


def test_no_dashboard_level_links_or_nav_panel():
    d = _dashboard()

    assert d["links"] == []
    assert all(p["title"] != "EMS Navigation" for p in d["panels"])


def test_panel_5_computes_energy_interval_delta_via_lag():
    # recommended_aggregation='delta' for energy points means the raw
    # numeric_value is a cumulative register (confirmed against migration
    # 172's own comment and real device data), so avg_value alone is
    # meaningless for energy -- interval consumption must come from
    # diffing consecutive max_value readings, clamped so a counter reset
    # shows 0 instead of a spurious negative spike.
    sql = _panel(5)["targets"][0]["rawSql"]

    assert "ILIKE '%ENERGY%'" in sql
    assert "LAG(max_value)" in sql
    assert "PARTITION BY asset_name, logical_point_name" in sql
    assert "GREATEST(" in sql
    assert "avg_value" in sql  # still used for the non-energy ELSE branch


def test_panel_5_case_guards_asset_and_metric_arrays_against_the_five_item_limit():
    # Same >5 threshold as the safeguard function itself and the status
    # banner -- a selection over the limit must fall back to an empty
    # array client-side so the query returns zero rows instead of
    # reaching analytics.get_grafana_explorer_intervals's RAISE EXCEPTION.
    sql = _panel(5)["targets"][0]["rawSql"]

    assert sql.count("CASE") >= 2
    assert "<= 5" in sql
    assert "ELSE ARRAY[]::uuid[]" in sql
    assert "ELSE ARRAY[]::text[]" in sql
    assert "analytics.v_grafana_asset_selector" in sql
    assert "analytics.v_grafana_asset_point_selector" in sql


def test_asset_and_metric_variables_default_to_empty_multiselect():
    # Deferred-execution UX: nothing selected by default, so
    # analytics.get_grafana_explorer_intervals's own empty/NULL-array
    # guard blocks the query until the user picks something -- no
    # collapsed row needed.
    d = _dashboard()

    for name in ("Asset", "Metric"):
        variable = next(
            v for v in d["templating"]["list"]
            if v["name"] == name
        )
        assert variable["multi"] is True
        assert variable["includeAll"] is False
        assert variable["current"] == {
            "selected": False,
            "text": [],
            "value": [],
        }


def _override_properties(panel, regex_options):
    override = next(
        o for o in panel["fieldConfig"]["overrides"]
        if o["matcher"]["id"] == "byRegexp"
        and o["matcher"]["options"] == regex_options
    )
    return {p["id"]: p["value"] for p in override["properties"]}


def test_panel_5_uses_real_bidirectional_watt_unit_not_fixed_kilowatt():
    # 'kw'/'kwatt' would assume the raw value is already in kilowatts and
    # only ever scale upward. telemetry.normalized_points.numeric_value is
    # natively in watts (verified via device physics earlier this
    # session -- the same investigation that caught assets rendering as
    # MW/MWh due to this exact class of unit-ID mistake). 'watt' is the
    # bidirectional SI-prefixed unit: it displays as W for small values
    # and automatically scales to kW/MW for large ones, without
    # misinterpreting the raw magnitude.
    props = _override_properties(_panel(5), ".*POWER.*")

    assert props["unit"] == "watt"
    assert props["unit"] not in ("kw", "kwatt")


def test_panel_5_power_regex_does_not_break_power_factor_unit():
    # .*POWER.* also matches POWER_FACTOR fields. Grafana applies
    # byRegexp overrides in array order with later matches overwriting
    # earlier ones for the same property, so POWER_FACTOR's own
    # percentunit override must appear after the generic Power override.
    overrides = _panel(5)["fieldConfig"]["overrides"]
    regexes = [o["matcher"]["options"] for o in overrides]

    assert regexes.index(".*POWER.*") < regexes.index(".*POWER_FACTOR.*")

    pf_props = _override_properties(_panel(5), ".*POWER_FACTOR.*")
    assert pf_props["unit"] == "percentunit"


def test_panel_5_temperature_and_humidity_route_to_right_axis():
    for regex in (".*TEMPERATURE.*", ".*HUMIDITY.*"):
        props = _override_properties(_panel(5), regex)
        assert props["custom.axisPlacement"] == "right"

    temp = _override_properties(_panel(5), ".*TEMPERATURE.*")
    assert temp["unit"] == "celsius"

    humidity = _override_properties(_panel(5), ".*HUMIDITY.*")
    assert humidity["unit"] == "percent"


def test_panel_5_illuminance_unaffected_by_humidity_split():
    # Humidity and Illuminance used to share one combined regex/rule.
    # Splitting them for the new Humidity-specific right-axis routing
    # must not silently drop illuminance unit handling.
    props = _override_properties(_panel(5), ".*ILLUMINANCE.*")

    assert props["unit"] == "percent"
    assert "custom.axisPlacement" not in props


def test_panel_5_voltage_and_current_units():
    voltage = _override_properties(_panel(5), ".*VOLTAGE.*")
    assert voltage["unit"] == "volt"

    current = _override_properties(_panel(5), ".*CURRENT.*")
    assert current["unit"] == "amp"


def test_panel_5_tooltip_and_legend_use_real_schema_values():
    # Grafana's timeseries panel schema has no tooltip mode literally
    # called "shared" -- the value that produces a shared/multi-series
    # tooltip is "multi". Verified against the working tooltip/legend
    # blocks already live on asset-overview.json's timeseries panels.
    options = _panel(5)["options"]

    assert options["tooltip"]["mode"] == "multi"

    legend = options["legend"]
    assert legend["displayMode"] == "table"
    assert legend["placement"] == "bottom"
    assert "max" in legend["calcs"]
    assert "mean" in legend["calcs"]
