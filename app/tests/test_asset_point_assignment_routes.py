from uuid import UUID

import pytest
from psycopg.errors import DatabaseError

from src.asset_point_assignment_service import AssetPointAssignmentConflictError
from src.auth.models import AuthenticatedPortalUser
from src.auth.security import AuthenticationStatus
from src.auth.service import AuthenticationResult

ASSET_ID = UUID("11111111-1111-4111-8111-111111111111")
SITE_ID = UUID("22222222-2222-4222-8222-222222222222")
DEVICE_A = UUID("33333333-3333-4333-8333-333333333333")
DEVICE_B = UUID("44444444-4444-4444-8444-444444444444")
POINT_A = UUID("55555555-5555-4555-8555-555555555555")
POINT_B = UUID("66666666-6666-4666-8666-666666666666")
AUDIT_ID = UUID("99999999-9999-4999-8999-999999999999")


def successful_platform_admin_result() -> AuthenticationResult:
    return AuthenticationResult(
        authenticated=True,
        user=AuthenticatedPortalUser(
            portal_user_id=500,
            username="admin@example.com",
            display_name="Platform Admin",
            role_code="ADMIN",
            access_scope_mode="GLOBAL",
        ),
        status=AuthenticationStatus.AUTHENTICATED,
    )


def login_platform_admin(portal_client, monkeypatch: pytest.MonkeyPatch) -> None:
    async def fake_authenticate(username: str, password: str) -> AuthenticationResult:
        return successful_platform_admin_result()

    monkeypatch.setattr("src.main.authenticate_portal_user", fake_authenticate)

    response = portal_client.post(
        "/login",
        data={
            "username": "admin@example.com",
            "password": "valid-password",
            "next_path": "/administration/assets",
        },
    )
    assert response.status_code == 303


def asset_workspace_row() -> dict:
    return {
        "asset_id": str(ASSET_ID),
        "asset_name": "Main Chiller",
        "external_id": "CH-01",
        "asset_type_name": "Chiller",
        "parent_asset_name": None,
        "organization_id": "77777777-7777-4777-8777-777777777777",
        "organization_name": "Organization One",
        "site_id": str(SITE_ID),
        "site_name": "Main Site",
        "location_path": None,
        "lifecycle_status": "COMMISSIONING",
        "metering_requirement": "DIRECT_METER_REQUIRED",
        "coverage_status": "CONFIGURED",
        "commissioning_status": "IN_PROGRESS",
        "is_ready": True,
        "blocking_reason_codes": [],
        "warning_reason_codes": [],
        "created_at": None,
        "updated_at": None,
    }


def candidate_row(
    *,
    device_id: UUID,
    device_name: str,
    logical_point_id: UUID,
    logical_point_name: str,
    is_confirmed: bool,
    friendly_name: str | None = None,
    point_category_name: str | None = "Power",
) -> dict:
    return {
        "device_id": device_id,
        "device_name": device_name,
        "relationship_type": "PRIMARY_METER",
        "relationship_type_name": "Primary Meter",
        "logical_point_id": logical_point_id,
        "logical_point_name": logical_point_name,
        "point_category_id": None,
        "point_category_name": point_category_name,
        "unit_symbol": "kW",
        "is_confirmed": is_confirmed,
        "asset_point_id": UUID("88888888-8888-4888-8888-888888888888") if is_confirmed else None,
        "friendly_name": friendly_name,
        "effective_from": None,
        "effective_to": None,
    }


def relationship_row(*, device_id: UUID = DEVICE_A, device_name: str = "Meter A") -> dict:
    """A minimally-complete admin.list_accessible_asset_device_relationships row --
    covers every field asset_detail.html's "Assigned devices" section reads."""
    return {
        "relationship_id": UUID("77777777-7777-4777-8777-777777777777"),
        "asset_id": ASSET_ID,
        "device_id": device_id,
        "device_name": device_name,
        "device_external_id": "DEV-001",
        "device_category_name": "Energy Meter",
        "relationship_type": "PRIMARY_METER",
        "relationship_name": "Primary Meter",
        "panel_name": None,
        "feeder_name": None,
        "breaker_identifier": None,
        "channel_identifier": None,
        "ct_ratio": None,
        "phase_designation": None,
        "mounting_point": None,
        "engineering_notes": None,
    }


