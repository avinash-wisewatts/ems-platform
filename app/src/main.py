from contextlib import asynccontextmanager
from pathlib import Path
from typing import Annotated, AsyncIterator
from uuid import UUID

from fastapi import FastAPI, Form, Request
from fastapi.responses import (
    HTMLResponse,
    JSONResponse,
    RedirectResponse,
    Response,
)
from fastapi.staticfiles import StaticFiles
from starlette.middleware.sessions import SessionMiddleware
from fastapi.templating import Jinja2Templates
from psycopg import sql
from psycopg.errors import DatabaseError

from src.auth.dependencies import (
    authenticated_actor,
    clear_authenticated_portal_user,
    get_authenticated_portal_user,
    require_authenticated_portal_user,
    set_authenticated_portal_user,
)
from src.auth.authorization import (
    PortalPermission,
    has_permission,
)
from src.auth.middleware import PortalAuthenticationMiddleware
from src.auth.service import authenticate_portal_user
from src.admin_navigation import administration_navigation
from src.config import get_settings
from src.database import (
    close_database_pool,
    database_connection,
    open_database_pool,
)
from src.onboarding.forms import (
    OnboardingForm,
    OnboardingValidationError,
)
from src.onboarding.repository import (
    list_asset_types,
    list_assets,
    list_buildings,
    list_device_categories,
    list_device_models,
    list_device_profiles,
    list_devices,
    list_floors,
    list_gateway_models,
    list_gateways,
    list_organizations,
    list_sites,
    list_spaces,
)
from src.onboarding.drafts import (
    get_onboarding_draft,
    get_submitted_onboarding_result,
    log_onboarding_submission_failure,
    save_onboarding_draft_step,
    submit_onboarding_draft,
)
from src.onboarding.asset import (
    AssetStepValidationError,
    allowed_relationships,
    validate_asset_step,
)
from src.onboarding.device import (
    DeviceStepValidationError,
    validate_device_step,
)
from src.onboarding.gateway import (
    GatewayStepValidationError,
    validate_gateway_step,
)
from src.onboarding.location import (
    LocationStepValidationError,
    validate_location_step,
)
from src.onboarding.organization import (
    OrganizationStepValidationError,
    validate_organization_step,
)
from src.onboarding.site import (
    SiteStepValidationError,
    validate_site_step,
)
from src.onboarding.statuses import status_options
from src.onboarding.database_errors import user_facing_database_error
from src.onboarding.service import onboard_energy_asset
from src.onboarding.organization_service import (
    create_organization,
    list_organizations_with_grafana_status,
)
from src.onboarding.grafana_provisioning_service import (
    provision_grafana_for_organization,
)

settings = get_settings()

base_directory = Path(__file__).resolve().parent


def portal_template_context(request: Request) -> dict:
    """
    Provide safe authenticated-user information to every Jinja template.

    Password hashes and other authentication-only fields are never included.
    Public pages receive current_portal_user=None.
    """

    current_user = get_authenticated_portal_user(request)

    path = request.url.path
    active_navigation_key = (
        "onboarding"
        if path == "/onboarding" or path.startswith("/onboarding/")
        else "overview"
        if path == "/administration"
        else None
    )

    return {
        "current_portal_user": current_user,
        "administration_navigation": administration_navigation(
            current_user.role_code if current_user else None
        ),
        "active_navigation_key": active_navigation_key,
    }


templates = Jinja2Templates(
    directory=str(base_directory / "templates"),
    context_processors=[portal_template_context],
)


@asynccontextmanager
async def lifespan(_: FastAPI) -> AsyncIterator[None]:
    """Initialize and close shared application resources."""
    await open_database_pool()

    try:
        yield
    finally:
        await close_database_pool()


app = FastAPI(
    title="WiseWatts EMS Administration Portal",
    version="0.2.0",
    lifespan=lifespan,
)

# Register the authentication gate first. Starlette inserts subsequently
# registered middleware outside earlier middleware, so SessionMiddleware below
# will verify and populate the session before this gate reads it.
app.add_middleware(
    PortalAuthenticationMiddleware,
)

app.add_middleware(
    SessionMiddleware,
    secret_key=settings.session_secret,
    session_cookie=settings.session_cookie_name,
    max_age=settings.session_max_age_seconds,
    same_site="lax",
    https_only=settings.session_https_only,
)

app.mount(
    "/static",
    StaticFiles(directory=str(base_directory / "static")),
    name="static",
)


async def render_onboarding_page(
    request: Request,
    error: str | None = None,
    status_code: int = 200,
    form_data: dict[str, str] | None = None,
    field_error_name: str | None = None,
    field_error_message: str | None = None,
) -> HTMLResponse:
    organizations = await list_organizations()
    sites = await list_sites()
    gateways = await list_gateways()
    devices = await list_devices()
    profiles = await list_device_profiles()
    asset_types = await list_asset_types()
    assets = await list_assets()
    spaces = await list_spaces()
    device_categories = await list_device_categories()

    return templates.TemplateResponse(
        request=request,
        name="onboarding.html",
        context={
            "environment": settings.app_env,
            "organizations": organizations,
            "sites": sites,
            "gateways": gateways,
            "devices": devices,
            "profiles": profiles,
            "asset_types": asset_types,
            "assets": assets,
            "spaces": spaces,
            "device_categories": device_categories,
            "error": error,
            "form_data": form_data or {},
            "field_error_name": field_error_name,
            "field_error_message": field_error_message,
        },
        status_code=status_code,
    )


def safe_login_redirect_path(next_path: str | None) -> str:
    """
    Return a safe local path after authentication.

    Only absolute application-relative paths are accepted. Protocol-relative
    and external URLs are rejected to prevent open-redirect attacks.
    """

    if (
        not next_path
        or not next_path.startswith("/")
        or next_path.startswith("//")
        or "\r" in next_path
        or "\n" in next_path
        or "\\r" in next_path
        or "\\n" in next_path
    ):
        return "/onboarding/organization"

    return next_path


async def render_login_page(
    request: Request,
    *,
    error: str | None = None,
    username: str = "",
    next_path: str | None = None,
    status_code: int = 200,
) -> HTMLResponse:
    """Render the portal login page."""

    return templates.TemplateResponse(
        request=request,
        name="login.html",
        context={
            "environment": settings.app_env,
            "error": error,
            "username": username,
            "next_path": safe_login_redirect_path(next_path),
        },
        status_code=status_code,
    )


@app.get("/login", response_class=HTMLResponse)
async def login_page(
    request: Request,
    next_path: str | None = None,
) -> Response:
    """Display the login page or redirect an existing session."""

    if get_authenticated_portal_user(request) is not None:
        return RedirectResponse(
            url=safe_login_redirect_path(next_path),
            status_code=303,
        )

    return await render_login_page(
        request,
        next_path=next_path,
    )


@app.post("/login")
async def login_submit(
    request: Request,
    username: Annotated[str, Form()],
    password: Annotated[str, Form()],
    next_path: Annotated[str, Form()] = "/onboarding/organization",
) -> Response:
    """
    Authenticate a portal user and establish a signed session.

    Every unsuccessful outcome uses the same external error message so the
    response does not reveal whether the username exists, is disabled, or is
    temporarily locked.
    """

    result = await authenticate_portal_user(
        username,
        password,
    )

    if not result.authenticated or result.user is None:
        clear_authenticated_portal_user(request)

        return await render_login_page(
            request,
            error="Invalid username or password.",
            username=username.strip(),
            next_path=next_path,
            status_code=401,
        )

    # Clear any pre-authentication session state before establishing the new
    # identity. This reduces session-fixation risk.
    clear_authenticated_portal_user(request)
    set_authenticated_portal_user(
        request,
        result.user,
    )

    return RedirectResponse(
        url=safe_login_redirect_path(next_path),
        status_code=303,
    )


@app.post("/logout")
async def logout_submit(
    request: Request,
) -> RedirectResponse:
    """End the current portal session."""

    clear_authenticated_portal_user(request)

    return RedirectResponse(
        url="/login",
        status_code=303,
    )


@app.get(
    "/forbidden",
    response_class=HTMLResponse,
    include_in_schema=False,
)
async def forbidden_page(
    request: Request,
) -> HTMLResponse:
    """Display a controlled authorization-denied response."""

    user = get_authenticated_portal_user(request)

    if user is None:
        return templates.TemplateResponse(
            request=request,
            name="forbidden.html",
            context={
                "environment": settings.app_env,
                "username": "unknown",
                "role_code": "UNAUTHENTICATED",
            },
            status_code=403,
        )

    return templates.TemplateResponse(
        request=request,
        name="forbidden.html",
        context={
            "environment": settings.app_env,
            "username": user.username,
            "role_code": user.role_code,
        },
        status_code=403,
    )


@app.get(
    "/administration",
    response_class=HTMLResponse,
    include_in_schema=False,
)
async def administration_workspace(
    request: Request,
) -> HTMLResponse:
    """Display the role-aware administration workspace."""

    return templates.TemplateResponse(
        request=request,
        name="administration.html",
        context={
            "environment": settings.app_env,
            "page_title": "Administration workspace",
            "active_navigation_key": "overview",
        },
    )

async def render_organization_administration(
    request: Request,
    *,
    form_data: dict | None = None,
    result: dict | None = None,
    error: str | None = None,
    status_code: int = 200,
) -> HTMLResponse:
    """Render the independent organization administration page."""

    user = require_authenticated_portal_user(request)

    organizations = (
        await list_organizations_with_grafana_status()
    )

    can_retry_grafana = has_permission(
        user,
        PortalPermission.RETRY_GRAFANA_PROVISIONING,
    )

    return templates.TemplateResponse(
        request=request,
        name="organizations.html",
        context={
            "environment": settings.app_env,
            "page_title": "Organizations",
            "form_data": form_data or {},
            "result": result,
            "error": error,
            "can_retry_grafana": can_retry_grafana,
            "show_grafana_internal_details": can_retry_grafana,
            "organizations": organizations,
            "lifecycle_statuses": (
                "DRAFT",
                "ACTIVE",
                "SUSPENDED",
                "DECOMMISSIONED",
            ),
            "active_navigation_key": "organizations",
        },
        status_code=status_code,
    )

