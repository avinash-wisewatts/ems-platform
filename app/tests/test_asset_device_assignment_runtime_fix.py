from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


def test_relationship_type_lookup_uses_granted_reference_table_only():
    source = (ROOT / "app/src/relationship_management_service.py").read_text()
    function = source.split("async def list_relationship_types()", 1)[1].split(
        "async def list_accessible_relationships", 1
    )[0]
    assert "config.asset_device_relationship_types" in function
    assert "asset_device_relationship_category_compatibility" not in function
