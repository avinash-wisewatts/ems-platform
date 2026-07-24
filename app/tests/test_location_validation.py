from uuid import uuid4

import pytest

from src.onboarding.location import (
    LocationStepValidationError,
    validate_location_step,
)


def empty_location_values() -> dict[str, str]:
    return {
        "existing_space_id": "",
        "building_name": "",
        "building_code": "",
        "floor_name": "",
        "floor_code": "",
        "space_name": "",
        "space_code": "",
    }


def test_site_only_location_clears_all_location_fields() -> None:
    payload = validate_location_step(
        location_mode="site_only",
        **empty_location_values(),
    )

    assert payload == {
        "mode": "SITE_ONLY",
        "existing_space_id": None,
        "building_name": None,
        "building_code": None,
        "floor_name": None,
        "floor_code": None,
        "space_name": None,
        "space_code": None,
    }


def test_existing_space_returns_only_space_identity() -> None:
    space_id = str(uuid4())
    values = empty_location_values()
    values["existing_space_id"] = space_id

    payload = validate_location_step(
        location_mode="USE_EXISTING_SPACE",
        **values,
    )

    assert payload == {
        "mode": "USE_EXISTING_SPACE",
        "existing_space_id": space_id,
        "building_name": None,
        "building_code": None,
        "floor_name": None,
        "floor_code": None,
        "space_name": None,
        "space_code": None,
    }


def test_invalid_existing_space_is_rejected() -> None:
    values = empty_location_values()
    values["existing_space_id"] = "not-a-uuid"

    with pytest.raises(
        LocationStepValidationError,
        match="Select an existing space",
    ):
        validate_location_step(
            location_mode="USE_EXISTING_SPACE",
            **values,
        )


def test_create_location_normalizes_hierarchy() -> None:
    payload = validate_location_step(
        location_mode="create_location",
        existing_space_id="",
        building_name="  Main Building  ",
        building_code=" bldg_01 ",
        floor_name="  Ground Floor  ",
        floor_code=" gf ",
        space_name="  Chiller Room  ",
        space_code=" chiller_room ",
    )

    assert payload == {
        "mode": "CREATE_LOCATION",
        "existing_space_id": None,
        "building_name": "Main Building",
        "building_code": "BLDG_01",
        "floor_name": "Ground Floor",
        "floor_code": "GF",
        "space_name": "Chiller Room",
        "space_code": "CHILLER_ROOM",
    }


@pytest.mark.parametrize(
    ("field_name", "invalid_value"),
    [
        ("building_code", "1BUILDING"),
        ("floor_code", "_GROUND"),
        ("space_code", "CHILLER-ROOM"),
    ],
)
def test_location_codes_must_follow_controlled_format(
    field_name: str,
    invalid_value: str,
) -> None:
    values = {
        "location_mode": "CREATE_LOCATION",
        "existing_space_id": "",
        "building_name": "Main Building",
        "building_code": "BUILDING",
        "floor_name": "Ground Floor",
        "floor_code": "GROUND",
        "space_name": "Chiller Room",
        "space_code": "CHILLER_ROOM",
    }
    values[field_name] = invalid_value

    with pytest.raises(
        LocationStepValidationError,
        match="must start with A-Z",
    ):
        validate_location_step(**values)


@pytest.mark.parametrize(
    ("field_name", "message"),
    [
        ("building_name", "Building name is required"),
        ("floor_name", "Floor name is required"),
        ("space_name", "Space name is required"),
    ],
)
def test_created_location_requires_every_hierarchy_name(
    field_name: str,
    message: str,
) -> None:
    values = {
        "location_mode": "CREATE_LOCATION",
        "existing_space_id": "",
        "building_name": "Main Building",
        "building_code": "BUILDING",
        "floor_name": "Ground Floor",
        "floor_code": "GROUND",
        "space_name": "Chiller Room",
        "space_code": "CHILLER_ROOM",
    }
    values[field_name] = "   "

    with pytest.raises(
        LocationStepValidationError,
        match=message,
    ):
        validate_location_step(**values)