@app.get(
    "/administration/organizations",
    response_class=HTMLResponse,
    include_in_schema=False,
)
async def organization_administration(
    request: Request,
) -> HTMLResponse:
    """Display the independent organization creation page."""

    require_authenticated_portal_user(request)

    return await render_organization_administration(
        request,
        form_data={
            "organization_timezone": "Asia/Kolkata",
            "organization_lifecycle_status": "ACTIVE",
        },
    )

@app.post(
    "/administration/organizations",
    response_class=HTMLResponse,
    include_in_schema=False,
)
async def create_organization_administration(
    request: Request,
    organization_name: Annotated[str, Form()],
    organization_code: Annotated[str, Form()],
    organization_timezone: Annotated[str, Form()] = "Asia/Kolkata",
    organization_lifecycle_status: Annotated[str, Form()] = "ACTIVE",
) -> HTMLResponse:
    """Create one EMS organization independently."""

    user = require_authenticated_portal_user(request)

    submitted_form_data = {
        "organization_name": organization_name,
        "organization_code": organization_code,
        "organization_timezone": organization_timezone,
        "organization_lifecycle_status": (
            organization_lifecycle_status
        ),
    }

    try:
        result = await create_organization(
            name=organization_name,
            code=organization_code,
            timezone=organization_timezone,
            lifecycle_status=organization_lifecycle_status,
            requested_by=user.username,
        )

        provisioning = await provision_grafana_for_organization(
            organization_id=result["organization_id"],
            organization_name=result["organization_name"],
        )

        result["grafana_provisioning"] = provisioning

    except DatabaseError as exc:
        database_message = user_facing_database_error(
            exc,
            fallback="The database rejected the organization request.",
        )

        return await render_organization_administration(
            request,
            form_data=submitted_form_data,
            error=database_message,
            status_code=409,
        )

    return await render_organization_administration(
        request,
        form_data={
            "organization_timezone": "Asia/Kolkata",
            "organization_lifecycle_status": "ACTIVE",
        },
        result=result,
        status_code=201,
    )


@app.post(
    (
        "/administration/organizations/"
        "{organization_id}/grafana/retry"
    ),
    response_class=HTMLResponse,
    include_in_schema=False,
)
async def retry_organization_grafana_provisioning(
    request: Request,
    organization_id: UUID,
) -> HTMLResponse:
    """Retry Grafana provisioning for one existing EMS organization."""

    require_authenticated_portal_user(request)

    organizations = await list_organizations()

    organization = next(
        (
            item
            for item in organizations
            if str(item["id"]) == str(organization_id)
        ),
        None,
    )

    if organization is None:
        return await render_organization_administration(
            request,
            error="The requested EMS organization was not found.",
            status_code=404,
        )

    try:
        provisioning = await provision_grafana_for_organization(
            organization_id=str(organization_id),
            organization_name=organization["organization_name"],
        )

    except DatabaseError as exc:
        database_message = user_facing_database_error(
            exc,
            fallback=(
                "The database rejected the Grafana provisioning retry."
            ),
        )

        return await render_organization_administration(
            request,
            error=database_message,
            status_code=409,
        )

    result = {
        "organization_id": str(organization_id),
        "organization_name": organization["organization_name"],
        "organization_code": organization["organization_code"],
        "grafana_provisioning": provisioning,
    }

    return await render_organization_administration(
        request,
        result=result,
        status_code=200,
    )

@app.get("/", include_in_schema=False)
async def root_redirect() -> RedirectResponse:
    """Open the EMS onboarding application."""

    return RedirectResponse(
        url="/onboarding/organization",
        status_code=303,
    )


@app.get("/onboarding", include_in_schema=False)
async def onboarding_redirect() -> RedirectResponse:
    """Redirect the legacy onboarding URL to the first wizard step."""

    return RedirectResponse(
        url="/onboarding/organization",
        status_code=303,
    )


async def save_owned_onboarding_draft_step(
    request: Request,
    *,
    draft_token: UUID | None,
    step: str,
    step_payload: dict,
    next_step: str,
) -> UUID:
    """
    Save a draft step using the authenticated portal identity.

    PostgreSQL remains authoritative for role and ownership enforcement.
    """

    user = require_authenticated_portal_user(request)

    return await save_onboarding_draft_step(
        draft_token=draft_token,
        step=step,
        step_payload=step_payload,
        next_step=next_step,
        portal_user_id=user.portal_user_id,
        role_code=user.role_code,
        requested_by=user.username,
    )


async def submit_owned_onboarding_draft(
    request: Request,
    *,
    draft_token: UUID,
) -> dict:
    """
    Submit a completed draft using the authenticated portal identity.
    """

    user = require_authenticated_portal_user(request)

    return await submit_onboarding_draft(
        draft_token=draft_token,
        portal_user_id=user.portal_user_id,
        role_code=user.role_code,
        requested_by=user.username,
    )


async def get_visible_onboarding_draft(
    request: Request,
    draft_token: UUID,
) -> dict | None:
    """
    Return one active draft visible to the authenticated portal user.

    PostgreSQL enforces ownership and PLATFORM_ADMIN override. This helper keeps
    identity propagation consistent across every onboarding route.
    """

    user = require_authenticated_portal_user(request)

    return await get_onboarding_draft(
        draft_token,
        portal_user_id=user.portal_user_id,
        role_code=user.role_code,
    )


async def get_visible_submitted_onboarding_result(
    request: Request,
    draft_token: UUID,
) -> dict | None:
    """
    Return one submitted result visible to the authenticated portal user.
    """

    user = require_authenticated_portal_user(request)

    return await get_submitted_onboarding_result(
        draft_token,
        portal_user_id=user.portal_user_id,
        role_code=user.role_code,
    )


async def render_organization_step(
    request: Request,
    *,
    draft_token: UUID | None = None,
    form_data: dict[str, str] | None = None,
    error: str | None = None,
    status_code: int = 200,
) -> HTMLResponse:
    """Render the Organization wizard step."""

    organizations = await list_organizations()

    return templates.TemplateResponse(
        request=request,
        name="onboarding/organization.html",
        context={
            "environment": settings.app_env,
            "page_title": "Organization",
            "page_description": (
                "Start by selecting an existing tenant or creating a new "
                "organization."
            ),
            "current_step": "Organization",
            "active_step": "organization",
            "completed_steps": [],
            "organizations": organizations,
            "draft_token": (
                str(draft_token)
                if draft_token
                else None
            ),
            "form_data": form_data or {},
            "error": error,
        },
        status_code=status_code,
    )


@app.get(
    "/onboarding/organization",
    response_class=HTMLResponse,
)
async def organization_step(
    request: Request,
    draft: str | None = None,
) -> HTMLResponse:
    """Open the Organization wizard step."""

    draft_token: UUID | None = None
    form_data: dict[str, str] = {}

    if draft:
        try:
            draft_token = UUID(draft)
        except ValueError:
            return await render_organization_step(
                request,
                error="The onboarding draft token is invalid.",
                status_code=400,
            )

        draft_record = await get_visible_onboarding_draft(
            request,
            draft_token,
        )

        if draft_record is None:
            return await render_organization_step(
                request,
                error=(
                    "The onboarding draft was not found or has expired."
                ),
                status_code=404,
            )

        organization = (
            draft_record["payload"].get("organization", {})
        )

        form_data = {
            "organization_mode": (
                organization.get("mode")
                or "CREATE_NEW"
            ),
            "existing_organization_id": (
                organization.get(
                    "existing_organization_id"
                )
                or ""
            ),
            "organization_name": (
                organization.get("name")
                or ""
            ),
            "organization_code": (
                organization.get("code")
                or ""
            ),
            "organization_description": (
                organization.get("description")
                or ""
            ),
        }

    return await render_organization_step(
        request,
        draft_token=draft_token,
        form_data=form_data,
    )


@app.post(
    "/onboarding/organization",
    response_class=HTMLResponse,
)
async def save_organization_step(
    request: Request,
    organization_mode: Annotated[str, Form()],
    draft_token: Annotated[str, Form()] = "",
    existing_organization_id: Annotated[str, Form()] = "",
    organization_name: Annotated[str, Form()] = "",
    organization_code: Annotated[str, Form()] = "",
    organization_description: Annotated[str, Form()] = "",
) -> HTMLResponse:
    """Validate and save the Organization wizard step."""

    submitted_form_data = {
        "organization_mode": organization_mode,
        "existing_organization_id": existing_organization_id,
        "organization_name": organization_name,
        "organization_code": organization_code,
        "organization_description": organization_description,
    }

    parsed_draft_token: UUID | None = None

    if draft_token.strip():
        try:
            parsed_draft_token = UUID(
                draft_token.strip()
            )
        except ValueError:
            return await render_organization_step(
                request,
                form_data=submitted_form_data,
                error="The onboarding draft token is invalid.",
                status_code=400,
            )

    try:
        organization_payload = (
            validate_organization_step(
                organization_mode=organization_mode,
                existing_organization_id=(
                    existing_organization_id
                ),
                organization_name=organization_name,
                organization_code=organization_code,
                organization_description=(
                    organization_description
                ),
            )
        )

        saved_draft_token = (
            await save_owned_onboarding_draft_step(
                request,
                draft_token=parsed_draft_token,
                step="organization",
                step_payload=organization_payload,
                next_step="site",
            )
        )

    except OrganizationStepValidationError as exc:
        return await render_organization_step(
            request,
            draft_token=parsed_draft_token,
            form_data=submitted_form_data,
            error=str(exc),
            status_code=422,
        )

    except DatabaseError as exc:
        database_message = user_facing_database_error(
            exc,
            fallback="The database rejected the onboarding draft.",
        )

        return await render_organization_step(
            request,
            draft_token=parsed_draft_token,
            form_data=submitted_form_data,
            error=database_message,
            status_code=409,
        )

    return RedirectResponse(
        url=(
            "/onboarding/site"
            f"?draft={saved_draft_token}"
        ),
        status_code=303,
    )


