"""Route tests for the Physical Location onboarding step.

All repository and persistence dependencies are replaced with deterministic
test doubles. The FastAPI lifespan is not entered, so no live database pool is
started.
"""

from uuid import UUID

import pytest
from psycopg.errors import DatabaseError

from src.auth.models import AuthenticatedPortalUser
from src.auth.security import AuthenticationStatus
from src.auth.service import AuthenticationResult


DRAFT_TOKEN = UUID("88888888-8888-4888-8888-888888888888")
ORGANIZATION_ID = UUID("99999999-9999-4999-8999-999999999999")
SITE_ID = UUID("aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")
SPACE_ID = UUID("bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb")
OTHER_ORGANIZATION_ID = UUID(
    "cccccccc-cccc-4ccc-8ccc-cccccccccccc"
)
OTHER_SITE_ID = UUID("dddddddd-dddd-4ddd-8ddd-dddddddddddd")
OTHER_SPACE_ID = UUID("eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee")


def successful_result() -> AuthenticationResult:
    return AuthenticationResult(
        authenticated=True,
        user=AuthenticatedPortalUser(
            portal_user_id=302,
            username="location.operator@example.com",
            display_name="Location Test Operator",
            role_code="OPERATOR",
        ),
        status=AuthenticationStatus.AUTHENTICATED,
    )


