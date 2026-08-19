import inspect
from pathlib import Path

import src.location_management as location_management
from src.location_management import validate_site_submission
from src.onboarding.site import validate_site_step


ORG_ID = "11111111-1111-1111-1111-111111111111"
SUB_SECTOR_ID = "55555555-5555-5555-5555-555555555555"


def test_legacy_site_sectors_constant_is_removed():
    assert not hasattr(location_management, "SITE_SECTORS")


def test_validate_site_submission_no_longer_accepts_legacy_sector():
    assert "site_sector" not in inspect.signature(validate_site_submission).parameters
    assert "sub_sector_id" in inspect.signature(validate_site_submission).parameters


def test_validate_site_submission_requires_sub_sector():
    result = validate_site_submission(
        organization_id=ORG_ID, site_name="Hospital", site_code="HOSPITAL",
        site_timezone="Asia/Kolkata", lifecycle_status="ACTIVE",
        sub_sector_id=SUB_SECTOR_ID,
    )
    assert result["sub_sector_id"] == SUB_SECTOR_ID
    assert "sector_code" not in result


def test_validate_site_step_no_longer_accepts_legacy_sector():
    assert "site_sector" not in inspect.signature(validate_site_step).parameters


def test_onboarding_site_step_no_longer_returns_sector_code():
    result = validate_site_step(
        site_mode="CREATE_NEW", existing_site_id="", site_name="Plant",
        site_code="PLANT", site_timezone="Asia/Kolkata", site_address="",
        organization_mode="CREATE_NEW", sub_sector_id=SUB_SECTOR_ID,
    )
    assert "sector_code" not in result
    assert result["sub_sector_id"] == SUB_SECTOR_ID


def test_onboarding_site_step_requires_sub_sector_for_new_sites():
    assert "sub_sector_id" in inspect.signature(validate_site_step).parameters


def test_forms_no_longer_expose_legacy_sector_field():
    root = Path(__file__).parents[1]
    for template in (
        "src/templates/site_create.html",
        "src/templates/site_edit.html",
        "src/templates/onboarding/site.html",
    ):
        assert 'name="site_sector"' not in (root / template).read_text()


def test_forms_expose_cascading_sector_sub_sector_dropdowns():
    root = Path(__file__).parents[1]
    for template in (
        "src/templates/site_create.html",
        "src/templates/site_edit.html",
        "src/templates/onboarding/site.html",
    ):
        contents = (root / template).read_text()
        assert 'id="sector_id"' in contents
        assert 'name="sub_sector_id"' in contents
