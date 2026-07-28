import pytest

from src.code_generation import generate_entity_code


@pytest.mark.parametrize(
    ("name", "expected"),
    [
        ("North Ridge Energy", "NORTH_RIDGE_ENERGY"),
        ("  Hotel---Hyderabad  ", "HOTEL_HYDERABAD"),
        ("Café & Plant #2", "CAFE_PLANT_2"),
    ],
)
def test_generate_entity_code_preserves_current_format(name, expected):
    assert generate_entity_code(name) == expected


def test_generate_entity_code_returns_empty_for_invalid_name():
    assert generate_entity_code("---") == ""
