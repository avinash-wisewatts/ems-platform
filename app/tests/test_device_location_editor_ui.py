from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
TEMPLATE = (ROOT / "src/templates/device_edit.html").read_text()
SCRIPT = (ROOT / "src/static/js/device-workspace.js").read_text()
CSS = (ROOT / "src/static/css/app.css").read_text()


def test_device_location_editor_uses_large_aligned_checkbox() -> None:
    assert "device-location-inherit-checkbox" in TEMPLATE
    assert "device-location-inherit-control" in TEMPLATE
    assert "width: 1.25rem !important" in CSS


def test_device_location_catalog_is_built_before_inheritance_is_applied() -> None:
    """The Building/Floor/Space catalog must be populated before the
    "inherit from gateway" disabled state is applied, so the fields never
    flash empty-then-disabled. Catalog population now happens in
    location-picker.js, which the template loads before device-workspace.js
    (see test_device_location_site_catalog.py); device-workspace.js's own
    init runs updateLocationMode() as its last step, after that catalog is
    already in place.
    """

    init_block = SCRIPT.split("syncExternalId();", 1)[1]
    init_calls = [
        line.strip()
        for line in init_block.splitlines()
        if line.strip().endswith("();")
        and not line.strip().startswith("}")
    ]
    assert init_calls[-1] == "updateLocationMode();"
    assert "if (disabled) select.value = '';" not in SCRIPT


def test_device_location_rerender_uses_submitted_field_names() -> None:
    assert "form_data.get('device_location_building_id'" in TEMPLATE
    assert "form_data.get('device_location_floor_id'" in TEMPLATE
    assert "form_data.get('device_location_space_id'" in TEMPLATE