async def render_site_step(
    request: Request,
    *,
    draft_token: UUID,
    draft_record: dict,
    form_data: dict[str, str] | None = None,
    error: str | None = None,
    status_code: int = 200,
) -> HTMLResponse:
    """Render the Site wizard step."""

    organization = (
        draft_record["payload"].get("organization", {})
    )

    organization_mode = (
        organization.get("mode") or ""
    ).upper()

    sites = []

    if organization_mode == "USE_EXISTING":
        organization_id = organization.get(
            "existing_organization_id"
        )

        all_sites = await list_sites()

        sites = [
            site
            for site in all_sites
            if str(site["organization_id"])
            == str(organization_id)
        ]

        organizations = await list_organizations()

        selected_organization = next(
            (
                item
                for item in organizations
                if str(item["id"])
                == str(organization_id)
            ),
            None,
        )

        organization_label = (
            (
                f"{selected_organization['organization_name']} "
                f"— {selected_organization['organization_code']}"
            )
            if selected_organization
            else "Existing organization"
        )

    else:
        organization_label = (
            f"{organization.get('name')} "
            f"— {organization.get('code')}"
        )

    return templates.TemplateResponse(
        request=request,
        name="onboarding/site.html",
        context={
            "environment": settings.app_env,
            "page_title": "Site",
            "page_description": (
                "Select an existing facility or create a new site under "
                "the chosen organization."
            ),
            "current_step": "Site",
            "active_step": "site",
            "completed_steps": ["organization"],
            "draft_token": str(draft_token),
            "draft_record": draft_record,
            "organization_mode": organization_mode,
            "organization_label": organization_label,
            "sites": sites,
            "form_data": form_data or {},
            "error": error,
        },
        status_code=status_code,
    )


@app.get(
    "/onboarding/site",
    response_class=HTMLResponse,
)
async def site_step(
    request: Request,
    draft: str,
) -> HTMLResponse:
    """Open the Site wizard step."""

    try:
        draft_token = UUID(draft)
    except ValueError:
        return await render_organization_step(
            request,
            error="The onboarding draft token is invalid.",
            status_code=400,
        )

    draft_record = await get_visible_onboarding_draft(
            request,
            draft_token,
        )

    if draft_record is None:
        return await render_organization_step(
            request,
            error=(
                "The onboarding draft was not found or has expired."
            ),
            status_code=404,
        )

    organization = (
        draft_record["payload"].get("organization")
    )

    if not organization:
        return RedirectResponse(
            url=(
                "/onboarding/organization"
                f"?draft={draft_token}"
            ),
            status_code=303,
        )

    site = draft_record["payload"].get("site", {})

    address = site.get("address") or {}

    form_data = {
        "site_mode": (
            site.get("mode") or "CREATE_NEW"
        ),
        "existing_site_id": (
            site.get("existing_site_id") or ""
        ),
        "site_name": site.get("name") or "",
        "site_code": site.get("code") or "",
        "site_timezone": (
            site.get("timezone") or "Asia/Kolkata"
        ),
        "site_address": (
            address.get("full_address") or ""
        ),
    }

    return await render_site_step(
        request,
        draft_token=draft_token,
        draft_record=draft_record,
        form_data=form_data,
    )


@app.post(
    "/onboarding/site",
    response_class=HTMLResponse,
)
async def save_site_step(
    request: Request,
    draft_token: Annotated[str, Form()],
    site_mode: Annotated[str, Form()],
    existing_site_id: Annotated[str, Form()] = "",
    site_name: Annotated[str, Form()] = "",
    site_code: Annotated[str, Form()] = "",
    site_timezone: Annotated[str, Form()] = "Asia/Kolkata",
    site_address: Annotated[str, Form()] = "",
) -> HTMLResponse:
    """Validate and save the Site wizard step."""

    try:
        parsed_draft_token = UUID(draft_token)
    except ValueError:
        return await render_organization_step(
            request,
            error="The onboarding draft token is invalid.",
            status_code=400,
        )

    draft_record = await get_visible_onboarding_draft(
            request,
            parsed_draft_token,
        )

    if draft_record is None:
        return await render_organization_step(
            request,
            error=(
                "The onboarding draft was not found or has expired."
            ),
            status_code=404,
        )

    organization = (
        draft_record["payload"].get("organization", {})
    )

    submitted_form_data = {
        "site_mode": site_mode,
        "existing_site_id": existing_site_id,
        "site_name": site_name,
        "site_code": site_code,
        "site_timezone": site_timezone,
        "site_address": site_address,
    }

    try:
        site_payload = validate_site_step(
            site_mode=site_mode,
            existing_site_id=existing_site_id,
            site_name=site_name,
            site_code=site_code,
            site_timezone=site_timezone,
            site_address=site_address,
            organization_mode=(
                organization.get("mode") or ""
            ),
        )

        if site_payload["mode"] == "USE_EXISTING":
            all_sites = await list_sites()

            selected_site = next(
                (
                    site
                    for site in all_sites
                    if str(site["id"])
                    == site_payload["existing_site_id"]
                ),
                None,
            )

            if selected_site is None:
                raise SiteStepValidationError(
                    "The selected site does not exist."
                )

            if (
                str(selected_site["organization_id"])
                != str(
                    organization.get(
                        "existing_organization_id"
                    )
                )
            ):
                raise SiteStepValidationError(
                    "The selected site does not belong to the chosen "
                    "organization."
                )

        saved_draft_token = (
            await save_owned_onboarding_draft_step(
                request,
                draft_token=parsed_draft_token,
                step="site",
                step_payload=site_payload,
                next_step="location",
            )
        )

    except SiteStepValidationError as exc:
        return await render_site_step(
            request,
            draft_token=parsed_draft_token,
            draft_record=draft_record,
            form_data=submitted_form_data,
            error=str(exc),
            status_code=422,
        )

    except DatabaseError as exc:
        database_message = user_facing_database_error(
            exc,
            fallback="The database rejected the onboarding draft.",
        )

        return await render_site_step(
            request,
            draft_token=parsed_draft_token,
            draft_record=draft_record,
            form_data=submitted_form_data,
            error=database_message,
            status_code=409,
        )

    return RedirectResponse(
        url=(
            "/onboarding/location"
            f"?draft={saved_draft_token}"
        ),
        status_code=303,
    )


async def render_location_step(
    request: Request,
    *,
    draft_token: UUID,
    draft_record: dict,
    form_data: dict[str, str] | None = None,
    error: str | None = None,
    status_code: int = 200,
) -> HTMLResponse:
    """Render the Physical Location wizard step."""

    organization = (
        draft_record["payload"].get("organization", {})
    )

    site = draft_record["payload"].get("site", {})

    organization_mode = (
        organization.get("mode") or ""
    ).upper()

    site_mode = (
        site.get("mode") or ""
    ).upper()

    organization_id = (
        organization.get("existing_organization_id")
        if organization_mode == "USE_EXISTING"
        else None
    )

    site_id = (
        site.get("existing_site_id")
        if site_mode == "USE_EXISTING"
        else None
    )

    spaces: list[dict] = []
    buildings: list[dict] = []
    floors: list[dict] = []

    if organization_id and site_id:
        all_spaces = await list_spaces()
        all_buildings = await list_buildings()
        all_floors = await list_floors()

        spaces = [
            space
            for space in all_spaces
            if str(space["organization_id"])
            == str(organization_id)
            and str(space["site_id"])
            == str(site_id)
        ]

        buildings = [
            building
            for building in all_buildings
            if str(building["organization_id"])
            == str(organization_id)
            and str(building["site_id"])
            == str(site_id)
        ]

        floors = [
            floor
            for floor in all_floors
            if str(floor["organization_id"])
            == str(organization_id)
            and str(floor["site_id"])
            == str(site_id)
        ]

    if site_mode == "USE_EXISTING":
        all_sites = await list_sites()

        selected_site = next(
            (
                item
                for item in all_sites
                if str(item["id"])
                == str(site_id)
            ),
            None,
        )

        site_label = (
            (
                f"{selected_site['site_name']} "
                f"— {selected_site['site_code']}"
            )
            if selected_site
            else "Existing site"
        )

    else:
        site_label = (
            f"{site.get('name')} "
            f"— {site.get('code')}"
        )

    return templates.TemplateResponse(
        request=request,
        name="onboarding/location.html",
        context={
            "environment": settings.app_env,
            "page_title": "Physical Location",
            "page_description": (
                "Define where the gateway and operational asset are "
                "installed."
            ),
            "current_step": "Physical Location",
            "active_step": "location",
            "completed_steps": [
                "organization",
                "site",
            ],
            "draft_token": str(draft_token),
            "draft_record": draft_record,
            "site_label": site_label,
            "spaces": spaces,
            "buildings": buildings,
            "floors": floors,
            "form_data": form_data or {},
            "error": error,
        },
        status_code=status_code,
    )


