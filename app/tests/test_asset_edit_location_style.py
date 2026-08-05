from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
TEMPLATE = (ROOT / "src/templates/asset_edit.html").read_text()
CSS = (ROOT / "src/static/css/app.css").read_text()


def test_asset_edit_location_uses_form_subsection_theme() -> None:
    assert "asset-edit-page" in TEMPLATE
    assert "form-subsection asset-location-subsection" in TEMPLATE
    assert "form-subsection-heading" in TEMPLATE
    assert ".form-subsection" in CSS


def test_asset_edit_location_preserves_shared_cascade_contract() -> None:
    assert "data-physical-location-selector" in TEMPLATE
    assert "data-location-options" in TEMPLATE
    assert 'data-location-level="building"' in TEMPLATE
    assert 'data-location-level="floor"' in TEMPLATE
    assert 'data-location-level="space"' in TEMPLATE
