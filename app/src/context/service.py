"""Application service for server-validated administration context."""

from uuid import UUID

from fastapi import Request

from src.auth.models import AuthenticatedPortalUser
from src.context.models import AdministrationContext
from src.context.session import (
    SESSION_CONTEXT_KEY,
    deserialize_administration_context,
    serialize_administration_context,
)


class AdministrationContextError(ValueError):
    """Safe context-selection failure."""


GENERIC_CONTEXT_ERROR = "The selected administration context is not available."


async def _accessible_organizations(
    *,
    user: AuthenticatedPortalUser,
) -> list[dict]:
    from src.context.repository import (
        list_accessible_organizations_for_user,
    )

    return await list_accessible_organizations_for_user(
        portal_user_id=user.portal_user_id,
        role_code=user.role_code,
        access_scope_mode=user.access_scope_mode,
        assigned_organization_id=user.organization_id,
    )


async def _accessible_sites(
    *,
    user: AuthenticatedPortalUser,
) -> list[dict]:
    from src.context.repository import list_accessible_sites_for_user

    return await list_accessible_sites_for_user(
        portal_user_id=user.portal_user_id
    )


async def _accessible_locations(
    *,
    user: AuthenticatedPortalUser,
) -> list[dict]:
    from src.context.repository import (
        list_accessible_locations_for_user,
    )

    return await list_accessible_locations_for_user(
        portal_user_id=user.portal_user_id
    )


def _normalize_uuid(value: str) -> str:
    try:
        return str(UUID(value.strip()))
    except (AttributeError, ValueError) as exc:
        raise AdministrationContextError(GENERIC_CONTEXT_ERROR) from exc


def get_administration_context(request: Request) -> AdministrationContext:
    """Return valid session context or an empty context."""

    session = getattr(request, "session", None)
    if not isinstance(session, dict):
        return AdministrationContext()

    context = deserialize_administration_context(
        session.get(SESSION_CONTEXT_KEY)
    )
    return context or AdministrationContext()


def store_administration_context(
    request: Request,
    context: AdministrationContext,
) -> None:
    """Store one validated context in the signed session."""

    request.session[SESSION_CONTEXT_KEY] = (
        serialize_administration_context(context)
    )


def bootstrap_context_for_identity(
    request: Request,
    user: AuthenticatedPortalUser,
) -> AdministrationContext:
    """Initialize context after login without changing assigned scope."""

    context = AdministrationContext(
        active_organization_id=(
            None
            if user.access_scope_mode == "GLOBAL"
            else user.organization_id
        )
    )
    store_administration_context(request, context)
    return context


def clear_administration_context(request: Request) -> None:
    """Remove active administration context but preserve identity."""

    request.session.pop(SESSION_CONTEXT_KEY, None)


async def set_active_organization(
    request: Request,
    user: AuthenticatedPortalUser,
    organization_id: str,
) -> AdministrationContext:
    """Validate and establish organization context."""

    normalized_id = _normalize_uuid(organization_id)
    organizations = await _accessible_organizations(user=user)

    selected = next(
        (
            organization
            for organization in organizations
            if str(
                organization.get("id")
                or organization.get("organization_id")
            ) == normalized_id
        ),
        None,
    )

    if selected is None:
        raise AdministrationContextError(GENERIC_CONTEXT_ERROR)

    context = AdministrationContext(
        active_organization_id=normalized_id,
        active_organization_name=(
            selected.get("organization_name")
            or selected.get("name")
        ),
        active_organization_code=(
            selected.get("organization_code")
            or selected.get("code")
        ),
    )
    store_administration_context(request, context)
    return context


