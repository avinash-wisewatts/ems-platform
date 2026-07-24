from datetime import datetime, timezone
from enum import Enum

from argon2 import PasswordHasher
from argon2.exceptions import InvalidHashError, VerificationError, VerifyMismatchError

from src.auth.models import (
    AuthenticatedPortalUser,
    PortalUserAuthenticationRecord,
)


class AuthenticationStatus(str, Enum):
    """Internal authentication result categories."""

    AUTHENTICATED = "AUTHENTICATED"
    INVALID_CREDENTIALS = "INVALID_CREDENTIALS"
    ACCOUNT_DISABLED = "ACCOUNT_DISABLED"
    ACCOUNT_LOCKED = "ACCOUNT_LOCKED"


_password_hasher = PasswordHasher(
    time_cost=3,
    memory_cost=65536,
    parallelism=4,
    hash_len=32,
    salt_len=16,
)


def verify_portal_password(
    password_hash: str,
    submitted_password: str,
) -> bool:
    """
    Verify a submitted password against an Argon2id hash.

    Invalid, corrupted, or unsupported hashes fail closed.
    """

    if not submitted_password:
        return False

    try:
        return _password_hasher.verify(
            password_hash,
            submitted_password,
        )
    except (
        VerifyMismatchError,
        VerificationError,
        InvalidHashError,
    ):
        return False


def portal_account_status(
    user: PortalUserAuthenticationRecord,
    *,
    now: datetime | None = None,
) -> AuthenticationStatus:
    """Evaluate whether the portal identity may attempt authentication."""

    if not user.is_active:
        return AuthenticationStatus.ACCOUNT_DISABLED

    comparison_time = now or datetime.now(timezone.utc)

    if (
        user.locked_until is not None
        and user.locked_until > comparison_time
    ):
        return AuthenticationStatus.ACCOUNT_LOCKED

    return AuthenticationStatus.AUTHENTICATED


def safe_authenticated_user(
    user: PortalUserAuthenticationRecord,
) -> AuthenticatedPortalUser:
    """Remove password and lockout fields from an authenticated identity."""

    return AuthenticatedPortalUser(
        portal_user_id=user.portal_user_id,
        username=user.username,
        display_name=user.display_name,
        role_code=user.role_code,
    )
