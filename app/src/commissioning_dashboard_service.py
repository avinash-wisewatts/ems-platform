"""Commissioning dashboard presentation helpers."""

from collections.abc import Iterable
from typing import Any

COMMISSIONING_STATUSES = (
    "NOT_STARTED",
    "IN_PROGRESS",
    "BLOCKED",
    "READY",
    "COMMISSIONED",
    "FAILED",
)
ENTITY_TYPES = ("ASSET", "GATEWAY", "DEVICE")

BLOCKER_GUIDANCE = {
    "ASSET_DECOMMISSIONED": "Review the asset lifecycle; decommissioned assets cannot be commissioned.",
    "METERING_POLICY_MISSING": "Select an asset metering policy.",
    "QUALIFYING_PRIMARY_METER_REQUIRED": "Assign a qualifying primary meter to the asset.",
    "GATEWAY_DECOMMISSIONED": "Review the gateway lifecycle; decommissioned gateways cannot be commissioned.",
    "GATEWAY_IDENTITY_MISSING": "Add a valid gateway external identity.",
    "GATEWAY_MODEL_MISSING": "Select a gateway model.",
    "GATEWAY_NEVER_SEEN": "Confirm connectivity and wait for the gateway to communicate.",
    "GATEWAY_CONNECTIVITY_OFFLINE": "Restore gateway connectivity within the configured online threshold.",
    "DEVICE_DECOMMISSIONED": "Review the device lifecycle; decommissioned devices cannot be commissioned.",
    "GATEWAY_REQUIRED": "Assign the device to a gateway.",
    "DEVICE_MODEL_REQUIRED": "Select a device model.",
    "DEVICE_PROFILE_REQUIRED": "Select a device profile.",
    "PROFILE_CATEGORY_INCOMPATIBLE": "Choose a profile compatible with the device model category.",
    "REQUIRED_TELEMETRY_POINTS_NOT_VALIDATED": "Validate all telemetry points required by the selected profile.",
    "ASSET_ASSIGNMENT_REQUIRED_BY_POLICY": "Assign the device to an asset or change its operational policy.",
}

CORRECTION_LINKS = {
    "ASSET": "/administration/assets",
    "GATEWAY": "/administration/gateways",
    "DEVICE": "/administration/devices",
}


def build_commissioning_dashboard(
    rows: Iterable[dict[str, Any]],
    *,
    organization_id: str | None = None,
    site_id: str | None = None,
    entity_type: str | None = None,
) -> dict[str, Any]:
    """Filter, enrich, and group readiness rows for dashboard rendering."""

    normalized_entity_type = entity_type.upper() if entity_type else None
    grouped = {status: [] for status in COMMISSIONING_STATUSES}

    for source_row in rows:
        row = dict(source_row)
        if organization_id and str(row.get("organization_id")) != organization_id:
            continue
        if site_id and str(row.get("site_id")) != site_id:
            continue
        if normalized_entity_type and row.get("entity_type") != normalized_entity_type:
            continue

        status = row.get("commissioning_status") or "NOT_STARTED"
        if status not in grouped:
            status = "NOT_STARTED"
        row["commissioning_status"] = status
        row["correction_href"] = CORRECTION_LINKS.get(row.get("entity_type"), "/administration")
        row["actionable_blockers"] = [
            {
                "code": code,
                "guidance": BLOCKER_GUIDANCE.get(code, "Review and correct this readiness condition."),
            }
            for code in (row.get("blocking_reason_codes") or [])
        ]
        grouped[status].append(row)

    for status_rows in grouped.values():
        status_rows.sort(
            key=lambda item: (
                item.get("entity_type") or "",
                (item.get("entity_name") or "").casefold(),
            )
        )

    return {
        "groups": grouped,
        "counts": {status: len(grouped[status]) for status in COMMISSIONING_STATUSES},
        "total": sum(len(status_rows) for status_rows in grouped.values()),
    }