@app.get(
    "/onboarding/location",
    response_class=HTMLResponse,
)
async def location_step(
    request: Request,
    draft: str,
) -> HTMLResponse:
    """Open the Physical Location wizard step."""

    try:
        draft_token = UUID(draft)
    except ValueError:
        return await render_organization_step(
            request,
            error="The onboarding draft token is invalid.",
            status_code=400,
        )

    draft_record = await get_visible_onboarding_draft(
            request,
            draft_token,
        )

    if draft_record is None:
        return await render_organization_step(
            request,
            error=(
                "The onboarding draft was not found or has expired."
            ),
            status_code=404,
        )

    organization = (
        draft_record["payload"].get("organization")
    )

    if not organization:
        return RedirectResponse(
            url=(
                "/onboarding/organization"
                f"?draft={draft_token}"
            ),
            status_code=303,
        )

    site = draft_record["payload"].get("site")

    if not site:
        return RedirectResponse(
            url=(
                "/onboarding/site"
                f"?draft={draft_token}"
            ),
            status_code=303,
        )

    location = (
        draft_record["payload"].get("location", {})
    )

    form_data = {
        "location_mode": (
            location.get("mode") or "SITE_ONLY"
        ),
        "existing_space_id": (
            location.get("existing_space_id") or ""
        ),
        "building_name": (
            location.get("building_name") or ""
        ),
        "building_code": (
            location.get("building_code") or ""
        ),
        "floor_name": (
            location.get("floor_name") or ""
        ),
        "floor_code": (
            location.get("floor_code") or ""
        ),
        "space_name": (
            location.get("space_name") or ""
        ),
        "space_code": (
            location.get("space_code") or ""
        ),
    }

    return await render_location_step(
        request,
        draft_token=draft_token,
        draft_record=draft_record,
        form_data=form_data,
    )


@app.post(
    "/onboarding/location",
    response_class=HTMLResponse,
)
async def save_location_step(
    request: Request,
    draft_token: Annotated[str, Form()],
    location_mode: Annotated[str, Form()],
    existing_space_id: Annotated[str, Form()] = "",
    building_name: Annotated[str, Form()] = "",
    building_code: Annotated[str, Form()] = "",
    floor_name: Annotated[str, Form()] = "",
    floor_code: Annotated[str, Form()] = "",
    space_name: Annotated[str, Form()] = "",
    space_code: Annotated[str, Form()] = "",
) -> HTMLResponse:
    """Validate and save the Physical Location wizard step."""

    try:
        parsed_draft_token = UUID(draft_token)
    except ValueError:
        return await render_organization_step(
            request,
            error="The onboarding draft token is invalid.",
            status_code=400,
        )

    draft_record = await get_visible_onboarding_draft(
            request,
            parsed_draft_token,
        )

    if draft_record is None:
        return await render_organization_step(
            request,
            error=(
                "The onboarding draft was not found or has expired."
            ),
            status_code=404,
        )

    organization = (
        draft_record["payload"].get("organization")
    )

    site = draft_record["payload"].get("site")

    if not organization:
        return RedirectResponse(
            url=(
                "/onboarding/organization"
                f"?draft={parsed_draft_token}"
            ),
            status_code=303,
        )

    if not site:
        return RedirectResponse(
            url=(
                "/onboarding/site"
                f"?draft={parsed_draft_token}"
            ),
            status_code=303,
        )

    submitted_form_data = {
        "location_mode": location_mode,
        "existing_space_id": existing_space_id,
        "building_name": building_name,
        "building_code": building_code,
        "floor_name": floor_name,
        "floor_code": floor_code,
        "space_name": space_name,
        "space_code": space_code,
    }

    try:
        location_payload = validate_location_step(
            location_mode=location_mode,
            existing_space_id=existing_space_id,
            building_name=building_name,
            building_code=building_code,
            floor_name=floor_name,
            floor_code=floor_code,
            space_name=space_name,
            space_code=space_code,
        )

        if (
            location_payload["mode"]
            == "USE_EXISTING_SPACE"
        ):
            organization_mode = (
                organization.get("mode") or ""
            ).upper()

            site_mode = (
                site.get("mode") or ""
            ).upper()

            if (
                organization_mode != "USE_EXISTING"
                or site_mode != "USE_EXISTING"
            ):
                raise LocationStepValidationError(
                    "An existing space can only be selected when both "
                    "the organization and site already exist."
                )

            all_spaces = await list_spaces()

            selected_space = next(
                (
                    space
                    for space in all_spaces
                    if str(space["id"])
                    == location_payload[
                        "existing_space_id"
                    ]
                ),
                None,
            )

            if selected_space is None:
                raise LocationStepValidationError(
                    "The selected space does not exist."
                )

            if (
                str(selected_space["organization_id"])
                != str(
                    organization.get(
                        "existing_organization_id"
                    )
                )
                or str(selected_space["site_id"])
                != str(site.get("existing_site_id"))
            ):
                raise LocationStepValidationError(
                    "The selected space does not belong to the chosen "
                    "organization and site."
                )

        saved_draft_token = (
            await save_owned_onboarding_draft_step(
                request,
                draft_token=parsed_draft_token,
                step="location",
                step_payload=location_payload,
                next_step="gateway",
            )
        )

    except LocationStepValidationError as exc:
        return await render_location_step(
            request,
            draft_token=parsed_draft_token,
            draft_record=draft_record,
            form_data=submitted_form_data,
            error=str(exc),
            status_code=422,
        )

    except DatabaseError as exc:
        database_message = user_facing_database_error(
            exc,
            fallback="The database rejected the onboarding draft.",
        )

        return await render_location_step(
            request,
            draft_token=parsed_draft_token,
            draft_record=draft_record,
            form_data=submitted_form_data,
            error=database_message,
            status_code=409,
        )

    return RedirectResponse(
        url=(
            "/onboarding/gateway"
            f"?draft={saved_draft_token}"
        ),
        status_code=303,
    )


async def render_gateway_step(
    request: Request,
    *,
    draft_token: UUID,
    draft_record: dict,
    form_data: dict[str, str] | None = None,
    error: str | None = None,
    status_code: int = 200,
) -> HTMLResponse:
    """Render the Gateway wizard step."""

    organization = (
        draft_record["payload"].get("organization", {})
    )

    site = draft_record["payload"].get("site", {})

    organization_mode = (
        organization.get("mode") or ""
    ).upper()

    site_mode = (
        site.get("mode") or ""
    ).upper()

    organization_id = (
        organization.get("existing_organization_id")
        if organization_mode == "USE_EXISTING"
        else None
    )

    site_id = (
        site.get("existing_site_id")
        if site_mode == "USE_EXISTING"
        else None
    )

    gateways: list[dict] = []

    if organization_id and site_id:
        all_gateways = await list_gateways()

        gateways = [
            gateway
            for gateway in all_gateways
            if str(gateway["organization_id"])
            == str(organization_id)
            and str(gateway["site_id"])
            == str(site_id)
        ]

    allow_existing_gateway = bool(gateways)

    if site_mode == "USE_EXISTING":
        all_sites = await list_sites()

        selected_site = next(
            (
                item
                for item in all_sites
                if str(item["id"])
                == str(site_id)
            ),
            None,
        )

        site_label = (
            (
                f"{selected_site['site_name']} "
                f"— {selected_site['site_code']}"
            )
            if selected_site
            else "Existing site"
        )

    else:
        site_label = (
            f"{site.get('name')} "
            f"— {site.get('code')}"
        )

    gateway_models = await list_gateway_models()

    return templates.TemplateResponse(
        request=request,
        name="onboarding/gateway.html",
        context={
            "environment": settings.app_env,
            "page_title": "Gateway",
            "page_description": (
                "Select or register the communications gateway that will "
                "deliver telemetry to the EMS platform."
            ),
            "current_step": "Gateway",
            "active_step": "gateway",
            "completed_steps": [
                "organization",
                "site",
                "location",
            ],
            "draft_token": str(draft_token),
            "draft_record": draft_record,
            "site_label": site_label,
            "allow_existing_gateway": (
                allow_existing_gateway
            ),
            "gateways": gateways,
            "gateway_models": gateway_models,
            "form_data": form_data or {},
            "error": error,
        },
        status_code=status_code,
    )


@app.get(
    "/onboarding/gateway",
    response_class=HTMLResponse,
)
async def gateway_step(
    request: Request,
    draft: str,
) -> HTMLResponse:
    """Open the Gateway wizard step."""

    try:
        draft_token = UUID(draft)
    except ValueError:
        return await render_organization_step(
            request,
            error="The onboarding draft token is invalid.",
            status_code=400,
        )

    draft_record = await get_visible_onboarding_draft(
            request,
            draft_token,
        )

    if draft_record is None:
        return await render_organization_step(
            request,
            error=(
                "The onboarding draft was not found or has expired."
            ),
            status_code=404,
        )

    for required_step, redirect_path in (
        ("organization", "/onboarding/organization"),
        ("site", "/onboarding/site"),
        ("location", "/onboarding/location"),
    ):
        if not draft_record["payload"].get(required_step):
            return RedirectResponse(
                url=(
                    f"{redirect_path}"
                    f"?draft={draft_token}"
                ),
                status_code=303,
            )

    gateway = (
        draft_record["payload"].get("gateway", {})
    )

    form_data = {
        "gateway_mode": (
            gateway.get("mode") or "CREATE_NEW"
        ),
        "existing_gateway_id": (
            gateway.get("existing_gateway_id") or ""
        ),
        "gateway_name": (
            gateway.get("name") or ""
        ),
        "gateway_external_id": (
            gateway.get("external_id") or ""
        ),
        "gateway_vendor": (
            gateway.get("vendor") or ""
        ),
        "gateway_model": (
            gateway.get("model") or ""
        ),
        "gateway_protocol": (
            gateway.get("protocol") or "MQTT"
        ),
    }

    return await render_gateway_step(
        request,
        draft_token=draft_token,
        draft_record=draft_record,
        form_data=form_data,
    )


