"""Change one's own portal password -- the single implementation behind the
Administration App's /administration/account/password page and the JSON
POST /api/admin/v1/me/password.

Rules (identical for both surfaces):
- the new password meets the account policy and differs from the current one;
- the account is active and is the signed-in identity;
- a locked account is refused before the current password is checked, so this
  cannot be used to keep guessing;
- a wrong current password counts towards the sign-in lockout;
- the change goes through admin.change_own_portal_user_password (audited).
"""

from __future__ import annotations

from dataclasses import dataclass

from psycopg.errors import DatabaseError

from src.auth.models import AuthenticatedPortalUser
from src.auth.repository import (
    get_portal_user_for_authentication,
    record_portal_login_failure,
)
from src.auth.security import (
    AuthenticationStatus,
    hash_portal_password,
    portal_account_status,
    verify_portal_password,
)
from src.user_account_policy import AccountPolicyError, validate_password
from src.user_management_service import change_own_password


@dataclass(frozen=True)
class OwnPasswordChangeError(Exception):
    """A refused own-password change; ``message`` is user-facing."""

    status_code: int
    code: str
    message: str

    def __str__(self) -> str:  # pragma: no cover - trivial
        return self.message


async def change_own_password_verified(
    actor: AuthenticatedPortalUser,
    *,
    current_password: str,
    new_password: str,
) -> None:
    """Change the actor's own password, or raise OwnPasswordChangeError."""

    try:
        new_password = validate_password(new_password, username=actor.username)
    except AccountPolicyError as exc:
        raise OwnPasswordChangeError(400, "invalid_request", str(exc)) from exc
    if new_password == current_password:
        raise OwnPasswordChangeError(400, "invalid_request", "The new password must differ from the current one.")

    record = await get_portal_user_for_authentication(actor.username)
    if record is None or record.portal_user_id != actor.portal_user_id or not record.is_active:
        raise OwnPasswordChangeError(403, "forbidden", "Your account cannot change its password.")
    if portal_account_status(record) is AuthenticationStatus.ACCOUNT_LOCKED:
        raise OwnPasswordChangeError(
            403,
            "account_locked",
            "Your account is temporarily locked after failed password attempts. Try again later.",
        )
    if not verify_portal_password(record.password_hash, current_password or ""):
        await record_portal_login_failure(record.portal_user_id)
        raise OwnPasswordChangeError(400, "invalid_current_password", "The current password is incorrect.")

    try:
        await change_own_password(
            portal_user_id=actor.portal_user_id,
            password_hash=hash_portal_password(new_password),
        )
    except DatabaseError as exc:
        raise OwnPasswordChangeError(409, "rejected", "The database rejected the password change.") from exc
