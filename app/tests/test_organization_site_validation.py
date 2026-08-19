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
        "timezone": "Asia/Kolkata",
        "lifecycle_status": "ACTIVE",
        "legal_name": "",
        "locale": "en-US",
        "primary_contact": {"name": "", "email": "", "phone": ""},
        "address": {
            "line1": "",
            "line2": "",
            "city": "",
            "region": "",
            "postal_code": "",
            "country": "",
        },
        "notes": "",
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
        "timezone": None,
        "lifecycle_status": None,
        "legal_name": None,
        "locale": None,
        "primary_contact": None,
        "address": None,
        "notes": None,
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
    sub_sector_id = str(uuid4())

    payload = validate_site_step(
        site_mode="create_new",
        existing_site_id="",
        site_name="  Hyderabad Hotel  ",
        site_code=" hyd_hotel ",
        site_timezone=" Asia/Kolkata ",
        site_address="  Hyderabad, Telangana  ",
        organization_mode="CREATE_NEW",
        sub_sector_id=f" {sub_sector_id} ",
    )

    assert payload == {
        "mode": "CREATE_NEW",
        "existing_site_id": None,
        "name": "Hyderabad Hotel",
        "code": "HYD_HOTEL",
        "timezone": "Asia/Kolkata",
        "telemetry_capture_interval_seconds": 60,
        "address": {
            "full_address": "Hyderabad, Telangana",
        },
        "sub_sector_id": sub_sector_id,
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
        sub_sector_id=str(uuid4()),
    )

    assert payload["address"] == {}


def test_create_new_site_requires_sub_sector() -> None:
    with pytest.raises(
        SiteStepValidationError,
        match="Select a sub-sector.",
    ):
        validate_site_step(
            site_mode="CREATE_NEW",
            existing_site_id="",
            site_name="Hyderabad Hotel",
            site_code="HYD_HOTEL",
            site_timezone="Asia/Kolkata",
            site_address="",
            organization_mode="CREATE_NEW",
            sub_sector_id="",
        )


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
        "telemetry_capture_interval_seconds": 60,
        "sub_sector_id": None,
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
