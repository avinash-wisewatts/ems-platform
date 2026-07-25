import pytest

from src.asset_management import (
    AssetManagementValidationError,
    validate_asset_submission,
)


ORG_ID = "11111111-1111-4111-8111-111111111111"
SITE_ID = "22222222-2222-4222-8222-222222222222"
TYPE_ID = "33333333-3333-4333-8333-333333333333"
PARENT_ID = "44444444-4444-4444-8444-444444444444"
BUILDING_ID = "55555555-5555-4555-8555-555555555555"
FLOOR_ID = "66666666-6666-4666-8666-666666666666"
SPACE_ID = "77777777-7777-4777-8777-777777777777"


def valid_values() -> dict[str, str]:
    return {
        "organization_id": ORG_ID,
        "site_id": SITE_ID,
        "asset_name": " Main Chiller ",
        "asset_type_id": TYPE_ID,
        "lifecycle_status": " active ",
        "metering_requirement": " direct_meter_required ",
        "parent_asset_id": PARENT_ID,
        "building_id": BUILDING_ID,
        "floor_id": FLOOR_ID,
        "space_id": SPACE_ID,
    }


def test_validate_asset_submission_normalizes_values() -> None:
    assert validate_asset_submission(**valid_values()) == {
        "organization_id": ORG_ID,
        "site_id": SITE_ID,
        "asset_name": "Main Chiller",
        "asset_type_id": TYPE_ID,
        "lifecycle_status": "ACTIVE",
        "metering_requirement": "DIRECT_METER_REQUIRED",
        "parent_asset_id": PARENT_ID,
        "building_id": BUILDING_ID,
        "floor_id": FLOOR_ID,
        "space_id": SPACE_ID,
    }


def test_validate_asset_submission_allows_optional_links() -> None:
    values = valid_values()
    values.update(
        {
            "parent_asset_id": "",
            "building_id": "",
            "floor_id": "",
            "space_id": "",
        }
    )

    result = validate_asset_submission(**values)

    assert result["asset_type_id"] == TYPE_ID
    assert result["parent_asset_id"] is None
    assert result["building_id"] is None
    assert result["floor_id"] is None
    assert result["space_id"] is None


@pytest.mark.parametrize(
    ("field", "value", "message"),
    [
        (
            "organization_id",
            "",
            "Organization is required.",
        ),
        (
            "site_id",
            "",
            "Site is required.",
        ),
        (
            "asset_name",
            "",
            "Asset name is required.",
        ),
        (
            "asset_type_id",
            "invalid",
            "Select a valid asset type.",
        ),
        (
            "lifecycle_status",
            "REGISTERED",
            "Select a valid asset lifecycle status.",
        ),
        (
            "metering_requirement",
            "OPTIONAL",
            "Select a valid metering requirement.",
        ),
    ],
)
def test_validate_asset_submission_rejects_invalid_values(
    field: str,
    value: str,
    message: str,
) -> None:
    values = valid_values()
    values[field] = value

    with pytest.raises(
        AssetManagementValidationError,
        match=message,
    ):
        validate_asset_submission(**values)


def test_validate_asset_submission_requires_floor_for_space() -> None:
    values = valid_values()
    values["floor_id"] = ""

    with pytest.raises(
        AssetManagementValidationError,
        match="A selected space requires its floor.",
    ):
        validate_asset_submission(**values)


def test_validate_asset_submission_requires_building_for_floor() -> None:
    values = valid_values()
    values["building_id"] = ""
    values["space_id"] = ""

    with pytest.raises(
        AssetManagementValidationError,
        match="A selected floor requires its building.",
    ):
        validate_asset_submission(**values)
