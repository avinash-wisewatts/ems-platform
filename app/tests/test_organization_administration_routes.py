from uuid import UUID

import pytest
from psycopg.errors import UniqueViolation

from src.auth.models import AuthenticatedPortalUser
from src.auth.security import AuthenticationStatus
from src.auth.service import AuthenticationResult


ORGANIZATION_ID = UUID(
    "33333333-3333-4333-8333-333333333333"
)


def successful_super_admin_result() -> AuthenticationResult:
    return AuthenticationResult(
        authenticated=True,
        user=AuthenticatedPortalUser(
            portal_user_id=500,
            username="superadmin@example.com",
            display_name="Test Super Admin",
            role_code="SUPER_ADMIN",
        ),
        status=AuthenticationStatus.AUTHENTICATED,
    )


def login_super_admin(
    portal_client,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    async def fake_authenticate(
        username: str,
        password: str,
    ) -> AuthenticationResult:
        return successful_super_admin_result()

    monkeypatch.setattr(
        "src.main.authenticate_portal_user",
        fake_authenticate,
    )

    response = portal_client.post(
        "/login",
        data={
            "username": "superadmin@example.com",
            "password": "valid-password",
            "next_path": "/administration/organizations",
        },
    )

    assert response.status_code == 303


def test_organization_administration_get_renders_form(
    portal_client,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    login_super_admin(portal_client, monkeypatch)

    response = portal_client.get(
        "/administration/organizations"
    )

    assert response.status_code == 200
    assert "Create organization" in response.text
    assert "Asia/Kolkata" in response.text
    assert "Lifecycle status" in response.text


def test_organization_administration_post_creates_organization(
    portal_client,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    login_super_admin(portal_client, monkeypatch)

    captured: dict = {}

    async def fake_create_organization(
        *,
        name: str,
        code: str,
        timezone: str,
        lifecycle_status: str,
        requested_by: str,
    ) -> dict:
        captured.update(
            {
                "name": name,
                "code": code,
                "timezone": timezone,
                "lifecycle_status": lifecycle_status,
                "requested_by": requested_by,
            }
        )

        return {
            "success": True,
            "entity_type": "ORGANIZATION",
            "entity_id": str(ORGANIZATION_ID),
            "organization_id": str(ORGANIZATION_ID),
            "organization_name": name,
            "organization_code": code,
            "timezone": timezone,
            "lifecycle_status": lifecycle_status,
            "commissioning_status": None,
            "validation_warnings": [],
            "blocking_conditions": [],
            "audit_transaction_id": (
                "44444444-4444-4444-8444-444444444444"
            ),
        }

    monkeypatch.setattr(
        "src.main.create_organization",
        fake_create_organization,
    )

    async def fake_provision_grafana_for_organization(
        *,
        organization_id: str,
        organization_name: str,
    ) -> dict:
        assert organization_id == str(ORGANIZATION_ID)
        assert organization_name == "Organization One"

        return {
            "organization_id": organization_id,
            "provisioning_status": "PROVISIONED",
            "grafana_org_id": 7,
            "attempt_count": 1,
            "last_error": None,
        }

    monkeypatch.setattr(
        "src.main.provision_grafana_for_organization",
        fake_provision_grafana_for_organization,
    )

    response = portal_client.post(
        "/administration/organizations",
        data={
            "organization_name": "Organization One",
            "organization_code": "ORG_1",
            "organization_timezone": "Asia/Kolkata",
            "organization_lifecycle_status": "ACTIVE",
        },
    )

    assert response.status_code == 201
    assert "Organization created" in response.text
    assert "Organization One" in response.text
    assert "ORG_1" in response.text

    assert captured == {
        "name": "Organization One",
        "code": "ORG_1",
        "timezone": "Asia/Kolkata",
        "lifecycle_status": "ACTIVE",
        "requested_by": "superadmin@example.com",
    }


def test_organization_administration_preserves_form_on_database_error(
    portal_client,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    login_super_admin(portal_client, monkeypatch)

    async def fake_create_organization(**kwargs):
        raise UniqueViolation(
            "Organization code ORG_1 already exists."
        )

    monkeypatch.setattr(
        "src.main.create_organization",
        fake_create_organization,
    )

    response = portal_client.post(
        "/administration/organizations",
        data={
            "organization_name": "Organization One",
            "organization_code": "ORG_1",
            "organization_timezone": "Asia/Kolkata",
            "organization_lifecycle_status": "ACTIVE",
        },
    )

    assert response.status_code == 409
    assert "Organization One" in response.text
    assert "ORG_1" in response.text
    assert "Asia/Kolkata" in response.text