def _stub_common_asset_detail_dependencies(
    monkeypatch: pytest.MonkeyPatch, *, relationships: list[dict] | None = None
) -> None:
    async def fake_get_asset_workspace(*, portal_user_id: int, asset_id: str) -> dict:
        return asset_workspace_row()

    async def fake_list_accessible_relationships(*, portal_user_id: int) -> list[dict]:
        return relationships if relationships is not None else []

    async def fake_list_accessible_devices(*, portal_user_id: int) -> list[dict]:
        return []

    async def fake_list_relationship_types() -> list[dict]:
        return []

    monkeypatch.setattr("src.main.get_asset_workspace", fake_get_asset_workspace)
    monkeypatch.setattr(
        "src.main.list_accessible_relationships", fake_list_accessible_relationships
    )
    monkeypatch.setattr("src.main.list_accessible_devices", fake_list_accessible_devices)
    monkeypatch.setattr("src.main.list_relationship_types", fake_list_relationship_types)


# ---------------------------------------------------------------------------
# GET /administration/assets/{asset_id} -- candidate/landing-table rendering.
# ---------------------------------------------------------------------------


def test_landing_table_shows_confirmed_points(portal_client, monkeypatch):
    login_platform_admin(portal_client, monkeypatch)
    _stub_common_asset_detail_dependencies(monkeypatch)

    async def fake_candidates(*, portal_user_id: int, asset_id: str) -> list[dict]:
        assert asset_id == str(ASSET_ID)
        return [
            candidate_row(
                device_id=DEVICE_A, device_name="Meter A",
                logical_point_id=POINT_A, logical_point_name="ACTIVE_POWER_TOTAL",
                is_confirmed=True, friendly_name="Main Active Power",
            ),
            candidate_row(
                device_id=DEVICE_A, device_name="Meter A",
                logical_point_id=POINT_B, logical_point_name="REACTIVE_POWER_L1",
                is_confirmed=False,
            ),
        ]

    async def fake_backfill_status(*, portal_user_id: int, asset_id: str) -> None:
        return None

    monkeypatch.setattr("src.main.list_asset_point_assignment_candidates", fake_candidates)
    monkeypatch.setattr(
        "src.main.get_asset_commissioning_backfill_status", fake_backfill_status
    )

    response = portal_client.get(f"/administration/assets/{ASSET_ID}")

    assert response.status_code == 200
    assert "Main Active Power" in response.text
    assert "ACTIVE_POWER_TOTAL" in response.text
    assert "Assign Data Points" not in response.text  # landing table shown, not the empty state


def test_empty_state_shown_when_device_has_unconfirmed_candidates(portal_client, monkeypatch):
    """A device is associated AND has enabled candidate points, but none are
    confirmed yet -> the "Assign Data Points" / edit-panels empty state."""
    login_platform_admin(portal_client, monkeypatch)
    _stub_common_asset_detail_dependencies(
        monkeypatch, relationships=[relationship_row(device_id=DEVICE_A, device_name="Meter A")]
    )

    async def fake_candidates(*, portal_user_id: int, asset_id: str) -> list[dict]:
        return [
            candidate_row(
                device_id=DEVICE_A, device_name="Meter A",
                logical_point_id=POINT_A, logical_point_name="ACTIVE_POWER_TOTAL",
                is_confirmed=False,
            )
        ]

    async def fake_backfill_status(*, portal_user_id: int, asset_id: str) -> None:
        return None

    monkeypatch.setattr("src.main.list_asset_point_assignment_candidates", fake_candidates)
    monkeypatch.setattr(
        "src.main.get_asset_commissioning_backfill_status", fake_backfill_status
    )

    response = portal_client.get(f"/administration/assets/{ASSET_ID}")

    assert response.status_code == 200
    assert "Assign Data Points" in response.text
    assert "No data points are assigned to this asset yet" in response.text
    assert "Edit data points" in response.text  # the panel this message refers to actually exists
    assert "No Devices Associated" not in response.text
    assert "No Data Points Available" not in response.text


