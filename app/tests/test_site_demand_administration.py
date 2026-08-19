import pytest

from src.location_management import (
    DEMAND_LATE_ARRIVAL_TOLERANCE_SECONDS,
    DEMAND_MINIMUM_COVERAGE_PERCENT,
    LocationManagementValidationError,
    validate_site_demand_submission,
)


def test_site_demand_defaults_are_platform_managed() -> None:
    result = validate_site_demand_submission(
        demand_monitoring_enabled="on",
        demand_interval_seconds="900",
        demand_basis="ACTIVE_POWER_KW",
        site_demand_source_role="GRID_IMPORT",
    )

    assert result == {
        "is_enabled": True,
        "demand_interval_seconds": 900,
        "demand_basis": "ACTIVE_POWER_KW",
        "site_demand_source_role": "GRID_IMPORT",
        "minimum_coverage_percent": DEMAND_MINIMUM_COVERAGE_PERCENT,
        "late_arrival_tolerance_seconds":
            DEMAND_LATE_ARRIVAL_TOLERANCE_SECONDS,
    }

    assert result["minimum_coverage_percent"] == 90.0
    assert result["late_arrival_tolerance_seconds"] == 30


def test_site_demand_checkbox_absence_means_disabled() -> None:
    result = validate_site_demand_submission(
        demand_monitoring_enabled=None,
        demand_interval_seconds="900",
        demand_basis="ACTIVE_POWER_KW",
        site_demand_source_role="GRID_IMPORT",
    )

    assert result["is_enabled"] is False


@pytest.mark.parametrize("interval", ["10", "60", "300", "600", "3600"])
def test_site_demand_rejects_unsupported_intervals(interval: str) -> None:
    with pytest.raises(
        LocationManagementValidationError,
        match="Demand interval must be 15 or 30 minutes",
    ):
        validate_site_demand_submission(
            demand_monitoring_enabled="on",
            demand_interval_seconds=interval,
            demand_basis="ACTIVE_POWER_KW",
            site_demand_source_role="GRID_IMPORT",
        )


@pytest.mark.parametrize(
    "basis",
    ["POWER", "KW", "KVA", "ENERGY_KWH"],
)
def test_site_demand_rejects_invalid_basis(basis: str) -> None:
    with pytest.raises(
        LocationManagementValidationError,
        match="Select a valid demand basis",
    ):
        validate_site_demand_submission(
            demand_monitoring_enabled="on",
            demand_interval_seconds="900",
            demand_basis=basis,
            site_demand_source_role="GRID_IMPORT",
        )


@pytest.mark.parametrize(
    "source",
    ["SOLAR_GENERATION", "GENERATOR_OUTPUT", "LOAD_SUBMETER"],
)
def test_site_demand_rejects_ineligible_sources(source: str) -> None:
    with pytest.raises(
        LocationManagementValidationError,
        match="Select a valid site demand source",
    ):
        validate_site_demand_submission(
            demand_monitoring_enabled="on",
            demand_interval_seconds="900",
            demand_basis="ACTIVE_POWER_KW",
            site_demand_source_role=source,
        )


def test_site_demand_accepts_30_min_kva_site_consumption() -> None:
    result = validate_site_demand_submission(
        demand_monitoring_enabled="true",
        demand_interval_seconds="1800",
        demand_basis="APPARENT_POWER_KVA",
        site_demand_source_role="SITE_CONSUMPTION",
    )

    assert result["is_enabled"] is True
    assert result["demand_interval_seconds"] == 1800
    assert result["demand_basis"] == "APPARENT_POWER_KVA"
    assert result["site_demand_source_role"] == "SITE_CONSUMPTION"


def test_site_edit_exposes_only_user_facing_demand_controls() -> None:
    from pathlib import Path

    template = Path(
        "app/src/templates/site_edit.html"
    ).read_text()

    assert 'name="demand_monitoring_enabled"' in template
    assert 'name="demand_interval_seconds"' in template
    assert 'name="demand_basis"' in template
    assert 'name="site_demand_source_role"' in template

    # Quality-control parameters remain platform managed.
    assert 'name="minimum_coverage_percent"' not in template
    assert 'name="late_arrival_tolerance_seconds"' not in template


def test_site_demand_labels_hide_internal_role_codes_from_users() -> None:
    from pathlib import Path

    template = Path(
        "app/src/templates/site_edit.html"
    ).read_text()

    assert "Utility / grid meter" in template
    assert "Total site consumption meter" in template
    assert "Active power (kW)" in template
    assert "Apparent power (kVA)" in template


def test_site_detail_displays_demand_monitoring() -> None:
    from pathlib import Path

    template = Path(
        "app/src/templates/site_detail.html"
    ).read_text()

    assert "Demand monitoring" in template
    assert "Source meter not configured" in template
    assert "Utility / grid meter" in template
    assert "Total site consumption meter" in template


def test_telemetry_storage_help_does_not_claim_normalized_full_resolution() -> None:
    from pathlib import Path

    templates = [
        "app/src/templates/site_edit.html",
        "app/src/templates/site_create.html",
        "app/src/templates/onboarding/site.html",
    ]

    for filename in templates:
        text = Path(filename).read_text()

        assert (
            "Raw and normalized telemetry remain full resolution"
            not in text
        )
        assert (
            "long-term normalized telemetry resolution"
            in text
        )


def test_site_edit_uses_demand_enabled_disabled_dropdown() -> None:
    from pathlib import Path

    template = Path(
        "app/src/templates/site_edit.html"
    ).read_text()

    assert 'name="demand_monitoring_enabled"' in template
    assert 'value="ENABLED"' in template
    assert 'value="DISABLED"' in template
    assert 'type="checkbox"' not in template[
        template.find("Demand monitoring"):
        template.find("Demand monitoring") + 1500
    ]
