import pytest

from src.auth.models import AuthenticatedPortalUser
from src.auth.session import (
    deserialize_authenticated_user,
    serialize_authenticated_user,
)


def test_serialize_authenticated_user_contains_only_safe_fields(
    authenticated_operator: AuthenticatedPortalUser,
) -> None:
    payload = serialize_authenticated_user(
        authenticated_operator
    )

    assert payload == {
        "portal_user_id": 10,
        "username": "operator@example.com",
        "display_name": "Test Operator",
        "role_code": "OPERATOR",
        "organization_id": None,
    }

    assert "password_hash" not in payload
    assert "locked_until" not in payload
    assert "failed_login_count" not in payload


def test_session_round_trip(
    authenticated_operator: AuthenticatedPortalUser,
) -> None:
    payload = serialize_authenticated_user(
        authenticated_operator
    )

    assert deserialize_authenticated_user(payload) == (
        authenticated_operator
    )


@pytest.mark.parametrize(
    "payload",
    [
        None,
        "",
        [],
        123,
        {},
        {"portal_user_id": 0},
        {
            "portal_user_id": -1,
            "username": "user",
            "display_name": "User",
            "role_code": "OPERATOR",
        },
        {
            "portal_user_id": True,
            "username": "user",
            "display_name": "User",
            "role_code": "OPERATOR",
        },
        {
            "portal_user_id": 1,
            "username": "",
            "display_name": "User",
            "role_code": "OPERATOR",
        },
        {
            "portal_user_id": 1,
            "username": "   ",
            "display_name": "User",
            "role_code": "OPERATOR",
        },
        {
            "portal_user_id": 1,
            "username": "user",
            "display_name": "",
            "role_code": "OPERATOR",
        },
        {
            "portal_user_id": 1,
            "username": "user",
            "display_name": "User",
            "role_code": "UNKNOWN",
        },
    ],
)
def test_invalid_session_payloads_fail_closed(
    payload: object,
) -> None:
    assert deserialize_authenticated_user(payload) is None


@pytest.mark.parametrize(
    "role_code",
    ["PLATFORM_ADMIN", "ORG_ADMIN", "OPERATOR", "VIEWER"],
)
def test_deserializer_accepts_only_controlled_roles(
    role_code: str,
) -> None:
    result = deserialize_authenticated_user(
        {
            "portal_user_id": 1,
            "username": "user@example.com",
            "display_name": "Test User",
            "role_code": role_code,
            "organization_id": (
                "11111111-1111-1111-1111-111111111111"
                if role_code == "ORG_ADMIN"
                else None
            ),
        }
    )

    assert result is not None
    assert result.role_code == role_code


def test_session_round_trip_preserves_organization_scope() -> None:
    user = AuthenticatedPortalUser(
        portal_user_id=42,
        username="orgadmin@example.com",
        display_name="Organization Administrator",
        role_code="ORG_ADMIN",
        organization_id="11111111-1111-1111-1111-111111111111",
    )

    payload = serialize_authenticated_user(user)
    restored = deserialize_authenticated_user(payload)

    assert payload["organization_id"] == (
        "11111111-1111-1111-1111-111111111111"
    )
    assert restored == user


def test_platform_admin_session_allows_null_organization_scope() -> None:
    user = AuthenticatedPortalUser(
        portal_user_id=1,
        username="platform@example.com",
        display_name="Platform Administrator",
        role_code="PLATFORM_ADMIN",
        organization_id=None,
    )

    payload = serialize_authenticated_user(user)
    restored = deserialize_authenticated_user(payload)

    assert payload["organization_id"] is None
    assert restored == user


def test_tenant_role_session_rejects_missing_organization_scope() -> None:
    payload = {
        "portal_user_id": 42,
        "username": "orgadmin@example.com",
        "display_name": "Organization Administrator",
        "role_code": "ORG_ADMIN",
        "organization_id": None,
    }

    assert deserialize_authenticated_user(payload) is None


def test_session_rejects_invalid_organization_identifier() -> None:
    payload = {
        "portal_user_id": 42,
        "username": "orgadmin@example.com",
        "display_name": "Organization Administrator",
        "role_code": "ORG_ADMIN",
        "organization_id": "not-a-uuid",
    }

    assert deserialize_authenticated_user(payload) is None
