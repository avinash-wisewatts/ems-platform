from pathlib import Path

from jinja2 import Environment, FileSystemLoader


TEMPLATE_ROOT = Path("app/src/templates")


def render_selector(**context) -> str:
    environment = Environment(
        loader=FileSystemLoader(TEMPLATE_ROOT),
        autoescape=True,
    )
    template = environment.get_template(
        "components/physical_location_selector.html"
    )

    return template.module.physical_location_selector(
        context["field_prefix"],
        context["hierarchy_rows"],
        context.get("selected_site_id", ""),
        context.get("selected_building_id", ""),
        context.get("selected_floor_id", ""),
        context.get("selected_space_id", ""),
        context.get("required_site", True),
    )


def hierarchy_rows() -> list[dict]:
    return [
        {
            "organization_id": (
                "11111111-1111-4111-8111-111111111111"
            ),
            "organization_code": "ORG_1",
            "organization_name": "Organization One",
            "site_id": "22222222-2222-4222-8222-222222222222",
            "site_code": "SITE_1",
            "site_name": "Main Site",
            "building_id": (
                "33333333-3333-4333-8333-333333333333"
            ),
            "building_code": "BUILDING_A",
            "building_name": "Building A",
            "floor_id": "44444444-4444-4444-8444-444444444444",
            "floor_code": "FLOOR_1",
            "floor_name": "First Floor",
            "space_id": "55555555-5555-4555-8555-555555555555",
            "space_code": "PLANT_ROOM",
            "space_name": "Plant Room",
        }
    ]


def test_selector_renders_site_and_hierarchy_data() -> None:
    rendered = render_selector(
        field_prefix="asset_location",
        hierarchy_rows=hierarchy_rows(),
    )

    assert 'name="asset_location_site_id"' in rendered
    assert 'name="asset_location_building_id"' in rendered
    assert 'name="asset_location_floor_id"' in rendered
    assert 'name="asset_location_space_id"' in rendered
    assert 'name="asset_location_location_id"' in rendered

    assert "Organization One" in rendered
    assert "Main Site" in rendered
    assert "Building A" in rendered
    assert "First Floor" in rendered
    assert "Plant Room" in rendered


def test_selector_prefers_most_specific_selected_location() -> None:
    rendered = render_selector(
        field_prefix="device_location",
        hierarchy_rows=hierarchy_rows(),
        selected_site_id="22222222-2222-4222-8222-222222222222",
        selected_building_id=(
            "33333333-3333-4333-8333-333333333333"
        ),
        selected_floor_id="44444444-4444-4444-8444-444444444444",
        selected_space_id="55555555-5555-4555-8555-555555555555",
    )

    assert (
        'data-selected-value="'
        '33333333-3333-4333-8333-333333333333"'
    ) in rendered
    assert (
        'data-selected-value="'
        '44444444-4444-4444-8444-444444444444"'
    ) in rendered
    assert (
        'data-selected-value="'
        '55555555-5555-4555-8555-555555555555"'
    ) in rendered
    assert (
        'value="55555555-5555-4555-8555-555555555555"'
    ) in rendered


def test_selector_can_make_site_optional() -> None:
    rendered = render_selector(
        field_prefix="gateway_location",
        hierarchy_rows=hierarchy_rows(),
        required_site=False,
    )

    site_select = rendered.split(
        'data-location-level="site"',
        1,
    )[1].split("</select>", 1)[0]

    assert "required" not in site_select


def test_locations_page_loads_selector_controller() -> None:
    template = Path(
        "app/src/templates/locations.html"
    ).read_text()

    assert (
        "components/physical_location_selector.html"
        in template
    )
    assert "physical_location_selector(" in template
    assert "physical-location-selector.js" in template


def test_selector_controller_uses_most_specific_value() -> None:
    script = Path(
        "app/src/static/js/physical-location-selector.js"
    ).read_text()

    normalized_script = " ".join(script.split())

    assert (
        "space.value || floor.value "
        "|| building.value || site.value"
    ) in normalized_script
    assert 'data-location-level="site"' in script
    assert 'data-location-level="building"' in script
    assert 'data-location-level="floor"' in script
    assert 'data-location-level="space"' in script