@app.post(
    "/onboarding/gateway",
    response_class=HTMLResponse,
)
async def save_gateway_step(
    request: Request,
    draft_token: Annotated[str, Form()],
    gateway_mode: Annotated[str, Form()],
    existing_gateway_id: Annotated[str, Form()] = "",
    gateway_name: Annotated[str, Form()] = "",
    gateway_external_id: Annotated[str, Form()] = "",
    gateway_vendor: Annotated[str, Form()] = "",
    gateway_model: Annotated[str, Form()] = "",
    gateway_protocol: Annotated[str, Form()] = "MQTT",
) -> HTMLResponse:
    """Validate and save the Gateway wizard step."""

    try:
        parsed_draft_token = UUID(draft_token)
    except ValueError:
        return await render_organization_step(
            request,
            error="The onboarding draft token is invalid.",
            status_code=400,
        )

    draft_record = await get_visible_onboarding_draft(
            request,
            parsed_draft_token,
        )

    if draft_record is None:
        return await render_organization_step(
            request,
            error=(
                "The onboarding draft was not found or has expired."
            ),
            status_code=404,
        )

    organization = (
        draft_record["payload"].get("organization", {})
    )

    site = (
        draft_record["payload"].get("site", {})
    )

    submitted_form_data = {
        "gateway_mode": gateway_mode,
        "existing_gateway_id": existing_gateway_id,
        "gateway_name": gateway_name,
        "gateway_external_id": gateway_external_id,
        "gateway_vendor": gateway_vendor,
        "gateway_model": gateway_model,
        "gateway_protocol": gateway_protocol,
    }

    try:
        gateway_payload = validate_gateway_step(
            gateway_mode=gateway_mode,
            existing_gateway_id=existing_gateway_id,
            gateway_name=gateway_name,
            gateway_external_id=gateway_external_id,
            gateway_vendor=gateway_vendor,
            gateway_model=gateway_model,
            gateway_protocol=gateway_protocol,
            organization_mode=(
                organization.get("mode") or ""
            ),
            site_mode=(
                site.get("mode") or ""
            ),
        )

        if gateway_payload["mode"] == "USE_EXISTING":
            all_gateways = await list_gateways()

            selected_gateway = next(
                (
                    gateway
                    for gateway in all_gateways
                    if str(gateway["id"])
                    == gateway_payload[
                        "existing_gateway_id"
                    ]
                ),
                None,
            )

            if selected_gateway is None:
                raise GatewayStepValidationError(
                    "The selected gateway does not exist."
                )

            if (
                str(selected_gateway["organization_id"])
                != str(
                    organization.get(
                        "existing_organization_id"
                    )
                )
                or str(selected_gateway["site_id"])
                != str(site.get("existing_site_id"))
            ):
                raise GatewayStepValidationError(
                    "The selected gateway does not belong to the "
                    "chosen organization and site."
                )

        saved_draft_token = (
            await save_owned_onboarding_draft_step(
                request,
                draft_token=parsed_draft_token,
                step="gateway",
                step_payload=gateway_payload,
                next_step="device",
            )
        )

    except GatewayStepValidationError as exc:
        return await render_gateway_step(
            request,
            draft_token=parsed_draft_token,
            draft_record=draft_record,
            form_data=submitted_form_data,
            error=str(exc),
            status_code=422,
        )

    except DatabaseError as exc:
        database_message = user_facing_database_error(
            exc,
            fallback="The database rejected the onboarding draft.",
        )

        return await render_gateway_step(
            request,
            draft_token=parsed_draft_token,
            draft_record=draft_record,
            form_data=submitted_form_data,
            error=database_message,
            status_code=409,
        )

    return RedirectResponse(
        url=(
            "/onboarding/device"
            f"?draft={saved_draft_token}"
        ),
        status_code=303,
    )


async def render_device_step(
    request: Request,
    *,
    draft_token: UUID,
    draft_record: dict,
    form_data: dict[str, str] | None = None,
    error: str | None = None,
    status_code: int = 200,
) -> HTMLResponse:
    """Render the Device wizard step."""

    gateway = draft_record["payload"].get("gateway", {})
    gateway_mode = (gateway.get("mode") or "").upper()

    gateway_id = (
        gateway.get("existing_gateway_id")
        if gateway_mode == "USE_EXISTING"
        else None
    )

    devices: list[dict] = []

    if gateway_id:
        all_devices = await list_devices()

        devices = [
            device
            for device in all_devices
            if str(device["gateway_id"])
            == str(gateway_id)
            and device.get("device_category_id") is not None
            and device.get("device_category_name")
            and device.get("profile_id") is not None
            and device.get("profile_code")
        ]

    allow_existing_device = bool(devices)

    if gateway_mode == "USE_EXISTING":
        all_gateways = await list_gateways()

        selected_gateway = next(
            (
                item
                for item in all_gateways
                if str(item["id"]) == str(gateway_id)
            ),
            None,
        )

        gateway_label = (
            (
                f"{selected_gateway['gateway_name']} "
                f"— {selected_gateway['external_id']}"
            )
            if selected_gateway
            else "Existing gateway"
        )
    else:
        gateway_label = (
            f"{gateway.get('name')} "
            f"— {gateway.get('external_id')}"
        )

    return templates.TemplateResponse(
        request=request,
        name="onboarding/device.html",
        context={
            "environment": settings.app_env,
            "page_title": "Device",
            "page_description": (
                "Select or register the field device that produces "
                "telemetry."
            ),
            "current_step": "Device",
            "active_step": "device",
            "completed_steps": [
                "organization",
                "site",
                "location",
                "gateway",
            ],
            "draft_token": str(draft_token),
            "draft_record": draft_record,
            "gateway_label": gateway_label,
            "allow_existing_device": allow_existing_device,
            "devices": devices,
            "device_categories": (
                await list_device_categories()
            ),
            "device_models": await list_device_models(),
            "device_profiles": (
                await list_device_profiles()
            ),
            "form_data": form_data or {},
            "error": error,
        },
        status_code=status_code,
    )


@app.get(
    "/onboarding/device",
    response_class=HTMLResponse,
)
async def device_step(
    request: Request,
    draft: str,
) -> HTMLResponse:
    """Open the Device wizard step."""

    try:
        draft_token = UUID(draft)
    except ValueError:
        return await render_organization_step(
            request,
            error="The onboarding draft token is invalid.",
            status_code=400,
        )

    draft_record = await get_visible_onboarding_draft(
        request,
        draft_token,
    )

    if draft_record is None:
        return await render_organization_step(
            request,
            error="The onboarding draft was not found or has expired.",
            status_code=404,
        )

    for required_step, redirect_path in (
        ("organization", "/onboarding/organization"),
        ("site", "/onboarding/site"),
        ("location", "/onboarding/location"),
        ("gateway", "/onboarding/gateway"),
    ):
        if not draft_record["payload"].get(required_step):
            return RedirectResponse(
                url=f"{redirect_path}?draft={draft_token}",
                status_code=303,
            )

    device = draft_record["payload"].get("device", {})
    identifier = device.get("identifier") or {}

    form_data = {
        "device_mode": (
            device.get("mode") or "CREATE_NEW"
        ),
        "existing_device_id": (
            device.get("existing_device_id") or ""
        ),
        "device_name": device.get("name") or "",
        "device_external_id": (
            device.get("external_id") or ""
        ),
        "device_category_id": (
            device.get("device_category_id") or ""
        ),
        "device_vendor": (
            device.get("model_vendor") or ""
        ),
        "device_model": device.get("model") or "",
        "device_protocol": (
            device.get("protocol") or "MQTT"
        ),
        "profile_code": (
            device.get("profile_code") or ""
        ),
        "firmware_version": (
            device.get("firmware_version") or ""
        ),
        "identifier_type": (
            identifier.get("type") or "MQTT_UID"
        ),
        "identifier_value": (
            identifier.get("value") or ""
        ),
    }

    return await render_device_step(
        request,
        draft_token=draft_token,
        draft_record=draft_record,
        form_data=form_data,
    )


