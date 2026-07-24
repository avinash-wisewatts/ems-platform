from dataclasses import dataclass
from datetime import datetime


@dataclass(frozen=True, slots=True)
class PortalUserAuthenticationRecord:
    """
    Restricted portal-user record used only during authentication.

    The password hash is intentionally confined to the authentication layer and
    must never be placed in a browser session, template context, log entry, or
    API response.
    """

    portal_user_id: int
    username: str
    display_name: str
    password_hash: str
    role_code: str
    is_active: bool
    failed_login_count: int
    locked_until: datetime | None


@dataclass(frozen=True, slots=True)
class AuthenticatedPortalUser:
    """
    Safe identity representation suitable for a signed server session.

    No password-derived material is included.
    """

    portal_user_id: int
    username: str
    display_name: str
    role_code: str