def test_no_devices_associated_state(portal_client, monkeypatch):
    """An asset with zero associated devices must show its own state, never
    a message pointing at an "Edit data points" panel that does not exist."""
    login_platform_admin(portal_client, monkeypatch)
    _stub_common_asset_detail_dependencies(monkeypatch, relationships=[])

    async def fake_candidates(*, portal_user_id: int, asset_id: str) -> list[dict]:
        return []

    async def fake_backfill_status(*, portal_user_id: int, asset_id: str) -> None:
        return None

    monkeypatch.setattr("src.main.list_asset_point_assignment_candidates", fake_candidates)
    monkeypatch.setattr(
        "src.main.get_asset_commissioning_backfill_status", fake_backfill_status
    )

    response = portal_client.get(f"/administration/assets/{ASSET_ID}")

    assert response.status_code == 200
    assert "No Devices Associated" in response.text
    assert "This asset has no associated devices yet" in response.text
    # Must never reference edit panels that cannot exist without a device.
    assert "Use one of the" not in response.text
    assert "Edit data points" not in response.text
    assert "No Data Points Available" not in response.text


def test_no_data_points_available_state(portal_client, monkeypatch):
    """A device IS associated, but it has zero enabled candidate points ->
    a distinct state from "no devices" and never the contradictory
    "assign a device" message when a device already exists."""
    login_platform_admin(portal_client, monkeypatch)
    _stub_common_asset_detail_dependencies(
        monkeypatch,
        relationships=[relationship_row(device_id=DEVICE_A, device_name="Banquet AHU Meter")],
    )

    async def fake_candidates(*, portal_user_id: int, asset_id: str) -> list[dict]:
        return []  # the associated device has no enabled config.device_point_configuration rows

    async def fake_backfill_status(*, portal_user_id: int, asset_id: str) -> None:
        return None

    monkeypatch.setattr("src.main.list_asset_point_assignment_candidates", fake_candidates)
    monkeypatch.setattr(
        "src.main.get_asset_commissioning_backfill_status", fake_backfill_status
    )

    response = portal_client.get(f"/administration/assets/{ASSET_ID}")

    assert response.status_code == 200
    assert "No Data Points Available" in response.text
    assert "have no enabled data points available for assignment" in response.text
    assert "No Devices Associated" not in response.text
    # The old contradictory fallback ("Assign a device above first" when a
    # device is already associated) must be gone entirely.
    assert "Assign a device above first" not in response.text
    assert "No associated device has any enabled data points to assign" not in response.text
    assert "Use one of the" not in response.text
    assert "Edit data points" not in response.text


@pytest.mark.parametrize(
    ("status", "expected_text"),
    [
        ("PENDING", "Pending"),
        ("RUNNING", "Running"),
        ("COMPLETED", "Completed"),
        ("FAILED", "Failed"),
    ],
)
def test_backfill_status_rendered_for_each_state(
    portal_client, monkeypatch, status, expected_text
):
    login_platform_admin(portal_client, monkeypatch)
    _stub_common_asset_detail_dependencies(monkeypatch)

    async def fake_candidates(*, portal_user_id: int, asset_id: str) -> list[dict]:
        return []

    async def fake_backfill_status(*, portal_user_id: int, asset_id: str) -> dict:
        return {
            "status": status,
            "requested_at": None,
            "started_at": None,
            "completed_at": None,
            "failed_at": None,
            "attempt_count": 1,
            "last_error": "Backfill record ... has no trigger_audit_transaction_id."
            if status == "FAILED"
            else None,
        }

    monkeypatch.setattr("src.main.list_asset_point_assignment_candidates", fake_candidates)
    monkeypatch.setattr(
        "src.main.get_asset_commissioning_backfill_status", fake_backfill_status
    )

    response = portal_client.get(f"/administration/assets/{ASSET_ID}")

    assert response.status_code == 200
    assert expected_text in response.text
    if status == "FAILED":
        assert "trigger_audit_transaction_id" in response.text


