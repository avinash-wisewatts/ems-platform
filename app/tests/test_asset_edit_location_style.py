from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
ASSET_EDIT_TEMPLATE = (ROOT / "src/templates/asset_edit.html").read_text()
ASSET_CREATE_TEMPLATE = (ROOT / "src/templates/asset_create.html").read_text()
LOCATION_MACRO = (
    ROOT / "src/templates/components/physical_location_selector.html"
).read_text()


def test_asset_edit_location_uses_shared_macro() -> None:
    """asset_edit.html no longer hand-duplicates the location picker markup.

    It imports and calls the same components/physical_location_selector.html
    macro that asset_create.html uses, so a future field change to the
    picker only has to be made once.
    """

    assert "asset-edit-page" in ASSET_EDIT_TEMPLATE
    assert (
        'from "components/physical_location_selector.html" '
        "import physical_location_selector"
    ) in ASSET_EDIT_TEMPLATE
    assert "physical_location_selector(" in ASSET_EDIT_TEMPLATE
    assert (
        'from "components/physical_location_selector.html" '
        "import physical_location_selector"
    ) in ASSET_CREATE_TEMPLATE


def test_asset_edit_location_preserves_shared_cascade_contract() -> None:
    """The shared macro -- not a per-page copy -- carries the cascade wiring."""

    assert "data-physical-location-selector" in LOCATION_MACRO
    assert "data-location-options" in LOCATION_MACRO
    assert 'data-location-level="building"' in LOCATION_MACRO
    assert 'data-location-level="floor"' in LOCATION_MACRO
    assert 'data-location-level="space"' in LOCATION_MACRO
