from uuid import uuid4

import pytest

from src.onboarding.organization import (
    OrganizationStepValidationError,
    validate_organization_step,
)
from src.onboarding.site import (
    SiteStepValidationError,
    validate_site_step,
)


def test_create_organization_normalizes_values() -> None:
    payload = validate_organization_step(
        organization_mode="create_new",
        existing_organization_id="",
        organization_name="  WiseWatts Demo  ",
        organization_code=" wise_watts_01 ",
        organization_description="  Demo organization  ",
    )

    assert payload == {
        "mode": "CREATE_NEW",
        "existing_organization_id": None,
        "name": "WiseWatts Demo",
        "code": "WISE_WATTS_01",
        "description": "Demo organization",
    }


def test_blank_organization_description_becomes_none() -> None:
    payload = validate_organization_step(
        organization_mode="CREATE_NEW",
        existing_organization_id="",
        organization_name="WiseWatts Demo",
        organization_code="WISEWATTS",
        organization_description="   ",
    )

    assert payload["description"] is None


@pytest.mark.parametrize(
    "code",
    [
        "WISE-WATTS",
        "WISE WATTS",
        "WISE.WATTS",
        "WISE/WATTS",
    ],
)
def test_invalid_organization_code_is_rejected(
    code: str,
) -> None:
    with pytest.raises(
        OrganizationStepValidationError,
        match="may contain only",
    ):
        validate_organization_step(
            organization_mode="CREATE_NEW",
            existing_organization_id="",
            organization_name="WiseWatts",
            organization_code=code,
            organization_description="",
        )


def test_existing_organization_returns_only_identity() -> None:
    organization_id = str(uuid4())

    payload = validate_organization_step(
        organization_mode="USE_EXISTING",
        existing_organization_id=organization_id,
        organization_name="Ignored",
        organization_code="IGNORED",
        organization_description="Ignored",
    )

    assert payload == {
        "mode": "USE_EXISTING",
        "existing_organization_id": organization_id,
        "name": None,
        "code": None,
        "description": None,
    }


def test_invalid_existing_organization_id_is_rejected() -> None:
    with pytest.raises(
        OrganizationStepValidationError,
        match="Select an existing organization",
    ):
        validate_organization_step(
            organization_mode="USE_EXISTING",
            existing_organization_id="not-a-uuid",
            organization_name="",
            organization_code="",
            organization_description="",
        )


def test_create_site_normalizes_values() -> None:
    payload = validate_site_step(
        site_mode="create_new",
        existing_site_id="",
        site_name="  Hyderabad Hotel  ",
        site_code=" hyd_hotel ",
        site_timezone=" Asia/Kolkata ",
        site_address="  Hyderabad, Telangana  ",
        organization_mode="CREATE_NEW",
    )

    assert payload == {
        "mode": "CREATE_NEW",
        "existing_site_id": None,
        "name": "Hyderabad Hotel",
        "code": "HYD_HOTEL",
        "timezone": "Asia/Kolkata",
        "address": {
            "full_address": "Hyderabad, Telangana",
        },
    }


def test_blank_site_address_becomes_empty_object() -> None:
    payload = validate_site_step(
        site_mode="CREATE_NEW",
        existing_site_id="",
        site_name="Hyderabad Hotel",
        site_code="HYD_HOTEL",
        site_timezone="Asia/Kolkata",
        site_address="   ",
        organization_mode="CREATE_NEW",
    )

    assert payload["address"] == {}


def test_new_organization_cannot_use_existing_site() -> None:
    with pytest.raises(
        SiteStepValidationError,
        match="new organization cannot use an existing site",
    ):
        validate_site_step(
            site_mode="USE_EXISTING",
            existing_site_id=str(uuid4()),
            site_name="",
            site_code="",
            site_timezone="",
            site_address="",
            organization_mode="CREATE_NEW",
        )


def test_existing_organization_can_use_existing_site() -> None:
    site_id = str(uuid4())

    payload = validate_site_step(
        site_mode="USE_EXISTING",
        existing_site_id=site_id,
        site_name="Ignored",
        site_code="IGNORED",
        site_timezone="Ignored",
        site_address="Ignored",
        organization_mode="USE_EXISTING",
    )

    assert payload == {
        "mode": "USE_EXISTING",
        "existing_site_id": site_id,
        "name": None,
        "code": None,
        "timezone": None,
        "address": None,
    }


@pytest.mark.parametrize(
    "code",
    [
        "HYD-HOTEL",
        "HYD HOTEL",
        "HYD.HOTEL",
    ],
)
def test_invalid_site_code_is_rejected(
    code: str,
) -> None:
    with pytest.raises(
        SiteStepValidationError,
        match="may contain only",
    ):
        validate_site_step(
            site_mode="CREATE_NEW",
            existing_site_id="",
            site_name="Hyderabad Hotel",
            site_code=code,
            site_timezone="Asia/Kolkata",
            site_address="",
            organization_mode="USE_EXISTING",
        )
