"""Account-field policy for portal user management (EMS Web App Admin -> Users,
the initial-administrator provisioning CLI).

Pure functions, no database: the database functions remain authoritative for
roles, scope and tenant boundaries; this module validates the free-text
fields before they reach them and generates temporary passwords.

Password policy: the Administration App's existing rule (at least 12
characters) plus an upper bound (bounded Argon2 work per request) and "not
the username". Temporary passwords come from the operating system CSPRNG.
"""

from __future__ import annotations

import re
import secrets
import string

PASSWORD_MIN_LENGTH = 12
PASSWORD_MAX_LENGTH = 128
TEMPORARY_PASSWORD_LENGTH = 20

USERNAME_MIN_LENGTH = 3
USERNAME_MAX_LENGTH = 128
DISPLAY_NAME_MAX_LENGTH = 200
EMAIL_MAX_LENGTH = 254

# Lower-case after normalization (the table requires lower(btrim(username))).
# Existing usernames are e-mail addresses or simple handles such as admin_user.
_USERNAME_PATTERN = re.compile(r"^[a-z0-9][a-z0-9._@+-]*$")
# Deliberately simple: one @, a dot in the domain, no whitespace.
_EMAIL_PATTERN = re.compile(r"^[^@\s]+@[^@\s]+\.[^@\s]+$")

# Unambiguous alphabet (no 0/O, 1/l/I) so a temporary password can be read out.
_TEMPORARY_ALPHABET = "".join(
    c for c in string.ascii_letters + string.digits if c not in "0O1lI"
) + "-_.!@#%"


class AccountPolicyError(ValueError):
    """A submitted account field breaks the policy; the message is user-facing."""


def normalize_username(username: str) -> str:
    value = (username or "").strip().lower()
    if not value:
        raise AccountPolicyError("Username is required.")
    if not USERNAME_MIN_LENGTH <= len(value) <= USERNAME_MAX_LENGTH:
        raise AccountPolicyError(
            f"Username must be {USERNAME_MIN_LENGTH}-{USERNAME_MAX_LENGTH} characters."
        )
    if not _USERNAME_PATTERN.match(value):
        raise AccountPolicyError(
            "Username may contain only letters, digits and . _ @ + - and must start with a letter or digit."
        )
    return value


def normalize_display_name(display_name: str) -> str:
    value = " ".join((display_name or "").split())
    if not value:
        raise AccountPolicyError("Full name is required.")
    if len(value) > DISPLAY_NAME_MAX_LENGTH:
        raise AccountPolicyError(f"Full name must be at most {DISPLAY_NAME_MAX_LENGTH} characters.")
    return value


def normalize_email(email: str) -> str:
    value = (email or "").strip()
    if not value:
        raise AccountPolicyError("Email address is required.")
    if len(value) > EMAIL_MAX_LENGTH or not _EMAIL_PATTERN.match(value):
        raise AccountPolicyError("Enter a valid email address.")
    return value


def validate_password(password: str, *, username: str | None = None) -> str:
    if not isinstance(password, str) or not password:
        raise AccountPolicyError("Password is required.")
    if len(password) < PASSWORD_MIN_LENGTH:
        raise AccountPolicyError(f"Passwords must contain at least {PASSWORD_MIN_LENGTH} characters.")
    if len(password) > PASSWORD_MAX_LENGTH:
        raise AccountPolicyError(f"Passwords must contain at most {PASSWORD_MAX_LENGTH} characters.")
    if not password.strip():
        raise AccountPolicyError("Passwords cannot be only whitespace.")
    if username and password.strip().lower() == username.strip().lower():
        raise AccountPolicyError("The password cannot be the username.")
    return password


def generate_temporary_password(length: int = TEMPORARY_PASSWORD_LENGTH) -> str:
    """A random password that satisfies validate_password (letters, digits, a symbol)."""

    if length < PASSWORD_MIN_LENGTH:
        raise ValueError("Temporary passwords must meet the minimum length.")
    while True:
        candidate = "".join(secrets.choice(_TEMPORARY_ALPHABET) for _ in range(length))
        if (
            any(c.islower() for c in candidate)
            and any(c.isupper() for c in candidate)
            and any(c.isdigit() for c in candidate)
            and any(not c.isalnum() for c in candidate)
        ):
            return candidate


def password_policy_description() -> dict[str, int]:
    """The policy the browser shows (and pre-checks); the server re-checks."""

    return {"min_length": PASSWORD_MIN_LENGTH, "max_length": PASSWORD_MAX_LENGTH}
