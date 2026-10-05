import pytest

from src.asset_point_assignment import (
    AssetPointAssignmentValidationError,
    validate_asset_point_assignment_submission,
)

ASSET = "11111111-1111-1111-1111-111111111111"
DEVICE = "22222222-2222-2222-2222-222222222222"
POINT_A = "33333333-3333-3333-3333-333333333333"
POINT_B = "44444444-4444-4444-4444-444444444444"


def test_valid_submission_normalizes_ids_and_friendly_names():
    result = validate_asset_point_assignment_submission(
        asset_id=ASSET,
        device_id=DEVICE,
        checked_logical_point_ids=[POINT_A, POINT_B],
        friendly_names={POINT_A: " Main Active Power ", POINT_B: "Reactive Power L1"},
    )
    assert result["asset_id"] == ASSET
    assert result["device_id"] == DEVICE
    assert result["confirmed_points"] == [
        {"logical_point_id": POINT_A, "friendly_name": "Main Active Power"},
        {"logical_point_id": POINT_B, "friendly_name": "Reactive Power L1"},
    ]


def test_empty_payload_is_valid():
    result = validate_asset_point_assignment_submission(
        asset_id=ASSET, device_id=DEVICE, checked_logical_point_ids=[], friendly_names={}
    )
    assert result["confirmed_points"] == []


def test_friendly_name_handling_blank_and_whitespace_normalize_to_none():
    result = validate_asset_point_assignment_submission(
        asset_id=ASSET,
        device_id=DEVICE,
        checked_logical_point_ids=[POINT_A, POINT_B],
        friendly_names={POINT_A: "", POINT_B: "   "},
    )
    assert result["confirmed_points"] == [
        {"logical_point_id": POINT_A, "friendly_name": None},
        {"logical_point_id": POINT_B, "friendly_name": None},
    ]


def test_friendly_name_handling_missing_key_defaults_to_none():
    result = validate_asset_point_assignment_submission(
        asset_id=ASSET, device_id=DEVICE, checked_logical_point_ids=[POINT_A], friendly_names={}
    )
    assert result["confirmed_points"] == [
        {"logical_point_id": POINT_A, "friendly_name": None}
    ]


def test_malformed_asset_id_rejected():
    with pytest.raises(AssetPointAssignmentValidationError, match="Asset is required"):
        validate_asset_point_assignment_submission(
            asset_id="not-a-uuid", device_id=DEVICE, checked_logical_point_ids=[], friendly_names={}
        )


def test_malformed_device_id_rejected():
    with pytest.raises(AssetPointAssignmentValidationError, match="Device is required"):
        validate_asset_point_assignment_submission(
            asset_id=ASSET, device_id="", checked_logical_point_ids=[], friendly_names={}
        )


def test_malformed_checked_point_id_rejected():
    with pytest.raises(AssetPointAssignmentValidationError, match="Data point is required"):
        validate_asset_point_assignment_submission(
            asset_id=ASSET,
            device_id=DEVICE,
            checked_logical_point_ids=[POINT_A, "<script>not-a-uuid"],
            friendly_names={},
        )


def test_duplicate_checked_point_ids_silently_deduplicated():
    result = validate_asset_point_assignment_submission(
        asset_id=ASSET,
        device_id=DEVICE,
        checked_logical_point_ids=[POINT_A, POINT_A],
        friendly_names={POINT_A: "Main Active Power"},
    )
    assert result["confirmed_points"] == [
        {"logical_point_id": POINT_A, "friendly_name": "Main Active Power"}
    ]
