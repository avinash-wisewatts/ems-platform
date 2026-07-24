"""Tests for shared administration status definitions."""

import pytest

from src.onboarding.statuses import (
    STATUS_DEFINITIONS,
    status_codes,
    status_options,
)


def test_all_story_1_1_domains_are_defined() -> None:
    assert set(STATUS_DEFINITIONS) == {
        "ORGANIZATION_LIFECYCLE",
        "SITE_LIFECYCLE",
        "ASSET_LIFECYCLE",
        "GATEWAY_LIFECYCLE",
        "DEVICE_LIFECYCLE",
        "COMMISSIONING_STATUS",
        "GRAFANA_PROVISIONING_STATUS",
        "TELEMETRY_AVAILABILITY",
        "METERING_REQUIREMENT",
        "METER_COVERAGE_STATUS",
    }


def test_definitions_contain_51_canonical_codes() -> None:
    assert sum(len(options) for options in STATUS_DEFINITIONS.values()) == 51


def test_metering_requirement_codes_are_canonical() -> None:
    assert status_codes("METERING_REQUIREMENT") == {
        "DIRECT_METER_REQUIRED",
        "DESCENDANT_COVERAGE_ALLOWED",
        "NOT_REQUIRED",
    }


def test_options_include_user_facing_text() -> None:
    for options in STATUS_DEFINITIONS.values():
        for option in options:
            assert option.code
            assert option.label
            assert option.description


def test_unknown_domain_is_rejected() -> None:
    with pytest.raises(ValueError, match="Unknown status domain"):
        status_options("NOT_A_DOMAIN")


def test_definition_mapping_is_immutable() -> None:
    with pytest.raises(TypeError):
        STATUS_DEFINITIONS["NEW_DOMAIN"] = ()
