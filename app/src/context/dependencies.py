"""FastAPI dependencies enforcing the three-tier organization/site/location
scope model: each tier requires its parent tier to already be active, so a
route depending on site_context is automatically satisfied only when both
an organization and a site are active, and a request scoped to that site
transitively covers every child location/asset under it while remaining
isolated from sites outside the active scope. Which organizations/sites/
locations can ever become "active" is itself scope-validated against the
authenticated user in src.context.service.set_active_{organization,site,
location} (backed by portal_user_id-scoped repository queries) -- these
dependencies only check that a validly-scoped tier is currently selected.

Raising AdministrationContextError here is safe to use directly as a
FastAPI dependency: main.py registers an exception handler for it that
converts it into the same "redirect to /forbidden" response every other
authorization failure in this app produces.
"""

from fastapi import Request

from src.context.models import AdministrationContext
from src.context.service import (
    require_location_context,
    require_organization_context,
    require_site_context,
)


def organization_context(request: Request) -> AdministrationContext:
    """Require an active organization. Child sites/locations/assets are
    reachable only through the narrower dependencies below."""

    return require_organization_context(request)


def site_context(request: Request) -> AdministrationContext:
    """Require an active site (and its parent organization). All child
    locations and assets under this site inherit access; other sites do
    not."""

    return require_site_context(request)


def location_context(request: Request) -> AdministrationContext:
    """Require an active location (and its parent site and organization)."""

    return require_location_context(request)
