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
            role_code="PLATFORM_ADMIN",
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


@pytest.fixture(autouse=True)
def mock_organization_provisioning_status_list(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    async def fake_list() -> list[dict]:
        return []

    monkeypatch.setattr(
        "src.main.list_organizations_with_grafana_status",
        fake_list,
    )


def test_organization_administration_displays_persisted_status(
    portal_client,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    login_super_admin(portal_client, monkeypatch)

    async def fake_list() -> list[dict]:
        return [
            {
                "organization_id": str(ORGANIZATION_ID),
                "organization_code": "ORG_1",
                "organization_name": "Organization One",
                "timezone": "Asia/Kolkata",
                "lifecycle_status": "ACTIVE",
                "provisioning_status": "FAILED",
                "grafana_org_id": None,
                "attempt_count": 2,
                "last_attempt_at": None,
                "provisioned_at": None,
                "last_error": "Grafana API connection refused.",
            }
        ]

    monkeypatch.setattr(
        "src.main.list_organizations_with_grafana_status",
        fake_list,
    )

    response = portal_client.get(
        "/administration/organizations"
    )

    assert response.status_code == 200
    assert "Organization provisioning status" in response.text
    assert "Organization One" in response.text
    assert "FAILED" in response.text
    assert "Grafana API connection refused." in response.text
    assert (
        f"/administration/organizations/"
        f"{ORGANIZATION_ID}/grafana/retry"
    ) in response.text



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


def test_super_admin_retries_grafana_provisioning(
    portal_client,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    login_super_admin(portal_client, monkeypatch)

    async def fake_list_organizations() -> list[dict]:
        return [
            {
                "id": ORGANIZATION_ID,
                "organization_code": "ORG_1",
                "organization_name": "Organization One",
                "description": None,
                "is_active": True,
            }
        ]

    captured: dict = {}

    async def fake_provision_grafana_for_organization(
        *,
        organization_id: str,
        organization_name: str,
    ) -> dict:
        captured.update(
            {
                "organization_id": organization_id,
                "organization_name": organization_name,
            }
        )

        return {
            "organization_id": organization_id,
            "provisioning_status": "PROVISIONED",
            "grafana_org_id": 7,
            "attempt_count": 2,
            "last_error": None,
        }

    monkeypatch.setattr(
        "src.main.list_organizations",
        fake_list_organizations,
    )
    monkeypatch.setattr(
        "src.main.provision_grafana_for_organization",
        fake_provision_grafana_for_organization,
    )

    response = portal_client.post(
        (
            "/administration/organizations/"
            f"{ORGANIZATION_ID}/grafana/retry"
        )
    )

    assert response.status_code == 200
    assert "PROVISIONED" in response.text
    assert "Organization One" in response.text
    assert captured == {
        "organization_id": str(ORGANIZATION_ID),
        "organization_name": "Organization One",
    }


def test_failed_grafana_retry_shows_internal_error_to_super_admin(
    portal_client,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    login_super_admin(portal_client, monkeypatch)

    async def fake_list_organizations() -> list[dict]:
        return [
            {
                "id": ORGANIZATION_ID,
                "organization_code": "ORG_1",
                "organization_name": "Organization One",
                "description": None,
                "is_active": True,
            }
        ]

    async def fake_provision_grafana_for_organization(
        *,
        organization_id: str,
        organization_name: str,
    ) -> dict:
        return {
            "organization_id": organization_id,
            "provisioning_status": "FAILED",
            "grafana_org_id": None,
            "attempt_count": 2,
            "last_error": "Grafana API connection refused.",
        }

    monkeypatch.setattr(
        "src.main.list_organizations",
        fake_list_organizations,
    )
    monkeypatch.setattr(
        "src.main.provision_grafana_for_organization",
        fake_provision_grafana_for_organization,
    )

    response = portal_client.post(
        (
            "/administration/organizations/"
            f"{ORGANIZATION_ID}/grafana/retry"
        )
    )

    assert response.status_code == 200
    assert "FAILED" in response.text
    assert "Grafana API connection refused." in response.text
    assert "Retry Grafana provisioning" in response.text

def successful_operator_result() -> AuthenticationResult:
    return AuthenticationResult(
        authenticated=True,
        user=AuthenticatedPortalUser(
            portal_user_id=501,
            username="operator@example.com",
            display_name="Test Operator",
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
        return successful_operator_result()

    monkeypatch.setattr(
        "src.main.authenticate_portal_user",
        fake_authenticate,
    )

    response = portal_client.post(
        "/login",
        data={
            "username": "operator@example.com",
            "password": "valid-password",
            "next_path": "/administration/organizations",
        },
    )

    assert response.status_code == 303


def test_operator_sees_generic_grafana_failure_without_retry(
    portal_client,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    login_operator(portal_client, monkeypatch)

    async def fake_list() -> list[dict]:
        return [
            {
                "organization_id": str(ORGANIZATION_ID),
                "organization_code": "ORG_1",
                "organization_name": "Organization One",
                "timezone": "Asia/Kolkata",
                "lifecycle_status": "ACTIVE",
                "provisioning_status": "FAILED",
                "grafana_org_id": None,
                "attempt_count": 2,
                "last_attempt_at": None,
                "provisioned_at": None,
                "last_error": "Grafana API connection refused.",
            }
        ]

    monkeypatch.setattr(
        "src.main.list_organizations_with_grafana_status",
        fake_list,
    )

    response = portal_client.get(
        "/administration/organizations"
    )

    assert response.status_code == 200
    assert "FAILED" in response.text
    assert (
        "Grafana provisioning did not complete."
        in response.text
    )
    assert "Grafana API connection refused." not in response.text
    assert "Retry Grafana provisioning" not in response.text
    assert "/grafana/retry" not in response.text


def test_operator_cannot_post_grafana_retry(
    portal_client,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    login_operator(portal_client, monkeypatch)

    response = portal_client.post(
        (
            "/administration/organizations/"
            f"{ORGANIZATION_ID}/grafana/retry"
        ),
        follow_redirects=False,
    )

    assert response.status_code == 303
    assert response.headers["location"] == "/forbidden"
