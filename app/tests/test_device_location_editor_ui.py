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
    rebuild_position = SCRIPT.index("else rebuildEditFloors({ preserve: true });")
    mode_position = SCRIPT.index("updateLocationMode();", rebuild_position)
    assert rebuild_position < mode_position
    assert "if (disabled) select.value = '';" not in SCRIPT


def test_device_location_rerender_uses_submitted_field_names() -> None:
    assert "form_data.get('device_location_building_id'" in TEMPLATE
    assert "form_data.get('device_location_floor_id'" in TEMPLATE
    assert "form_data.get('device_location_space_id'" in TEMPLATE