@app.post(
    "/onboarding/device",
    response_class=HTMLResponse,
)
async def save_device_step(
    request: Request,
    draft_token: Annotated[str, Form()],
    device_mode: Annotated[str, Form()],
    existing_device_id: Annotated[str, Form()] = "",
    device_name: Annotated[str, Form()] = "",
    device_external_id: Annotated[str, Form()] = "",
    device_category_id: Annotated[str, Form()] = "",
    device_vendor: Annotated[str, Form()] = "",
    device_model: Annotated[str, Form()] = "",
    device_protocol: Annotated[str, Form()] = "MQTT",
    profile_code: Annotated[str, Form()] = "",
    firmware_version: Annotated[str, Form()] = "",
    identifier_type: Annotated[str, Form()] = "",
    identifier_value: Annotated[str, Form()] = "",
) -> HTMLResponse:
    """Validate and save the Device wizard step."""

    try:
        parsed_draft_token = UUID(draft_token)
    except ValueError:
        return await render_organization_step(
            request,
            error="The onboarding draft token is invalid.",
            status_code=400,
        )

    draft_record = await get_visible_onboarding_draft(
            request,
            parsed_draft_token,
        )

    if draft_record is None:
        return await render_organization_step(
            request,
            error="The onboarding draft was not found or has expired.",
            status_code=404,
        )

    gateway = draft_record["payload"].get("gateway", {})

    submitted_form_data = {
        "device_mode": device_mode,
        "existing_device_id": existing_device_id,
        "device_name": device_name,
        "device_external_id": device_external_id,
        "device_category_id": device_category_id,
        "device_vendor": device_vendor,
        "device_model": device_model,
        "device_protocol": device_protocol,
        "profile_code": profile_code,
        "firmware_version": firmware_version,
        "identifier_type": identifier_type,
        "identifier_value": identifier_value,
    }

    try:
        device_payload = validate_device_step(
            device_mode=device_mode,
            existing_device_id=existing_device_id,
            device_name=device_name,
            device_external_id=device_external_id,
            device_category_id=device_category_id,
            device_vendor=device_vendor,
            device_model=device_model,
            device_protocol=device_protocol,
            profile_code=profile_code,
            firmware_version=firmware_version,
            identifier_type=identifier_type,
            identifier_value=identifier_value,
            gateway_mode=gateway.get("mode") or "",
        )

        if device_payload["mode"] == "USE_EXISTING":
            all_devices = await list_devices()

            selected_device = next(
                (
                    device
                    for device in all_devices
                    if str(device["id"])
                    == device_payload["existing_device_id"]
                ),
                None,
            )

            if selected_device is None:
                raise DeviceStepValidationError(
                    "The selected device does not exist."
                )

            if (
                str(selected_device["gateway_id"])
                != str(gateway.get("existing_gateway_id"))
            ):
                raise DeviceStepValidationError(
                    "The selected device does not belong to the chosen "
                    "gateway."
                )

        else:
            categories = await list_device_categories()
            selected_category = next(
                (
                    category
                    for category in categories
                    if str(category["id"])
                    == device_payload["device_category_id"]
                ),
                None,
            )

            if selected_category is None:
                raise DeviceStepValidationError(
                    "The selected device category does not exist."
                )

            profiles = await list_device_profiles()
            selected_profile = next(
                (
                    profile
                    for profile in profiles
                    if profile["profile_code"]
                    == device_payload["profile_code"]
                ),
                None,
            )

            if selected_profile is None:
                raise DeviceStepValidationError(
                    "The selected telemetry profile does not exist."
                )

            compatible_ids = {
                str(category_id)
                for category_id in (
                    selected_profile[
                        "device_category_ids"
                    ] or []
                )
            }

            if (
                device_payload["device_category_id"]
                not in compatible_ids
            ):
                raise DeviceStepValidationError(
                    "The selected telemetry profile is not compatible "
                    "with the chosen device category."
                )

        saved_draft_token = (
            await save_owned_onboarding_draft_step(
                request,
                draft_token=parsed_draft_token,
                step="device",
                step_payload=device_payload,
                next_step="asset",
            )
        )

    except DeviceStepValidationError as exc:
        return await render_device_step(
            request,
            draft_token=parsed_draft_token,
            draft_record=draft_record,
            form_data=submitted_form_data,
            error=str(exc),
            status_code=422,
        )

    except DatabaseError as exc:
        database_message = user_facing_database_error(
            exc,
            fallback="The database rejected the onboarding draft.",
        )

        return await render_device_step(
            request,
            draft_token=parsed_draft_token,
            draft_record=draft_record,
            form_data=submitted_form_data,
            error=database_message,
            status_code=409,
        )

    return RedirectResponse(
        url=(
            "/onboarding/asset"
            f"?draft={saved_draft_token}"
        ),
        status_code=303,
    )


async def resolve_draft_device_context(
    draft_record: dict,
) -> tuple[str, str]:
    """Resolve the selected device label and controlled category."""

    device = draft_record["payload"].get("device", {})
    device_mode = (device.get("mode") or "").upper()

    if device_mode == "USE_EXISTING":
        all_devices = await list_devices()

        selected_device = next(
            (
                item
                for item in all_devices
                if str(item["id"])
                == str(device.get("existing_device_id"))
            ),
            None,
        )

        if selected_device is None:
            raise AssetStepValidationError(
                "The selected device no longer exists."
            )

        device_label = (
            f"{selected_device['device_name']} "
            f"— {selected_device['external_id']}"
        )

        category_name = (
            selected_device.get("device_category_name")
            or ""
        )

    else:
        categories = await list_device_categories()

        selected_category = next(
            (
                item
                for item in categories
                if str(item["id"])
                == str(device.get("device_category_id"))
            ),
            None,
        )

        if selected_category is None:
            raise AssetStepValidationError(
                "The selected device category no longer exists."
            )

        device_label = (
            f"{device.get('name')} "
            f"— {device.get('external_id')}"
        )

        category_name = selected_category["name"]

    return device_label, category_name


async def render_asset_step(
    request: Request,
    *,
    draft_token: UUID,
    draft_record: dict,
    form_data: dict[str, str] | None = None,
    error: str | None = None,
    status_code: int = 200,
) -> HTMLResponse:
    """Render the Asset wizard step."""

    organization = (
        draft_record["payload"].get("organization", {})
    )

    site = draft_record["payload"].get("site", {})

    organization_mode = (
        organization.get("mode") or ""
    ).upper()

    site_mode = (
        site.get("mode") or ""
    ).upper()

    organization_id = (
        organization.get("existing_organization_id")
        if organization_mode == "USE_EXISTING"
        else None
    )

    site_id = (
        site.get("existing_site_id")
        if site_mode == "USE_EXISTING"
        else None
    )

    assets: list[dict] = []

    if organization_id and site_id:
        all_assets = await list_assets()

        assets = [
            asset
            for asset in all_assets
            if str(asset["organization_id"])
            == str(organization_id)
            and str(asset["site_id"])
            == str(site_id)
            and asset["parent_asset_id"] is None
            and asset["status"] == "active"
        ]

    device_label, device_category_name = (
        await resolve_draft_device_context(
            draft_record
        )
    )

    relationships = allowed_relationships(
        device_category_name
    )

    return templates.TemplateResponse(
        request=request,
        name="onboarding/asset.html",
        context={
            "environment": settings.app_env,
            "page_title": "Asset",
            "page_description": (
                "Select or register the physical equipment monitored "
                "by the device."
            ),
            "current_step": "Asset",
            "active_step": "asset",
            "completed_steps": [
                "organization",
                "site",
                "location",
                "gateway",
                "device",
            ],
            "draft_token": str(draft_token),
            "draft_record": draft_record,
            "device_label": device_label,
            "device_category_name": (
                device_category_name
            ),
            "relationships": relationships,
            "allow_existing_asset": bool(assets),
            "assets": assets,
            "asset_types": await list_asset_types(),
            "metering_requirements": status_options(
                "METERING_REQUIREMENT"
            ),
            "form_data": form_data or {},
            "error": error,
        },
        status_code=status_code,
    )


@app.get(
    "/onboarding/asset",
    response_class=HTMLResponse,
)
async def asset_step(
    request: Request,
    draft: str,
) -> HTMLResponse:
    """Open the Asset wizard step."""

    try:
        draft_token = UUID(draft)
    except ValueError:
        return await render_organization_step(
            request,
            error="The onboarding draft token is invalid.",
            status_code=400,
        )

    draft_record = await get_visible_onboarding_draft(
            request,
            draft_token,
        )

    if draft_record is None:
        return await render_organization_step(
            request,
            error=(
                "The onboarding draft was not found or has expired."
            ),
            status_code=404,
        )

    for required_step, redirect_path in (
        ("organization", "/onboarding/organization"),
        ("site", "/onboarding/site"),
        ("location", "/onboarding/location"),
        ("gateway", "/onboarding/gateway"),
        ("device", "/onboarding/device"),
    ):
        if not draft_record["payload"].get(required_step):
            return RedirectResponse(
                url=f"{redirect_path}?draft={draft_token}",
                status_code=303,
            )

    asset = draft_record["payload"].get("asset", {})
    metadata = asset.get("metadata") or {}

    form_data = {
        "asset_mode": (
            asset.get("mode") or "CREATE_NEW"
        ),
        "existing_asset_id": (
            asset.get("existing_asset_id") or ""
        ),
        "asset_name": asset.get("name") or "",
        "asset_type_id": (
            asset.get("asset_type_id") or ""
        ),
        "metering_requirement": (
            asset.get("metering_requirement") or ""
        ),
        "relationship_type": (
            asset.get("relationship_type") or ""
        ),
        "operational_notes": (
            metadata.get("operational_notes") or ""
        ),
    }

    try:
        return await render_asset_step(
            request,
            draft_token=draft_token,
            draft_record=draft_record,
            form_data=form_data,
        )
    except AssetStepValidationError as exc:
        return RedirectResponse(
            url=(
                "/onboarding/device"
                f"?draft={draft_token}"
            ),
            status_code=303,
        )


