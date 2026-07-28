"""Route tests for the Site onboarding wizard step.

All database-backed dependencies are replaced with deterministic test doubles.
The FastAPI lifespan is not entered, so no production connection pool starts.
"""

from uuid import UUID

import pytest
from psycopg.errors import DatabaseError

from src.auth.models import AuthenticatedPortalUser
from src.auth.security import AuthenticationStatus
from src.auth.service import AuthenticationResult


DRAFT_TOKEN = UUID("33333333-3333-4333-8333-333333333333")
ORGANIZATION_ID = UUID("44444444-4444-4444-8444-444444444444")
OTHER_ORGANIZATION_ID = UUID(
    "55555555-5555-4555-8555-555555555555"
)
SITE_ID = UUID("66666666-6666-4666-8666-666666666666")
OTHER_SITE_ID = UUID("77777777-7777-4777-8777-777777777777")


def successful_result() -> AuthenticationResult:
    return AuthenticationResult(
        authenticated=True,
        user=AuthenticatedPortalUser(
            portal_user_id=301,
            username="site.operator@example.com",
            display_name="Site Test Operator",
            role_code="OPERATOR",
            organization_id=(
                "11111111-1111-1111-1111-111111111111"
            ),
            access_scope_mode="ORGANIZATION",
            site_ids=(),
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
            "username": "site.operator@example.com",
            "password": "valid-password",
            "next_path": "/onboarding/site",
        },
    )

    assert response.status_code == 303


def create_new_organization_draft(
    *,
    include_site: bool = False,
) -> dict:
    payload = {
        "organization": {
            "mode": "CREATE_NEW",
            "existing_organization_id": None,
            "name": "New Organization",
            "code": "NEW_ORGANIZATION",
            "description": None,
        }
    }

    if include_site:
        payload["site"] = {
            "mode": "CREATE_NEW",
            "existing_site_id": None,
            "name": "Restored Site",
            "code": "RESTORED_SITE",
            "timezone": "Asia/Dubai",
            "address": {
                "full_address": "Restored test address"
            },
        }

    return {
        "draft_token": DRAFT_TOKEN,
        "payload": payload,
    }


