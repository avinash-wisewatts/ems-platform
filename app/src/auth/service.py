from dataclasses import dataclass

from argon2 import PasswordHasher

from src.auth.models import AuthenticatedPortalUser
from src.auth.repository import (
    get_portal_user_for_authentication,
    record_portal_login_failure,
    record_portal_login_success,
)
from src.auth.security import (
    AuthenticationStatus,
    portal_account_status,
    safe_authenticated_user,
    verify_portal_password,
)


@dataclass(frozen=True, slots=True)
class AuthenticationResult:
    """
    Safe authentication outcome returned to the HTTP layer.

    The result deliberately avoids exposing whether the username, password,
    account state, or lockout caused the failure. The login page must display
    one generic error for every unsuccessful result.
    """

    authenticated: bool
    user: AuthenticatedPortalUser | None
    status: AuthenticationStatus


# A valid Argon2id hash is used when the submitted username does not exist.
# Performing a real password verification in that case reduces observable
# timing differences between valid and invalid usernames.
_dummy_password_hash = PasswordHasher(
    time_cost=3,
    memory_cost=65536,
    parallelism=4,
    hash_len=32,
    salt_len=16,
).hash("ems-portal-dummy-password-never-used-for-login")


def normalize_username(username: str) -> str:
    """Normalize a submitted portal username."""

    return username.strip().lower()


async def authenticate_portal_user(
    username: str,
    password: str,
) -> AuthenticationResult:
    """
    Authenticate one portal user through the controlled database functions.

    The caller must always return a generic login failure message whenever
    authenticated is False.
    """

    normalized_username = normalize_username(username)

    if not normalized_username or not password:
        # Execute Argon2 verification even for structurally invalid input so
        # obvious blank submissions do not create a separate fast path.
        verify_portal_password(
            _dummy_password_hash,
            password or "invalid-empty-password",
        )

        return AuthenticationResult(
            authenticated=False,
            user=None,
            status=AuthenticationStatus.INVALID_CREDENTIALS,
        )

    user = await get_portal_user_for_authentication(
        normalized_username
    )

    if user is None:
        verify_portal_password(
            _dummy_password_hash,
            password,
        )

        return AuthenticationResult(
            authenticated=False,
            user=None,
            status=AuthenticationStatus.INVALID_CREDENTIALS,
        )

    account_status = portal_account_status(user)

    if account_status is AuthenticationStatus.ACCOUNT_DISABLED:
        # Verify the hash before returning so disabled accounts do not create
        # an obvious timing distinction from bad-password attempts.
        verify_portal_password(
            user.password_hash,
            password,
        )

        return AuthenticationResult(
            authenticated=False,
            user=None,
            status=AuthenticationStatus.ACCOUNT_DISABLED,
        )

    if account_status is AuthenticationStatus.ACCOUNT_LOCKED:
        verify_portal_password(
            user.password_hash,
            password,
        )

        return AuthenticationResult(
            authenticated=False,
            user=None,
            status=AuthenticationStatus.ACCOUNT_LOCKED,
        )

    if not verify_portal_password(
        user.password_hash,
        password,
    ):
        await record_portal_login_failure(
            user.portal_user_id
        )

        return AuthenticationResult(
            authenticated=False,
            user=None,
            status=AuthenticationStatus.INVALID_CREDENTIALS,
        )

    await record_portal_login_success(
        user.portal_user_id
    )

    return AuthenticationResult(
        authenticated=True,
        user=safe_authenticated_user(user),
        status=AuthenticationStatus.AUTHENTICATED,
    )
