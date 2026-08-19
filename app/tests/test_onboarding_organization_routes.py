"""Route tests for the Organization onboarding wizard step.

These tests deliberately bypass the FastAPI lifespan and replace every
database-backed dependency used by the route. No live PostgreSQL connection is
opened.
"""

from collections.abc import Callable
from uuid import UUID

import pytest
from psycopg.errors import DatabaseError

from src.auth.models import AuthenticatedPortalUser
from src.auth.security import AuthenticationStatus
from src.auth.service import AuthenticationResult


DRAFT_TOKEN = UUID("11111111-1111-4111-8111-111111111111")
EXISTING_ORGANIZATION_ID = UUID(
    "22222222-2222-4222-8222-222222222222"
)


def successful_result() -> AuthenticationResult:
    """Return a deterministic authenticated OPERATOR identity."""

    return AuthenticationResult(
        authenticated=True,
        user=AuthenticatedPortalUser(
            portal_user_id=300,
            username="organization.operator@example.com",
            display_name="Organization Test Operator",
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
    """Create an authenticated portal session for route tests."""

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
            "username": "organization.operator@example.com",
            "password": "valid-password",
            "next_path": "/onboarding/organization",
        },
    )

    assert response.status_code == 303


def install_organization_list(
    monkeypatch: pytest.MonkeyPatch,
) -> list[dict]:
    """Replace the organization lookup repository."""

    organizations = [
        {
            "id": EXISTING_ORGANIZATION_ID,
            "organization_code": "EXISTING_ORG",
            "organization_name": "Existing Organization",
        }
    ]

    async def fake_list_organizations() -> list[dict]:
        return organizations

    monkeypatch.setattr(
        "src.main.list_organizations",
        fake_list_organizations,
    )

    return organizations


