"""Which portal identities each entry point accepts (ADR-023).

There is one identity store (admin.portal_users) for WiseWatts staff and
customers. What separates them is the access scope: a GLOBAL-scope identity
is WiseWatts staff; an ORGANIZATION- or SELECTED_SITES-scope identity belongs
to a customer organisation. Data access is re-derived in the database from
portal_user_id on every read (admin.portal_user_can_access_site), so these
predicates decide only which host an identity may sign in to -- they never
widen what it can read.
"""

from __future__ import annotations

from collections.abc import Callable

from src.auth.access_scope import PortalAccessScopeMode
from src.auth.models import AuthenticatedPortalUser

Audience = Callable[[AuthenticatedPortalUser], bool]


def is_staff_identity(user: AuthenticatedPortalUser) -> bool:
    """WiseWatts staff: a GLOBAL-scope portal identity."""

    return user.access_scope_mode == PortalAccessScopeMode.GLOBAL.value


def staff_audience(user: AuthenticatedPortalUser) -> bool:
    """The staff-only Administration App audience."""

    return is_staff_identity(user)


def customer_audience(*, allow_staff: bool) -> Audience:
    """The customer API audience: customer identities, plus staff if allowed."""

    def accepts(user: AuthenticatedPortalUser) -> bool:
        return allow_staff or not is_staff_identity(user)

    return accepts
