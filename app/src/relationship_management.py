"""Validation for independent asset-device relationship administration."""

from decimal import Decimal, InvalidOperation
from uuid import UUID

RELATIONSHIP_TYPES = (
    "PRIMARY_METER", "SECONDARY_METER", "TEMPERATURE_SENSOR",
    "PRESSURE_SENSOR", "FLOW_SENSOR", "VIBRATION_SENSOR",
    "RUN_STATUS", "FAULT_STATUS", "STATUS_INPUT",
)
PHASE_DESIGNATIONS = ("", "L1", "L2", "L3", "N", "L1_L2", "L2_L3", "L3_L1", "THREE_PHASE")

class RelationshipManagementValidationError(ValueError):
    """Invalid relationship administration submission."""

def _uuid(value: str, label: str) -> str:
    try:
        return str(UUID(value.strip()))
    except (ValueError, AttributeError) as exc:
        raise RelationshipManagementValidationError(f"{label} is required.") from exc

def _text(value: str, label: str, maximum: int) -> str | None:
    normalized = value.strip()
    if len(normalized) > maximum:
        raise RelationshipManagementValidationError(f"{label} must not exceed {maximum} characters.")
    return normalized or None

def validate_relationship_submission(*, asset_id: str, device_id: str, relationship_type: str) -> dict[str, str]:
    relationship = relationship_type.strip().upper()
    if relationship not in RELATIONSHIP_TYPES:
        raise RelationshipManagementValidationError("Select a valid controlled relationship type.")
    return {"asset_id": _uuid(asset_id, "Asset"), "device_id": _uuid(device_id, "Device"), "relationship_type": relationship}

def validate_relationship_metadata(*, relationship_id: str, panel_name: str = "", feeder_name: str = "", breaker_identifier: str = "", channel_identifier: str = "", ct_ratio: str = "", phase_designation: str = "", mounting_point: str = "", engineering_notes: str = "") -> dict:
    phase = phase_designation.strip().upper()
    if phase not in PHASE_DESIGNATIONS:
        raise RelationshipManagementValidationError("Select a valid phase designation.")
    ratio = None
    if ct_ratio.strip():
        try:
            ratio = Decimal(ct_ratio.strip())
        except InvalidOperation as exc:
            raise RelationshipManagementValidationError("CT ratio must be a positive number.") from exc
        if ratio <= 0 or ratio > Decimal("100000"):
            raise RelationshipManagementValidationError("CT ratio must be greater than zero and no more than 100000.")
    return {
        "relationship_id": _uuid(relationship_id, "Relationship"),
        "panel_name": _text(panel_name, "Panel", 120),
        "feeder_name": _text(feeder_name, "Feeder", 120),
        "breaker_identifier": _text(breaker_identifier, "Breaker identifier", 120),
        "channel_identifier": _text(channel_identifier, "Channel identifier", 120),
        "ct_ratio": str(ratio) if ratio is not None else None,
        "phase_designation": phase or None,
        "mounting_point": _text(mounting_point, "Mounting point", 200),
        "engineering_notes": _text(engineering_notes, "Engineering notes", 2000),
    }

def validate_relationship_removal(*, relationship_id: str, removal_reason: str) -> dict[str, str]:
    reason = removal_reason.strip()
    if not reason:
        raise RelationshipManagementValidationError("Removal reason is required.")
    if len(reason) > 500:
        raise RelationshipManagementValidationError("Removal reason must not exceed 500 characters.")
    return {"relationship_id": _uuid(relationship_id, "Relationship"), "removal_reason": reason}

def validate_primary_meter_replacement(*, relationship_id: str, replacement_device_id: str, replacement_reason: str) -> dict[str, str]:
    reason = replacement_reason.strip()
    if not reason:
        raise RelationshipManagementValidationError("Replacement reason is required.")
    if len(reason) > 500:
        raise RelationshipManagementValidationError("Replacement reason must not exceed 500 characters.")
    return {"relationship_id": _uuid(relationship_id, "Relationship"), "replacement_device_id": _uuid(replacement_device_id, "Replacement device"), "replacement_reason": reason}