def test_no_backfill_status_line_when_never_commissioned(portal_client, monkeypatch):
    login_platform_admin(portal_client, monkeypatch)
    _stub_common_asset_detail_dependencies(monkeypatch)

    async def fake_candidates(*, portal_user_id: int, asset_id: str) -> list[dict]:
        return []

    async def fake_backfill_status(*, portal_user_id: int, asset_id: str) -> None:
        return None

    monkeypatch.setattr("src.main.list_asset_point_assignment_candidates", fake_candidates)
    monkeypatch.setattr(
        "src.main.get_asset_commissioning_backfill_status", fake_backfill_status
    )

    response = portal_client.get(f"/administration/assets/{ASSET_ID}")

    assert response.status_code == 200
    assert "Historical backfill" not in response.text


# ---------------------------------------------------------------------------
# Unauthorized access -- candidates/backfill status must never be exposed.
# ---------------------------------------------------------------------------


def test_inaccessible_asset_never_fetches_candidates_or_backfill_status(
    portal_client, monkeypatch
):
    login_platform_admin(portal_client, monkeypatch)

    async def fake_get_asset_workspace(*, portal_user_id: int, asset_id: str) -> None:
        return None  # inaccessible / not found

    async def fail_if_called_candidates(*, portal_user_id: int, asset_id: str):
        raise AssertionError(
            "list_asset_point_assignment_candidates must not be called for an inaccessible asset"
        )

    async def fail_if_called_backfill(*, portal_user_id: int, asset_id: str):
        raise AssertionError(
            "get_asset_commissioning_backfill_status must not be called for an inaccessible asset"
        )

    monkeypatch.setattr("src.main.get_asset_workspace", fake_get_asset_workspace)
    monkeypatch.setattr(
        "src.main.list_asset_point_assignment_candidates", fail_if_called_candidates
    )
    monkeypatch.setattr(
        "src.main.get_asset_commissioning_backfill_status", fail_if_called_backfill
    )

    response = portal_client.get(f"/administration/assets/{ASSET_ID}")

    assert response.status_code == 303
    assert response.headers["location"] == "/forbidden"


# ---------------------------------------------------------------------------
# POST /administration/assets/{asset_id}/points/{device_id}/save
# ---------------------------------------------------------------------------


def test_valid_assignment_submission_saves_and_redirects(portal_client, monkeypatch):
    login_platform_admin(portal_client, monkeypatch)

    captured: dict = {}

    async def fake_save(**kwargs) -> dict:
        captured.update(kwargs)
        return {
            "success": True,
            "asset_id": str(ASSET_ID),
            "device_id": str(DEVICE_A),
            "added": [{"asset_point_id": str(POINT_A)}],
            "removed": [],
            "unchanged": [],
            "commissioning_triggered": True,
            "backfill_record_id": "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
            "audit_transaction_id": str(AUDIT_ID),
        }

    monkeypatch.setattr("src.main.save_asset_point_assignments", fake_save)

    response = portal_client.post(
        f"/administration/assets/{ASSET_ID}/points/{DEVICE_A}/save",
        data={"logical_point_id": [str(POINT_A)], f"friendly_name__{POINT_A}": "Main Active Power"},
    )

    assert response.status_code == 303
    assert response.headers["location"] == f"/administration/assets/{ASSET_ID}?point_notice=Data%20point%20assignments%20saved."
    assert captured == {
        "portal_user_id": 500,
        "asset_id": str(ASSET_ID),
        "device_id": str(DEVICE_A),
        "confirmed_points": [
            {"logical_point_id": str(POINT_A), "friendly_name": "Main Active Power"}
        ],
    }


def test_friendly_name_handling_passed_through_and_trimmed(portal_client, monkeypatch):
    login_platform_admin(portal_client, monkeypatch)

    captured: dict = {}

    async def fake_save(**kwargs) -> dict:
        captured.update(kwargs)
        return {
            "success": True, "asset_id": str(ASSET_ID), "device_id": str(DEVICE_A),
            "added": [], "removed": [], "unchanged": [{"asset_point_id": str(POINT_A)}],
            "commissioning_triggered": False, "backfill_record_id": None,
            "audit_transaction_id": str(AUDIT_ID),
        }

    monkeypatch.setattr("src.main.save_asset_point_assignments", fake_save)

    response = portal_client.post(
        f"/administration/assets/{ASSET_ID}/points/{DEVICE_A}/save",
        data={
            "logical_point_id": [str(POINT_A), str(POINT_B)],
            f"friendly_name__{POINT_A}": "  Main Active Power  ",
            f"friendly_name__{POINT_B}": "   ",
        },
    )

    assert response.status_code == 303
    assert captured["confirmed_points"] == [
        {"logical_point_id": str(POINT_A), "friendly_name": "Main Active Power"},
        {"logical_point_id": str(POINT_B), "friendly_name": None},
    ]


