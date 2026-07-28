import pytest
from src.relationship_management import RelationshipManagementValidationError, validate_primary_meter_replacement, validate_relationship_metadata, validate_relationship_removal
RID="12345678-1234-5678-1234-567812345678"; DID="87654321-4321-8765-4321-876543218765"
def test_metadata_normalizes_optional_fields():
    p=validate_relationship_metadata(relationship_id=RID,panel_name=" Panel A ",ct_ratio="200",phase_designation="l1")
    assert p["panel_name"]=="Panel A" and p["ct_ratio"]=="200" and p["phase_designation"]=="L1"
def test_metadata_rejects_invalid_ct_ratio():
    with pytest.raises(RelationshipManagementValidationError,match="CT ratio"): validate_relationship_metadata(relationship_id=RID,ct_ratio="0")
def test_metadata_rejects_invalid_phase():
    with pytest.raises(RelationshipManagementValidationError,match="phase"): validate_relationship_metadata(relationship_id=RID,phase_designation="X")
def test_removal_requires_reason():
    with pytest.raises(RelationshipManagementValidationError,match="reason"): validate_relationship_removal(relationship_id=RID,removal_reason=" ")
def test_replacement_normalizes_identifiers():
    p=validate_primary_meter_replacement(relationship_id=RID,replacement_device_id=DID,replacement_reason=" Failed calibration ")
    assert p["replacement_reason"]=="Failed calibration"
