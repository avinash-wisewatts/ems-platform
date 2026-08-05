from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
TEMPLATE = (ROOT / "src/templates/device_edit.html").read_text()
SCRIPT = (ROOT / "src/static/js/device-workspace.js").read_text()


def test_device_edit_renders_server_side_building_floor_space_options() -> None:
    assert "seen_buildings" in TEMPLATE
    assert 'data-building="{{ row.building_id }}"' in TEMPLATE
    assert 'data-floor="{{ row.floor_id }}"' in TEMPLATE
    assert "/static/js/device-workspace.js" in TEMPLATE


def test_device_location_cascade_uses_rendered_option_parent_ids() -> None:
    assert "editFloorCatalog" in SCRIPT
    assert "editSpaceCatalog" in SCRIPT
    assert "rebuildCatalog(" in SCRIPT
    assert "option.dataset.building" in SCRIPT
    assert "option.dataset.floor" in SCRIPT
    assert "window.deviceHierarchy" not in TEMPLATE
