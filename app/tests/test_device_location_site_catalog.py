from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
TEMPLATE = (ROOT / "src/templates/device_edit.html").read_text()
LOCATION_PICKER = (ROOT / "src/static/js/location-picker.js").read_text()
DEVICE_WORKSPACE = (ROOT / "src/static/js/device-workspace.js").read_text()


def test_device_edit_uses_shared_location_picker_json_catalog() -> None:
    """device_edit.html no longer hand-pre-renders building/floor/space
    options in Jinja. It delegates to the same [data-physical-location-selector]
    + <script type="application/json" data-location-options> contract that
    gateway and asset forms use, populated by the shared location-picker.js.
    """

    assert "data-physical-location-selector" in TEMPLATE
    assert "data-location-options" in TEMPLATE
    assert 'data-location-level="building"' in TEMPLATE
    assert 'data-location-level="floor"' in TEMPLATE
    assert 'data-location-level="space"' in TEMPLATE
    assert "/static/js/location-picker.js" in TEMPLATE
    assert "/static/js/device-workspace.js" in TEMPLATE
    assert "window.deviceHierarchy" not in TEMPLATE
    assert "seen_buildings" not in TEMPLATE
    assert "seen_floors" not in TEMPLATE
    assert "seen_spaces" not in TEMPLATE

    # location-picker.js's <script> tag must precede device-workspace.js's:
    # device-workspace.js relies on the selects already being populated by
    # the time its own change listeners and init code run.
    picker_index = TEMPLATE.index("/static/js/location-picker.js")
    workspace_index = TEMPLATE.index("/static/js/device-workspace.js")
    assert picker_index < workspace_index


def test_device_location_cascade_lives_in_shared_location_picker() -> None:
    """The Building -> Floor -> Space cascade is owned by location-picker.js,
    not duplicated inside device-workspace.js anymore."""

    assert "data-location-options" in LOCATION_PICKER
    assert 'data-location-level="building"' in LOCATION_PICKER
    assert 'data-location-level="floor"' in LOCATION_PICKER
    assert 'data-location-level="space"' in LOCATION_PICKER

    assert "editFloorCatalog" not in DEVICE_WORKSPACE
    assert "editSpaceCatalog" not in DEVICE_WORKSPACE
    assert "rebuildEditFloors" not in DEVICE_WORKSPACE
    assert "rebuildEditSpaces" not in DEVICE_WORKSPACE
    assert "rebuildBuildings" not in DEVICE_WORKSPACE