@app.post(
    "/onboarding/asset",
    response_class=HTMLResponse,
)
async def save_asset_step(
    request: Request,
    draft_token: Annotated[str, Form()],
    asset_mode: Annotated[str, Form()],
    existing_asset_id: Annotated[str, Form()] = "",
    asset_name: Annotated[str, Form()] = "",
    asset_type_id: Annotated[str, Form()] = "",
    metering_requirement: Annotated[str, Form()] = "",
    relationship_type: Annotated[str, Form()] = "",
    operational_notes: Annotated[str, Form()] = "",
) -> HTMLResponse:
    """Validate and save the Asset wizard step."""

    try:
        parsed_draft_token = UUID(draft_token)
    except ValueError:
        return await render_organization_step(
            request,
            error="The onboarding draft token is invalid.",
            status_code=400,
        )

    draft_record = await get_visible_onboarding_draft(
            request,
            parsed_draft_token,
        )

    if draft_record is None:
        return await render_organization_step(
            request,
            error=(
                "The onboarding draft was not found or has expired."
            ),
            status_code=404,
        )

    organization = (
        draft_record["payload"].get("organization", {})
    )

    site = draft_record["payload"].get("site", {})

    submitted_form_data = {
        "asset_mode": asset_mode,
        "existing_asset_id": existing_asset_id,
        "asset_name": asset_name,
        "asset_type_id": asset_type_id,
        "metering_requirement": metering_requirement,
        "relationship_type": relationship_type,
        "operational_notes": operational_notes,
    }

    try:
        _, device_category_name = (
            await resolve_draft_device_context(
                draft_record
            )
        )

        asset_payload = validate_asset_step(
            asset_mode=asset_mode,
            existing_asset_id=existing_asset_id,
            asset_name=asset_name,
            asset_type_id=asset_type_id,
            metering_requirement=metering_requirement,
            relationship_type=relationship_type,
            operational_notes=operational_notes,
            device_category_name=device_category_name,
            organization_mode=(
                organization.get("mode") or ""
            ),
            site_mode=(
                site.get("mode") or ""
            ),
        )

        if asset_payload["mode"] == "USE_EXISTING":
            all_assets = await list_assets()

            selected_asset = next(
                (
                    asset
                    for asset in all_assets
                    if str(asset["id"])
                    == asset_payload["existing_asset_id"]
                ),
                None,
            )

            if selected_asset is None:
                raise AssetStepValidationError(
                    "The selected asset does not exist."
                )

            if (
                str(selected_asset["organization_id"])
                != str(
                    organization.get(
                        "existing_organization_id"
                    )
                )
                or str(selected_asset["site_id"])
                != str(site.get("existing_site_id"))
            ):
                raise AssetStepValidationError(
                    "The selected asset does not belong to the chosen "
                    "organization and site."
                )

        else:
            asset_types = await list_asset_types()

            selected_type = next(
                (
                    asset_type
                    for asset_type in asset_types
                    if str(asset_type["id"])
                    == asset_payload["asset_type_id"]
                ),
                None,
            )

            if selected_type is None:
                raise AssetStepValidationError(
                    "The selected asset type does not exist."
                )

        saved_draft_token = (
            await save_owned_onboarding_draft_step(
                request,
                draft_token=parsed_draft_token,
                step="asset",
                step_payload=asset_payload,
                next_step="review",
            )
        )

    except AssetStepValidationError as exc:
        return await render_asset_step(
            request,
            draft_token=parsed_draft_token,
            draft_record=draft_record,
            form_data=submitted_form_data,
            error=str(exc),
            status_code=422,
        )

    except DatabaseError as exc:
        database_message = user_facing_database_error(
            exc,
            fallback="The database rejected the onboarding draft.",
        )

        return await render_asset_step(
            request,
            draft_token=parsed_draft_token,
            draft_record=draft_record,
            form_data=submitted_form_data,
            error=database_message,
            status_code=409,
        )

    return RedirectResponse(
        url=(
            "/onboarding/review"
            f"?draft={saved_draft_token}"
        ),
        status_code=303,
    )


async def build_review_context(
    draft_record: dict,
) -> dict:
    """Resolve human-readable labels for the final review."""

    payload = draft_record["payload"]

    organization = payload["organization"]
    site = payload["site"]
    location = payload["location"]
    gateway = payload["gateway"]
    device = payload["device"]
    asset = payload["asset"]

    organization_label = (
        f"{organization.get('name')} — {organization.get('code')}"
    )

    if organization.get("mode") == "USE_EXISTING":
        organizations = await list_organizations()
        selected = next(
            (
                item
                for item in organizations
                if str(item["id"])
                == str(
                    organization.get(
                        "existing_organization_id"
                    )
                )
            ),
            None,
        )

        organization_label = (
            f"{selected['organization_name']} "
            f"— {selected['organization_code']}"
            if selected
            else "Existing organization"
        )

    site_label = (
        f"{site.get('name')} — {site.get('code')}"
    )

    if site.get("mode") == "USE_EXISTING":
        sites = await list_sites()
        selected = next(
            (
                item
                for item in sites
                if str(item["id"])
                == str(site.get("existing_site_id"))
            ),
            None,
        )

        site_label = (
            f"{selected['site_name']} — {selected['site_code']}"
            if selected
            else "Existing site"
        )

    location_label = "Site level"

    if location.get("mode") == "USE_EXISTING_SPACE":
        spaces = await list_spaces()
        selected = next(
            (
                item
                for item in spaces
                if str(item["id"])
                == str(location.get("existing_space_id"))
            ),
            None,
        )

        location_label = (
            f"{selected['building_name']} / "
            f"{selected['floor_name']} / "
            f"{selected['space_name']}"
            if selected
            else "Existing space"
        )

    elif location.get("mode") == "CREATE_LOCATION":
        location_label = (
            f"{location.get('building_name')} / "
            f"{location.get('floor_name')} / "
            f"{location.get('space_name')}"
        )

    gateway_label = (
        f"{gateway.get('name')} — {gateway.get('external_id')}"
    )

    if gateway.get("mode") == "USE_EXISTING":
        gateways = await list_gateways()
        selected = next(
            (
                item
                for item in gateways
                if str(item["id"])
                == str(gateway.get("existing_gateway_id"))
            ),
            None,
        )

        gateway_label = (
            f"{selected['gateway_name']} "
            f"— {selected['external_id']}"
            if selected
            else "Existing gateway"
        )

    device_label, device_category_name = (
        await resolve_draft_device_context(draft_record)
    )

    asset_label = (
        f"{asset.get('name')}"
    )

    asset_type_name = ""

    if asset.get("mode") == "USE_EXISTING":
        assets = await list_assets()
        selected = next(
            (
                item
                for item in assets
                if str(item["id"])
                == str(asset.get("existing_asset_id"))
            ),
            None,
        )

        asset_label = (
            f"{selected['asset_name']} "
            f"— {selected.get('asset_type_name') or 'Unclassified'}"
            if selected
            else "Existing asset"
        )

    else:
        asset_types = await list_asset_types()
        selected = next(
            (
                item
                for item in asset_types
                if str(item["id"])
                == str(asset.get("asset_type_id"))
            ),
            None,
        )

        asset_type_name = (
            selected["name"]
            if selected
            else "Unknown asset type"
        )

    return {
        "organization": organization,
        "site": site,
        "location": location,
        "gateway": gateway,
        "device": device,
        "asset": asset,
        "organization_label": organization_label,
        "site_label": site_label,
        "location_label": location_label,
        "gateway_label": gateway_label,
        "device_label": device_label,
        "device_category_name": device_category_name,
        "asset_label": asset_label,
        "asset_type_name": asset_type_name,
    }


async def render_review_step(
    request: Request,
    *,
    draft_token: UUID,
    draft_record: dict,
    error: str | None = None,
    submission_result: dict | None = None,
    status_code: int = 200,
) -> HTMLResponse:
    """Render final review or completed submission result."""

    context = {
        "environment": settings.app_env,
        "page_title": "Review",
        "page_description": (
            "Review all onboarding modules and execute one atomic "
            "production submission."
        ),
        "current_step": "Review",
        "active_step": "review",
        "completed_steps": [
            "organization",
            "site",
            "location",
            "gateway",
            "device",
            "asset",
        ],
        "draft_token": str(draft_token),
        "draft_record": draft_record,
        "submission_result": submission_result,
        "error": error,
    }

    if submission_result is None:
        context.update(
            await build_review_context(draft_record)
        )

    return templates.TemplateResponse(
        request=request,
        name="onboarding/review.html",
        context=context,
        status_code=status_code,
    )


@app.get(
    "/onboarding/result",
    response_class=HTMLResponse,
)
async def onboarding_result(
    request: Request,
    draft: str,
) -> HTMLResponse:
    """Display one immutable submitted onboarding result."""

    try:
        draft_token = UUID(draft)
    except ValueError:
        return await render_organization_step(
            request,
            error="The onboarding result token is invalid.",
            status_code=400,
        )

    record = await get_visible_submitted_onboarding_result(
            request,
            draft_token,
        )

    if record is None:
        return await render_organization_step(
            request,
            error=(
                "The submitted onboarding result was not found."
            ),
            status_code=404,
        )

    return templates.TemplateResponse(
        request=request,
        name="onboarding/result.html",
        context={
            "environment": settings.app_env,
            "page_title": "Onboarding Result",
            "page_description": (
                "Read-only production onboarding result."
            ),
            "current_step": "Completed",
            "active_step": "review",
            "completed_steps": [
                "organization",
                "site",
                "location",
                "gateway",
                "device",
                "asset",
                "review",
            ],
            "draft_token": str(draft_token),
            "record": record,
            "result": record["result"],
            "error": None,
        },
    )


@app.get(
    "/onboarding/review",
    response_class=HTMLResponse,
)
async def review_step(
    request: Request,
    draft: str,
) -> HTMLResponse:
    """Open the completed draft review."""

    try:
        draft_token = UUID(draft)
    except ValueError:
        return await render_organization_step(
            request,
            error="The onboarding draft token is invalid.",
            status_code=400,
        )

    draft_record = await get_visible_onboarding_draft(
            request,
            draft_token,
        )

    if draft_record is None:
        submitted_record = (
            await get_visible_submitted_onboarding_result(
            request,
            draft_token,
        )
        )

        if submitted_record is not None:
            return RedirectResponse(
                url=(
                    "/onboarding/result"
                    f"?draft={draft_token}"
                ),
                status_code=303,
            )

        return await render_organization_step(
            request,
            error=(
                "The onboarding draft was not found or has expired."
            ),
            status_code=404,
        )

    for required_step, redirect_path in (
        ("organization", "/onboarding/organization"),
        ("site", "/onboarding/site"),
        ("location", "/onboarding/location"),
        ("gateway", "/onboarding/gateway"),
        ("device", "/onboarding/device"),
        ("asset", "/onboarding/asset"),
    ):
        if not draft_record["payload"].get(required_step):
            return RedirectResponse(
                url=f"{redirect_path}?draft={draft_token}",
                status_code=303,
            )

    return await render_review_step(
        request,
        draft_token=draft_token,
        draft_record=draft_record,
    )


async def safely_log_submission_failure(
    *,
    draft_token: UUID,
    requested_by: str,
    error_message: str,
    error_type: str,
) -> None:
    """
    Record a submission failure without masking the original error.

    Audit persistence occurs in a separate transaction after the failed
    production transaction has rolled back.
    """

    try:
        await log_onboarding_submission_failure(
            draft_token=draft_token,
            requested_by=requested_by,
            error_message=error_message,
            error_type=error_type,
        )
    except Exception:
        # The original onboarding error remains the user-facing failure.
        # Application logging will be added with authenticated observability.
        pass


