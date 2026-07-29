from uuid import uuid4

import pytest

from src.onboarding.asset import (
    AssetStepValidationError,
    allowed_relationships,
    validate_asset_step,
)


@pytest.mark.parametrize(
    ("category", "expected"),
    [
        (
            "Energy Meter",
            [
                "PRIMARY_METER",
                "SECONDARY_METER",
            ],
        ),
        (
            "Environmental Sensor",
            [
                "TEMPERATURE_SENSOR",
                "HUMIDITY_SENSOR",
            ],
        ),
        (
            "Digital Input Module",
            [
                "STATUS_INPUT",
                "RUN_STATUS",
                "FAULT_STATUS",
            ],
        ),
        (
            "PLC",
            [
                "STATUS_INPUT",
                "RUN_STATUS",
                "FAULT_STATUS",
                "CONTROLLER",
            ],
        ),
        ("Unknown Category", []),
    ],
)
def test_allowed_relationships_are_ordered(
    category: str,
    expected: list[str],
) -> None:
    assert allowed_relationships(category) == expected


def valid_asset_values() -> dict[str, str]:
    return {
        "asset_mode": "CREATE_NEW",
        "existing_asset_id": "",
        "asset_name": "Chiller 1",
        "asset_external_id": "CHILLER_1",
        "asset_type_id": str(uuid4()),
        "metering_requirement": "direct_meter_required",
        "relationship_type": "primary_meter",
        "operational_notes": "Main chiller energy meter",
        "device_category_name": "Energy Meter",
        "organization_mode": "CREATE_NEW",
        "site_mode": "CREATE_NEW",
    }


def test_create_asset_normalizes_relationship_and_metadata() -> None:
    values = valid_asset_values()

    payload = validate_asset_step(**values)

    assert payload == {
        "mode": "CREATE_NEW",
        "existing_asset_id": None,
        "name": "Chiller 1",
        "external_id": "CHILLER_1",
        "asset_type_id": values["asset_type_id"],
        "metering_requirement": "DIRECT_METER_REQUIRED",
        "relationship_type": "PRIMARY_METER",
        "metadata": {
            "operational_notes": "Main chiller energy meter",
        },
    }


def test_blank_operational_notes_produce_empty_metadata() -> None:
    values = valid_asset_values()
    values["operational_notes"] = "   "

    payload = validate_asset_step(**values)

    assert payload["metadata"] == {}


def test_relationship_must_match_device_category() -> None:
    values = valid_asset_values()
    values.update(
        {
            "device_category_name": "Temperature Sensor",
            "relationship_type": "PRIMARY_METER",
        }
    )

    with pytest.raises(
        AssetStepValidationError,
        match="not valid for device category",
    ):
        validate_asset_step(**values)


def test_unknown_device_category_fails_closed() -> None:
    values = valid_asset_values()
    values["device_category_name"] = "Unknown Category"

    with pytest.raises(
        AssetStepValidationError,
        match="No asset relationship rules are configured",
    ):
        validate_asset_step(**values)


def test_existing_asset_requires_existing_parents() -> None:
    values = valid_asset_values()
    values.update(
        {
            "asset_mode": "USE_EXISTING",
            "existing_asset_id": str(uuid4()),
            "organization_mode": "CREATE_NEW",
            "site_mode": "CREATE_NEW",
        }
    )

    with pytest.raises(
        AssetStepValidationError,
        match="both the organization and site already exist",
    ):
        validate_asset_step(**values)


def test_existing_asset_preserves_relationship_only() -> None:
    asset_id = str(uuid4())
    values = valid_asset_values()
    values.update(
        {
            "asset_mode": "USE_EXISTING",
            "existing_asset_id": asset_id,
            "organization_mode": "USE_EXISTING",
            "site_mode": "USE_EXISTING",
        }
    )

    payload = validate_asset_step(**values)

    assert payload == {
        "mode": "USE_EXISTING",
        "existing_asset_id": asset_id,
        "name": None,
        "external_id": None,
        "asset_type_id": None,
        "metering_requirement": None,
        "relationship_type": "PRIMARY_METER",
        "metadata": {},
    }


def test_invalid_asset_type_id_is_rejected() -> None:
    values = valid_asset_values()
    values["asset_type_id"] = "not-a-uuid"

    with pytest.raises(
        AssetStepValidationError,
        match="Select an asset type",
    ):
        validate_asset_step(**values)


def test_operational_notes_length_is_enforced() -> None:
    values = valid_asset_values()
    values["operational_notes"] = "x" * 2001

    with pytest.raises(
        AssetStepValidationError,
        match="must not exceed 2,000 characters",
    ):
        validate_asset_step(**values)

def test_metering_requirement_is_required_for_new_asset() -> None:
    values = valid_asset_values()
    values["metering_requirement"] = "   "

    with pytest.raises(
        AssetStepValidationError,
        match="Select how this asset must obtain energy-meter coverage",
    ):
        validate_asset_step(**values)


def test_invalid_metering_requirement_is_rejected() -> None:
    values = valid_asset_values()
    values["metering_requirement"] = "PARTIAL_COVERAGE"

    with pytest.raises(
        AssetStepValidationError,
        match="Select how this asset must obtain energy-meter coverage",
    ):
        validate_asset_step(**values)


@pytest.mark.parametrize(
    ("submitted", "expected"),
    [
        ("direct_meter_required", "DIRECT_METER_REQUIRED"),
        (
            "descendant_coverage_allowed",
            "DESCENDANT_COVERAGE_ALLOWED",
        ),
        ("not_required", "NOT_REQUIRED"),
    ],
)
def test_metering_requirement_is_normalized(
    submitted: str,
    expected: str,
) -> None:
    values = valid_asset_values()
    values["metering_requirement"] = submitted

    payload = validate_asset_step(**values)

    assert payload["metering_requirement"] == expected
