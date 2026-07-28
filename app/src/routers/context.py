"""HTTP routes for active administration context changes."""

from typing import Annotated

from fastapi import APIRouter, Form, Request
from fastapi.responses import RedirectResponse

from src.auth.dependencies import require_authenticated_portal_user
from src.context.service import (
    AdministrationContextError,
    clear_active_location,
    clear_active_organization,
    clear_active_site,
    set_active_location,
    set_active_organization,
    set_active_site,
)


router = APIRouter(prefix="/context", tags=["administration-context"])


def _redirect(url: str) -> RedirectResponse:
    response = RedirectResponse(url=url, status_code=303)
    response.headers["Cache-Control"] = (
        "no-store, no-cache, must-revalidate, private"
    )
    response.headers["Pragma"] = "no-cache"
    response.headers["Expires"] = "0"
    return response


def _safe_return_path(value: str | None, fallback: str) -> str:
    if (
        not value
        or not value.startswith("/")
        or value.startswith("//")
        or "\r" in value
        or "\n" in value
    ):
        return fallback
    return value


@router.post("/organization")
async def select_organization(
    request: Request,
    organization_id: Annotated[str, Form()],
    return_to: Annotated[str, Form()] = "/administration",
) -> RedirectResponse:
    user = require_authenticated_portal_user(request)
    try:
        await set_active_organization(
            request,
            user,
            organization_id,
        )
    except AdministrationContextError:
        return _redirect("/administration/organizations?context_error=1")
    return _redirect(_safe_return_path(return_to, "/administration"))


@router.post("/organization/clear")
async def clear_organization(
    request: Request,
) -> RedirectResponse:
    user = require_authenticated_portal_user(request)
    if user.role_code != "PLATFORM_ADMIN":
        return _redirect("/forbidden")
    clear_active_organization(request)
    return _redirect("/administration/organizations")


@router.post("/site")
async def select_site(
    request: Request,
    site_id: Annotated[str, Form()],
    return_to: Annotated[str, Form()] = "/administration",
) -> RedirectResponse:
    user = require_authenticated_portal_user(request)
    try:
        await set_active_site(request, user, site_id)
    except AdministrationContextError:
        return _redirect("/administration/sites?context_error=1")
    return _redirect(_safe_return_path(return_to, "/administration/locations"))


@router.post("/site/clear")
async def clear_site(request: Request) -> RedirectResponse:
    clear_active_site(request)
    return _redirect("/administration/sites")


@router.post("/location")
async def select_location(
    request: Request,
    location_id: Annotated[str, Form()],
    return_to: Annotated[str, Form()] = "/administration",
) -> RedirectResponse:
    user = require_authenticated_portal_user(request)
    try:
        await set_active_location(request, user, location_id)
    except AdministrationContextError:
        return _redirect("/administration/locations?context_error=1")
    return _redirect(_safe_return_path(return_to, "/administration/assets"))


@router.post("/location/clear")
async def clear_location(request: Request) -> RedirectResponse:
    clear_active_location(request)
    return _redirect("/administration/locations")