def test_organization_get_renders_for_authenticated_operator(
    portal_client,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    login_operator(portal_client, monkeypatch)
    install_organization_list(monkeypatch)

    response = portal_client.get("/onboarding/organization")

    assert response.status_code == 200
    assert "Organization" in response.text
    assert "Existing Organization" in response.text
    assert "EXISTING_ORG" in response.text


def test_organization_get_rejects_invalid_draft_token(
    portal_client,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    login_operator(portal_client, monkeypatch)
    install_organization_list(monkeypatch)

    response = portal_client.get(
        "/onboarding/organization?draft=not-a-uuid"
    )

    assert response.status_code == 400
    assert "The onboarding draft token is invalid." in response.text


def test_organization_get_returns_not_found_for_invisible_draft(
    portal_client,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    login_operator(portal_client, monkeypatch)
    install_organization_list(monkeypatch)

    async def fake_get_visible_draft(
        request,
        draft_token: UUID,
    ) -> None:
        assert draft_token == DRAFT_TOKEN
        return None

    monkeypatch.setattr(
        "src.main.get_visible_onboarding_draft",
        fake_get_visible_draft,
    )

    response = portal_client.get(
        f"/onboarding/organization?draft={DRAFT_TOKEN}"
    )

    assert response.status_code == 404
    assert (
        "The onboarding draft was not found or has expired."
        in response.text
    )


def test_organization_get_restores_existing_draft_values(
    portal_client,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    login_operator(portal_client, monkeypatch)
    install_organization_list(monkeypatch)

    async def fake_get_visible_draft(
        request,
        draft_token: UUID,
    ) -> dict:
        assert draft_token == DRAFT_TOKEN

        return {
            "draft_token": DRAFT_TOKEN,
            "payload": {
                "organization": {
                    "mode": "CREATE_NEW",
                    "name": "Restored Organization",
                    "code": "RESTORED_ORG",
                    "description": "Restored draft description",
                }
            },
        }

    monkeypatch.setattr(
        "src.main.get_visible_onboarding_draft",
        fake_get_visible_draft,
    )

    response = portal_client.get(
        f"/onboarding/organization?draft={DRAFT_TOKEN}"
    )

    assert response.status_code == 200
    assert "Restored Organization" in response.text
    assert "RESTORED_ORG" in response.text
    assert "Restored draft description" in response.text
    assert str(DRAFT_TOKEN) in response.text


def test_organization_post_create_new_saves_and_redirects(
    portal_client,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    login_operator(portal_client, monkeypatch)
    install_organization_list(monkeypatch)

    captured: dict = {}

    async def fake_save_owned_step(
        request,
        *,
        draft_token: UUID | None,
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
        "/onboarding/organization",
        data={
            "organization_mode": "CREATE_NEW",
            "draft_token": "",
            "existing_organization_id": "",
            "organization_name": "  WiseWatts Test  ",
            "organization_code": "IGNORED_CLIENT_VALUE",
            "organization_description": "  Route test tenant  ",
        },
    )

    assert response.status_code == 303
    assert response.headers["location"] == (
        f"/onboarding/site?draft={DRAFT_TOKEN}"
    )

    assert captured == {
        "draft_token": None,
        "step": "organization",
        "step_payload": {
            "mode": "CREATE_NEW",
            "existing_organization_id": None,
            "name": "WiseWatts Test",
            "code": "WISEWATTS_TEST",
            "description": "Route test tenant",
            "timezone": "Asia/Kolkata",
            "lifecycle_status": "ACTIVE",
            "legal_name": "",
            "locale": "en-US",
            "primary_contact": {"name": "", "email": "", "phone": ""},
            "address": {
                "line1": "",
                "line2": "",
                "city": "",
                "region": "",
                "postal_code": "",
                "country": "",
            },
            "notes": "",
        },
        "next_step": "site",
    }


def test_organization_post_use_existing_preserves_only_identity(
    portal_client,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    login_operator(portal_client, monkeypatch)
    install_organization_list(monkeypatch)

    captured_payload: dict = {}

    async def fake_save_owned_step(
        request,
        *,
        draft_token: UUID | None,
        step: str,
        step_payload: dict,
        next_step: str,
    ) -> UUID:
        assert draft_token == DRAFT_TOKEN
        assert step == "organization"
        assert next_step == "site"

        captured_payload.update(step_payload)
        return DRAFT_TOKEN

    monkeypatch.setattr(
        "src.main.save_owned_onboarding_draft_step",
        fake_save_owned_step,
    )

    response = portal_client.post(
        "/onboarding/organization",
        data={
            "organization_mode": "USE_EXISTING",
            "draft_token": str(DRAFT_TOKEN),
            "existing_organization_id": str(
                EXISTING_ORGANIZATION_ID
            ),
            "organization_name": "Must Be Discarded",
            "organization_code": "MUST_BE_DISCARDED",
            "organization_description": "Must be discarded",
        },
    )

    assert response.status_code == 303
    assert captured_payload == {
        "mode": "USE_EXISTING",
        "existing_organization_id": str(
            EXISTING_ORGANIZATION_ID
        ),
        "name": None,
        "code": None,
        "description": None,
        "timezone": None,
        "lifecycle_status": None,
        "legal_name": None,
        "locale": None,
        "primary_contact": None,
        "address": None,
        "notes": None,
    }


def test_organization_post_validation_error_preserves_form(
    portal_client,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    login_operator(portal_client, monkeypatch)
    install_organization_list(monkeypatch)

    async def unexpected_save(*args, **kwargs):
        raise AssertionError(
            "Invalid form data must not reach draft persistence."
        )

    monkeypatch.setattr(
        "src.main.save_owned_onboarding_draft_step",
        unexpected_save,
    )

    response = portal_client.post(
        "/onboarding/organization",
        data={
            "organization_mode": "CREATE_NEW",
            "draft_token": "",
            "existing_organization_id": "",
            "organization_name": "",
            "organization_code": "IGNORED_CLIENT_VALUE",
            "organization_description": "Preserved description",
        },
    )

    assert response.status_code == 422
    assert "Preserved description" in response.text
    assert "Organization name is required." in response.text


def test_organization_post_rejects_invalid_draft_token(
    portal_client,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    login_operator(portal_client, monkeypatch)
    install_organization_list(monkeypatch)

    response = portal_client.post(
        "/onboarding/organization",
        data={
            "organization_mode": "CREATE_NEW",
            "draft_token": "invalid-draft-token",
            "existing_organization_id": "",
            "organization_name": "Preserved Organization",
            "organization_code": "PRESERVED_ORG",
            "organization_description": "Preserved description",
        },
    )

    assert response.status_code == 400
    assert "The onboarding draft token is invalid." in response.text
    assert "Preserved Organization" in response.text
    assert "PRESERVED_ORG" in response.text


def test_organization_post_database_failure_returns_controlled_conflict(
    portal_client,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    login_operator(portal_client, monkeypatch)
    install_organization_list(monkeypatch)

    async def fake_save_owned_step(*args, **kwargs):
        raise DatabaseError("forced organization persistence failure")

    monkeypatch.setattr(
        "src.main.save_owned_onboarding_draft_step",
        fake_save_owned_step,
    )

    response = portal_client.post(
        "/onboarding/organization",
        data={
            "organization_mode": "CREATE_NEW",
            "draft_token": "",
            "existing_organization_id": "",
            "organization_name": "Database Failure Organization",
            "organization_code": "IGNORED_CLIENT_VALUE",
            "organization_description": "Preserve this value",
        },
    )

    assert response.status_code == 409
    assert (
        "The database rejected the onboarding draft."
        in response.text
    )
    assert "Database Failure Organization" in response.text
    assert "DATABASE_FAILURE_ORGANIZATION" in response.text