@app.post(
    "/onboarding/review",
    response_class=HTMLResponse,
)
async def submit_review_step(
    request: Request,
    draft_token: Annotated[str, Form()],
) -> HTMLResponse:
    """Execute final atomic onboarding submission."""

    try:
        parsed_draft_token = UUID(draft_token)
    except ValueError:
        return await render_organization_step(
            request,
            error="The onboarding draft token is invalid.",
            status_code=400,
        )

    draft_record = await get_visible_onboarding_draft(
            request,
            parsed_draft_token,
        )

    if draft_record is None:
        return await render_organization_step(
            request,
            error=(
                "The onboarding draft was not found, has expired, "
                "or was already submitted."
            ),
            status_code=404,
        )

    try:
        result = await submit_owned_onboarding_draft(
            request,
            draft_token=parsed_draft_token,
        )

    except OnboardingValidationError as exc:
        await safely_log_submission_failure(
            draft_token=parsed_draft_token,
            requested_by=authenticated_actor(request),
            error_message=exc.message,
            error_type=type(exc).__name__,
        )

        return await render_review_step(
            request,
            draft_token=parsed_draft_token,
            draft_record=draft_record,
            error=exc.message,
            status_code=422,
        )

    except DatabaseError as exc:
        database_message = user_facing_database_error(
            exc,
            fallback="The database rejected the final onboarding request.",
        )

        await safely_log_submission_failure(
            draft_token=parsed_draft_token,
            requested_by=authenticated_actor(request),
            error_message=database_message,
            error_type=type(exc).__name__,
        )

        return await render_review_step(
            request,
            draft_token=parsed_draft_token,
            draft_record=draft_record,
            error=database_message,
            status_code=409,
        )

    return RedirectResponse(
        url=(
            "/onboarding/result"
            f"?draft={parsed_draft_token}"
        ),
        status_code=303,
    )


@app.post("/onboarding", response_class=HTMLResponse)
async def submit_onboarding(
    request: Request,
    organization_mode: Annotated[str, Form()] = "CREATE_NEW",
    existing_organization_id: Annotated[str, Form()] = "",
    organization_name: Annotated[str, Form()] = "",
    organization_code: Annotated[str, Form()] = "",
    organization_description: Annotated[str, Form()] = "",
    site_mode: Annotated[str, Form()] = "CREATE_NEW",
    existing_site_id: Annotated[str, Form()] = "",
    site_name: Annotated[str, Form()] = "",
    site_code: Annotated[str, Form()] = "",
    site_timezone: Annotated[str, Form()] = "Asia/Kolkata",
    site_address: Annotated[str, Form()] = "",
    location_mode: Annotated[str, Form()] = "SITE_ONLY",
    existing_space_id: Annotated[str, Form()] = "",
    building_name: Annotated[str, Form()] = "",
    building_code: Annotated[str, Form()] = "",
    floor_name: Annotated[str, Form()] = "",
    floor_code: Annotated[str, Form()] = "",
    space_name: Annotated[str, Form()] = "",
    space_code: Annotated[str, Form()] = "",
    gateway_mode: Annotated[str, Form()] = "CREATE_NEW",
    existing_gateway_id: Annotated[str, Form()] = "",
    gateway_name: Annotated[str, Form()] = "",
    gateway_external_id: Annotated[str, Form()] = "",
    gateway_vendor: Annotated[str, Form()] = "",
    gateway_model: Annotated[str, Form()] = "",
    gateway_protocol: Annotated[str, Form()] = "MQTT",
    device_mode: Annotated[str, Form()] = "CREATE_NEW",
    existing_device_id: Annotated[str, Form()] = "",
    device_name: Annotated[str, Form()] = "",
    device_external_id: Annotated[str, Form()] = "",
    device_model_vendor: Annotated[str, Form()] = "",
    device_model: Annotated[str, Form()] = "",
    device_category_id: Annotated[str, Form()] = "",
    firmware_version: Annotated[str, Form()] = "",
    device_protocol: Annotated[str, Form()] = "MQTT",
    profile_code: Annotated[str, Form()] = "",
    identifier_type: Annotated[str, Form()] = "MQTT_UID",
    identifier_value: Annotated[str, Form()] = "",
    asset_mode: Annotated[str, Form()] = "CREATE_NEW",
    existing_asset_id: Annotated[str, Form()] = "",
    asset_name: Annotated[str, Form()] = "",
    asset_type_id: Annotated[str, Form()] = "",
    relationship_type: Annotated[str, Form()] = "PRIMARY_METER",
) -> HTMLResponse:
    """Validate and execute one atomic EMS onboarding request."""

    submitted_form_data = {
        "organization_mode": organization_mode,
        "existing_organization_id": existing_organization_id,
        "organization_name": organization_name,
        "organization_code": organization_code,
        "organization_description": organization_description,
        "site_mode": site_mode,
        "existing_site_id": existing_site_id,
        "site_name": site_name,
        "site_code": site_code,
        "site_timezone": site_timezone,
        "site_address": site_address,
        "location_mode": location_mode,
        "existing_space_id": existing_space_id,
        "building_name": building_name,
        "building_code": building_code,
        "floor_name": floor_name,
        "floor_code": floor_code,
        "space_name": space_name,
        "space_code": space_code,
        "gateway_mode": gateway_mode,
        "existing_gateway_id": existing_gateway_id,
        "gateway_name": gateway_name,
        "gateway_external_id": gateway_external_id,
        "gateway_vendor": gateway_vendor,
        "gateway_model": gateway_model,
        "gateway_protocol": gateway_protocol,
        "device_mode": device_mode,
        "existing_device_id": existing_device_id,
        "device_name": device_name,
        "device_external_id": device_external_id,
        "device_model_vendor": device_model_vendor,
        "device_model": device_model,
        "device_category_id": device_category_id,
        "firmware_version": firmware_version,
        "device_protocol": device_protocol,
        "profile_code": profile_code,
        "identifier_type": identifier_type,
        "identifier_value": identifier_value,
        "asset_mode": asset_mode,
        "existing_asset_id": existing_asset_id,
        "asset_name": asset_name,
        "asset_type_id": asset_type_id,
        "relationship_type": relationship_type,
    }

    form = OnboardingForm(
        organization_mode=organization_mode,
        existing_organization_id=existing_organization_id,
        organization_name=organization_name,
        organization_code=organization_code,
        organization_description=organization_description,
        site_mode=site_mode,
        existing_site_id=existing_site_id,
        site_name=site_name,
        site_code=site_code,
        site_timezone=site_timezone,
        site_address=site_address,
        location_mode=location_mode,
        existing_space_id=existing_space_id,
        building_name=building_name,
        building_code=building_code,
        floor_name=floor_name,
        floor_code=floor_code,
        space_name=space_name,
        space_code=space_code,
        gateway_mode=gateway_mode,
        existing_gateway_id=existing_gateway_id,
        gateway_name=gateway_name,
        gateway_external_id=gateway_external_id,
        gateway_vendor=gateway_vendor,
        gateway_model=gateway_model,
        gateway_protocol=gateway_protocol,
        device_mode=device_mode,
        existing_device_id=existing_device_id,
        device_name=device_name,
        device_external_id=device_external_id,
        device_model_vendor=device_model_vendor,
        device_model=device_model,
        device_category_id=device_category_id,
        firmware_version=firmware_version,
        device_protocol=device_protocol,
        profile_code=profile_code,
        identifier_type=identifier_type,
        identifier_value=identifier_value,
        asset_mode=asset_mode,
        existing_asset_id=existing_asset_id,
        asset_name=asset_name,
        asset_type_id=asset_type_id,
        relationship_type=relationship_type,
    )

    try:
        payload = form.to_request_payload()

        result = await onboard_energy_asset(
            request_payload=payload,
            requested_by="portal-v0.2",
        )

    except OnboardingValidationError as exc:
        return await render_onboarding_page(
            request,
            status_code=422,
            form_data=submitted_form_data,
            field_error_name=exc.field_name,
            field_error_message=exc.message,
            error=None if exc.field_name else exc.message,
        )

    except DatabaseError as exc:
        database_message = user_facing_database_error(
            exc,
            fallback="The database rejected the onboarding request.",
        )

        return await render_onboarding_page(
            request,
            error=database_message,
            status_code=409,
            form_data=submitted_form_data,
        )

    return templates.TemplateResponse(
        request=request,
        name="onboarding_result.html",
        context={
            "environment": settings.app_env,
            "result": result,
        },
    )


@app.get("/health", include_in_schema=False)
async def health() -> JSONResponse:
    """Verify application and restricted database connectivity."""

    async with database_connection() as connection:
        async with connection.cursor() as cursor:
            await cursor.execute(
                sql.SQL(
                    """
                    SELECT
                        current_database() AS database_name,
                        current_user AS database_user,
                        TRUE AS database_ok
                    """
                )
            )
            result = await cursor.fetchone()

    return JSONResponse(
        {
            "status": "ok",
            "environment": settings.app_env,
            "database": {
                "status": "ok" if result["database_ok"] else "error",
                "name": result["database_name"],
                "user": result["database_user"],
            },
        }
    )


@app.middleware("http")
async def add_sensitive_page_cache_headers(
    request: Request,
    call_next,
) -> Response:
    """
    Prevent browsers and intermediary caches from retaining authentication
    pages or session-related responses.
    """

    response = await call_next(request)

    if request.url.path in {
        "/login",
        "/logout",
        "/forbidden",
    }:
        response.headers["Cache-Control"] = (
            "no-store, no-cache, must-revalidate, private"
        )
        response.headers["Pragma"] = "no-cache"
        response.headers["Expires"] = "0"

    return response