def existing_organization_draft(
    *,
    include_site: bool = False,
) -> dict:
    payload = {
        "organization": {
            "mode": "USE_EXISTING",
            "existing_organization_id": str(ORGANIZATION_ID),
            "name": None,
            "code": None,
            "description": None,
        }
    }

    if include_site:
        payload["site"] = {
            "mode": "USE_EXISTING",
            "existing_site_id": str(SITE_ID),
            "name": None,
            "code": None,
            "timezone": None,
            "address": None,
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


def install_repository_lists(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    async def fake_list_organizations() -> list[dict]:
        return [
            {
                "id": ORGANIZATION_ID,
                "organization_code": "EXISTING_ORG",
                "organization_name": "Existing Organization",
                "description": None,
                "is_active": True,
            },
            {
                "id": OTHER_ORGANIZATION_ID,
                "organization_code": "OTHER_ORG",
                "organization_name": "Other Organization",
                "description": None,
                "is_active": True,
            },
        ]

    async def fake_list_sites(request) -> list[dict]:
        return [
            {
                "id": SITE_ID,
                "organization_id": ORGANIZATION_ID,
                "organization_code": "EXISTING_ORG",
                "organization_name": "Existing Organization",
                "site_code": "HYD_SITE",
                "site_name": "Hyderabad Site",
                "timezone": "Asia/Kolkata",
                "address": {},
                "is_active": True,
            },
            {
                "id": OTHER_SITE_ID,
                "organization_id": OTHER_ORGANIZATION_ID,
                "organization_code": "OTHER_ORG",
                "organization_name": "Other Organization",
                "site_code": "OTHER_SITE",
                "site_name": "Other Site",
                "timezone": "UTC",
                "address": {},
                "is_active": True,
            },
        ]

    monkeypatch.setattr(
        "src.main.list_organizations",
        fake_list_organizations,
    )
    monkeypatch.setattr(
        "src.main.list_sites_for_request",
        fake_list_sites,
    )


def test_site_get_rejects_invalid_draft_token(
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
        "/onboarding/site?draft=not-a-uuid"
    )

    assert response.status_code == 400
    assert "The onboarding draft token is invalid." in response.text


def test_site_get_returns_not_found_for_invisible_draft(
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
        f"/onboarding/site?draft={DRAFT_TOKEN}"
    )

    assert response.status_code == 404
    assert (
        "The onboarding draft was not found or has expired."
        in response.text
    )


def test_site_get_redirects_when_organization_step_missing(
    portal_client,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    login_operator(portal_client, monkeypatch)

    install_visible_draft(
        monkeypatch,
        {
            "draft_token": DRAFT_TOKEN,
            "payload": {},
        },
    )

    response = portal_client.get(
        f"/onboarding/site?draft={DRAFT_TOKEN}"
    )

    assert response.status_code == 303
    assert response.headers["location"] == (
        f"/onboarding/organization?draft={DRAFT_TOKEN}"
    )


def test_site_get_renders_create_new_organization_context(
    portal_client,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    login_operator(portal_client, monkeypatch)
    install_visible_draft(
        monkeypatch,
        create_new_organization_draft(),
    )

    response = portal_client.get(
        f"/onboarding/site?draft={DRAFT_TOKEN}"
    )

    assert response.status_code == 200
    assert "New Organization" in response.text
    assert "NEW_ORGANIZATION" in response.text
    assert "New organization selected" in response.text


def test_site_get_filters_sites_for_existing_organization(
    portal_client,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    login_operator(portal_client, monkeypatch)
    install_visible_draft(
        monkeypatch,
        existing_organization_draft(),
    )
    install_repository_lists(monkeypatch)

    response = portal_client.get(
        f"/onboarding/site?draft={DRAFT_TOKEN}"
    )

    assert response.status_code == 200
    assert "Existing Organization" in response.text
    assert "EXISTING_ORG" in response.text
    assert "Hyderabad Site" in response.text
    assert "HYD_SITE" in response.text
    assert "Other Site" not in response.text
    assert "OTHER_SITE" not in response.text


def test_site_get_restores_saved_site_values(
    portal_client,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    login_operator(portal_client, monkeypatch)
    install_visible_draft(
        monkeypatch,
        create_new_organization_draft(include_site=True),
    )

    response = portal_client.get(
        f"/onboarding/site?draft={DRAFT_TOKEN}"
    )

    assert response.status_code == 200
    assert "Restored Site" in response.text
    assert "RESTORED_SITE" in response.text
    assert "Asia/Dubai" in response.text
    assert "Restored test address" in response.text


def test_site_post_create_new_saves_and_redirects(
    portal_client,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    login_operator(portal_client, monkeypatch)
    install_visible_draft(
        monkeypatch,
        create_new_organization_draft(),
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
        "/onboarding/site",
        data={
            "draft_token": str(DRAFT_TOKEN),
            "site_mode": "CREATE_NEW",
            "existing_site_id": "",
            "site_name": "  Hyderabad Hotel  ",
            "site_code": "IGNORED_CLIENT_VALUE",
            "site_timezone": "  Asia/Kolkata  ",
            "site_address": "  Test site address  ",
        },
    )

    assert response.status_code == 303
    assert response.headers["location"] == (
        f"/onboarding/location?draft={DRAFT_TOKEN}"
    )

    assert captured == {
        "draft_token": DRAFT_TOKEN,
        "step": "site",
        "step_payload": {
            "mode": "CREATE_NEW",
            "existing_site_id": None,
            "name": "Hyderabad Hotel",
            "code": "HYDERABAD_HOTEL",
            "timezone": "Asia/Kolkata",
            "address": {
                "full_address": "Test site address"
            },
        },
        "next_step": "location",
    }


def test_site_post_use_existing_saves_only_site_identity(
    portal_client,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    login_operator(portal_client, monkeypatch)
    install_visible_draft(
        monkeypatch,
        existing_organization_draft(),
    )
    install_repository_lists(monkeypatch)

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
        assert step == "site"
        assert next_step == "location"
        captured_payload.update(step_payload)
        return DRAFT_TOKEN

    monkeypatch.setattr(
        "src.main.save_owned_onboarding_draft_step",
        fake_save_owned_step,
    )

    response = portal_client.post(
        "/onboarding/site",
        data={
            "draft_token": str(DRAFT_TOKEN),
            "site_mode": "USE_EXISTING",
            "existing_site_id": str(SITE_ID),
            "site_name": "Discarded",
            "site_code": "DISCARDED",
            "site_timezone": "UTC",
            "site_address": "Discarded",
        },
    )

    assert response.status_code == 303
    assert captured_payload == {
        "mode": "USE_EXISTING",
        "existing_site_id": str(SITE_ID),
        "name": None,
        "code": None,
        "timezone": None,
        "address": None,
    }


def test_site_post_rejects_site_from_another_organization(
    portal_client,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    login_operator(portal_client, monkeypatch)
    install_visible_draft(
        monkeypatch,
        existing_organization_draft(),
    )
    install_repository_lists(monkeypatch)

    async def unexpected_save(*args, **kwargs):
        raise AssertionError(
            "Cross-organization site must not be persisted."
        )

    monkeypatch.setattr(
        "src.main.save_owned_onboarding_draft_step",
        unexpected_save,
    )

    response = portal_client.post(
        "/onboarding/site",
        data={
            "draft_token": str(DRAFT_TOKEN),
            "site_mode": "USE_EXISTING",
            "existing_site_id": str(OTHER_SITE_ID),
            "site_name": "",
            "site_code": "",
            "site_timezone": "Asia/Kolkata",
            "site_address": "",
        },
    )

    assert response.status_code == 422
    assert (
        "The selected site does not belong to the chosen organization."
        in response.text
    )


def test_site_post_rejects_unknown_existing_site(
    portal_client,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    login_operator(portal_client, monkeypatch)
    install_visible_draft(
        monkeypatch,
        existing_organization_draft(),
    )
    install_repository_lists(monkeypatch)

    unknown_site_id = UUID(
        "88888888-8888-4888-8888-888888888888"
    )

    response = portal_client.post(
        "/onboarding/site",
        data={
            "draft_token": str(DRAFT_TOKEN),
            "site_mode": "USE_EXISTING",
            "existing_site_id": str(unknown_site_id),
            "site_name": "",
            "site_code": "",
            "site_timezone": "Asia/Kolkata",
            "site_address": "",
        },
    )

    assert response.status_code == 422
    assert "The selected site does not exist." in response.text


def test_site_post_validation_error_preserves_form_data(
    portal_client,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    login_operator(portal_client, monkeypatch)
    install_visible_draft(
        monkeypatch,
        create_new_organization_draft(),
    )

    response = portal_client.post(
        "/onboarding/site",
        data={
            "draft_token": str(DRAFT_TOKEN),
            "site_mode": "CREATE_NEW",
            "existing_site_id": "",
            "site_name": "",
            "site_code": "IGNORED_CLIENT_VALUE",
            "site_timezone": "Asia/Singapore",
            "site_address": "Preserved address",
        },
    )

    assert response.status_code == 422
    assert "Site name is required." in response.text
    assert "Asia/Singapore" in response.text
    assert "Preserved address" in response.text
    assert "IGNORED_CLIENT_VALUE" not in response.text


def test_site_post_database_failure_returns_controlled_conflict(
    portal_client,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    login_operator(portal_client, monkeypatch)
    install_visible_draft(
        monkeypatch,
        create_new_organization_draft(),
    )

    async def fake_save_owned_step(*args, **kwargs):
        raise DatabaseError("forced site persistence failure")

    monkeypatch.setattr(
        "src.main.save_owned_onboarding_draft_step",
        fake_save_owned_step,
    )

    response = portal_client.post(
        "/onboarding/site",
        data={
            "draft_token": str(DRAFT_TOKEN),
            "site_mode": "CREATE_NEW",
            "existing_site_id": "",
            "site_name": "Database Failure Site",
            "site_code": "IGNORED_CLIENT_VALUE",
            "site_timezone": "Asia/Kolkata",
            "site_address": "Preserved address",
        },
    )

    assert response.status_code == 409
    assert (
        "The database rejected the onboarding draft."
        in response.text
    )
    assert "Database Failure Site" in response.text
    assert "DATABASE_FAILURE_SITE" in response.text
    assert "IGNORED_CLIENT_VALUE" not in response.text
