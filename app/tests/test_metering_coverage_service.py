from src.metering_coverage_service import summarize_metering_coverage


def test_not_required_assets_are_excluded_from_kpi_denominator():
    summary = summarize_metering_coverage([
        {"is_coverage_in_scope": False, "coverage_status": "EXCLUDED"},
        {"is_coverage_in_scope": True, "coverage_status": "CONFIGURED"},
        {"is_coverage_in_scope": True, "coverage_status": "MISSING_DIRECT_METER"},
    ])
    assert summary == {
        "visible_assets": 3,
        "in_scope_assets": 2,
        "configured_assets": 1,
        "action_required_assets": 1,
        "excluded_assets": 1,
    }


def test_no_required_descendants_is_actionable():
    summary = summarize_metering_coverage([
        {"is_coverage_in_scope": True, "coverage_status": "NO_REQUIRED_DESCENDANTS"}
    ])
    assert summary["action_required_assets"] == 1
