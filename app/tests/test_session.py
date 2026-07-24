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
    ["SUPER_ADMIN", "OPERATOR", "VIEWER"],
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
        }
    )

    assert result is not None
    assert result.role_code == role_code
