import pytest

from src.location_management import (
    LocationManagementValidationError,
    validate_building_submission,
    validate_floor_submission,
    validate_site_submission,
    validate_space_submission,
)


ORG_ID = "11111111-1111-1111-1111-111111111111"
SITE_ID = "22222222-2222-2222-2222-222222222222"
BUILDING_ID = "33333333-3333-3333-3333-333333333333"
FLOOR_ID = "44444444-4444-4444-4444-444444444444"
SUB_SECTOR_ID = "55555555-5555-5555-5555-555555555555"


def test_validate_site_submission_normalizes_values() -> None:
    assert validate_site_submission(
        organization_id=f" {ORG_ID} ",
        site_name=" Main Site ",
        site_code=" main_site ",
        site_timezone="Europe/London",
        lifecycle_status=" active ",
        sub_sector_id=SUB_SECTOR_ID,
    ) == {
        "organization_id": ORG_ID,
        "name": "Main Site",
        "code": "MAIN_SITE",
        "timezone": "Europe/London",
        "lifecycle_status": "ACTIVE",
        "telemetry_capture_interval_seconds": 60,
        "sub_sector_id": SUB_SECTOR_ID,
    }


@pytest.mark.parametrize(
    ("field", "value", "message"),
    [
        (
            "organization_id",
            "",
            "Organization is required.",
        ),
        (
            "site_name",
            "",
            "Site name is required.",
        ),
        (
            "site_code",
            "site-code",
            (
                "Site code must start with A-Z and contain only "
                "A-Z, 0-9, and underscore."
            ),
        ),
        (
            "site_timezone",
            "Not/A_Timezone",
            "Site timezone must be a valid IANA timezone.",
        ),
        (
            "lifecycle_status",
            "UNKNOWN",
            "Select a valid lifecycle status.",
        ),
    ],
)
def test_validate_site_submission_rejects_invalid_values(
    field: str,
    value: str,
    message: str,
) -> None:
    values = {
        "organization_id": ORG_ID,
        "site_name": "Main Site",
        "site_code": "MAIN_SITE",
        "site_timezone": "Europe/London",
        "lifecycle_status": "ACTIVE",
        "sub_sector_id": SUB_SECTOR_ID,
    }
    values[field] = value

    with pytest.raises(
        LocationManagementValidationError,
        match=message,
    ):
        validate_site_submission(**values)


@pytest.mark.parametrize(
    ("validator", "kwargs", "expected"),
    [
        (
            validate_building_submission,
            {
                "site_id": SITE_ID,
                "building_name": " Building A ",
                "building_code": " building_a ",
            },
            {
                "site_id": SITE_ID,
                "name": "Building A",
                "code": "BUILDING_A",
            },
        ),
        (
            validate_floor_submission,
            {
                "building_id": BUILDING_ID,
                "floor_name": " First Floor ",
                "floor_code": " floor_1 ",
            },
            {
                "building_id": BUILDING_ID,
                "name": "First Floor",
                "code": "FLOOR_1",
            },
        ),
        (
            validate_space_submission,
            {
                "floor_id": FLOOR_ID,
                "space_name": " Plant Room ",
                "space_code": " plant_room ",
            },
            {
                "floor_id": FLOOR_ID,
                "name": "Plant Room",
                "code": "PLANT_ROOM",
            },
        ),
    ],
)
def test_validate_location_submissions(
    validator,
    kwargs: dict[str, str],
    expected: dict[str, str],
) -> None:
    assert validator(**kwargs) == expected


@pytest.mark.parametrize(
    "lifecycle_status",
    [
        "DRAFT",
        "ACTIVE",
        "INACTIVE",
        "DECOMMISSIONED",
    ],
)
def test_validate_site_submission_accepts_canonical_statuses(
    lifecycle_status: str,
) -> None:
    result = validate_site_submission(
        organization_id=ORG_ID,
        site_name="Main Site",
        site_code="MAIN_SITE",
        site_timezone="Europe/London",
        lifecycle_status=lifecycle_status,
        sub_sector_id=SUB_SECTOR_ID,
    )

    assert result["lifecycle_status"] == lifecycle_status


def test_validate_site_submission_rejects_organization_only_status() -> None:
    with pytest.raises(
        LocationManagementValidationError,
        match="Select a valid lifecycle status.",
    ):
        validate_site_submission(
            organization_id=ORG_ID,
            site_name="Main Site",
            site_code="MAIN_SITE",
            site_timezone="Europe/London",
            lifecycle_status="SUSPENDED",
            sub_sector_id=SUB_SECTOR_ID,
        )
