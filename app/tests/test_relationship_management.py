import pytest
from src.relationship_management import RELATIONSHIP_TYPES, RelationshipManagementValidationError, validate_relationship_submission

ASSET="11111111-1111-1111-1111-111111111111"
DEVICE="22222222-2222-2222-2222-222222222222"

def test_initial_controlled_relationship_types():
    assert RELATIONSHIP_TYPES == ("PRIMARY_METER","SECONDARY_METER","TEMPERATURE_SENSOR","PRESSURE_SENSOR","FLOW_SENSOR","VIBRATION_SENSOR","RUN_STATUS","FAULT_STATUS","STATUS_INPUT")

def test_relationship_submission_normalizes_type():
    assert validate_relationship_submission(asset_id=ASSET,device_id=DEVICE,relationship_type=" primary_meter ")["relationship_type"] == "PRIMARY_METER"

def test_free_text_relationship_type_rejected():
    with pytest.raises(RelationshipManagementValidationError,match="controlled relationship"):
        validate_relationship_submission(asset_id=ASSET,device_id=DEVICE,relationship_type="custom")

def test_asset_is_required():
    with pytest.raises(RelationshipManagementValidationError,match="Asset is required"):
        validate_relationship_submission(asset_id="",device_id=DEVICE,relationship_type="STATUS_INPUT")
