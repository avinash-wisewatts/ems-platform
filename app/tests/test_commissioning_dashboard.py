from src.commissioning_dashboard_service import (
    COMMISSIONING_STATUSES,
    build_commissioning_dashboard,
)


def test_dashboard_groups_every_required_status_and_enriches_blockers():
    result = build_commissioning_dashboard([
        {
            "entity_type": "DEVICE",
            "entity_id": "device-1",
            "entity_name": "Meter 1",
            "organization_id": "org-1",
            "site_id": "site-1",
            "lifecycle_status": "REGISTERED",
            "commissioning_status": "BLOCKED",
            "blocking_reason_codes": ["DEVICE_PROFILE_REQUIRED"],
            "warning_reason_codes": [],
        }
    ])
    assert tuple(result["groups"]) == COMMISSIONING_STATUSES
    assert result["counts"]["BLOCKED"] == 1
    row = result["groups"]["BLOCKED"][0]
    assert row["correction_href"] == "/administration/devices"
    assert "Select a device profile" in row["actionable_blockers"][0]["guidance"]


def test_dashboard_filters_by_scope_and_type():
    rows = [
        {"entity_type": "ASSET", "organization_id": "org-1", "site_id": "site-1", "commissioning_status": "READY"},
        {"entity_type": "GATEWAY", "organization_id": "org-2", "site_id": "site-2", "commissioning_status": "READY"},
    ]
    result = build_commissioning_dashboard(
        rows, organization_id="org-1", site_id="site-1", entity_type="ASSET"
    )
    assert result["total"] == 1
    assert result["counts"]["READY"] == 1