async def set_active_site(
    request: Request,
    user: AuthenticatedPortalUser,
    site_id: str,
) -> AdministrationContext:
    """Validate and establish site and parent organization context."""

    normalized_id = _normalize_uuid(site_id)
    sites = await _accessible_sites(user=user)
    selected = next(
        (
            site
            for site in sites
            if str(
                site.get("id") or site.get("site_id")
            ) == normalized_id
        ),
        None,
    )

    if selected is None:
        raise AdministrationContextError(GENERIC_CONTEXT_ERROR)

    selected_organization_id = str(selected.get("organization_id"))
    try:
        selected_organization_id = _normalize_uuid(
            selected_organization_id
        )
    except AdministrationContextError as exc:
        raise AdministrationContextError(GENERIC_CONTEXT_ERROR) from exc

    context = AdministrationContext(
        active_organization_id=selected_organization_id,
        active_organization_name=selected.get("organization_name"),
        active_organization_code=selected.get("organization_code"),
        active_site_id=normalized_id,
        active_site_name=(
            selected.get("site_name") or selected.get("name")
        ),
        active_site_code=(
            selected.get("site_code") or selected.get("code")
        ),
    )
    store_administration_context(request, context)
    return context


async def set_active_location(
    request: Request,
    user: AuthenticatedPortalUser,
    location_id: str,
) -> AdministrationContext:
    """Validate and establish a most-specific physical location."""

    current = get_administration_context(request)
    if current.active_site_id is None:
        raise AdministrationContextError(GENERIC_CONTEXT_ERROR)

    normalized_id = _normalize_uuid(location_id)
    locations = await _accessible_locations(user=user)

    selected = None
    for location in locations:
        candidate_ids = {
            str(location.get("building_id")),
            str(location.get("floor_id")),
            str(location.get("space_id")),
        }
        if normalized_id in candidate_ids:
            selected = location
            break

    if (
        selected is None
        or str(selected.get("site_id")) != current.active_site_id
        or str(selected.get("organization_id"))
        != current.active_organization_id
    ):
        raise AdministrationContextError(GENERIC_CONTEXT_ERROR)

    location_type = None
    location_name = None
    location_code = None
    for candidate_type, id_key, name_key, code_key in (
        ("SPACE", "space_id", "space_name", "space_code"),
        ("FLOOR", "floor_id", "floor_name", "floor_code"),
        ("BUILDING", "building_id", "building_name", "building_code"),
    ):
        if str(selected.get(id_key)) == normalized_id:
            location_type = candidate_type
            location_name = selected.get(name_key)
            location_code = selected.get(code_key)
            break

    context = AdministrationContext(
        active_organization_id=current.active_organization_id,
        active_organization_name=current.active_organization_name,
        active_organization_code=current.active_organization_code,
        active_site_id=current.active_site_id,
        active_site_name=current.active_site_name,
        active_site_code=current.active_site_code,
        active_location_id=normalized_id,
        active_location_name=location_name,
        active_location_code=location_code,
        active_location_type=location_type,
    )
    store_administration_context(request, context)
    return context


def clear_active_organization(request: Request) -> AdministrationContext:
    context = AdministrationContext()
    store_administration_context(request, context)
    return context


def clear_active_site(request: Request) -> AdministrationContext:
    current = get_administration_context(request)
    context = AdministrationContext(
        active_organization_id=current.active_organization_id,
        active_organization_name=current.active_organization_name,
        active_organization_code=current.active_organization_code,
    )
    store_administration_context(request, context)
    return context


def clear_active_location(request: Request) -> AdministrationContext:
    current = get_administration_context(request)
    context = AdministrationContext(
        active_organization_id=current.active_organization_id,
        active_organization_name=current.active_organization_name,
        active_organization_code=current.active_organization_code,
        active_site_id=current.active_site_id,
        active_site_name=current.active_site_name,
        active_site_code=current.active_site_code,
    )
    store_administration_context(request, context)
    return context


def require_organization_context(request: Request) -> AdministrationContext:
    context = get_administration_context(request)
    if context.active_organization_id is None:
        raise AdministrationContextError(GENERIC_CONTEXT_ERROR)
    return context


def require_site_context(request: Request) -> AdministrationContext:
    context = require_organization_context(request)
    if context.active_site_id is None:
        raise AdministrationContextError(GENERIC_CONTEXT_ERROR)
    return context


def require_location_context(request: Request) -> AdministrationContext:
    context = require_site_context(request)
    if context.active_location_id is None:
        raise AdministrationContextError(GENERIC_CONTEXT_ERROR)
    return context