def test_malformed_uuid_rejected_without_calling_save(portal_client, monkeypatch):
    login_platform_admin(portal_client, monkeypatch)

    async def fail_if_called(**kwargs):
        raise AssertionError("save_asset_point_assignments must not be called for a malformed submission")

    monkeypatch.setattr("src.main.save_asset_point_assignments", fail_if_called)

    response = portal_client.post(
        f"/administration/assets/{ASSET_ID}/points/{DEVICE_A}/save",
        data={"logical_point_id": ["not-a-valid-uuid"]},
    )

    assert response.status_code == 303
    location = response.headers["location"]
    assert location.startswith(f"/administration/assets/{ASSET_ID}?point_error=")
    assert "Data%20point" in location


def test_measurement_group_conflict_shown_to_admin(portal_client, monkeypatch):
    login_platform_admin(portal_client, monkeypatch)

    conflict_message = (
        "This Save would confirm Power from more than one device for this Asset; "
        "each measurement group must come from a single device."
    )

    async def fake_save(**kwargs):
        raise AssetPointAssignmentConflictError(conflict_message)

    monkeypatch.setattr("src.main.save_asset_point_assignments", fake_save)

    response = portal_client.post(
        f"/administration/assets/{ASSET_ID}/points/{DEVICE_A}/save",
        data={"logical_point_id": [str(POINT_A)]},
    )

    assert response.status_code == 303
    location = response.headers["location"]
    assert location.startswith(f"/administration/assets/{ASSET_ID}?point_error=")
    assert "more%20than%20one%20device" in location


def test_unexpected_database_error_uses_generic_fallback(portal_client, monkeypatch):
    login_platform_admin(portal_client, monkeypatch)

    class FakeDatabaseError(DatabaseError):
        pass

    async def fake_save(**kwargs):
        raise FakeDatabaseError("relation \"metadata.asset_points\" does not exist at line 42")

    monkeypatch.setattr("src.main.save_asset_point_assignments", fake_save)

    response = portal_client.post(
        f"/administration/assets/{ASSET_ID}/points/{DEVICE_A}/save",
        data={"logical_point_id": [str(POINT_A)]},
    )

    assert response.status_code == 303
    location = response.headers["location"]
    assert location.startswith(f"/administration/assets/{ASSET_ID}?point_error=")
    # The raw internal error text must never reach the redirect location.
    assert "metadata.asset_points" not in location
    assert "line+42" not in location
    assert "The%20database%20rejected%20the%20data%20point%20assignment." in location


def test_unauthorized_actor_redirected_to_forbidden(portal_client, monkeypatch):
    async def fake_authenticate(username: str, password: str) -> AuthenticationResult:
        return AuthenticationResult(
            authenticated=True,
            user=AuthenticatedPortalUser(
                portal_user_id=10,
                username="viewer@example.com",
                display_name="Viewer",
                role_code="VIEWER",
                access_scope_mode="GLOBAL",
            ),
            status=AuthenticationStatus.AUTHENTICATED,
        )

    monkeypatch.setattr("src.main.authenticate_portal_user", fake_authenticate)
    login_response = portal_client.post(
        "/login",
        data={
            "username": "viewer@example.com",
            "password": "valid-password",
            "next_path": "/administration/assets",
        },
    )
    assert login_response.status_code == 303

    async def fail_if_called(**kwargs):
        raise AssertionError("save_asset_point_assignments must not be called for an unauthorized actor")

    monkeypatch.setattr("src.main.save_asset_point_assignments", fail_if_called)

    response = portal_client.post(
        f"/administration/assets/{ASSET_ID}/points/{DEVICE_A}/save",
        data={"logical_point_id": [str(POINT_A)]},
    )

    assert response.status_code == 303
    assert response.headers["location"] == "/forbidden"