def login_operator(
    portal_client,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    async def fake_authenticate(
        username: str,
        password: str,
    ) -> AuthenticationResult:
        return successful_result()

    monkeypatch.setattr(
        "src.main.authenticate_portal_user",
        fake_authenticate,
    )

    response = portal_client.post(
        "/login",
        data={
            "username": "location.operator@example.com",
            "password": "valid-password",
            "next_path": "/onboarding/location",
        },
    )

    assert response.status_code == 303


def create_new_parent_draft(
    *,
    include_location: bool = False,
) -> dict:
    payload = {
        "organization": {
            "mode": "CREATE_NEW",
            "existing_organization_id": None,
            "name": "New Organization",
            "code": "NEW_ORGANIZATION",
        },
        "site": {
            "mode": "CREATE_NEW",
            "existing_site_id": None,
            "name": "New Site",
            "code": "NEW_SITE",
            "timezone": "Asia/Kolkata",
            "address": {},
        },
    }

    if include_location:
        payload["location"] = {
            "mode": "CREATE_LOCATION",
            "existing_space_id": None,
            "building_name": "Restored Building",
            "building_code": "RESTORED_BUILDING",
            "floor_name": "Restored Floor",
            "floor_code": "RESTORED_FLOOR",
            "space_name": "Restored Space",
            "space_code": "RESTORED_SPACE",
        }

    return {
        "draft_token": DRAFT_TOKEN,
        "payload": payload,
    }


def existing_parent_draft(
    *,
    include_location: bool = False,
) -> dict:
    payload = {
        "organization": {
            "mode": "USE_EXISTING",
            "existing_organization_id": str(ORGANIZATION_ID),
        },
        "site": {
            "mode": "USE_EXISTING",
            "existing_site_id": str(SITE_ID),
        },
    }

    if include_location:
        payload["location"] = {
            "mode": "USE_EXISTING_SPACE",
            "existing_space_id": str(SPACE_ID),
            "building_name": None,
            "building_code": None,
            "floor_name": None,
            "floor_code": None,
            "space_name": None,
            "space_code": None,
        }

    return {
        "draft_token": DRAFT_TOKEN,
        "payload": payload,
    }


def install_visible_draft(
    monkeypatch: pytest.MonkeyPatch,
    draft_record: dict | None,
) -> None:
    async def fake_get_visible_draft(
        request,
        draft_token: UUID,
    ) -> dict | None:
        assert draft_token == DRAFT_TOKEN
        return draft_record

    monkeypatch.setattr(
        "src.main.get_visible_onboarding_draft",
        fake_get_visible_draft,
    )


def install_location_lists(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    async def fake_list_sites() -> list[dict]:
        return [
            {
                "id": SITE_ID,
                "organization_id": ORGANIZATION_ID,
                "site_code": "EXISTING_SITE",
                "site_name": "Existing Site",
            },
            {
                "id": OTHER_SITE_ID,
                "organization_id": OTHER_ORGANIZATION_ID,
                "site_code": "OTHER_SITE",
                "site_name": "Other Site",
            },
        ]

    async def fake_list_spaces() -> list[dict]:
        return [
            {
                "id": SPACE_ID,
                "organization_id": ORGANIZATION_ID,
                "organization_code": "EXISTING_ORG",
                "site_id": SITE_ID,
                "site_code": "EXISTING_SITE",
                "building_id": UUID(
                    "11111111-2222-4333-8444-555555555555"
                ),
                "building_code": "MAIN_BUILDING",
                "building_name": "Main Building",
                "floor_id": UUID(
                    "22222222-3333-4444-8555-666666666666"
                ),
                "floor_code": "GROUND_FLOOR",
                "floor_name": "Ground Floor",
                "space_code": "CHILLER_ROOM",
                "space_name": "Chiller Room",
            },
            {
                "id": OTHER_SPACE_ID,
                "organization_id": OTHER_ORGANIZATION_ID,
                "organization_code": "OTHER_ORG",
                "site_id": OTHER_SITE_ID,
                "site_code": "OTHER_SITE",
                "building_id": UUID(
                    "33333333-4444-4555-8666-777777777777"
                ),
                "building_code": "OTHER_BUILDING",
                "building_name": "Other Building",
                "floor_id": UUID(
                    "44444444-5555-4666-8777-888888888888"
                ),
                "floor_code": "OTHER_FLOOR",
                "floor_name": "Other Floor",
                "space_code": "OTHER_SPACE",
                "space_name": "Other Space",
            },
        ]

    async def fake_list_buildings() -> list[dict]:
        return []

    async def fake_list_floors() -> list[dict]:
        return []

    monkeypatch.setattr("src.main.list_sites", fake_list_sites)
    monkeypatch.setattr("src.main.list_spaces", fake_list_spaces)
    monkeypatch.setattr("src.main.list_buildings", fake_list_buildings)
    monkeypatch.setattr("src.main.list_floors", fake_list_floors)


def test_location_get_rejects_invalid_draft_token(
    portal_client,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    login_operator(portal_client, monkeypatch)

    async def fake_list_organizations() -> list[dict]:
        return []

    monkeypatch.setattr(
        "src.main.list_organizations",
        fake_list_organizations,
    )

    response = portal_client.get(
        "/onboarding/location?draft=not-a-uuid"
    )

    assert response.status_code == 400
    assert "The onboarding draft token is invalid." in response.text


def test_location_get_returns_not_found_for_invisible_draft(
    portal_client,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    login_operator(portal_client, monkeypatch)
    install_visible_draft(monkeypatch, None)

    async def fake_list_organizations() -> list[dict]:
        return []

    monkeypatch.setattr(
        "src.main.list_organizations",
        fake_list_organizations,
    )

    response = portal_client.get(
        f"/onboarding/location?draft={DRAFT_TOKEN}"
    )

    assert response.status_code == 404
    assert (
        "The onboarding draft was not found or has expired."
        in response.text
    )


def test_location_get_redirects_when_organization_missing(
    portal_client,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    login_operator(portal_client, monkeypatch)
    install_visible_draft(
        monkeypatch,
        {"draft_token": DRAFT_TOKEN, "payload": {}},
    )

    response = portal_client.get(
        f"/onboarding/location?draft={DRAFT_TOKEN}"
    )

    assert response.status_code == 303
    assert response.headers["location"] == (
        f"/onboarding/organization?draft={DRAFT_TOKEN}"
    )


def test_location_get_redirects_when_site_missing(
    portal_client,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    login_operator(portal_client, monkeypatch)
    install_visible_draft(
        monkeypatch,
        {
            "draft_token": DRAFT_TOKEN,
            "payload": {
                "organization": {
                    "mode": "CREATE_NEW",
                    "name": "New Organization",
                    "code": "NEW_ORGANIZATION",
                }
            },
        },
    )

    response = portal_client.get(
        f"/onboarding/location?draft={DRAFT_TOKEN}"
    )

    assert response.status_code == 303
    assert response.headers["location"] == (
        f"/onboarding/site?draft={DRAFT_TOKEN}"
    )


def test_location_get_renders_create_new_site_context(
    portal_client,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    login_operator(portal_client, monkeypatch)
    install_visible_draft(
        monkeypatch,
        create_new_parent_draft(),
    )

    response = portal_client.get(
        f"/onboarding/location?draft={DRAFT_TOKEN}"
    )

    assert response.status_code == 200
    assert "New Site" in response.text
    assert "NEW_SITE" in response.text
    assert "Site level" in response.text


def test_location_get_filters_existing_spaces_by_tenant_and_site(
    portal_client,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    login_operator(portal_client, monkeypatch)
    install_visible_draft(
        monkeypatch,
        existing_parent_draft(),
    )
    install_location_lists(monkeypatch)

    response = portal_client.get(
        f"/onboarding/location?draft={DRAFT_TOKEN}"
    )

    assert response.status_code == 200
    assert "Existing Site" in response.text
    assert "Main Building" in response.text
    assert "Ground Floor" in response.text
    assert "Chiller Room" in response.text
    assert "Other Building" not in response.text
    assert "Other Space" not in response.text


def test_location_get_restores_saved_hierarchy_values(
    portal_client,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    login_operator(portal_client, monkeypatch)
    install_visible_draft(
        monkeypatch,
        create_new_parent_draft(include_location=True),
    )

    response = portal_client.get(
        f"/onboarding/location?draft={DRAFT_TOKEN}"
    )

    assert response.status_code == 200
    assert "Restored Building" in response.text
    assert "RESTORED_BUILDING" in response.text
    assert "Restored Floor" in response.text
    assert "RESTORED_FLOOR" in response.text
    assert "Restored Space" in response.text
    assert "RESTORED_SPACE" in response.text


def test_location_post_site_only_saves_and_redirects(
    portal_client,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    login_operator(portal_client, monkeypatch)
    install_visible_draft(
        monkeypatch,
        create_new_parent_draft(),
    )

    captured: dict = {}

    async def fake_save_owned_step(
        request,
        *,
        draft_token: UUID,
        step: str,
        step_payload: dict,
        next_step: str,
    ) -> UUID:
        captured.update(
            {
                "draft_token": draft_token,
                "step": step,
                "step_payload": step_payload,
                "next_step": next_step,
            }
        )
        return DRAFT_TOKEN

    monkeypatch.setattr(
        "src.main.save_owned_onboarding_draft_step",
        fake_save_owned_step,
    )

    response = portal_client.post(
        "/onboarding/location",
        data={
            "draft_token": str(DRAFT_TOKEN),
            "location_mode": "SITE_ONLY",
            "existing_space_id": "",
            "building_name": "Discarded",
            "building_code": "DISCARDED",
            "floor_name": "Discarded",
            "floor_code": "DISCARDED",
            "space_name": "Discarded",
            "space_code": "DISCARDED",
        },
    )

    assert response.status_code == 303
    assert response.headers["location"] == (
        f"/onboarding/gateway?draft={DRAFT_TOKEN}"
    )

    assert captured == {
        "draft_token": DRAFT_TOKEN,
        "step": "location",
        "step_payload": {
            "mode": "SITE_ONLY",
            "existing_space_id": None,
            "building_name": None,
            "building_code": None,
            "floor_name": None,
            "floor_code": None,
            "space_name": None,
            "space_code": None,
        },
        "next_step": "gateway",
    }


def test_location_post_create_hierarchy_saves_normalized_values(
    portal_client,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    login_operator(portal_client, monkeypatch)
    install_visible_draft(
        monkeypatch,
        create_new_parent_draft(),
    )

    captured_payload: dict = {}

    async def fake_save_owned_step(
        request,
        *,
        draft_token: UUID,
        step: str,
        step_payload: dict,
        next_step: str,
    ) -> UUID:
        assert draft_token == DRAFT_TOKEN
        assert step == "location"
        assert next_step == "gateway"
        captured_payload.update(step_payload)
        return DRAFT_TOKEN

    monkeypatch.setattr(
        "src.main.save_owned_onboarding_draft_step",
        fake_save_owned_step,
    )

    response = portal_client.post(
        "/onboarding/location",
        data={
            "draft_token": str(DRAFT_TOKEN),
            "location_mode": "CREATE_LOCATION",
            "existing_space_id": "",
            "building_name": "  Main Building  ",
            "building_code": "  main_building  ",
            "floor_name": "  Ground Floor  ",
            "floor_code": "  ground_floor  ",
            "space_name": "  Chiller Room  ",
            "space_code": "  chiller_room  ",
        },
    )

    assert response.status_code == 303
    assert captured_payload == {
        "mode": "CREATE_LOCATION",
        "existing_space_id": None,
        "building_name": "Main Building",
        "building_code": "MAIN_BUILDING",
        "floor_name": "Ground Floor",
        "floor_code": "GROUND_FLOOR",
        "space_name": "Chiller Room",
        "space_code": "CHILLER_ROOM",
    }


def test_location_post_use_existing_space_saves_only_identity(
    portal_client,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    login_operator(portal_client, monkeypatch)
    install_visible_draft(
        monkeypatch,
        existing_parent_draft(),
    )
    install_location_lists(monkeypatch)

    captured_payload: dict = {}

    async def fake_save_owned_step(
        request,
        *,
        draft_token: UUID,
        step: str,
        step_payload: dict,
        next_step: str,
    ) -> UUID:
        captured_payload.update(step_payload)
        return DRAFT_TOKEN

    monkeypatch.setattr(
        "src.main.save_owned_onboarding_draft_step",
        fake_save_owned_step,
    )

    response = portal_client.post(
        "/onboarding/location",
        data={
            "draft_token": str(DRAFT_TOKEN),
            "location_mode": "USE_EXISTING_SPACE",
            "existing_space_id": str(SPACE_ID),
            "building_name": "Discarded",
            "building_code": "DISCARDED",
            "floor_name": "Discarded",
            "floor_code": "DISCARDED",
            "space_name": "Discarded",
            "space_code": "DISCARDED",
        },
    )

    assert response.status_code == 303
    assert captured_payload == {
        "mode": "USE_EXISTING_SPACE",
        "existing_space_id": str(SPACE_ID),
        "building_name": None,
        "building_code": None,
        "floor_name": None,
        "floor_code": None,
        "space_name": None,
        "space_code": None,
    }


def test_location_post_rejects_existing_space_for_new_parents(
    portal_client,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    login_operator(portal_client, monkeypatch)
    install_visible_draft(
        monkeypatch,
        create_new_parent_draft(),
    )

    response = portal_client.post(
        "/onboarding/location",
        data={
            "draft_token": str(DRAFT_TOKEN),
            "location_mode": "USE_EXISTING_SPACE",
            "existing_space_id": str(SPACE_ID),
        },
    )

    assert response.status_code == 422
    assert (
        "An existing space can only be selected when both "
        "the organization and site already exist."
        in response.text
    )


def test_location_post_rejects_space_from_another_tenant_or_site(
    portal_client,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    login_operator(portal_client, monkeypatch)
    install_visible_draft(
        monkeypatch,
        existing_parent_draft(),
    )
    install_location_lists(monkeypatch)

    response = portal_client.post(
        "/onboarding/location",
        data={
            "draft_token": str(DRAFT_TOKEN),
            "location_mode": "USE_EXISTING_SPACE",
            "existing_space_id": str(OTHER_SPACE_ID),
        },
    )

    assert response.status_code == 422
    assert (
        "The selected space does not belong to the chosen "
        "organization and site."
        in response.text
    )


def test_location_post_rejects_unknown_existing_space(
    portal_client,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    login_operator(portal_client, monkeypatch)
    install_visible_draft(
        monkeypatch,
        existing_parent_draft(),
    )
    install_location_lists(monkeypatch)

    unknown_space_id = UUID(
        "ffffffff-ffff-4fff-8fff-ffffffffffff"
    )

    response = portal_client.post(
        "/onboarding/location",
        data={
            "draft_token": str(DRAFT_TOKEN),
            "location_mode": "USE_EXISTING_SPACE",
            "existing_space_id": str(unknown_space_id),
        },
    )

    assert response.status_code == 422
    assert "The selected space does not exist." in response.text


def test_location_post_validation_error_preserves_form_data(
    portal_client,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    login_operator(portal_client, monkeypatch)
    install_visible_draft(
        monkeypatch,
        create_new_parent_draft(),
    )

    response = portal_client.post(
        "/onboarding/location",
        data={
            "draft_token": str(DRAFT_TOKEN),
            "location_mode": "CREATE_LOCATION",
            "existing_space_id": "",
            "building_name": "Preserved Building",
            "building_code": "INVALID-CODE",
            "floor_name": "Preserved Floor",
            "floor_code": "PRESERVED_FLOOR",
            "space_name": "Preserved Space",
            "space_code": "PRESERVED_SPACE",
        },
    )

    assert response.status_code == 422
    assert "Preserved Building" in response.text
    assert "INVALID-CODE" in response.text
    assert "Preserved Floor" in response.text
    assert "Preserved Space" in response.text
    assert "Building code" in response.text


def test_location_post_database_failure_returns_controlled_conflict(
    portal_client,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    login_operator(portal_client, monkeypatch)
    install_visible_draft(
        monkeypatch,
        create_new_parent_draft(),
    )

    async def fake_save_owned_step(*args, **kwargs):
        raise DatabaseError("forced location persistence failure")

    monkeypatch.setattr(
        "src.main.save_owned_onboarding_draft_step",
        fake_save_owned_step,
    )

    response = portal_client.post(
        "/onboarding/location",
        data={
            "draft_token": str(DRAFT_TOKEN),
            "location_mode": "CREATE_LOCATION",
            "existing_space_id": "",
            "building_name": "Database Failure Building",
            "building_code": "DATABASE_FAILURE_BUILDING",
            "floor_name": "Database Failure Floor",
            "floor_code": "DATABASE_FAILURE_FLOOR",
            "space_name": "Database Failure Space",
            "space_code": "DATABASE_FAILURE_SPACE",
        },
    )

    assert response.status_code == 409
    assert (
        "The database rejected the onboarding draft."
        in response.text
    )
    assert "Database Failure Building" in response.text
    assert "DATABASE_FAILURE_BUILDING" in response.text
