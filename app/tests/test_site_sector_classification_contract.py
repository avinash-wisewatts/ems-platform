from pathlib import Path

from src.location_management import SITE_SECTORS, validate_site_submission
from src.onboarding.site import validate_site_step


def test_site_sector_catalog_is_controlled():
    assert SITE_SECTORS == (
        "HOSPITALITY", "HEALTHCARE", "MANUFACTURING", "RETAIL",
        "FOOD&BEVERAGE", "COMMERCIAL", "EDUCATION", "DATA CENTER", "OTHER",
    )

def test_standalone_site_validation_preserves_sector():
    result = validate_site_submission(organization_id="11111111-1111-1111-1111-111111111111", site_name="Hospital", site_code="HOSPITAL", site_timezone="Asia/Kolkata", lifecycle_status="ACTIVE", site_sector="HEALTHCARE")
    assert result["sector_code"] == "HEALTHCARE"

def test_onboarding_site_validation_preserves_sector():
    result = validate_site_step(site_mode="CREATE_NEW", existing_site_id="", site_name="Plant", site_code="PLANT", site_timezone="Asia/Kolkata", site_sector="MANUFACTURING", site_address="", organization_mode="CREATE_NEW")
    assert result["sector_code"] == "MANUFACTURING"

def test_forms_expose_sector_selection():
    root = Path(__file__).parents[1]
    assert 'name="site_sector"' in (root / "src/templates/site_create.html").read_text()
    assert 'name="site_sector"' in (root / "src/templates/onboarding/site.html").read_text()
