from dataclasses import replace
from datetime import timedelta

from argon2 import PasswordHasher

from src.auth.models import PortalUserAuthenticationRecord
from src.auth.security import (
    hash_portal_password,
    AuthenticationStatus,
    portal_account_status,
    safe_authenticated_user,
    verify_portal_password,
)


def test_active_unlocked_account_is_authenticatable(
    active_authentication_record: PortalUserAuthenticationRecord,
    fixed_utc_time,
) -> None:
    assert (
        portal_account_status(
            active_authentication_record,
            now=fixed_utc_time,
        )
        is AuthenticationStatus.AUTHENTICATED
    )


def test_disabled_account_is_rejected_before_lock_state(
    active_authentication_record: PortalUserAuthenticationRecord,
    fixed_utc_time,
) -> None:
    user = replace(
        active_authentication_record,
        is_active=False,
        locked_until=fixed_utc_time + timedelta(hours=1),
    )

    assert (
        portal_account_status(user, now=fixed_utc_time)
        is AuthenticationStatus.ACCOUNT_DISABLED
    )


def test_future_lock_rejects_account(
    active_authentication_record: PortalUserAuthenticationRecord,
    fixed_utc_time,
) -> None:
    user = replace(
        active_authentication_record,
        locked_until=fixed_utc_time + timedelta(seconds=1),
    )

    assert (
        portal_account_status(user, now=fixed_utc_time)
        is AuthenticationStatus.ACCOUNT_LOCKED
    )


def test_expired_lock_allows_authentication(
    active_authentication_record: PortalUserAuthenticationRecord,
    fixed_utc_time,
) -> None:
    user = replace(
        active_authentication_record,
        locked_until=fixed_utc_time - timedelta(seconds=1),
    )

    assert (
        portal_account_status(user, now=fixed_utc_time)
        is AuthenticationStatus.AUTHENTICATED
    )


def test_lock_expiring_exactly_now_is_not_active(
    active_authentication_record: PortalUserAuthenticationRecord,
    fixed_utc_time,
) -> None:
    user = replace(
        active_authentication_record,
        locked_until=fixed_utc_time,
    )

    assert (
        portal_account_status(user, now=fixed_utc_time)
        is AuthenticationStatus.AUTHENTICATED
    )


def test_safe_authenticated_user_excludes_authentication_secrets(
    active_authentication_record: PortalUserAuthenticationRecord,
) -> None:
    safe_user = safe_authenticated_user(
        active_authentication_record
    )

    assert safe_user.portal_user_id == 10
    assert safe_user.username == "operator@example.com"
    assert safe_user.display_name == "Test Operator"
    assert safe_user.role_code == "OPERATOR"
    assert not hasattr(safe_user, "password_hash")
    assert not hasattr(safe_user, "locked_until")


def test_verify_portal_password_accepts_correct_password() -> None:
    password_hash = PasswordHasher().hash(
        "correct-horse-battery-staple"
    )

    assert verify_portal_password(
        password_hash,
        "correct-horse-battery-staple",
    )


def test_verify_portal_password_rejects_wrong_password() -> None:
    password_hash = PasswordHasher().hash(
        "correct-horse-battery-staple"
    )

    assert not verify_portal_password(
        password_hash,
        "wrong-password",
    )


def test_verify_portal_password_rejects_empty_password() -> None:
    password_hash = PasswordHasher().hash("valid-password")

    assert not verify_portal_password(password_hash, "")


def test_verify_portal_password_rejects_corrupt_hash() -> None:
    assert not verify_portal_password(
        "not-an-argon2-hash",
        "submitted-password",
    )


def test_safe_authenticated_user_preserves_organization_scope(
    active_authentication_record: PortalUserAuthenticationRecord,
) -> None:
    scoped_record = replace(
        active_authentication_record,
        role_code="ORG_ADMIN",
        organization_id="11111111-1111-1111-1111-111111111111",
    )

    safe_user = safe_authenticated_user(scoped_record)

    assert safe_user.organization_id == (
        "11111111-1111-1111-1111-111111111111"
    )


def test_hash_portal_password_creates_verifiable_argon2id_hash() -> None:
    password_hash = hash_portal_password("ValidPassword123!")

    assert password_hash.startswith("$argon2id$")
    assert verify_portal_password(
        password_hash,
        "ValidPassword123!",
    )
    assert not verify_portal_password(
        password_hash,
        "WrongPassword123!",
    )
