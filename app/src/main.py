from src.grafana_client import GrafanaApiError
import asyncio
import contextlib
from contextlib import asynccontextmanager
from pathlib import Path
from typing import Annotated, AsyncIterator
from uuid import UUID

import websockets
from websockets.exceptions import InvalidHandshake, WebSocketException
from fastapi import FastAPI, Form, HTTPException, Request, WebSocket, WebSocketDisconnect
from fastapi.exception_handlers import (
    http_exception_handler as default_http_exception_handler,
    request_validation_exception_handler as default_request_validation_handler,
)
from fastapi.exceptions import RequestValidationError
from starlette.exceptions import HTTPException as StarletteHTTPException
from fastapi.responses import (
    FileResponse,
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
from src.auth.access_scope import (
    normalize_portal_access_scope_submission,
)
from src.auth.middleware import PortalAuthenticationMiddleware
from src.auth.session import SESSION_IDENTITY_KEY, deserialize_authenticated_user
from src.analytics_api_service import portal_user_can_access_asset
from src.context.dependencies import site_context
from src.context.service import (
    AdministrationContextError,
    bootstrap_context_for_identity,
    get_administration_context,
    set_active_location,
    set_active_site,
)
from src.routers.context import router as context_router
from src.routers.analytics_api import router as analytics_api_router
from src.auth.security import hash_portal_password
from src.auth.service import authenticate_portal_user
from src.admin_navigation import administration_navigation
from src.commissioning_dashboard_service import (
    COMMISSIONING_STATUSES,
    ENTITY_TYPES,
    build_commissioning_dashboard,
)
from src.telemetry_validation_service import (
    TELEMETRY_STATES,
    list_accessible_device_telemetry_availability,
)
from src.reconciliation_queue_service import (
    ISSUE_TYPES,
    list_accessible_reconciliation_queue,
    summarize_reconciliation_queue,
)
from src.relationship_management import (
    PHASE_DESIGNATIONS, RelationshipManagementValidationError,
    validate_primary_meter_replacement, validate_relationship_metadata,
    validate_relationship_removal, validate_relationship_submission,
)
from src.relationship_management_service import (
    assign_device_to_asset, list_accessible_relationships, list_relationship_types,
    remove_relationship, replace_primary_meter, update_relationship_metadata,
)
from src.metering_coverage_service import (
    list_accessible_metering_coverage, summarize_metering_coverage,
)
from src.config import get_settings
from src.code_generation import generate_entity_code
from src.database import (
    close_database_pool,
    database_connection,
    open_database_pool,
)
from src.organization_workspace_service import (
    create_organization_workspace,
    get_organization_workspace,
    update_organization_workspace,
)
from src.user_management_service import (
    change_managed_user_role,
    create_managed_user,
    list_manageable_users,
    set_managed_user_access_scope,
    set_managed_user_active,
)
from src.onboarding.forms import OnboardingValidationError
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
    list_accessible_sites,
    list_sectors,
    list_sites,
    list_spaces,
    list_sub_sectors,
    validate_asset_relationship_availability,
    validate_onboarding_field,
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
from src.onboarding.grafana_reconciliation_service import reconcile_grafana_tenant
from src.onboarding.organization_service import (
    create_organization,
    list_organizations_with_grafana_status,
)
from src.onboarding.grafana_provisioning_service import (
    provision_grafana_for_organization,
)
from src.location_management import (
    LIFECYCLE_STATUSES,
    LocationManagementValidationError,
    validate_building_submission,
    validate_floor_submission,
    validate_site_submission,
    TELEMETRY_CAPTURE_INTERVALS,
    DEMAND_INTERVALS,
    DEMAND_BASES,
    DEMAND_SOURCE_ROLES,
    validate_site_demand_submission,
    validate_space_submission,
)
from src.location_management_service import (
    create_building,
    create_floor,
    create_site,
    create_space,
    create_site_workspace,
    get_site_workspace,
    get_location_workspace,
    list_manageable_sites,
    update_site_workspace,
    update_location_workspace,
    list_accessible_physical_locations,
)
from src.asset_management import (
    ASSET_LIFECYCLE_STATUSES,
    METERING_REQUIREMENTS,
    AssetManagementValidationError,
    validate_asset_submission,
)
from src.asset_management_service import (
    commission_asset,
    create_asset,
    get_asset_workspace,
    list_accessible_assets,
    list_accessible_commissioning_readiness,
    update_asset,
    update_asset_workspace,
)
from src.gateway_management import (
    GATEWAY_LIFECYCLE_STATUSES,
    GatewayManagementValidationError,
    validate_gateway_submission,
    validate_gateway_lifecycle_update,
    validate_gateway_workspace_update,
)
from src.gateway_management_service import (
    commission_gateway,
    create_gateway,
    get_gateway_workspace,
    list_accessible_gateways,
    update_gateway_lifecycle,
    update_gateway_workspace,
)
from src.device_management import (
    DEVICE_IDENTIFIER_TYPES,
    DEVICE_LIFECYCLE_STATUSES,
    DEVICE_OPERATIONAL_POLICIES,
    DEVICE_PROTOCOLS,
    DeviceManagementValidationError,
    validate_device_lifecycle_update,
    validate_device_point_configuration_update,
    validate_device_submission,
    validate_device_workspace_update,
)
from src.device_management_service import (
    commission_device,
    create_device,
    get_device_workspace,
    list_accessible_devices,
    list_device_point_configuration,
    reset_device_point_configuration,
    set_device_operational_policy,
    update_device_lifecycle,
    update_device_point_configuration,
    update_device_workspace,
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

    if path == "/onboarding" or path.startswith("/onboarding/"):
        active_navigation_key = "onboarding"
    elif path == "/administration":
        active_navigation_key = "overview"
    elif (
        path == "/administration/organizations"
        or path.startswith("/administration/organizations/")
    ):
        active_navigation_key = "organizations"
    elif (
        path == "/administration/users"
        or path.startswith("/administration/users/")
    ):
        active_navigation_key = "users"
    elif (
        path == "/administration/sites"
        or path.startswith("/administration/sites/")
    ):
        active_navigation_key = "sites"
    elif (
        path == "/administration/locations"
        or path.startswith("/administration/locations/")
    ):
        active_navigation_key = "locations"
    elif (
        path == "/administration/assets"
        or path.startswith("/administration/assets/")
    ):
        active_navigation_key = "assets"
    elif (
        path == "/administration/gateways"
        or path.startswith("/administration/gateways/")
    ):
        active_navigation_key = "gateways"
    elif (
        path == "/administration/relationships"
        or path.startswith("/administration/relationships/")
    ):
        active_navigation_key = "relationships"
    elif (
        path == "/administration/metering-coverage"
        or path.startswith("/administration/metering-coverage/")
    ):
        active_navigation_key = "metering-coverage"
    elif (
        path == "/administration/devices"
        or path.startswith("/administration/devices/")
    ):
        active_navigation_key = "devices"
    elif (
        path == "/administration/commissioning"
        or path.startswith("/administration/commissioning/")
    ):
        active_navigation_key = "commissioning"
    elif (
        path == "/administration/telemetry-validation"
        or path.startswith("/administration/telemetry-validation/")
    ):
        active_navigation_key = "telemetry-validation"
    else:
        active_navigation_key = None

    return {
        "current_portal_user": current_user,
        "active_administration_context": (
            get_administration_context(request)
            if current_user is not None
            else None
        ),
        "administration_navigation": administration_navigation(
            current_user.role_code if current_user else None,
            current_user.access_scope_mode if current_user else None,
        ),
        "active_navigation_key": active_navigation_key,
    }


templates = Jinja2Templates(
    directory=str(base_directory / "templates"),
    context_processors=[portal_template_context],
)

def format_date_time(value):
    """Render timestamps without seconds or timezone noise."""
    if value is None:
        return "—"
    if hasattr(value, "strftime"):
        return value.strftime("%d %b %Y, %H:%M")
    text = str(value).strip()
    if not text:
        return "—"
    return text.replace("T", " ")[:16]


templates.env.filters["date_time"] = format_date_time



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

app.include_router(context_router)
app.include_router(analytics_api_router)


# ---------------------------------------------------------------------------
# Phase 8 -- same-origin serving of the React foundation shell under /app.
#
# The built SPA bundle is delivered as an INDEPENDENT artifact (see
# docs/operations/PHASE8_FRONTEND_DEPLOYMENT.md); it is not part of this
# Python image. This block is a complete NO-OP whenever app/src/spa/index.html
# is absent -- which is the case in the application image as built today, in
# every test, and in every environment that has not deployed the frontend.
# It therefore adds no route and changes no behaviour for the existing admin
# portal, Grafana, or the Phase 7 API until a frontend bundle is present.
#
# When present: static hashed assets are served from /app/assets/*, and every
# other /app/* path returns the SPA entry document so the client-side router
# can take over. /app/* is a normal protected path -- PortalAuthentication
# Middleware redirects an unauthenticated visitor to the existing /login flow
# and the SPA reuses the resulting session cookie. No second auth system, no
# CORS, no new cookie.
# ---------------------------------------------------------------------------
_spa_directory = base_directory / "spa"

if (_spa_directory / "index.html").is_file():
    _spa_assets_directory = _spa_directory / "assets"

    if _spa_assets_directory.is_dir():
        app.mount(
            "/app/assets",
            StaticFiles(directory=str(_spa_assets_directory)),
            name="spa_assets",
        )

    _spa_index = _spa_directory / "index.html"
    _spa_root_resolved = _spa_directory.resolve()

    @app.get("/app", include_in_schema=False)
    @app.get("/app/{spa_path:path}", include_in_schema=False)
    async def serve_frontend_shell(
        request: Request,
        spa_path: str = "",
    ) -> Response:
        """Serve the Phase 8 SPA entry (and its few root files) under /app.

        Client-side routes (e.g. /app/home) have no matching file and fall
        through to index.html. Hashed bundle assets are handled by the
        /app/assets mount above. Authentication is already enforced by
        PortalAuthenticationMiddleware before this handler runs.
        """

        if spa_path and not spa_path.startswith("assets/"):
            candidate = (_spa_directory / spa_path).resolve()

            if (
                _spa_root_resolved in candidate.parents
                and candidate.is_file()
            ):
                return FileResponse(candidate)

        return FileResponse(_spa_index)


@app.exception_handler(AdministrationContextError)
async def handle_administration_context_error(
    request: Request,
    exc: AdministrationContextError,
) -> RedirectResponse:
    """Convert a missing/invalid scope tier into the same authorization-
    denied response every other rejection in this app produces, so routes
    can depend on organization_context/site_context/location_context
    (src.context.dependencies) directly instead of hand-checking
    AdministrationContext fields."""

    return RedirectResponse(url="/forbidden", status_code=303)


# The /api/v1 JSON surface uses a flat top-level error contract
# ({"error": "<code>", "detail": "<message>"}) consistent with the
# PortalAuthenticationMiddleware 401. FastAPI's default HTTPException /
# RequestValidationError handlers wrap the payload as {"detail": ...}; these
# two handlers render the flat shape for /api/v1 paths only and delegate to
# the framework defaults everywhere else, so no legacy/application route's
# error contract changes.
_API_V1_ERROR_PREFIX = "/api/v1/"


@app.exception_handler(StarletteHTTPException)
async def handle_http_exception(
    request: Request,
    exc: StarletteHTTPException,
) -> Response:
    if (
        request.url.path.startswith(_API_V1_ERROR_PREFIX)
        and isinstance(exc.detail, dict)
        and "error" in exc.detail
    ):
        return JSONResponse(
            exc.detail,
            status_code=exc.status_code,
            headers=getattr(exc, "headers", None),
        )
    return await default_http_exception_handler(request, exc)


@app.exception_handler(RequestValidationError)
async def handle_request_validation_error(
    request: Request,
    exc: RequestValidationError,
) -> Response:
    if request.url.path.startswith(_API_V1_ERROR_PREFIX):
        return JSONResponse(
            {
                "error": "invalid_request",
                "detail": "One or more request parameters are missing or malformed.",
            },
            status_code=422,
        )
    return await default_request_validation_handler(request, exc)


async def list_sites_for_request(
    request: Request,
) -> list[dict]:
    """Return only sites accessible to the signed-in portal identity."""

    user = require_authenticated_portal_user(request)

    return await list_accessible_sites(
        portal_user_id=user.portal_user_id,
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

    existing_user = get_authenticated_portal_user(request)

    if existing_user is not None:
        destination = (
            "/administration/organizations"
            if existing_user.role_code == "ADMIN"
            and existing_user.access_scope_mode == "GLOBAL"
            and get_administration_context(
                request
            ).active_organization_id is None
            else safe_login_redirect_path(next_path)
        )
        return RedirectResponse(
            url=destination,
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
    bootstrap_context_for_identity(
        request,
        result.user,
    )

    destination = (
        "/administration/organizations"
        if result.user.role_code == "ADMIN"
        and result.user.access_scope_mode == "GLOBAL"
        else safe_login_redirect_path(next_path)
    )

    return RedirectResponse(
        url=destination,
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

def user_manager_assignable_roles(
    role_code: str,
) -> tuple[str, ...]:
    """Return roles assignable by one user-management actor."""

    if role_code == "ADMIN":
        return (
            "ADMIN",
            "OPERATOR",
            "VIEWER",
        )

    return ()


async def render_user_administration(
    request: Request,
    *,
    form_data: dict | None = None,
    result: dict | None = None,
    error: str | None = None,
    status_code: int = 200,
) -> HTMLResponse:
    """Render organization-scoped portal user management."""

    user = require_authenticated_portal_user(request)

    users = await list_manageable_users(
        actor_portal_user_id=user.portal_user_id,
    )

    sites = await list_sites_for_request(request)

    organizations = (
        await list_organizations()
        if (
            user.role_code == "ADMIN"
            and user.access_scope_mode == "GLOBAL"
        )
        else []
    )

    return templates.TemplateResponse(
        request=request,
        name="users.html",
        context={
            "environment": settings.app_env,
            "page_title": "User management",
            "users": users,
            "sites": sites,
            "organizations": organizations,
            "actor_role_code": user.role_code,
            "actor_access_scope_mode": user.access_scope_mode,
            "actor_organization_id": user.organization_id,
            "assignable_roles": user_manager_assignable_roles(
                user.role_code
            ),
            "form_data": form_data or {},
            "result": result,
            "error": error,
            "active_navigation_key": "users",
        },
        status_code=status_code,
    )


@app.get(
    "/administration/users",
    response_class=HTMLResponse,
    include_in_schema=False,
)
async def user_administration(
    request: Request,
) -> HTMLResponse:
    """Display organization-scoped portal user management."""
    return await render_user_administration(request)


@app.get(
    "/administration/users/new",
    response_class=HTMLResponse,
    include_in_schema=False,
)
async def create_user_page(request: Request) -> HTMLResponse:
    user = require_authenticated_portal_user(request)
    organizations = (
        await list_organizations()
        if user.access_scope_mode == "GLOBAL"
        else []
    )
    sites = await list_sites_for_request(request)
    return templates.TemplateResponse(
        request=request,
        name="user_create.html",
        context={
            "environment": settings.app_env,
            "form_data": {},
            "actor_role_code": user.role_code,
            "actor_access_scope_mode": user.access_scope_mode,
            "actor_organization_id": user.organization_id,
            "organizations": organizations,
            "sites": sites,
            "assignable_roles": user_manager_assignable_roles(user.role_code),
            "active_navigation_key": "users",
        },
    )


async def _manageable_user_or_none(request: Request, portal_user_id: int):
    actor = require_authenticated_portal_user(request)
    users = await list_manageable_users(actor_portal_user_id=actor.portal_user_id)
    return next((item for item in users if int(item["portal_user_id"]) == portal_user_id), None)


@app.get(
    "/administration/users/{portal_user_id}",
    response_class=HTMLResponse,
    include_in_schema=False,
)
async def user_access_detail(request: Request, portal_user_id: int) -> Response:
    portal_user = await _manageable_user_or_none(request, portal_user_id)
    if portal_user is None:
        return RedirectResponse(url="/administration/users", status_code=303)
    return templates.TemplateResponse(
        request=request,
        name="user_detail.html",
        context={"environment": settings.app_env, "portal_user": portal_user, "active_navigation_key": "users"},
    )


@app.get(
    "/administration/users/{portal_user_id}/edit",
    response_class=HTMLResponse,
    include_in_schema=False,
)
async def user_access_edit(request: Request, portal_user_id: int) -> Response:
    actor = require_authenticated_portal_user(request)
    portal_user = await _manageable_user_or_none(request, portal_user_id)
    if portal_user is None:
        return RedirectResponse(url="/administration/users", status_code=303)
    sites = await list_sites_for_request(request)
    organizations = (
        await list_organizations()
        if actor.access_scope_mode == "GLOBAL"
        else []
    )
    return templates.TemplateResponse(
        request=request,
        name="user_edit.html",
        context={
            "environment": settings.app_env,
            "portal_user": portal_user,
            "sites": sites,
            "organizations": organizations,
            "actor_access_scope_mode": actor.access_scope_mode,
            "actor_organization_id": actor.organization_id,
            "assignable_roles": user_manager_assignable_roles(actor.role_code),
            "active_navigation_key": "users",
        },
    )


@app.post(
    "/administration/users",
    response_class=HTMLResponse,
    include_in_schema=False,
)
async def create_user_administration(
    request: Request,
    display_name: Annotated[str, Form()],
    username: Annotated[str, Form()],
    email: Annotated[str, Form()],
    password: Annotated[str, Form()],
    role_code: Annotated[str, Form()],
    access_scope_mode: Annotated[str, Form()],
    organization_id: Annotated[str, Form()] = "",
    site_ids: Annotated[list[str], Form()] = [],
) -> HTMLResponse:
    """Create a portal user within the actor's authorized scope."""

    user = require_authenticated_portal_user(request)

    submitted_form_data = {
        "display_name": display_name,
        "username": username,
        "email": email,
        "role_code": role_code,
        "access_scope_mode": access_scope_mode,
        "organization_id": organization_id,
        "site_ids": site_ids,
    }

    if role_code not in user_manager_assignable_roles(user.role_code):
        return await render_user_administration(
            request,
            form_data=submitted_form_data,
            error=(
                f"{user.role_code} cannot assign the requested "
                f"{role_code} role."
            ),
            status_code=400,
        )

    if not display_name.strip() or not username.strip():
        return await render_user_administration(
            request,
            form_data=submitted_form_data,
            error="Display name and username are required.",
            status_code=400,
        )

    if len(password) < 12:
        return await render_user_administration(
            request,
            form_data=submitted_form_data,
            error="Temporary passwords must contain at least 12 characters.",
            status_code=400,
        )

    try:
        normalized_scope, normalized_site_ids = (
            normalize_portal_access_scope_submission(
                access_scope_mode=access_scope_mode,
                site_ids=site_ids,
            )
        )
    except ValueError as exc:
        return await render_user_administration(
            request,
            form_data=submitted_form_data,
            error=str(exc),
            status_code=400,
        )

    target_organization_id = (
        None
        if normalized_scope.value == "GLOBAL"
        else (
            user.organization_id
            if user.access_scope_mode != "GLOBAL"
            else organization_id.strip() or None
        )
    )

    if (
        normalized_scope.value != "GLOBAL"
        and not target_organization_id
    ):
        return await render_user_administration(
            request,
            form_data=submitted_form_data,
            error=(
                "ORGANIZATION and SELECTED_SITES scopes require "
                "an organization."
            ),
            status_code=400,
        )

    if (
        user.access_scope_mode != "GLOBAL"
        and normalized_scope.value == "GLOBAL"
    ):
        return await render_user_administration(
            request,
            form_data=submitted_form_data,
            error=(
                "Only a GLOBAL administrator may create a "
                "GLOBAL-scoped user."
            ),
            status_code=400,
        )

    try:
        portal_user_id = await create_managed_user(
            actor_portal_user_id=user.portal_user_id,
            username=username.strip(),
            display_name=display_name.strip(),
            email=email.strip(),
            password_hash=hash_portal_password(password),
            role_code=role_code,
            access_scope_mode=normalized_scope.value,
            organization_id=target_organization_id,
            site_ids=normalized_site_ids,
        )
    except DatabaseError as exc:
        return await render_user_administration(
            request,
            form_data=submitted_form_data,
            error=user_facing_database_error(
                exc,
                fallback="The database rejected the user request.",
            ),
            status_code=409,
        )

    return await render_user_administration(
        request,
        result={
            "portal_user_id": portal_user_id,
            "display_name": display_name.strip(),
            "username": username.strip(),
            "role_code": role_code,
        },
        status_code=201,
    )


@app.post(
    "/administration/users/{portal_user_id}/role",
    response_class=HTMLResponse,
    include_in_schema=False,
)
async def change_user_role_administration(
    request: Request,
    portal_user_id: int,
    role_code: Annotated[str, Form()],
) -> HTMLResponse:
    """Change a managed portal user's role and audit the change."""

    user = require_authenticated_portal_user(request)

    if role_code not in user_manager_assignable_roles(user.role_code):
        return await render_user_administration(
            request,
            error=(
                f"{user.role_code} cannot assign the requested "
                f"{role_code} role."
            ),
            status_code=400,
        )

    try:
        await change_managed_user_role(
            actor_portal_user_id=user.portal_user_id,
            target_portal_user_id=portal_user_id,
            role_code=role_code,
        )
    except DatabaseError as exc:
        return await render_user_administration(
            request,
            error=user_facing_database_error(
                exc,
                fallback="The database rejected the role change.",
            ),
            status_code=409,
        )

    return await render_user_administration(
        request,
        result={
            "portal_user_id": portal_user_id,
            "role_code": role_code,
            "action": "role_changed",
        },
    )


@app.post(
    "/administration/users/{portal_user_id}/scope",
    response_class=HTMLResponse,
    include_in_schema=False,
)
async def change_user_scope_administration(
    request: Request,
    portal_user_id: int,
    access_scope_mode: Annotated[str, Form()],
    organization_id: Annotated[str, Form()] = "",
    site_ids: Annotated[list[str], Form()] = [],
) -> HTMLResponse:
    """Change a managed portal user's access scope independently."""

    user = require_authenticated_portal_user(request)

    try:
        normalized_mode, normalized_site_ids = (
            normalize_portal_access_scope_submission(
                access_scope_mode=access_scope_mode,
                site_ids=site_ids,
            )
        )
    except ValueError as exc:
        return await render_user_administration(
            request,
            error=str(exc),
            status_code=400,
        )

    target_organization_id = (
        None
        if normalized_mode.value == "GLOBAL"
        else (
            user.organization_id
            if user.access_scope_mode != "GLOBAL"
            else organization_id.strip() or None
        )
    )

    if (
        normalized_mode.value != "GLOBAL"
        and not target_organization_id
    ):
        return await render_user_administration(
            request,
            error=(
                "ORGANIZATION and SELECTED_SITES scopes require "
                "an organization."
            ),
            status_code=400,
        )

    if (
        user.access_scope_mode != "GLOBAL"
        and normalized_mode.value == "GLOBAL"
    ):
        return await render_user_administration(
            request,
            error=(
                "Only a GLOBAL administrator may assign GLOBAL scope."
            ),
            status_code=400,
        )

    try:
        await set_managed_user_access_scope(
            actor_portal_user_id=user.portal_user_id,
            target_portal_user_id=portal_user_id,
            access_scope_mode=normalized_mode.value,
            organization_id=target_organization_id,
            site_ids=normalized_site_ids,
        )
    except DatabaseError as exc:
        return await render_user_administration(
            request,
            error=user_facing_database_error(
                exc,
                fallback=(
                    "The database rejected the access-scope change."
                ),
            ),
            status_code=409,
        )

    return await render_user_administration(
        request,
        result={
            "portal_user_id": portal_user_id,
            "access_scope_mode": normalized_mode.value,
            "action": "scope_changed",
        },
    )


@app.post(
    "/administration/users/{portal_user_id}/status",
    response_class=HTMLResponse,
    include_in_schema=False,
)
async def change_user_status_administration(
    request: Request,
    portal_user_id: int,
    is_active: Annotated[str, Form()],
) -> HTMLResponse:
    """Activate or deactivate a managed portal user."""

    user = require_authenticated_portal_user(request)

    normalized_status = is_active.strip().lower()

    if normalized_status not in {"true", "false"}:
        return await render_user_administration(
            request,
            error="Invalid user status.",
            status_code=400,
        )

    try:
        await set_managed_user_active(
            actor_portal_user_id=user.portal_user_id,
            target_portal_user_id=portal_user_id,
            is_active=normalized_status == "true",
        )
    except DatabaseError as exc:
        return await render_user_administration(
            request,
            error=user_facing_database_error(
                exc,
                fallback="The database rejected the status change.",
            ),
            status_code=409,
        )

    return await render_user_administration(
        request,
        result={
            "portal_user_id": portal_user_id,
            "is_active": normalized_status == "true",
            "action": "status_changed",
        },
    )


async def _site_page_organizations(user):
    from src.context.repository import list_accessible_organizations_for_user
    return await list_accessible_organizations_for_user(
        portal_user_id=user.portal_user_id,
        role_code=user.role_code,
        access_scope_mode=user.access_scope_mode,
        assigned_organization_id=user.organization_id,
    )


def _site_address_from_form(
    address_line1: str, address_line2: str, city: str, region: str,
    postal_code: str, country: str,
) -> dict[str, str]:
    return {
        key: value.strip()
        for key, value in {
            "line1": address_line1, "line2": address_line2,
            "city": city, "region": region,
            "postal_code": postal_code, "country": country,
        }.items()
        if value.strip()
    }


async def _site_sector_edit_context(sub_sector_id: str | None) -> dict:
    """
    Return the sectors/sub-sectors catalog plus the currently selected
    sector/sub-sector, so the Site Edit cascading dropdowns can pre-select
    the site's existing classification. The sector is derived by looking
    up the sub-sector's parent, since the sector <select> itself is a UI
    helper only and is never submitted.
    """
    sub_sectors = await list_sub_sectors()
    selected_sector_id = ""
    if sub_sector_id:
        match = next(
            (row for row in sub_sectors if str(row["id"]) == str(sub_sector_id)),
            None,
        )
        if match:
            selected_sector_id = str(match["sector_id"])
    return {
        "sectors": await list_sectors(),
        "sub_sectors": sub_sectors,
        "selected_sector_id": selected_sector_id,
        "selected_sub_sector_id": str(sub_sector_id) if sub_sector_id else "",
    }


async def render_site_administration(
    request: Request,
    *,
    selected_organization_id: str | None = None,
    error: str | None = None,
    status_code: int = 200,
) -> HTMLResponse:
    """Render all accessible sites, optionally filtered by organization."""

    user = require_authenticated_portal_user(request)
    active_context = get_administration_context(request)
    organizations = await _site_page_organizations(user)
    accessible_ids = {str(row.get("id")) for row in organizations}

    requested = request.query_params.get("organization_id")
    if requested == "all":
        selected = None
    elif requested:
        selected = requested if requested in accessible_ids else None
        if requested not in accessible_ids:
            error = "That organization is not available to your account."
    elif selected_organization_id is not None:
        selected = selected_organization_id
    else:
        selected = active_context.active_organization_id

    rows = await list_manageable_sites(portal_user_id=user.portal_user_id)
    sites = [row for row in rows if selected is None or str(row.get("organization_id")) == str(selected)]

    status_rank = {"ACTIVE": 0, "DRAFT": 1, "INACTIVE": 2, "DECOMMISSIONED": 3}
    sites.sort(key=lambda row: (
        status_rank.get(str(row.get("lifecycle_status")), 99),
        str(row.get("site_name") or "").casefold(),
        str(row.get("site_code") or "").casefold(),
    ))

    can_manage = has_permission(user, PortalPermission.SITE_MANAGE)
    can_create = can_manage and user.access_scope_mode != "SELECTED_SITES"

    return templates.TemplateResponse(
        request=request, name="sites.html",
        context={
            "environment": settings.app_env, "page_title": "Sites",
            "organizations": organizations, "sites": sites,
            "selected_organization_id": selected,
            "active_site_id": active_context.active_site_id,
            "can_create_site": can_create, "can_edit_sites": can_manage,
            "lifecycle_statuses": LIFECYCLE_STATUSES, "error": error,
            "context_error": request.query_params.get("context_error") == "1",
            "active_navigation_key": "sites",
        }, status_code=status_code,
    )


@app.get("/administration/sites", response_class=HTMLResponse, include_in_schema=False)
async def site_administration(request: Request) -> HTMLResponse:
    return await render_site_administration(request)


@app.get("/administration/sites/new", response_class=HTMLResponse, include_in_schema=False)
async def create_site_page(request: Request) -> Response:
    user = require_authenticated_portal_user(request)
    if not has_permission(user, PortalPermission.SITE_MANAGE) or user.access_scope_mode == "SELECTED_SITES":
        return RedirectResponse(url="/forbidden", status_code=303)
    organizations = await _site_page_organizations(user)
    active_context = get_administration_context(request)
    return templates.TemplateResponse(
        request=request, name="site_create.html",
        context={
            "environment": settings.app_env, "organizations": organizations,
            "selected_organization_id": active_context.active_organization_id,
            "form_data": {"site_timezone": "Asia/Kolkata", "lifecycle_status": "ACTIVE"},
            "lifecycle_statuses": LIFECYCLE_STATUSES, "telemetry_capture_intervals": TELEMETRY_CAPTURE_INTERVALS, "active_navigation_key": "sites",
            "sectors": await list_sectors(), "sub_sectors": await list_sub_sectors(),
        },
    )


@app.post("/administration/sites", response_class=HTMLResponse, include_in_schema=False)
async def create_site_administration(
    request: Request, organization_id: Annotated[str, Form()],
    site_name: Annotated[str, Form()], site_timezone: Annotated[str, Form()],
    sub_sector_id: Annotated[str, Form()] = "",
    lifecycle_status: Annotated[str, Form()] = "ACTIVE", address_line1: Annotated[str, Form()] = "",
    address_line2: Annotated[str, Form()] = "", city: Annotated[str, Form()] = "",
    region: Annotated[str, Form()] = "", postal_code: Annotated[str, Form()] = "",
    country: Annotated[str, Form()] = "",
    telemetry_capture_interval_seconds: Annotated[str, Form()] = "60",
) -> Response:
    user = require_authenticated_portal_user(request)
    organizations = await _site_page_organizations(user)
    accessible_ids = {str(row.get("id")) for row in organizations}
    if organization_id not in accessible_ids or user.access_scope_mode == "SELECTED_SITES":
        return RedirectResponse(url="/forbidden", status_code=303)
    site_code = generate_entity_code(site_name)
    submitted = locals().copy()
    try:
        validated = validate_site_submission(organization_id=organization_id, site_name=site_name,
            site_code=site_code, site_timezone=site_timezone, lifecycle_status=lifecycle_status, telemetry_capture_interval_seconds=telemetry_capture_interval_seconds,
            sub_sector_id=sub_sector_id)
        result = await create_site_workspace(
            portal_user_id=user.portal_user_id, organization_id=validated["organization_id"],
            name=validated["name"], code=validated["code"], timezone=validated["timezone"],
            lifecycle_status=validated["lifecycle_status"],
            address=_site_address_from_form(address_line1,address_line2,city,region,postal_code,country),
            telemetry_capture_interval_seconds=validated["telemetry_capture_interval_seconds"],
            sub_sector_id=validated["sub_sector_id"],
        )
    except (LocationManagementValidationError, DatabaseError) as exc:
        return templates.TemplateResponse(request=request, name="site_create.html", context={
            "environment": settings.app_env, "organizations": organizations,
            "selected_organization_id": organization_id, "form_data": submitted,
            "error": str(exc) if isinstance(exc, LocationManagementValidationError) else user_facing_database_error(exc, fallback="The database rejected the site request."),
            "lifecycle_statuses": LIFECYCLE_STATUSES, "telemetry_capture_intervals": TELEMETRY_CAPTURE_INTERVALS, "active_navigation_key": "sites",
            "sectors": await list_sectors(), "sub_sectors": await list_sub_sectors()},
            status_code=400 if isinstance(exc, LocationManagementValidationError) else 409)
    return RedirectResponse(url=f"/administration/sites/{result['site_id']}", status_code=303)


@app.get("/administration/api/sub-sectors", include_in_schema=False)
async def list_sub_sectors_api(request: Request, sector_id: str = "") -> JSONResponse:
    """Return sub-sectors for a sector, for the site-creation cascading dropdown."""
    require_authenticated_portal_user(request)
    return JSONResponse([
        {"id": str(row["id"]), "name": row["name"]}
        for row in await list_sub_sectors(sector_id or None)
    ])


@app.get("/administration/api/asset-types", include_in_schema=False)
async def list_site_asset_types_api(request: Request, site_id: str = "") -> JSONResponse:
    """Return asset types filtered to a site's sub-sector, for the asset-creation form."""
    require_authenticated_portal_user(request)
    return JSONResponse([
        {"id": str(row["id"]), "name": row["name"]}
        for row in await list_asset_types(site_id or None)
    ])


async def _accessible_site_or_none(request: Request, site_id: UUID):
    user = require_authenticated_portal_user(request)
    return await get_site_workspace(portal_user_id=user.portal_user_id, site_id=str(site_id))


@app.get("/administration/sites/{site_id}", response_class=HTMLResponse, include_in_schema=False)
async def site_detail_administration(request: Request, site_id: UUID) -> Response:
    user = require_authenticated_portal_user(request)
    site = await _accessible_site_or_none(request, site_id)
    if site is None:
        return RedirectResponse(url="/administration/sites?context_error=1", status_code=303)
    return templates.TemplateResponse(request=request, name="site_detail.html", context={
        "environment": settings.app_env, "site": site,
        "can_edit": has_permission(user, PortalPermission.SITE_MANAGE),
        "active_navigation_key": "sites"})


@app.get("/administration/sites/{site_id}/edit", response_class=HTMLResponse, include_in_schema=False)
async def edit_site_page(request: Request, site_id: UUID) -> Response:
    user = require_authenticated_portal_user(request)
    if not has_permission(user, PortalPermission.SITE_MANAGE):
        return RedirectResponse(url="/forbidden", status_code=303)
    site = await _accessible_site_or_none(request, site_id)
    if site is None:
        return RedirectResponse(url="/administration/sites?context_error=1", status_code=303)
    return templates.TemplateResponse(request=request, name="site_edit.html", context={
        "environment": settings.app_env, "site": site, "form_data": {},
        "lifecycle_statuses": LIFECYCLE_STATUSES, "telemetry_capture_intervals": TELEMETRY_CAPTURE_INTERVALS, "active_navigation_key": "sites",
        **await _site_sector_edit_context(site.get("sub_sector_id"))})


@app.post("/administration/sites/{site_id}/edit", response_class=HTMLResponse, include_in_schema=False)
async def edit_site_submit(
    request: Request, site_id: UUID, site_name: Annotated[str, Form()],
    site_timezone: Annotated[str, Form()], lifecycle_status: Annotated[str, Form()],
    change_reason: Annotated[str, Form()], sub_sector_id: Annotated[str, Form()] = "",
    address_line1: Annotated[str, Form()] = "",
    address_line2: Annotated[str, Form()] = "", city: Annotated[str, Form()] = "",
    region: Annotated[str, Form()] = "", postal_code: Annotated[str, Form()] = "", country: Annotated[str, Form()] = "",
    telemetry_capture_interval_seconds: Annotated[str, Form()] = "60",
    demand_monitoring_enabled: Annotated[str | None, Form()] = None,
    demand_interval_seconds: Annotated[str, Form()] = "900",
    demand_basis: Annotated[str, Form()] = "ACTIVE_POWER_KW",
    site_demand_source_role: Annotated[str, Form()] = "GRID_IMPORT",
) -> Response:
    user = require_authenticated_portal_user(request)
    site = await _accessible_site_or_none(request, site_id)
    if site is None:
        return RedirectResponse(url="/administration/sites?context_error=1", status_code=303)
    submitted = locals().copy()
    try:
        validated = validate_site_submission(organization_id=str(site["organization_id"]),
            site_name=site_name, site_code=site["site_code"], site_timezone=site_timezone, lifecycle_status=lifecycle_status, telemetry_capture_interval_seconds=telemetry_capture_interval_seconds,
            sub_sector_id=sub_sector_id)
        demand = validate_site_demand_submission(
            demand_monitoring_enabled=demand_monitoring_enabled,
            demand_interval_seconds=demand_interval_seconds,
            demand_basis=demand_basis,
            site_demand_source_role=site_demand_source_role,
        )
        result = await update_site_workspace(portal_user_id=user.portal_user_id, site_id=str(site_id),
            name=validated["name"], timezone=validated["timezone"], lifecycle_status=validated["lifecycle_status"],
            address=_site_address_from_form(address_line1,address_line2,city,region,postal_code,country), change_reason=change_reason,
            telemetry_capture_interval_seconds=validated["telemetry_capture_interval_seconds"],
            demand_monitoring_enabled=demand["is_enabled"],
            demand_interval_seconds=demand["demand_interval_seconds"],
            demand_basis=demand["demand_basis"],
            site_demand_source_role=demand["site_demand_source_role"],
            demand_minimum_coverage_percent=demand["minimum_coverage_percent"],
            demand_late_arrival_tolerance_seconds=demand["late_arrival_tolerance_seconds"],
            sub_sector_id=validated["sub_sector_id"])
        if not result.get("success", False):
            raise LocationManagementValidationError(result.get("failure_reason", "The lifecycle transition was rejected."))
    except (LocationManagementValidationError, DatabaseError) as exc:
        return templates.TemplateResponse(request=request, name="site_edit.html", context={
            "environment": settings.app_env, "site": site, "form_data": submitted,
            "error": str(exc) if isinstance(exc, LocationManagementValidationError) else user_facing_database_error(exc, fallback="The database rejected the site update."),
            "lifecycle_statuses": LIFECYCLE_STATUSES, "telemetry_capture_intervals": TELEMETRY_CAPTURE_INTERVALS, "active_navigation_key": "sites",
            **await _site_sector_edit_context(sub_sector_id)},
            status_code=400 if isinstance(exc, LocationManagementValidationError) else 409)
    return RedirectResponse(url=f"/administration/sites/{site_id}", status_code=303)


async def _location_page_catalog(request: Request) -> dict:
    user = require_authenticated_portal_user(request)
    context = get_administration_context(request)
    rows = await list_accessible_physical_locations(
        portal_user_id=user.portal_user_id,
    )
    serializable = [
        {
            key: str(value) if isinstance(value, UUID) else value
            for key, value in row.items()
        }
        for row in rows
    ]

    if not context.active_organization_id or not context.active_site_id:
        return {
            "context": context,
            "rows": [],
            "locations": [],
            "buildings": [],
            "floors": [],
        }

    filtered = [
        row for row in serializable
        if str(row.get("organization_id")) == context.active_organization_id
        and str(row.get("site_id")) == context.active_site_id
    ]

    locations: dict[tuple[str, str], dict] = {}
    buildings: dict[str, dict] = {}
    floors: dict[str, dict] = {}
    for row in filtered:
        if row.get("building_id"):
            buildings.setdefault(row["building_id"], {
                "location_id": row["building_id"],
                "location_type": "BUILDING",
                "location_name": row.get("building_name"),
                "location_code": row.get("building_code"),
                "organization_name": row.get("organization_name"),
                "site_name": row.get("site_name"),
                "parent_name": row.get("site_name"),
                "lifecycle_status": row.get("building_lifecycle_status") or "ACTIVE",
                "hierarchy": row.get("building_name"),
            })
        if row.get("floor_id"):
            floors.setdefault(row["floor_id"], {
                "location_id": row["floor_id"],
                "location_type": "FLOOR",
                "location_name": row.get("floor_name"),
                "location_code": row.get("floor_code"),
                "organization_name": row.get("organization_name"),
                "site_name": row.get("site_name"),
                "building_name": row.get("building_name"),
                "parent_name": row.get("building_name"),
                "lifecycle_status": row.get("floor_lifecycle_status") or "ACTIVE",
                "hierarchy": f'{row.get("building_name") or ""} / {row.get("floor_name") or ""}',
            })
        for location_type, id_key, name_key, code_key, parent_name in (
            ("BUILDING", "building_id", "building_name", "building_code", row.get("site_name")),
            ("FLOOR", "floor_id", "floor_name", "floor_code", row.get("building_name")),
            ("SPACE", "space_id", "space_name", "space_code", row.get("floor_name")),
        ):
            location_id = row.get(id_key)
            if not location_id:
                continue
            locations.setdefault((location_type, location_id), {
                "location_id": location_id,
                "location_type": location_type,
                "location_name": row.get(name_key),
                "location_code": row.get(code_key),
                "organization_name": row.get("organization_name"),
                "site_name": row.get("site_name"),
                "building_name": row.get("building_name"),
                "floor_name": row.get("floor_name"),
                "space_name": row.get("space_name"),
                "parent_name": parent_name,
                "lifecycle_status": row.get(f"{location_type.lower()}_lifecycle_status") or "ACTIVE",
            })

    type_order = {"BUILDING": 0, "FLOOR": 1, "SPACE": 2}
    return {
        "context": context,
        "rows": filtered,
        "locations": sorted(
            locations.values(),
            key=lambda item: (
                type_order[item["location_type"]],
                (item["location_name"] or "").casefold(),
                item["location_code"] or "",
            ),
        ),
        "buildings": sorted(buildings.values(), key=lambda item: (item["location_name"] or "").casefold()),
        "floors": sorted(floors.values(), key=lambda item: (item["location_name"] or "").casefold()),
    }


async def render_location_administration(
    request: Request,
    *,
    error: str | None = None,
    status_code: int = 200,
) -> HTMLResponse:
    """Render a site-scoped location administration workspace."""

    user = require_authenticated_portal_user(request)
    catalog = await _location_page_catalog(request)
    context = catalog["context"]
    has_site_context = bool(
        context.active_organization_id and context.active_site_id
    )
    return templates.TemplateResponse(
        request=request,
        name="locations.html",
        context={
            "environment": settings.app_env,
            "page_title": "Locations",
            "locations": catalog["locations"],
            "error": error,
            "context_error": request.query_params.get("context_error") == "1",
            "active_context": context,
            "has_site_context": has_site_context,
            "can_manage_locations": has_permission(user, PortalPermission.LOCATION_MANAGE),
            "lifecycle_statuses": ("ACTIVE", "INACTIVE", "DECOMMISSIONED"),
            "active_navigation_key": "locations",
        },
        status_code=status_code,
    )


@app.get("/administration/locations", response_class=HTMLResponse, include_in_schema=False)
async def location_administration(request: Request) -> Response:
    return await render_location_administration(request)


@app.get("/administration/locations/new", response_class=HTMLResponse, include_in_schema=False)
async def create_location_page(request: Request) -> Response:
    user = require_authenticated_portal_user(request)
    if not has_permission(user, PortalPermission.LOCATION_MANAGE):
        return RedirectResponse(url="/forbidden", status_code=303)
    context = site_context(request)
    catalog = await _location_page_catalog(request)
    return templates.TemplateResponse(
        request=request,
        name="location_create.html",
        context={
            "environment": settings.app_env,
            "active_context": context,
            "buildings": catalog["buildings"],
            "floors": catalog["floors"],
            "form_data": {},
            "active_navigation_key": "locations",
        },
    )


async def _render_location_create_error(
    request: Request,
    *,
    form_data: dict,
    error: str,
    status_code: int,
) -> HTMLResponse:
    catalog = await _location_page_catalog(request)
    return templates.TemplateResponse(
        request=request,
        name="location_create.html",
        context={
            "environment": settings.app_env,
            "active_context": catalog["context"],
            "buildings": catalog["buildings"],
            "floors": catalog["floors"],
            "form_data": form_data,
            "error": error,
            "active_navigation_key": "locations",
        },
        status_code=status_code,
    )


@app.post("/administration/locations", response_class=HTMLResponse, include_in_schema=False)
@app.post("/administration/locations/new", response_class=HTMLResponse, include_in_schema=False)
async def create_location_administration(
    request: Request,
    location_type: Annotated[str, Form()],
    parent_id: Annotated[str, Form()] = "",
    location_name: Annotated[str, Form()] = "",
    location_code: Annotated[str, Form()] = "",
) -> Response:
    """Create one building, floor, or space inside the active site."""

    user = require_authenticated_portal_user(request)
    if not has_permission(user, PortalPermission.LOCATION_MANAGE):
        return RedirectResponse(url="/forbidden", status_code=303)
    context = site_context(request)

    normalized_type = location_type.strip().upper()
    generated_code = generate_entity_code(location_name)
    submitted = {
        "location_type": normalized_type,
        "parent_id": parent_id,
        "location_name": location_name,
        "location_code": generated_code,
    }
    try:
        if normalized_type == "BUILDING":
            validated = validate_building_submission(
                site_id=context.active_site_id,
                building_name=location_name,
                building_code=generated_code,
            )
            result = await create_building(portal_user_id=user.portal_user_id, **validated)
        elif normalized_type == "FLOOR":
            validated = validate_floor_submission(
                building_id=parent_id,
                floor_name=location_name,
                floor_code=generated_code,
            )
            result = await create_floor(portal_user_id=user.portal_user_id, **validated)
        elif normalized_type == "SPACE":
            validated = validate_space_submission(
                floor_id=parent_id,
                space_name=location_name,
                space_code=generated_code,
            )
            result = await create_space(portal_user_id=user.portal_user_id, **validated)
        else:
            raise LocationManagementValidationError("Select a valid location type.")
    except LocationManagementValidationError as exc:
        return await _render_location_create_error(
            request, form_data=submitted, error=str(exc), status_code=400,
        )
    except DatabaseError as exc:
        return await _render_location_create_error(
            request,
            form_data=submitted,
            error=user_facing_database_error(exc, fallback="The database rejected the location request."),
            status_code=409,
        )
    location_id = result.get(f"{normalized_type.lower()}_id") or result.get("entity_id")
    return RedirectResponse(
        url=f"/administration/locations/{normalized_type.lower()}/{location_id}",
        status_code=303,
    )


async def _accessible_location_or_none(
    request: Request,
    location_type: str,
    location_id: UUID,
) -> dict | None:
    user = require_authenticated_portal_user(request)
    normalized_type = location_type.strip().upper()
    if normalized_type not in {"BUILDING", "FLOOR", "SPACE"}:
        return None
    return await get_location_workspace(
        portal_user_id=user.portal_user_id,
        location_type=normalized_type,
        location_id=str(location_id),
    )


@app.get("/administration/locations/{location_type}/{location_id}", response_class=HTMLResponse, include_in_schema=False)
async def location_detail_page(request: Request, location_type: str, location_id: UUID) -> Response:
    user = require_authenticated_portal_user(request)
    location = await _accessible_location_or_none(request, location_type, location_id)
    if location is None:
        return RedirectResponse(url="/administration/locations?context_error=1", status_code=303)
    return templates.TemplateResponse(
        request=request,
        name="location_detail.html",
        context={
            "environment": settings.app_env,
            "location": location,
            "can_edit": has_permission(user, PortalPermission.LOCATION_MANAGE),
            "active_navigation_key": "locations",
        },
    )


@app.get("/administration/locations/{location_type}/{location_id}/edit", response_class=HTMLResponse, include_in_schema=False)
async def edit_location_page(request: Request, location_type: str, location_id: UUID) -> Response:
    user = require_authenticated_portal_user(request)
    if not has_permission(user, PortalPermission.LOCATION_MANAGE):
        return RedirectResponse(url="/forbidden", status_code=303)
    location = await _accessible_location_or_none(request, location_type, location_id)
    if location is None:
        return RedirectResponse(url="/administration/locations?context_error=1", status_code=303)
    return templates.TemplateResponse(
        request=request,
        name="location_edit.html",
        context={
            "environment": settings.app_env,
            "location": location,
            "form_data": {},
            "active_navigation_key": "locations",
        },
    )


@app.post("/administration/locations/{location_type}/{location_id}/edit", response_class=HTMLResponse, include_in_schema=False)
async def edit_location_submit(
    request: Request,
    location_type: str,
    location_id: UUID,
    location_name: Annotated[str, Form()],
    change_reason: Annotated[str, Form()],
) -> Response:
    user = require_authenticated_portal_user(request)
    if not has_permission(user, PortalPermission.LOCATION_MANAGE):
        return RedirectResponse(url="/forbidden", status_code=303)
    location = await _accessible_location_or_none(request, location_type, location_id)
    if location is None:
        return RedirectResponse(url="/administration/locations?context_error=1", status_code=303)
    submitted = {"location_name": location_name, "change_reason": change_reason}
    try:
        normalized_name = location_name.strip()
        if not normalized_name:
            raise LocationManagementValidationError("Location name is required.")
        if len(normalized_name) > 200:
            raise LocationManagementValidationError("Location name must not exceed 200 characters.")
        if not change_reason.strip():
            raise LocationManagementValidationError("Change reason is required.")
        await update_location_workspace(
            portal_user_id=user.portal_user_id,
            location_type=location["location_type"],
            location_id=str(location_id),
            name=normalized_name,
            change_reason=change_reason.strip(),
        )
    except (LocationManagementValidationError, DatabaseError) as exc:
        return templates.TemplateResponse(
            request=request,
            name="location_edit.html",
            context={
                "environment": settings.app_env,
                "location": location,
                "form_data": submitted,
                "error": str(exc) if isinstance(exc, LocationManagementValidationError) else user_facing_database_error(exc, fallback="The database rejected the location update."),
                "active_navigation_key": "locations",
            },
            status_code=400 if isinstance(exc, LocationManagementValidationError) else 409,
        )
    return RedirectResponse(
        url=f"/administration/locations/{location['location_type'].lower()}/{location_id}",
        status_code=303,
    )


def _matches_active_location(row: dict, location_id: str) -> bool:
    return location_id in {
        str(row.get("building_id")), str(row.get("floor_id")), str(row.get("space_id"))
    }


async def render_asset_administration(
    request: Request,
    *,
    form_data: dict | None = None,
    result: dict | None = None,
    error: str | None = None,
    status_code: int = 200,
) -> HTMLResponse:
    """Render independent asset inventory administration."""

    user = require_authenticated_portal_user(request)
    context = get_administration_context(request)

    organization_rows = await list_organizations()
    organizations = [
        organization
        for organization in organization_rows
        if (
            user.access_scope_mode == "GLOBAL"
            or str(organization["id"])
            == str(user.organization_id)
        )
    ]

    hierarchy_rows = await list_accessible_physical_locations(
        portal_user_id=user.portal_user_id,
    )
    assets = await list_accessible_assets(
        portal_user_id=user.portal_user_id,
    )
    readiness_rows = await list_accessible_commissioning_readiness(
        portal_user_id=user.portal_user_id,
        entity_type="ASSET",
    )
    readiness_by_asset = {
        str(row["entity_id"]): row for row in readiness_rows
    }
    asset_types = await list_asset_types()

    serializable_hierarchy_rows = [
        {
            key: str(value) if isinstance(value, UUID) else value
            for key, value in row.items()
        }
        for row in hierarchy_rows
    ]

    return templates.TemplateResponse(
        request=request,
        name="assets.html",
        context={
            "environment": settings.app_env,
            "page_title": "Assets",
            "organizations": organizations,
            "hierarchy_rows": serializable_hierarchy_rows,
            "assets": assets,
            "asset_readiness": readiness_by_asset,
            "can_manage": has_permission(user, PortalPermission.ASSET_MANAGE),
            "active_context": context,
            "asset_types": asset_types,
            "asset_lifecycle_statuses": (
                ASSET_LIFECYCLE_STATUSES
            ),
            "metering_requirements": METERING_REQUIREMENTS,
            "form_data": form_data or {},
            "result": result,
            "error": error,
            "active_navigation_key": "assets",
        },
        status_code=status_code,
    )


@app.get(
    "/administration/assets",
    response_class=HTMLResponse,
    include_in_schema=False,
)
async def asset_administration(
    request: Request,
) -> Response:
    """Display every asset available within the actor's controlled scope."""
    return await render_asset_administration(request)


async def _asset_form_context(request: Request, form_data: dict | None = None) -> dict:
    user = require_authenticated_portal_user(request)
    organizations = await list_organizations()
    if user.access_scope_mode != "GLOBAL":
        organizations = [
            row for row in organizations
            if str(row["id"]) == str(user.organization_id)
        ]
    hierarchy_rows = await list_accessible_physical_locations(
        portal_user_id=user.portal_user_id
    )
    assets = await list_accessible_assets(portal_user_id=user.portal_user_id)
    active_context = get_administration_context(request)
    defaults = {
        "organization_id": active_context.active_organization_id or "",
        "site_id": active_context.active_site_id or "",
        "building_id": active_context.active_location_id
            if active_context.active_location_type == "BUILDING" else "",
        "floor_id": active_context.active_location_id
            if active_context.active_location_type == "FLOOR" else "",
        "space_id": active_context.active_location_id
            if active_context.active_location_type == "SPACE" else "",
        "lifecycle_status": "DRAFT",
        "metering_requirement": "NOT_REQUIRED",
    }
    defaults.update(form_data or {})
    return {
        "environment": settings.app_env,
        "page_title": "Create asset",
        "organizations": organizations,
        "hierarchy_rows": [
            {key: str(value) if isinstance(value, UUID) else value for key, value in row.items()}
            for row in hierarchy_rows
        ],
        "assets": assets,
        "asset_types": await list_asset_types(defaults.get("site_id") or None),
        "asset_lifecycle_statuses": ASSET_LIFECYCLE_STATUSES,
        "metering_requirements": METERING_REQUIREMENTS,
        "form_data": defaults,
        "active_navigation_key": "assets",
    }


@app.get(
    "/administration/assets/new",
    response_class=HTMLResponse,
    include_in_schema=False,
)
async def asset_create_page(request: Request) -> Response:
    user = require_authenticated_portal_user(request)
    if not has_permission(user, PortalPermission.ASSET_MANAGE):
        return RedirectResponse("/forbidden", status_code=303)
    return templates.TemplateResponse(
        request=request, name="asset_create.html",
        context={**await _asset_form_context(request), "error": None},
    )


@app.post(
    "/administration/assets",
    response_class=HTMLResponse,
    include_in_schema=False,
)
async def create_asset_administration(
    request: Request,
    organization_id: Annotated[str, Form()],
    asset_location_site_id: Annotated[str, Form()],
    asset_name: Annotated[str, Form()],
    asset_type_id: Annotated[str, Form()] = "",
    lifecycle_status: Annotated[str, Form()] = "ACTIVE",
    metering_requirement: Annotated[str, Form()] = (
        "NOT_REQUIRED"
    ),
    parent_asset_id: Annotated[str, Form()] = "",
    asset_location_building_id: Annotated[str, Form()] = "",
    asset_location_floor_id: Annotated[str, Form()] = "",
    asset_location_space_id: Annotated[str, Form()] = "",
) -> HTMLResponse:
    """Create one independent asset without requiring a device."""

    user = require_authenticated_portal_user(request)

    submitted_form_data = {
        "organization_id": organization_id,
        "site_id": asset_location_site_id,
        "asset_name": asset_name,
        "asset_type_id": asset_type_id,
        "lifecycle_status": lifecycle_status,
        "metering_requirement": metering_requirement,
        "parent_asset_id": parent_asset_id,
        "building_id": asset_location_building_id,
        "floor_id": asset_location_floor_id,
        "space_id": asset_location_space_id,
    }

    try:
        validated = validate_asset_submission(
            organization_id=organization_id,
            site_id=asset_location_site_id,
            asset_name=asset_name,
            asset_type_id=asset_type_id,
            lifecycle_status=lifecycle_status,
            metering_requirement=metering_requirement,
            parent_asset_id=parent_asset_id,
            building_id=asset_location_building_id,
            floor_id=asset_location_floor_id,
            space_id=asset_location_space_id,
        )
    except AssetManagementValidationError as exc:
        return templates.TemplateResponse(
            request=request, name="asset_create.html",
            context={**await _asset_form_context(request, submitted_form_data), "error": str(exc)},
            status_code=400,
        )

    try:
        result = await create_asset(
            portal_user_id=user.portal_user_id,
            **validated,
        )
    except DatabaseError as exc:
        return templates.TemplateResponse(
            request=request, name="asset_create.html",
            context={**await _asset_form_context(request, submitted_form_data),
                     "error": user_facing_database_error(
                         exc, fallback="The database rejected the asset request.")},
            status_code=409,
        )

    return RedirectResponse(
        f"/administration/assets/{result['entity_id']}", status_code=303
    )


@app.post(
    "/administration/assets/{asset_id}/commission",
    response_class=HTMLResponse,
    include_in_schema=False,
)
async def commission_asset_administration(
    request: Request, asset_id: UUID,
) -> HTMLResponse:
    """Commission one accessible asset using declarative readiness."""
    user = require_authenticated_portal_user(request)
    try:
        result = await commission_asset(
            portal_user_id=user.portal_user_id,
            asset_id=str(asset_id),
        )
    except DatabaseError as exc:
        return await render_asset_administration(
            request,
            error=user_facing_database_error(
                exc, fallback="The database blocked asset commissioning."
            ),
            status_code=409,
        )
    return await render_asset_administration(
        request, result=result, status_code=200
    )


@app.post(
    "/administration/assets/{asset_id}",
    response_class=HTMLResponse,
    include_in_schema=False,
)
async def update_asset_administration(
    request: Request,
    asset_id: UUID,
    asset_name: Annotated[str, Form()],
    asset_type_id: Annotated[str, Form()],
    lifecycle_status: Annotated[str, Form()],
    metering_requirement: Annotated[str, Form()],
    parent_asset_id: Annotated[str, Form()] = "",
    asset_location_building_id: Annotated[str, Form()] = "",
    asset_location_floor_id: Annotated[str, Form()] = "",
    asset_location_space_id: Annotated[str, Form()] = "",
) -> HTMLResponse:
    """Update one accessible asset without changing ownership."""

    user = require_authenticated_portal_user(request)

    accessible_assets = await list_accessible_assets(
        portal_user_id=user.portal_user_id,
    )

    selected_asset = next(
        (
            asset
            for asset in accessible_assets
            if str(asset["asset_id"]) == str(asset_id)
        ),
        None,
    )

    if selected_asset is None:
        raise HTTPException(
            status_code=404,
            detail="Asset was not found.",
        )

    submitted_form_data = {
        "organization_id": str(
            selected_asset["organization_id"]
        ),
        "site_id": str(selected_asset["site_id"]),
        "asset_id": str(asset_id),
        "asset_name": asset_name,
        "asset_type_id": asset_type_id,
        "lifecycle_status": lifecycle_status,
        "metering_requirement": metering_requirement,
        "parent_asset_id": parent_asset_id,
        "building_id": asset_location_building_id,
        "floor_id": asset_location_floor_id,
        "space_id": asset_location_space_id,
    }

    try:
        validated = validate_asset_submission(
            organization_id=submitted_form_data[
                "organization_id"
            ],
            site_id=submitted_form_data["site_id"],
            asset_name=asset_name,
            asset_type_id=asset_type_id,
            lifecycle_status=lifecycle_status,
            metering_requirement=metering_requirement,
            parent_asset_id=parent_asset_id,
            building_id=asset_location_building_id,
            floor_id=asset_location_floor_id,
            space_id=asset_location_space_id,
        )
    except AssetManagementValidationError as exc:
        return await render_asset_administration(
            request,
            form_data=submitted_form_data,
            error=str(exc),
            status_code=400,
        )

    if validated["parent_asset_id"] == str(asset_id):
        return await render_asset_administration(
            request,
            form_data=submitted_form_data,
            error="An asset cannot be its own parent.",
            status_code=400,
        )

    try:
        result = await update_asset(
            portal_user_id=user.portal_user_id,
            asset_id=str(asset_id),
            asset_name=validated["asset_name"],
            asset_type_id=validated["asset_type_id"],
            lifecycle_status=validated["lifecycle_status"],
            metering_requirement=validated[
                "metering_requirement"
            ],
            parent_asset_id=validated["parent_asset_id"],
            building_id=validated["building_id"],
            floor_id=validated["floor_id"],
            space_id=validated["space_id"],
        )
    except DatabaseError as exc:
        return await render_asset_administration(
            request,
            form_data=submitted_form_data,
            error=user_facing_database_error(
                exc,
                fallback=(
                    "The database rejected the asset update."
                ),
            ),
            status_code=409,
        )

    return await render_asset_administration(
        request,
        result=result,
        status_code=200,
    )


async def _accessible_asset_or_none(request: Request, asset_id: UUID) -> dict | None:
    user = require_authenticated_portal_user(request)
    return await get_asset_workspace(
        portal_user_id=user.portal_user_id, asset_id=str(asset_id)
    )


@app.get(
    "/administration/assets/{asset_id}",
    response_class=HTMLResponse,
    include_in_schema=False,
)
async def asset_detail_page(request: Request, asset_id: UUID) -> Response:
    user = require_authenticated_portal_user(request)
    asset = await _accessible_asset_or_none(request, asset_id)
    if asset is None:
        return RedirectResponse("/forbidden", status_code=303)
    relationships = [
        row for row in await list_accessible_relationships(
            portal_user_id=user.portal_user_id
        ) if str(row["asset_id"]) == str(asset_id)
    ]
    candidate_devices = [
        row for row in await list_accessible_devices(
            portal_user_id=user.portal_user_id
        ) if str(row["site_id"]) == str(asset["site_id"])
    ]
    return templates.TemplateResponse(
        request=request, name="asset_detail.html",
        context={
            "environment": settings.app_env, "page_title": asset["asset_name"],
            "asset": asset, "relationships": relationships,
            "candidate_devices": candidate_devices,
            "relationship_types": await list_relationship_types(),
            "phase_designations": PHASE_DESIGNATIONS,
            "relationship_error": request.query_params.get("relationship_error"),
            "relationship_notice": request.query_params.get("relationship_notice"),
            "can_edit": has_permission(user, PortalPermission.ASSET_MANAGE),
            "can_manage_relationships": has_permission(
                user, PortalPermission.RELATIONSHIP_MANAGE
            ),
            "active_navigation_key": "assets",
        },
    )


@app.get(
    "/administration/assets/{asset_id}/edit",
    response_class=HTMLResponse,
    include_in_schema=False,
)
async def asset_edit_page(request: Request, asset_id: UUID) -> Response:
    user = require_authenticated_portal_user(request)
    if not has_permission(user, PortalPermission.ASSET_MANAGE):
        return RedirectResponse("/forbidden", status_code=303)
    asset = await _accessible_asset_or_none(request, asset_id)
    if asset is None:
        return RedirectResponse("/forbidden", status_code=303)
    catalog = await _asset_form_context(request, {"site_id": str(asset["site_id"])})
    return templates.TemplateResponse(
        request=request, name="asset_edit.html",
        context={**catalog, "page_title": f"Edit {asset['asset_name']}",
                 "asset": asset, "form_data": {}, "error": None},
    )


@app.post(
    "/administration/assets/{asset_id}/edit",
    response_class=HTMLResponse,
    include_in_schema=False,
)
async def asset_edit_submit(
    request: Request, asset_id: UUID,
    asset_name: Annotated[str, Form()], asset_type_id: Annotated[str, Form()],
    lifecycle_status: Annotated[str, Form()],
    metering_requirement: Annotated[str, Form()],
    change_reason: Annotated[str, Form()],
    parent_asset_id: Annotated[str, Form()] = "",
    asset_location_building_id: Annotated[str, Form()] = "",
    asset_location_floor_id: Annotated[str, Form()] = "",
    asset_location_space_id: Annotated[str, Form()] = "",
) -> Response:
    user = require_authenticated_portal_user(request)
    asset = await _accessible_asset_or_none(request, asset_id)
    if asset is None:
        return RedirectResponse("/forbidden", status_code=303)
    submitted = {
        "asset_name": asset_name, "asset_type_id": asset_type_id,
        "lifecycle_status": lifecycle_status,
        "metering_requirement": metering_requirement,
        "parent_asset_id": parent_asset_id, "building_id": asset_location_building_id,
        "floor_id": asset_location_floor_id, "space_id": asset_location_space_id,
        "change_reason": change_reason,
    }
    catalog = await _asset_form_context(request, submitted)
    try:
        validated = validate_asset_submission(
            organization_id=str(asset["organization_id"]),
            site_id=str(asset["site_id"]), asset_name=asset_name,
            asset_type_id=asset_type_id, lifecycle_status=lifecycle_status,
            metering_requirement=metering_requirement, parent_asset_id=parent_asset_id,
            building_id=asset_location_building_id, floor_id=asset_location_floor_id,
            space_id=asset_location_space_id,
        )
        if validated["parent_asset_id"] == str(asset_id):
            raise AssetManagementValidationError("An asset cannot be its own parent.")
        reason = change_reason.strip()
        if not reason or len(reason) > 1000:
            raise AssetManagementValidationError(
                "Change reason is required and must not exceed 1000 characters."
            )
        await update_asset_workspace(
            portal_user_id=user.portal_user_id, asset_id=str(asset_id),
            asset_name=validated["asset_name"], asset_type_id=validated["asset_type_id"],
            lifecycle_status=validated["lifecycle_status"],
            metering_requirement=validated["metering_requirement"],
            parent_asset_id=validated["parent_asset_id"],
            building_id=validated["building_id"], floor_id=validated["floor_id"],
            space_id=validated["space_id"], change_reason=reason,
        )
    except (AssetManagementValidationError, DatabaseError) as exc:
        return templates.TemplateResponse(
            request=request, name="asset_edit.html",
            context={**catalog, "page_title": f"Edit {asset['asset_name']}",
                     "asset": asset, "form_data": submitted,
                     "error": str(exc) if isinstance(exc, AssetManagementValidationError)
                     else user_facing_database_error(
                         exc, fallback="The database rejected the asset update.")},
            status_code=400 if isinstance(exc, AssetManagementValidationError) else 409,
        )
    return RedirectResponse(f"/administration/assets/{asset_id}", status_code=303)



def _relationship_redirect(path: str, *, notice: str | None = None, error: str | None = None) -> RedirectResponse:
    from urllib.parse import quote
    key, value = ("relationship_error", error) if error else ("relationship_notice", notice or "Relationship updated.")
    return RedirectResponse(f"{path}?{key}={quote(value)}", status_code=303)


@app.post("/administration/assets/{asset_id}/assign-device", include_in_schema=False)
async def assign_device_from_asset(request: Request, asset_id: UUID, device_id: Annotated[str, Form()], relationship_type: Annotated[str, Form()]) -> Response:
    user = require_authenticated_portal_user(request)
    path = f"/administration/assets/{asset_id}"
    try:
        validated = validate_relationship_submission(asset_id=str(asset_id), device_id=device_id, relationship_type=relationship_type)
        await assign_device_to_asset(portal_user_id=user.portal_user_id, **validated)
    except RelationshipManagementValidationError as exc:
        return _relationship_redirect(path, error=str(exc))
    except DatabaseError as exc:
        return _relationship_redirect(path, error=user_facing_database_error(exc, fallback="The database rejected the device assignment."))
    return _relationship_redirect(path, notice="Device assigned to asset.")


@app.post("/administration/devices/{device_id}/assign-asset", include_in_schema=False)
async def assign_asset_from_device(request: Request, device_id: UUID, asset_id: Annotated[str, Form()], relationship_type: Annotated[str, Form()]) -> Response:
    user = require_authenticated_portal_user(request)
    path = f"/administration/devices/{device_id}"
    try:
        validated = validate_relationship_submission(asset_id=asset_id, device_id=str(device_id), relationship_type=relationship_type)
        await assign_device_to_asset(portal_user_id=user.portal_user_id, **validated)
    except RelationshipManagementValidationError as exc:
        return _relationship_redirect(path, error=str(exc))
    except DatabaseError as exc:
        return _relationship_redirect(path, error=user_facing_database_error(exc, fallback="The database rejected the asset assignment."))
    return _relationship_redirect(path, notice="Asset assignment created.")


@app.post("/administration/assets/{asset_id}/relationships/{relationship_id}/metadata", include_in_schema=False)
async def update_asset_relationship_metadata(
    request: Request, asset_id: UUID, relationship_id: UUID,
    panel_name: Annotated[str, Form()] = "", feeder_name: Annotated[str, Form()] = "",
    breaker_identifier: Annotated[str, Form()] = "", channel_identifier: Annotated[str, Form()] = "",
    ct_ratio: Annotated[str, Form()] = "", phase_designation: Annotated[str, Form()] = "",
    mounting_point: Annotated[str, Form()] = "", engineering_notes: Annotated[str, Form()] = "",
) -> Response:
    user = require_authenticated_portal_user(request)
    path = f"/administration/assets/{asset_id}"
    rows = await list_accessible_relationships(portal_user_id=user.portal_user_id)
    if not any(str(r["relationship_id"]) == str(relationship_id) and str(r["asset_id"]) == str(asset_id) for r in rows):
        return _relationship_redirect(path, error="Relationship was not found for this asset.")
    try:
        validated = validate_relationship_metadata(relationship_id=str(relationship_id), panel_name=panel_name, feeder_name=feeder_name, breaker_identifier=breaker_identifier, channel_identifier=channel_identifier, ct_ratio=ct_ratio, phase_designation=phase_designation, mounting_point=mounting_point, engineering_notes=engineering_notes)
        await update_relationship_metadata(portal_user_id=user.portal_user_id, **validated)
    except RelationshipManagementValidationError as exc:
        return _relationship_redirect(path, error=str(exc))
    except DatabaseError as exc:
        return _relationship_redirect(path, error=user_facing_database_error(exc, fallback="The database rejected the assignment details."))
    return _relationship_redirect(path, notice="Assignment details updated.")


@app.post("/administration/assets/{asset_id}/relationships/{relationship_id}/replace-primary-meter", include_in_schema=False)
async def replace_asset_primary_meter(
    request: Request, asset_id: UUID, relationship_id: UUID,
    replacement_device_id: Annotated[str, Form()], replacement_reason: Annotated[str, Form()],
) -> Response:
    user = require_authenticated_portal_user(request)
    path = f"/administration/assets/{asset_id}"
    rows = await list_accessible_relationships(portal_user_id=user.portal_user_id)
    if not any(str(r["relationship_id"]) == str(relationship_id) and str(r["asset_id"]) == str(asset_id) and r["relationship_type"] == "PRIMARY_METER" for r in rows):
        return _relationship_redirect(path, error="Primary-meter relationship was not found for this asset.")
    try:
        validated = validate_primary_meter_replacement(relationship_id=str(relationship_id), replacement_device_id=replacement_device_id, replacement_reason=replacement_reason)
        await replace_primary_meter(portal_user_id=user.portal_user_id, **validated)
    except RelationshipManagementValidationError as exc:
        return _relationship_redirect(path, error=str(exc))
    except DatabaseError as exc:
        return _relationship_redirect(path, error=user_facing_database_error(exc, fallback="The database rejected the primary-meter replacement."))
    return _relationship_redirect(path, notice="Primary meter replaced.")


@app.post("/administration/assets/{asset_id}/relationships/{relationship_id}/remove", include_in_schema=False)
async def remove_asset_relationship(request: Request, asset_id: UUID, relationship_id: UUID, removal_reason: Annotated[str, Form()]) -> Response:
    user = require_authenticated_portal_user(request)
    path = f"/administration/assets/{asset_id}"
    rows = await list_accessible_relationships(portal_user_id=user.portal_user_id)
    if not any(str(r["relationship_id"]) == str(relationship_id) and str(r["asset_id"]) == str(asset_id) for r in rows):
        return _relationship_redirect(path, error="Relationship was not found for this asset.")
    try:
        validated = validate_relationship_removal(relationship_id=str(relationship_id), removal_reason=removal_reason)
        await remove_relationship(portal_user_id=user.portal_user_id, **validated)
    except RelationshipManagementValidationError as exc:
        return _relationship_redirect(path, error=str(exc))
    except DatabaseError as exc:
        return _relationship_redirect(path, error=user_facing_database_error(exc, fallback="The database rejected the relationship removal."))
    return _relationship_redirect(path, notice="Device assignment removed.")

@app.get(
    "/administration/metering-coverage",
    response_class=HTMLResponse,
    include_in_schema=False,
)
async def metering_coverage_administration(request: Request) -> HTMLResponse:
    user = require_authenticated_portal_user(request)
    coverage_rows = await list_accessible_metering_coverage(
        portal_user_id=user.portal_user_id
    )
    return templates.TemplateResponse(
        request=request,
        name="metering_coverage.html",
        context={
            "environment": settings.app_env,
            "page_title": "Metering coverage",
            "coverage_rows": coverage_rows,
            "summary": summarize_metering_coverage(coverage_rows),
            "active_navigation_key": "metering-coverage",
        },
        status_code=200,
    )


async def render_relationship_administration(request: Request, *, result: dict | None = None, error: str | None = None, status_code: int = 200) -> HTMLResponse:
    user = require_authenticated_portal_user(request)
    assets = await list_accessible_assets(portal_user_id=user.portal_user_id)
    devices = await list_accessible_devices(portal_user_id=user.portal_user_id)
    relationships = await list_accessible_relationships(portal_user_id=user.portal_user_id)
    relationship_types = await list_relationship_types()
    return templates.TemplateResponse(request=request,name="relationships.html",context={"environment":settings.app_env,"page_title":"Relationships","assets":assets,"devices":devices,"relationships":relationships,"relationship_types":relationship_types,"phase_designations":PHASE_DESIGNATIONS,"result":result,"error":error,"active_navigation_key":"relationships"},status_code=status_code)

@app.get("/administration/relationships",response_class=HTMLResponse,include_in_schema=False)
async def relationship_administration(request: Request) -> Response:
    return RedirectResponse("/administration/assets", status_code=303)

@app.post("/administration/relationships",response_class=HTMLResponse,include_in_schema=False)
async def create_relationship_administration(request: Request,asset_id: Annotated[str,Form()],device_id: Annotated[str,Form()],relationship_type: Annotated[str,Form()]) -> HTMLResponse:
    user=require_authenticated_portal_user(request)
    try:
        validated=validate_relationship_submission(asset_id=asset_id,device_id=device_id,relationship_type=relationship_type)
        result=await assign_device_to_asset(portal_user_id=user.portal_user_id,**validated)
    except RelationshipManagementValidationError as exc:
        return await render_relationship_administration(request,error=str(exc),status_code=400)
    except DatabaseError as exc:
        return await render_relationship_administration(request,error=user_facing_database_error(exc,fallback="The database rejected the relationship assignment."),status_code=409)
    return await render_relationship_administration(request,result=result,status_code=201)

@app.post("/administration/relationships/{relationship_id}/metadata",response_class=HTMLResponse,include_in_schema=False)
async def update_relationship_metadata_administration(request: Request,relationship_id: UUID,panel_name: Annotated[str,Form()]="",feeder_name: Annotated[str,Form()]="",breaker_identifier: Annotated[str,Form()]="",channel_identifier: Annotated[str,Form()]="",ct_ratio: Annotated[str,Form()]="",phase_designation: Annotated[str,Form()]="",mounting_point: Annotated[str,Form()]="",engineering_notes: Annotated[str,Form()]="") -> HTMLResponse:
    user=require_authenticated_portal_user(request)
    try:
        validated=validate_relationship_metadata(relationship_id=str(relationship_id),panel_name=panel_name,feeder_name=feeder_name,breaker_identifier=breaker_identifier,channel_identifier=channel_identifier,ct_ratio=ct_ratio,phase_designation=phase_designation,mounting_point=mounting_point,engineering_notes=engineering_notes)
        result=await update_relationship_metadata(portal_user_id=user.portal_user_id,**validated)
    except RelationshipManagementValidationError as exc: return await render_relationship_administration(request,error=str(exc),status_code=400)
    except DatabaseError as exc: return await render_relationship_administration(request,error=user_facing_database_error(exc,fallback="The database rejected the metadata update."),status_code=409)
    return await render_relationship_administration(request,result=result,status_code=200)

@app.post("/administration/relationships/{relationship_id}/remove",response_class=HTMLResponse,include_in_schema=False)
async def remove_relationship_administration(request: Request,relationship_id: UUID,removal_reason: Annotated[str,Form()]) -> HTMLResponse:
    user=require_authenticated_portal_user(request)
    try:
        validated=validate_relationship_removal(relationship_id=str(relationship_id),removal_reason=removal_reason)
        result=await remove_relationship(portal_user_id=user.portal_user_id,**validated)
    except RelationshipManagementValidationError as exc: return await render_relationship_administration(request,error=str(exc),status_code=400)
    except DatabaseError as exc: return await render_relationship_administration(request,error=user_facing_database_error(exc,fallback="The database rejected the relationship removal."),status_code=409)
    return await render_relationship_administration(request,result=result,status_code=200)

@app.post("/administration/relationships/{relationship_id}/replace-primary-meter",response_class=HTMLResponse,include_in_schema=False)
async def replace_primary_meter_administration(request: Request,relationship_id: UUID,replacement_device_id: Annotated[str,Form()],replacement_reason: Annotated[str,Form()]) -> HTMLResponse:
    user=require_authenticated_portal_user(request)
    try:
        validated=validate_primary_meter_replacement(relationship_id=str(relationship_id),replacement_device_id=replacement_device_id,replacement_reason=replacement_reason)
        result=await replace_primary_meter(portal_user_id=user.portal_user_id,**validated)
    except RelationshipManagementValidationError as exc: return await render_relationship_administration(request,error=str(exc),status_code=400)
    except DatabaseError as exc: return await render_relationship_administration(request,error=user_facing_database_error(exc,fallback="The database rejected the primary-meter replacement."),status_code=409)
    return await render_relationship_administration(request,result=result,status_code=200)


def _device_matches_context(row: dict, active_context) -> bool:
    """Return whether one accessible device is inside the active context."""
    if active_context.active_location_id:
        location_id = active_context.active_location_id
        if active_context.active_location_type == "SPACE":
            return str(row.get("space_id")) == location_id
        if active_context.active_location_type == "FLOOR":
            return str(row.get("floor_id")) == location_id
        return str(row.get("building_id")) == location_id
    if active_context.active_site_id:
        return str(row.get("site_id")) == active_context.active_site_id
    if active_context.active_organization_id:
        return str(row.get("organization_id")) == active_context.active_organization_id
    return True


async def render_device_administration(
    request: Request,
    *,
    error: str | None = None,
    status_code: int = 200,
) -> HTMLResponse:
    """Render the scope-safe Device administration landing page."""
    user = require_authenticated_portal_user(request)
    devices = await list_accessible_devices(portal_user_id=user.portal_user_id)
    devices.sort(key=lambda row: (
        str(row.get("organization_name") or "").casefold(),
        str(row.get("site_name") or "").casefold(),
        str(row.get("building_name") or "").casefold(),
        str(row.get("floor_name") or "").casefold(),
        str(row.get("space_name") or "").casefold(),
        str(row.get("device_name") or "").casefold(),
        str(row.get("lifecycle_status") or ""),
    ))
    telemetry_states = tuple(dict.fromkeys(
        [*TELEMETRY_STATES, "SILENT"]
    ))
    return templates.TemplateResponse(
        request=request,
        name="devices.html",
        context={
            "environment": settings.app_env,
            "page_title": "Devices",
            "devices": devices,
            "can_manage": has_permission(user, PortalPermission.DEVICE_MANAGE),
            "device_lifecycle_statuses": DEVICE_LIFECYCLE_STATUSES,
            "telemetry_states": telemetry_states,
            "error": error,
            "active_navigation_key": "devices",
        },
        status_code=status_code,
    )


DEVICE_COMMISSIONING_BLOCKERS = {
    "DEVICE_DECOMMISSIONED": {"title": "Device decommissioned", "message": "A decommissioned device cannot be commissioned.", "action_label": None, "action_path": None},
    "GATEWAY_REQUIRED": {"title": "Gateway required", "message": "Assign the device to a gateway before commissioning.", "action_label": "Edit device", "action_path": "edit"},
    "DEVICE_MODEL_REQUIRED": {"title": "Device model required", "message": "Select a device model before commissioning.", "action_label": "Edit device", "action_path": "edit"},
    "DEVICE_PROFILE_REQUIRED": {"title": "Telemetry profile required", "message": "Select a compatible telemetry profile before commissioning.", "action_label": "Edit profile", "action_path": "edit"},
    "PROFILE_CATEGORY_INCOMPATIBLE": {"title": "Profile is incompatible", "message": "The selected telemetry profile is not compatible with the device category.", "action_label": "Edit profile", "action_path": "edit"},
    "REQUIRED_TELEMETRY_POINTS_NOT_VALIDATED": {"title": "Required telemetry is not validated", "message": "Receive and validate all required telemetry points before commissioning.", "action_label": "Open telemetry diagnostics", "action_path": "/administration/telemetry-validation"},
    "ASSET_ASSIGNMENT_REQUIRED_BY_POLICY": {"title": "Asset assignment required", "message": "This device must be assigned to an asset before it can be commissioned.", "action_label": "Assign device to asset", "action_path": "#asset-assignments"},
    "READINESS_UNAVAILABLE": {"title": "Readiness unavailable", "message": "Commissioning readiness could not be evaluated. Review device configuration and try again.", "action_label": "Edit device", "action_path": "edit"},
}

def _device_commissioning_context(device: dict) -> dict:
    lifecycle = str(device.get("lifecycle_status") or "REGISTERED").upper()
    if lifecycle == "ACTIVE":
        status = "Commissioned"
        readiness = "Not applicable"
    elif lifecycle == "DECOMMISSIONED":
        status = "Decommissioned"
        readiness = "Not applicable"
    else:
        status = "Not commissioned"
        readiness = "Ready" if device.get("is_ready") else "Not ready"
    blockers = []
    for code in device.get("blocking_reason_codes") or []:
        detail = dict(DEVICE_COMMISSIONING_BLOCKERS.get(code, {
            "title": str(code).replace("_", " ").title(),
            "message": "Resolve this commissioning requirement and check readiness again.",
            "action_label": None,
            "action_path": None,
        }))
        path = detail.get("action_path")
        if path == "edit":
            detail["action_path"] = f"/administration/devices/{device['device_id']}/edit"
        detail["code"] = code
        blockers.append(detail)
    return {
        "commissioning_display_status": status,
        "commissioning_readiness_display": readiness,
        "commissioning_blockers": blockers,
        "asset_assignment_requirement": (
            "Required before commissioning"
            if device.get("operational_policy") == "ASSET_ASSIGNED"
            else "Optional"
        ),
    }


async def _device_form_catalog(request: Request) -> dict:
    """Return accessible and controlled catalogs used by Device forms."""
    user = require_authenticated_portal_user(request)
    gateways = await list_accessible_gateways(portal_user_id=user.portal_user_id)
    hierarchy_rows = await list_accessible_physical_locations(
        portal_user_id=user.portal_user_id
    )
    return {
        "gateways": gateways,
        "hierarchy_rows": [
            {
                key: str(value) if isinstance(value, UUID) else value
                for key, value in row.items()
            }
            for row in hierarchy_rows
        ],
        "categories": await list_device_categories(),
        "models": await list_device_models(),
        "profiles": await list_device_profiles(),
        "device_protocols": DEVICE_PROTOCOLS,
        "device_lifecycle_statuses": DEVICE_LIFECYCLE_STATUSES,
        "identifier_types": DEVICE_IDENTIFIER_TYPES,
        "operational_policies": DEVICE_OPERATIONAL_POLICIES,
    }


@app.get(
    "/administration/devices",
    response_class=HTMLResponse,
    include_in_schema=False,
)
async def device_administration(request: Request) -> Response:
    return await render_device_administration(request)


@app.get(
    "/administration/devices/new",
    response_class=HTMLResponse,
    include_in_schema=False,
)
async def device_create_page(request: Request) -> Response:
    user = require_authenticated_portal_user(request)
    if not has_permission(user, PortalPermission.DEVICE_MANAGE):
        return RedirectResponse("/forbidden", status_code=303)
    catalog = await _device_form_catalog(request)
    return templates.TemplateResponse(
        request=request,
        name="device_create.html",
        context={
            "environment": settings.app_env,
            "page_title": "Create device",
            "active_navigation_key": "devices",
            "form_data": {
                "lifecycle_status": "REGISTERED",
                "protocol": "MQTT",
                "identifier_type": "MQTT_UID",
                "operational_policy": "ASSET_ASSIGNED",
                "use_gateway_location": True,
            },
            "error": None,
            **catalog,
        },
    )


@app.post(
    "/administration/devices",
    response_class=HTMLResponse,
    include_in_schema=False,
)
async def create_device_administration(
    request: Request,
    gateway_id: Annotated[str, Form()],
    device_name: Annotated[str, Form()],
    external_id: Annotated[str, Form()],
    device_category_id: Annotated[str, Form()],
    device_model_id: Annotated[str, Form()],
    profile_id: Annotated[str, Form()],
    protocol: Annotated[str, Form()],
    identifier_type: Annotated[str, Form()],
    identifier_value: Annotated[str, Form()],
    operational_policy: Annotated[str, Form()],
    lifecycle_status: Annotated[str, Form()] = "REGISTERED",
    firmware_version: Annotated[str, Form()] = "",
    serial_number: Annotated[str, Form()] = "",
    use_gateway_location: Annotated[str, Form()] = "",
    device_location_building_id: Annotated[str, Form()] = "",
    device_location_floor_id: Annotated[str, Form()] = "",
    device_location_space_id: Annotated[str, Form()] = "",
) -> Response:
    user = require_authenticated_portal_user(request)
    submitted = {
        "gateway_id": gateway_id,
        "device_name": device_name,
        "external_id": external_id,
        "device_category_id": device_category_id,
        "device_model_id": device_model_id,
        "profile_id": profile_id,
        "protocol": protocol,
        "identifier_type": identifier_type,
        "identifier_value": identifier_value,
        "operational_policy": operational_policy,
        "lifecycle_status": lifecycle_status,
        "firmware_version": firmware_version,
        "serial_number": serial_number,
        "use_gateway_location": use_gateway_location,
        "building_id": device_location_building_id,
        "floor_id": device_location_floor_id,
        "space_id": device_location_space_id,
    }
    catalog = await _device_form_catalog(request)
    base_context = {
        "environment": settings.app_env,
        "page_title": "Create device",
        "active_navigation_key": "devices",
        "form_data": submitted,
        **catalog,
    }
    try:
        validated = validate_device_submission(
            gateway_id=gateway_id,
            device_name=device_name,
            external_id=external_id,
            device_category_id=device_category_id,
            device_model_id=device_model_id,
            profile_id=profile_id,
            protocol=protocol,
            lifecycle_status=lifecycle_status,
            firmware_version=firmware_version,
            serial_number=serial_number,
            identifier_type=identifier_type,
            identifier_value=identifier_value,
            operational_policy=operational_policy,
            use_gateway_location=use_gateway_location,
            building_id=device_location_building_id,
            floor_id=device_location_floor_id,
            space_id=device_location_space_id,
        )
        result = await create_device(
            portal_user_id=user.portal_user_id,
            **validated,
        )
    except DeviceManagementValidationError as exc:
        return templates.TemplateResponse(
            request=request,
            name="device_create.html",
            context={**base_context, "error": str(exc)},
            status_code=400,
        )
    except DatabaseError as exc:
        return templates.TemplateResponse(
            request=request,
            name="device_create.html",
            context={
                **base_context,
                "error": user_facing_database_error(
                    exc,
                    fallback="The database rejected the device request.",
                ),
            },
            status_code=409,
        )
    return RedirectResponse(
        f"/administration/devices/{result['entity_id']}?commissioning_notice=created#operational-lifecycle",
        status_code=303,
    )


async def _accessible_device_or_none(
    request: Request,
    device_id: UUID,
) -> dict | None:
    user = require_authenticated_portal_user(request)
    return await get_device_workspace(
        portal_user_id=user.portal_user_id,
        device_id=str(device_id),
    )


@app.get(
    "/administration/devices/{device_id}",
    response_class=HTMLResponse,
    include_in_schema=False,
)
async def device_detail_page(request: Request, device_id: UUID) -> Response:
    user = require_authenticated_portal_user(request)
    device = await _accessible_device_or_none(request, device_id)
    if device is None:
        return RedirectResponse("/forbidden", status_code=303)
    relationships = [
        row for row in await list_accessible_relationships(
            portal_user_id=user.portal_user_id
        ) if str(row["device_id"]) == str(device_id)
    ]
    candidate_assets = [
        row for row in await list_accessible_assets(
            portal_user_id=user.portal_user_id
        ) if str(row["site_id"]) == str(device["site_id"])
    ]
    return templates.TemplateResponse(
        request=request,
        name="device_detail.html",
        context={
            "environment": settings.app_env,
            "page_title": device["device_name"],
            "active_navigation_key": "devices",
            "device": device, "relationships": relationships,
            "candidate_assets": candidate_assets,
            "relationship_types": await list_relationship_types(),
            "relationship_error": request.query_params.get("relationship_error"),
            "relationship_notice": request.query_params.get("relationship_notice"),
            "can_manage_relationships": has_permission(
                user, PortalPermission.RELATIONSHIP_MANAGE
            ),
            "can_edit": has_permission(user, PortalPermission.DEVICE_MANAGE),
            "can_commission": has_permission(
                user, PortalPermission.COMMISSIONING_EXECUTE
            ),
            "commissioning_notice": request.query_params.get("commissioning_notice"),
            "commissioning_error": request.query_params.get("commissioning_error"),
            **_device_commissioning_context(device),
        },
    )



async def _render_device_point_configuration(
    request: Request,
    device_id: UUID,
    *,
    error: str | None = None,
    status_code: int = 200,
) -> Response:
    user = require_authenticated_portal_user(request)
    device = await _accessible_device_or_none(request, device_id)
    if device is None:
        return RedirectResponse("/forbidden", status_code=303)
    points = await list_device_point_configuration(
        portal_user_id=user.portal_user_id,
        device_id=str(device_id),
    )
    return templates.TemplateResponse(
        request=request,
        name="device_telemetry_points.html",
        context={
            "environment": settings.app_env,
            "page_title": f"Telemetry points · {device['device_name']}",
            "active_navigation_key": "devices",
            "device": device,
            "points": points,
            "enabled_count": sum(1 for row in points if row.get("is_enabled")),
            "can_manage": has_permission(
                user, PortalPermission.DEVICE_MANAGE
            ),
            "notice": request.query_params.get("point_notice"),
            "error": error,
        },
        status_code=status_code,
    )


@app.get(
    "/administration/devices/{device_id}/telemetry-points",
    response_class=HTMLResponse,
    include_in_schema=False,
)
async def device_point_configuration_page(
    request: Request, device_id: UUID
) -> Response:
    return await _render_device_point_configuration(request, device_id)


@app.post(
    "/administration/devices/{device_id}/telemetry-points",
    response_class=HTMLResponse,
    include_in_schema=False,
)
async def device_point_configuration_submit(
    request: Request, device_id: UUID
) -> Response:
    user = require_authenticated_portal_user(request)
    if not has_permission(user, PortalPermission.DEVICE_MANAGE):
        return RedirectResponse("/forbidden", status_code=303)
    form = await request.form()
    try:
        validated = validate_device_point_configuration_update(
            enabled_logical_point_ids=[
                str(value) for value in form.getlist("enabled_logical_point_ids")
            ],
            change_reason=str(form.get("change_reason") or ""),
        )
        await update_device_point_configuration(
            portal_user_id=user.portal_user_id,
            device_id=str(device_id),
            **validated,
        )
    except DeviceManagementValidationError as exc:
        return await _render_device_point_configuration(
            request, device_id, error=str(exc), status_code=400
        )
    except DatabaseError as exc:
        return await _render_device_point_configuration(
            request,
            device_id,
            error=user_facing_database_error(
                exc,
                fallback="The database rejected the telemetry-point update.",
            ),
            status_code=409,
        )
    return RedirectResponse(
        f"/administration/devices/{device_id}/telemetry-points"
        "?point_notice=Telemetry+point+configuration+saved.",
        status_code=303,
    )


@app.post(
    "/administration/devices/{device_id}/telemetry-points/reset",
    response_class=HTMLResponse,
    include_in_schema=False,
)
async def device_point_configuration_reset(
    request: Request,
    device_id: UUID,
    change_reason: Annotated[str, Form()],
) -> Response:
    user = require_authenticated_portal_user(request)
    if not has_permission(user, PortalPermission.DEVICE_MANAGE):
        return RedirectResponse("/forbidden", status_code=303)
    try:
        validated = validate_device_point_configuration_update(
            enabled_logical_point_ids=[],
            change_reason=change_reason,
        )
        await reset_device_point_configuration(
            portal_user_id=user.portal_user_id,
            device_id=str(device_id),
            change_reason=validated["change_reason"],
        )
    except DeviceManagementValidationError as exc:
        return await _render_device_point_configuration(
            request, device_id, error=str(exc), status_code=400
        )
    except DatabaseError as exc:
        return await _render_device_point_configuration(
            request,
            device_id,
            error=user_facing_database_error(
                exc,
                fallback="The database rejected the telemetry-point reset.",
            ),
            status_code=409,
        )
    return RedirectResponse(
        f"/administration/devices/{device_id}/telemetry-points"
        "?point_notice=Telemetry+points+reset+from+the+current+profile.",
        status_code=303,
    )

@app.get(
    "/administration/devices/{device_id}/edit",
    response_class=HTMLResponse,
    include_in_schema=False,
)
async def device_edit_page(request: Request, device_id: UUID) -> Response:
    user = require_authenticated_portal_user(request)
    if not has_permission(user, PortalPermission.DEVICE_MANAGE):
        return RedirectResponse("/forbidden", status_code=303)
    device = await _accessible_device_or_none(request, device_id)
    if device is None:
        return RedirectResponse("/forbidden", status_code=303)
    gateway = await get_gateway_workspace(
        portal_user_id=user.portal_user_id,
        gateway_id=str(device["gateway_id"]),
    )
    catalog = await _device_form_catalog(request)
    device_site_id = str(
        device.get("site_id")
        or (gateway or {}).get("site_id")
        or ""
    )
    catalog["hierarchy_rows"] = [
        row
        for row in catalog["hierarchy_rows"]
        if str(row.get("site_id") or "") == device_site_id
    ]
    inherited = device.get("location_mode") == "GATEWAY"
    return templates.TemplateResponse(
        request=request,
        name="device_edit.html",
        context={
            "environment": settings.app_env,
            "page_title": f"Edit {device['device_name']}",
            "active_navigation_key": "devices",
            "device": device,
            "gateway": gateway or {},
            "device_site_id": device_site_id,
            "form_data": {"use_gateway_location": inherited},
            "error": None,
            **_device_commissioning_context(device),
            **catalog,
        },
    )


@app.post(
    "/administration/devices/{device_id}/edit",
    response_class=HTMLResponse,
    include_in_schema=False,
)
async def device_edit_submit(
    request: Request,
    device_id: UUID,
    device_name: Annotated[str, Form()],
    device_category_id: Annotated[str, Form()],
    device_model_id: Annotated[str, Form()],
    profile_id: Annotated[str, Form()],
    protocol: Annotated[str, Form()],
    lifecycle_status: Annotated[str, Form()],
    identifier_type: Annotated[str, Form()],
    identifier_value: Annotated[str, Form()],
    operational_policy: Annotated[str, Form()],
    change_reason: Annotated[str, Form()],
    firmware_version: Annotated[str, Form()] = "",
    serial_number: Annotated[str, Form()] = "",
    use_gateway_location: Annotated[str, Form()] = "",
    device_location_building_id: Annotated[str, Form()] = "",
    device_location_floor_id: Annotated[str, Form()] = "",
    device_location_space_id: Annotated[str, Form()] = "",
) -> Response:
    user = require_authenticated_portal_user(request)
    device = await _accessible_device_or_none(request, device_id)
    if device is None:
        return RedirectResponse("/forbidden", status_code=303)
    gateway = await get_gateway_workspace(
        portal_user_id=user.portal_user_id,
        gateway_id=str(device["gateway_id"]),
    )
    submitted = {
        "device_name": device_name,
        "device_category_id": device_category_id,
        "device_model_id": device_model_id,
        "profile_id": profile_id,
        "protocol": protocol,
        "lifecycle_status": lifecycle_status,
        "identifier_type": identifier_type,
        "identifier_value": identifier_value,
        "operational_policy": operational_policy,
        "change_reason": change_reason,
        "firmware_version": firmware_version,
        "serial_number": serial_number,
        "use_gateway_location": use_gateway_location,
        "building_id": device_location_building_id,
        "floor_id": device_location_floor_id,
        "space_id": device_location_space_id,
    }
    catalog = await _device_form_catalog(request)
    device_site_id = str(
        device.get("site_id")
        or (gateway or {}).get("site_id")
        or ""
    )
    catalog["hierarchy_rows"] = [
        row
        for row in catalog["hierarchy_rows"]
        if str(row.get("site_id") or "") == device_site_id
    ]
    base_context = {
        "environment": settings.app_env,
        "page_title": f"Edit {device['device_name']}",
        "active_navigation_key": "devices",
        "device": device,
        "gateway": gateway or {},
        "device_site_id": device_site_id,
        "form_data": submitted,
        **_device_commissioning_context(device),
        **catalog,
    }
    try:
        if (
            lifecycle_status.strip().upper() == "ACTIVE"
            and device.get("lifecycle_status") != "ACTIVE"
        ):
            raise DeviceManagementValidationError(
                "Use the controlled commissioning action to activate a device."
            )
        validated = validate_device_workspace_update(
            device_name=device_name,
            device_category_id=device_category_id,
            device_model_id=device_model_id,
            profile_id=profile_id,
            protocol=protocol,
            lifecycle_status=lifecycle_status,
            firmware_version=firmware_version,
            serial_number=serial_number,
            identifier_type=identifier_type,
            identifier_value=identifier_value,
            operational_policy=operational_policy,
            use_gateway_location=use_gateway_location,
            building_id=device_location_building_id,
            floor_id=device_location_floor_id,
            space_id=device_location_space_id,
            change_reason=change_reason,
        )
        await update_device_workspace(
            portal_user_id=user.portal_user_id,
            device_id=str(device_id),
            **validated,
        )
    except DeviceManagementValidationError as exc:
        return templates.TemplateResponse(
            request=request,
            name="device_edit.html",
            context={**base_context, "error": str(exc)},
            status_code=400,
        )
    except DatabaseError as exc:
        return templates.TemplateResponse(
            request=request,
            name="device_edit.html",
            context={
                **base_context,
                "error": user_facing_database_error(
                    exc,
                    fallback="The database rejected the device update.",
                ),
            },
            status_code=409,
        )
    return RedirectResponse(
        f"/administration/devices/{device_id}",
        status_code=303,
    )


@app.post(
    "/administration/devices/{device_id}/lifecycle",
    response_class=HTMLResponse,
    include_in_schema=False,
)
async def update_device_lifecycle_administration(
    request: Request,
    device_id: UUID,
    lifecycle_status: Annotated[str, Form()],
    change_reason: Annotated[str, Form()] = "",
) -> Response:
    user = require_authenticated_portal_user(request)
    try:
        validated = validate_device_lifecycle_update(
            lifecycle_status=lifecycle_status,
            change_reason=change_reason,
        )
        await update_device_lifecycle(
            portal_user_id=user.portal_user_id,
            device_id=str(device_id),
            **validated,
        )
    except (DeviceManagementValidationError, DatabaseError) as exc:
        return await render_device_administration(
            request,
            error=(str(exc) if isinstance(exc, DeviceManagementValidationError)
                   else user_facing_database_error(
                       exc,
                       fallback="The database rejected the device lifecycle change.",
                   )),
            status_code=(400 if isinstance(exc, DeviceManagementValidationError) else 409),
        )
    return RedirectResponse(
        f"/administration/devices/{device_id}",
        status_code=303,
    )


@app.post(
    "/administration/devices/{device_id}/operational-policy",
    response_class=HTMLResponse,
    include_in_schema=False,
)
async def set_device_operational_policy_administration(
    request: Request,
    device_id: UUID,
    operational_policy: Annotated[str, Form()],
) -> Response:
    user = require_authenticated_portal_user(request)
    try:
        await set_device_operational_policy(
            portal_user_id=user.portal_user_id,
            device_id=str(device_id),
            operational_policy=operational_policy,
        )
    except DatabaseError as exc:
        return await render_device_administration(
            request,
            error=user_facing_database_error(
                exc,
                fallback="The database rejected the device operational policy.",
            ),
            status_code=409,
        )
    return RedirectResponse(
        f"/administration/devices/{device_id}",
        status_code=303,
    )


@app.post(
    "/administration/devices/{device_id}/commission",
    response_class=HTMLResponse,
    include_in_schema=False,
)
async def commission_device_administration(
    request: Request,
    device_id: UUID,
) -> Response:
    user = require_authenticated_portal_user(request)
    try:
        await commission_device(
            portal_user_id=user.portal_user_id,
            device_id=str(device_id),
        )
    except DatabaseError as exc:
        from urllib.parse import quote
        message = user_facing_database_error(
            exc,
            fallback="Commissioning could not be completed. Review readiness and try again.",
        )
        return RedirectResponse(
            f"/administration/devices/{device_id}?commissioning_error={quote(message)}#operational-lifecycle",
            status_code=303,
        )
    return RedirectResponse(
        f"/administration/devices/{device_id}?commissioning_notice=commissioned#operational-lifecycle",
        status_code=303,
    )


@app.get(
    "/administration/commissioning",
    response_class=HTMLResponse,
    include_in_schema=False,
)
async def commissioning_dashboard(request: Request) -> HTMLResponse:
    """Display tenant-scoped commissioning readiness grouped by status."""
    user = require_authenticated_portal_user(request)
    organization_id = request.query_params.get("organization_id") or None
    site_id = request.query_params.get("site_id") or None
    entity_type = request.query_params.get("entity_type") or None
    if entity_type and entity_type.upper() not in ENTITY_TYPES:
        entity_type = None

    readiness_rows = await list_accessible_commissioning_readiness(
        portal_user_id=user.portal_user_id,
    )
    accessible_sites = await list_accessible_sites(
        portal_user_id=user.portal_user_id,
    )
    organizations_by_id = {}
    for site in accessible_sites:
        organizations_by_id[str(site["organization_id"])] = {
            "organization_id": site["organization_id"],
            "organization_code": site["organization_code"],
            "organization_name": site["organization_name"],
        }

    dashboard = build_commissioning_dashboard(
        readiness_rows,
        organization_id=organization_id,
        site_id=site_id,
        entity_type=entity_type,
    )
    return templates.TemplateResponse(
        request=request,
        name="commissioning.html",
        context={
            "environment": settings.app_env,
            "page_title": "Commissioning dashboard",
            "commissioning_statuses": COMMISSIONING_STATUSES,
            "entity_types": ENTITY_TYPES,
            "dashboard": dashboard,
            "organizations": sorted(
                organizations_by_id.values(),
                key=lambda row: row["organization_name"].casefold(),
            ),
            "sites": accessible_sites,
            "selected_organization_id": organization_id or "",
            "selected_site_id": site_id or "",
            "selected_entity_type": (entity_type or "").upper(),
            "active_navigation_key": "commissioning",
        },
    )


@app.get(
    "/administration/telemetry-validation",
    response_class=HTMLResponse,
    include_in_schema=False,
)
async def telemetry_validation_dashboard(request: Request) -> HTMLResponse:
    """Display tenant-scoped device configuration and telemetry health."""
    user = require_authenticated_portal_user(request)
    organization_id = request.query_params.get("organization_id") or None
    site_id = request.query_params.get("site_id") or None
    telemetry_state = request.query_params.get("telemetry_state") or None
    if telemetry_state and telemetry_state.upper() not in TELEMETRY_STATES:
        telemetry_state = None
    rows = await list_accessible_device_telemetry_availability(
        portal_user_id=user.portal_user_id,
        organization_id=organization_id,
        site_id=site_id,
        telemetry_state=telemetry_state,
    )
    accessible_sites = await list_accessible_sites(portal_user_id=user.portal_user_id)
    organizations_by_id = {}
    for site in accessible_sites:
        organizations_by_id[str(site["organization_id"])] = {
            "organization_id": site["organization_id"],
            "organization_code": site["organization_code"],
            "organization_name": site["organization_name"],
        }
    return templates.TemplateResponse(
        request=request, name="telemetry_validation.html",
        context={
            "environment": settings.app_env,
            "page_title": "Telemetry validation",
            "rows": rows,
            "telemetry_states": TELEMETRY_STATES,
            "organizations": sorted(organizations_by_id.values(), key=lambda row: row["organization_name"].casefold()),
            "sites": accessible_sites,
            "selected_organization_id": organization_id or "",
            "selected_site_id": site_id or "",
            "selected_telemetry_state": (telemetry_state or "").upper(),
            "active_navigation_key": "telemetry-validation",
        },
    )


@app.get(
    "/administration/reconciliation",
    response_class=HTMLResponse,
    include_in_schema=False,
)
async def reconciliation_queue_dashboard(request: Request) -> HTMLResponse:
    """Display one tenant-safe operational reconciliation queue."""
    user = require_authenticated_portal_user(request)
    organization_id = request.query_params.get("organization_id") or None
    site_id = request.query_params.get("site_id") or None
    issue_type = request.query_params.get("issue_type") or None
    if issue_type and issue_type.upper() not in ISSUE_TYPES:
        issue_type = None
    rows = await list_accessible_reconciliation_queue(
        portal_user_id=user.portal_user_id,
        organization_id=organization_id,
        site_id=site_id,
        issue_type=issue_type,
    )
    accessible_sites = await list_accessible_sites(portal_user_id=user.portal_user_id)
    organizations_by_id = {}
    for site in accessible_sites:
        organizations_by_id[str(site["organization_id"])] = {
            "organization_id": site["organization_id"],
            "organization_name": site["organization_name"],
        }
    return templates.TemplateResponse(
        request=request,
        name="reconciliation_queue.html",
        context={
            "environment": settings.app_env,
            "page_title": "Reconciliation queue",
            "rows": rows,
            "summary": summarize_reconciliation_queue(rows),
            "issue_types": ISSUE_TYPES,
            "organizations": sorted(organizations_by_id.values(), key=lambda row: row["organization_name"].casefold()),
            "sites": accessible_sites,
            "selected_organization_id": organization_id or "",
            "selected_site_id": site_id or "",
            "selected_issue_type": (issue_type or "").upper(),
            "active_navigation_key": "reconciliation",
        },
    )


async def render_gateway_administration(
    request: Request,
    *,
    form_data: dict | None = None,
    result: dict | None = None,
    error: str | None = None,
    status_code: int = 200,
) -> HTMLResponse:
    """Render the scope-safe gateway administration landing page."""
    user = require_authenticated_portal_user(request)
    gateways = await list_accessible_gateways(portal_user_id=user.portal_user_id)
    readiness_rows = await list_accessible_commissioning_readiness(
        portal_user_id=user.portal_user_id, entity_type="GATEWAY"
    )
    gateway_readiness = {str(row["entity_id"]): row for row in readiness_rows}

    gateways.sort(key=lambda row: (
        str(row.get("organization_name") or "").casefold(),
        str(row.get("site_name") or "").casefold(),
        str(row.get("building_name") or "").casefold(),
        str(row.get("floor_name") or "").casefold(),
        str(row.get("space_name") or "").casefold(),
        str(row.get("gateway_name") or "").casefold(),
        str(row.get("lifecycle_status") or ""),
    ))
    return templates.TemplateResponse(
        request=request, name="gateways.html",
        context={
            "environment": settings.app_env, "page_title": "Gateways",
            "gateways": gateways,
            "can_manage": has_permission(user, PortalPermission.GATEWAY_MANAGE),
            "gateway_readiness": gateway_readiness,
            "gateway_lifecycle_statuses": GATEWAY_LIFECYCLE_STATUSES,
            "form_data": form_data or {}, "result": result, "error": error,
            "active_navigation_key": "gateways",
        }, status_code=status_code,
    )


@app.get(
    "/administration/gateways",
    response_class=HTMLResponse,
    include_in_schema=False,
)
async def gateway_administration(request: Request) -> Response:
    return await render_gateway_administration(request)


@app.post(
    "/administration/gateways",
    response_class=HTMLResponse,
    include_in_schema=False,
)
async def create_gateway_administration(
    request: Request,
    organization_id: Annotated[str, Form()],
    gateway_location_site_id: Annotated[str, Form()],
    gateway_name: Annotated[str, Form()],
    external_id: Annotated[str, Form()],
    gateway_model_id: Annotated[str, Form()],
    lifecycle_status: Annotated[str, Form()] = "REGISTERED",
    gateway_location_building_id: Annotated[str, Form()] = "",
    gateway_location_floor_id: Annotated[str, Form()] = "",
    gateway_location_space_id: Annotated[str, Form()] = "",
) -> Response:
    user = require_authenticated_portal_user(request)
    submitted = {
        "gateway_name": gateway_name, "external_id": external_id,
        "gateway_model_id": gateway_model_id, "lifecycle_status": lifecycle_status,
        "building_id": gateway_location_building_id, "floor_id": gateway_location_floor_id,
        "space_id": gateway_location_space_id,
    }
    context = get_administration_context(request)
    if (not context.active_site_id or not context.active_organization_id
            or context.active_site_id != gateway_location_site_id
            or context.active_organization_id != organization_id):
        return RedirectResponse("/forbidden", status_code=303)
    catalog = await _gateway_form_catalog(request, context.active_site_id)
    base_context = {
        "environment": settings.app_env, "page_title": "Create gateway",
        "active_navigation_key": "gateways", "active_context": context,
        "form_data": submitted, **catalog,
    }
    try:
        validated = validate_gateway_submission(
            organization_id=organization_id, site_id=gateway_location_site_id,
            gateway_name=gateway_name, external_id=external_id,
            gateway_model_id=gateway_model_id, lifecycle_status=lifecycle_status,
            building_id=gateway_location_building_id, floor_id=gateway_location_floor_id,
            space_id=gateway_location_space_id,
        )
        result = await create_gateway(portal_user_id=user.portal_user_id, **validated)
    except GatewayManagementValidationError as exc:
        return templates.TemplateResponse(request=request, name="gateway_create.html",
            context={**base_context, "error": str(exc)}, status_code=400)
    except DatabaseError as exc:
        return templates.TemplateResponse(request=request, name="gateway_create.html",
            context={**base_context, "error": user_facing_database_error(
                exc, fallback="The database rejected the gateway request.")}, status_code=409)
    return RedirectResponse(
        f"/administration/gateways/{result['entity_id']}", status_code=303
    )


@app.post(
    "/administration/gateways/{gateway_id}/commission",
    response_class=HTMLResponse,
    include_in_schema=False,
)
async def commission_gateway_administration(
    request: Request, gateway_id: UUID,
) -> HTMLResponse:
    """Commission one accessible gateway using declarative readiness."""
    user = require_authenticated_portal_user(request)
    try:
        result = await commission_gateway(
            portal_user_id=user.portal_user_id, gateway_id=str(gateway_id)
        )
    except DatabaseError as exc:
        return await render_gateway_administration(
            request,
            error=user_facing_database_error(
                exc, fallback="The database blocked gateway commissioning."
            ),
            status_code=409,
        )
    return await render_gateway_administration(
        request, result=result, status_code=200
    )


@app.post(
    "/administration/gateways/{gateway_id}/lifecycle",
    response_class=HTMLResponse,
    include_in_schema=False,
)
async def update_gateway_lifecycle_administration(
    request: Request,
    gateway_id: UUID,
    lifecycle_status: Annotated[str, Form()],
    change_reason: Annotated[str, Form()] = "",
) -> HTMLResponse:
    user = require_authenticated_portal_user(request)
    try:
        validated = validate_gateway_lifecycle_update(
            lifecycle_status=lifecycle_status,
            change_reason=change_reason,
        )
        result = await update_gateway_lifecycle(
            portal_user_id=user.portal_user_id,
            gateway_id=str(gateway_id),
            **validated,
        )
    except GatewayManagementValidationError as exc:
        return await render_gateway_administration(
            request, error=str(exc), status_code=400
        )
    except DatabaseError as exc:
        return await render_gateway_administration(
            request,
            error=user_facing_database_error(
                exc, fallback="The database rejected the lifecycle change."
            ),
            status_code=409,
        )
    return await render_gateway_administration(
        request, result=result, status_code=200
    )


async def _gateway_form_catalog(request: Request, site_id: str) -> dict:
    user = require_authenticated_portal_user(request)
    rows = await list_accessible_physical_locations(portal_user_id=user.portal_user_id)
    rows = [row for row in rows if str(row.get("site_id")) == str(site_id)]
    return {
        "hierarchy_rows": [{key: str(value) if isinstance(value, UUID) else value for key, value in row.items()} for row in rows],
        "gateway_models": await list_gateway_models(),
        "gateway_lifecycle_statuses": GATEWAY_LIFECYCLE_STATUSES,
    }


@app.get("/administration/gateways/new", response_class=HTMLResponse, include_in_schema=False)
async def gateway_create_page(request: Request) -> Response:
    user = require_authenticated_portal_user(request)
    if not has_permission(user, PortalPermission.GATEWAY_MANAGE):
        return RedirectResponse("/forbidden", status_code=303)
    context = get_administration_context(request)
    if not context.active_site_id or not context.active_organization_id:
        return RedirectResponse("/administration/sites?chooser=1&return_to=/administration/gateways/new", status_code=303)
    catalog = await _gateway_form_catalog(request, context.active_site_id)
    return templates.TemplateResponse(request=request, name="gateway_create.html", context={
        "environment": settings.app_env, "page_title": "Create gateway",
        "active_navigation_key": "gateways", "form_data": {"lifecycle_status": "REGISTERED"},
        "error": None, "active_context": context, **catalog})


async def _accessible_gateway_or_none(request: Request, gateway_id: UUID):
    user = require_authenticated_portal_user(request)
    return await get_gateway_workspace(portal_user_id=user.portal_user_id, gateway_id=str(gateway_id))


@app.get("/administration/gateways/{gateway_id}", response_class=HTMLResponse, include_in_schema=False)
async def gateway_detail_page(request: Request, gateway_id: UUID) -> Response:
    user = require_authenticated_portal_user(request)
    gateway = await _accessible_gateway_or_none(request, gateway_id)
    if gateway is None:
        return RedirectResponse("/forbidden", status_code=303)
    return templates.TemplateResponse(request=request, name="gateway_detail.html", context={
        "environment": settings.app_env, "page_title": gateway["gateway_name"],
        "active_navigation_key": "gateways", "gateway": gateway,
        "can_edit": has_permission(user, PortalPermission.GATEWAY_MANAGE)})


@app.post("/administration/gateways/{gateway_id}/select", include_in_schema=False)
async def select_gateway_context(request: Request, gateway_id: UUID) -> Response:
    user = require_authenticated_portal_user(request)
    gateway = await _accessible_gateway_or_none(request, gateway_id)
    if gateway is None:
        return RedirectResponse("/forbidden", status_code=303)
    await set_active_site(request, user, str(gateway["site_id"]))
    location_id = gateway.get("space_id") or gateway.get("floor_id") or gateway.get("building_id")
    if location_id:
        await set_active_location(request, user, str(location_id))
    return RedirectResponse("/administration/gateways", status_code=303)


@app.get("/administration/gateways/{gateway_id}/edit", response_class=HTMLResponse, include_in_schema=False)
async def gateway_edit_page(request: Request, gateway_id: UUID) -> Response:
    user = require_authenticated_portal_user(request)
    if not has_permission(user, PortalPermission.GATEWAY_MANAGE):
        return RedirectResponse("/forbidden", status_code=303)
    gateway = await _accessible_gateway_or_none(request, gateway_id)
    if gateway is None:
        return RedirectResponse("/forbidden", status_code=303)
    catalog = await _gateway_form_catalog(request, str(gateway["site_id"]))
    return templates.TemplateResponse(request=request, name="gateway_edit.html", context={
        "environment": settings.app_env, "page_title": f"Edit {gateway['gateway_name']}",
        "active_navigation_key": "gateways", "gateway": gateway,
        "form_data": {}, "error": None, **catalog})


@app.post("/administration/gateways/{gateway_id}/edit", response_class=HTMLResponse, include_in_schema=False)
async def gateway_edit_submit(
    request: Request, gateway_id: UUID, gateway_name: Annotated[str, Form()],
    gateway_model_id: Annotated[str, Form()], lifecycle_status: Annotated[str, Form()],
    change_reason: Annotated[str, Form()], gateway_location_building_id: Annotated[str, Form()] = "",
    gateway_location_floor_id: Annotated[str, Form()] = "", gateway_location_space_id: Annotated[str, Form()] = "",
) -> Response:
    user = require_authenticated_portal_user(request)
    gateway = await _accessible_gateway_or_none(request, gateway_id)
    if gateway is None:
        return RedirectResponse("/forbidden", status_code=303)
    submitted = {"gateway_name": gateway_name, "gateway_model_id": gateway_model_id,
                 "lifecycle_status": lifecycle_status, "change_reason": change_reason,
                 "building_id": gateway_location_building_id, "floor_id": gateway_location_floor_id,
                 "space_id": gateway_location_space_id}
    catalog = await _gateway_form_catalog(request, str(gateway["site_id"]))
    try:
        validated = validate_gateway_workspace_update(
            gateway_name=gateway_name, gateway_model_id=gateway_model_id, lifecycle_status=lifecycle_status,
            building_id=gateway_location_building_id, floor_id=gateway_location_floor_id,
            space_id=gateway_location_space_id, change_reason=change_reason)
        await update_gateway_workspace(portal_user_id=user.portal_user_id, gateway_id=str(gateway_id), **validated)
    except GatewayManagementValidationError as exc:
        return templates.TemplateResponse(request=request, name="gateway_edit.html", context={
            "environment": settings.app_env, "page_title": f"Edit {gateway['gateway_name']}",
            "active_navigation_key": "gateways", "gateway": gateway, "form_data": submitted,
            "error": str(exc), **catalog}, status_code=400)
    except DatabaseError as exc:
        return templates.TemplateResponse(request=request, name="gateway_edit.html", context={
            "environment": settings.app_env, "page_title": f"Edit {gateway['gateway_name']}",
            "active_navigation_key": "gateways", "gateway": gateway, "form_data": submitted,
            "error": user_facing_database_error(exc, fallback="The database rejected the gateway update."), **catalog}, status_code=409)
    return RedirectResponse(f"/administration/gateways/{gateway_id}", status_code=303)


async def render_organization_administration(
    request: Request,
    *,
    form_data: dict | None = None,
    result: dict | None = None,
    error: str | None = None,
    status_code: int = 200,
    chooser_mode: bool = False,
    return_to: str = "/administration/organizations",
) -> HTMLResponse:
    """Render the organization administration and context-selection page."""

    user = require_authenticated_portal_user(request)

    organizations = (
        await list_organizations_with_grafana_status()
    )

    can_retry_grafana = has_permission(
        user,
        PortalPermission.ORGANIZATION_MANAGE,
    )

    active_context = get_administration_context(request)
    context_error = request.query_params.get("context_error") == "1"

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
            "can_create_organization": can_retry_grafana,
            "show_grafana_internal_details": can_retry_grafana,
            "organizations": organizations,
            "active_organization_id": (
                active_context.active_organization_id
            ),
            "context_error": context_error,
            "lifecycle_statuses": (
                "DRAFT",
                "ACTIVE",
                "SUSPENDED",
                "DECOMMISSIONED",
            ),
            "active_navigation_key": "organizations",
            "chooser_mode": chooser_mode,
            "return_to": return_to,
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
    mode: str = "manage",
    return_to: str = "/administration/organizations",
) -> HTMLResponse:
    """Display organizations for viewing or context selection."""

    require_authenticated_portal_user(request)

    return await render_organization_administration(
        request,
        chooser_mode=mode == "choose",
        return_to=return_to,
    )


@app.get(
    "/administration/organizations/new",
    response_class=HTMLResponse,
    include_in_schema=False,
)
async def create_organization_page(request: Request) -> HTMLResponse:
    user = require_authenticated_portal_user(request)
    if not has_permission(user, PortalPermission.ORGANIZATION_MANAGE):
        return RedirectResponse(url="/forbidden", status_code=303)
    return templates.TemplateResponse(
        request=request,
        name="organization_create.html",
        context={
            "environment": settings.app_env,
            "form_data": {
                "organization_timezone": "Asia/Kolkata",
                "organization_lifecycle_status": "ACTIVE",
            },
            "lifecycle_statuses": ("DRAFT", "ACTIVE", "SUSPENDED", "DECOMMISSIONED"),
            "active_navigation_key": "organizations",
        },
    )


@app.get(
    "/administration/organizations/{organization_id}",
    response_class=HTMLResponse,
    include_in_schema=False,
)
async def organization_detail_administration(
    request: Request,
    organization_id: UUID,
) -> HTMLResponse:
    user = require_authenticated_portal_user(request)
    try:
        organization = await get_organization_workspace(
            actor_portal_user_id=user.portal_user_id,
            organization_id=str(organization_id),
        )
    except DatabaseError as exc:
        return await render_organization_administration(
            request,
            error=user_facing_database_error(
                exc,
                fallback="Organization details are temporarily unavailable.",
            ),
            status_code=503,
        )
    if organization is None:
        return RedirectResponse(url="/administration/organizations?context_error=1", status_code=303)

    provisioning_rows = await list_organizations_with_grafana_status()
    provisioning = next(
        (row for row in provisioning_rows if str(row.get("organization_id")) == str(organization_id)),
        {},
    )
    organization = {**organization, **{
        key: provisioning.get(key)
        for key in (
            "provisioning_status", "grafana_org_id", "attempt_count",
            "last_attempt_at", "provisioned_at", "last_error",
        )
        if key in provisioning
    }}
    can_manage = has_permission(user, PortalPermission.ORGANIZATION_MANAGE)
    return templates.TemplateResponse(
        request=request,
        name="organization_detail.html",
        context={
            "environment": settings.app_env,
            "organization": organization,
            "can_edit": can_manage,
            "can_retry_grafana": can_manage,
            "show_grafana_internal_details": can_manage,
            "active_navigation_key": "organizations",
        },
    )


@app.get(
    "/administration/organizations/{organization_id}/edit",
    response_class=HTMLResponse,
    include_in_schema=False,
)
async def edit_organization_page(request: Request, organization_id: UUID) -> HTMLResponse:
    user = require_authenticated_portal_user(request)
    if not has_permission(user, PortalPermission.ORGANIZATION_MANAGE):
        return RedirectResponse(url="/forbidden", status_code=303)
    try:
        organization = await get_organization_workspace(
            actor_portal_user_id=user.portal_user_id,
            organization_id=str(organization_id),
        )
    except DatabaseError as exc:
        return await render_organization_administration(
            request,
            error=user_facing_database_error(
                exc,
                fallback="Organization settings are temporarily unavailable.",
            ),
            status_code=503,
        )
    if organization is None:
        return RedirectResponse(url="/administration/organizations?context_error=1", status_code=303)
    return templates.TemplateResponse(
        request=request,
        name="organization_edit.html",
        context={
            "environment": settings.app_env,
            "organization": organization,
            "form_data": {},
            "lifecycle_statuses": ("DRAFT", "ACTIVE", "SUSPENDED", "DECOMMISSIONED"),
            "active_navigation_key": "organizations",
        },
    )


@app.post(
    "/administration/organizations/{organization_id}/edit",
    response_class=HTMLResponse,
    include_in_schema=False,
)
async def edit_organization_submit(
    request: Request,
    organization_id: UUID,
    organization_name: Annotated[str, Form()],
    legal_name: Annotated[str, Form()] = "",
    timezone: Annotated[str, Form()] = "Asia/Kolkata",
    locale: Annotated[str, Form()] = "en-US",
    lifecycle_status: Annotated[str, Form()] = "ACTIVE",
    contact_name: Annotated[str, Form()] = "",
    contact_email: Annotated[str, Form()] = "",
    contact_phone: Annotated[str, Form()] = "",
    address_line1: Annotated[str, Form()] = "",
    address_line2: Annotated[str, Form()] = "",
    city: Annotated[str, Form()] = "",
    region: Annotated[str, Form()] = "",
    postal_code: Annotated[str, Form()] = "",
    country: Annotated[str, Form()] = "",
    notes: Annotated[str, Form()] = "",
) -> Response:
    user = require_authenticated_portal_user(request)
    submitted = dict(organization_name=organization_name, legal_name=legal_name, timezone=timezone, locale=locale, lifecycle_status=lifecycle_status, contact_name=contact_name, contact_email=contact_email, contact_phone=contact_phone, address_line1=address_line1, address_line2=address_line2, city=city, region=region, postal_code=postal_code, country=country, notes=notes)
    try:
        await update_organization_workspace(
            actor_portal_user_id=user.portal_user_id,
            organization_id=str(organization_id),
            name=organization_name,
            legal_name=legal_name,
            timezone=timezone,
            locale=locale,
            lifecycle_status=lifecycle_status,
            primary_contact={"name": contact_name.strip(), "email": contact_email.strip(), "phone": contact_phone.strip()},
            address={"line1": address_line1.strip(), "line2": address_line2.strip(), "city": city.strip(), "region": region.strip(), "postal_code": postal_code.strip(), "country": country.strip()},
            notes=notes,
        )
    except DatabaseError as exc:
        organization = await get_organization_workspace(actor_portal_user_id=user.portal_user_id, organization_id=str(organization_id))
        return templates.TemplateResponse(request=request, name="organization_edit.html", context={"environment": settings.app_env, "organization": organization, "form_data": submitted, "error": user_facing_database_error(exc, fallback="The database rejected the organization update."), "lifecycle_statuses": ("DRAFT", "ACTIVE", "SUSPENDED", "DECOMMISSIONED"), "active_navigation_key": "organizations"}, status_code=409)
    return RedirectResponse(url=f"/administration/organizations/{organization_id}", status_code=303)


@app.post(
    "/administration/organizations",
    response_class=HTMLResponse,
    include_in_schema=False,
)
async def create_organization_administration(
    request: Request,
    organization_name: Annotated[str, Form()],
    organization_code: Annotated[str, Form()] = "",
    organization_timezone: Annotated[str, Form()] = "Asia/Kolkata",
    organization_lifecycle_status: Annotated[str, Form()] = "ACTIVE",
    legal_name: Annotated[str, Form()] = "",
    locale: Annotated[str, Form()] = "en-US",
    contact_name: Annotated[str, Form()] = "",
    contact_email: Annotated[str, Form()] = "",
    contact_phone: Annotated[str, Form()] = "",
    address_line1: Annotated[str, Form()] = "",
    address_line2: Annotated[str, Form()] = "",
    city: Annotated[str, Form()] = "",
    region: Annotated[str, Form()] = "",
    postal_code: Annotated[str, Form()] = "",
    country: Annotated[str, Form()] = "",
    notes: Annotated[str, Form()] = "",
) -> Response:
    user = require_authenticated_portal_user(request)
    if not has_permission(user, PortalPermission.ORGANIZATION_MANAGE):
        return RedirectResponse(url="/forbidden", status_code=303)

    generated_code = generate_entity_code(organization_name)
    submitted_form_data = {
        "organization_name": organization_name,
        "organization_code": generated_code,
        "organization_timezone": organization_timezone,
        "organization_lifecycle_status": organization_lifecycle_status,
        "legal_name": legal_name,
        "locale": locale,
        "contact_name": contact_name,
        "contact_email": contact_email,
        "contact_phone": contact_phone,
        "address_line1": address_line1,
        "address_line2": address_line2,
        "city": city,
        "region": region,
        "postal_code": postal_code,
        "country": country,
        "notes": notes,
    }
    try:
        extended_profile_requested = any(
            value.strip()
            for value in (
                legal_name, contact_name, contact_email, contact_phone,
                address_line1, address_line2, city, region, postal_code,
                country, notes,
            )
        ) or locale.strip() not in ("", "en-US")

        if extended_profile_requested:
            result = await create_organization_workspace(
                actor_portal_user_id=user.portal_user_id,
                requested_by=user.username,
                name=organization_name,
                code=generated_code,
                legal_name=legal_name,
                timezone=organization_timezone,
                locale=locale,
                lifecycle_status=organization_lifecycle_status,
                primary_contact={"name": contact_name.strip(), "email": contact_email.strip(), "phone": contact_phone.strip()},
                address={"line1": address_line1.strip(), "line2": address_line2.strip(), "city": city.strip(), "region": region.strip(), "postal_code": postal_code.strip(), "country": country.strip()},
                notes=notes,
            )
        else:
            result = await create_organization(
                name=organization_name,
                code=generated_code,
                timezone=organization_timezone,
                lifecycle_status=organization_lifecycle_status,
                requested_by=user.username,
            )
        try:
            await provision_grafana_for_organization(
                organization_id=result["organization_id"],
                organization_name=result["organization_name"],
            )
        except (DatabaseError, GrafanaApiError):
            pass
    except DatabaseError as exc:
        return templates.TemplateResponse(
            request=request,
            name="organization_create.html",
            context={
                "environment": settings.app_env,
                "form_data": submitted_form_data,
                "error": user_facing_database_error(exc, fallback="The database rejected the organization request."),
                "lifecycle_statuses": ("DRAFT", "ACTIVE", "SUSPENDED", "DECOMMISSIONED"),
                "active_navigation_key": "organizations",
            },
            status_code=409,
        )
    return RedirectResponse(url=f"/administration/organizations/{result['organization_id']}", status_code=303)


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
        await provision_grafana_for_organization(
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

    return RedirectResponse(
        url=f"/administration/organizations/{organization_id}",
        status_code=303,
    )



@app.post(
    "/administration/organizations/{organization_id}/grafana/reconcile",
    response_class=HTMLResponse,
    include_in_schema=False,
)
async def reconcile_organization_grafana_tenant(
    request: Request,
    organization_id: UUID,
) -> HTMLResponse:
    """Detect and safely repair one Grafana tenant mapping."""
    user = require_authenticated_portal_user(request)
    try:
        result = await reconcile_grafana_tenant(
            portal_user_id=user.portal_user_id,
            organization_id=str(organization_id),
        )
    except (DatabaseError, GrafanaApiError) as exc:
        return await render_organization_administration(
            request,
            error=str(exc),
            status_code=409,
        )
    return await render_organization_administration(
        request,
        result={"organization_id": str(organization_id), "grafana_reconciliation": result},
        status_code=200 if result.get("success") else 409,
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

    PostgreSQL enforces ownership and GLOBAL-scope override. This helper keeps
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
            "lifecycle_statuses": (
                "DRAFT",
                "ACTIVE",
                "SUSPENDED",
                "DECOMMISSIONED",
            ),
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
            "organization_timezone": (
                organization.get("timezone")
                or "Asia/Kolkata"
            ),
            "organization_lifecycle_status": (
                organization.get("lifecycle_status")
                or "ACTIVE"
            ),
            "legal_name": (
                organization.get("legal_name") or ""
            ),
            "locale": (
                organization.get("locale") or "en-US"
            ),
            "contact_name": (
                (organization.get("primary_contact") or {}).get("name") or ""
            ),
            "contact_email": (
                (organization.get("primary_contact") or {}).get("email") or ""
            ),
            "contact_phone": (
                (organization.get("primary_contact") or {}).get("phone") or ""
            ),
            "address_line1": (
                (organization.get("address") or {}).get("line1") or ""
            ),
            "address_line2": (
                (organization.get("address") or {}).get("line2") or ""
            ),
            "city": (
                (organization.get("address") or {}).get("city") or ""
            ),
            "region": (
                (organization.get("address") or {}).get("region") or ""
            ),
            "postal_code": (
                (organization.get("address") or {}).get("postal_code") or ""
            ),
            "country": (
                (organization.get("address") or {}).get("country") or ""
            ),
            "notes": (
                organization.get("notes") or ""
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
    organization_timezone: Annotated[str, Form()] = "Asia/Kolkata",
    organization_lifecycle_status: Annotated[str, Form()] = "ACTIVE",
    legal_name: Annotated[str, Form()] = "",
    locale: Annotated[str, Form()] = "en-US",
    contact_name: Annotated[str, Form()] = "",
    contact_email: Annotated[str, Form()] = "",
    contact_phone: Annotated[str, Form()] = "",
    address_line1: Annotated[str, Form()] = "",
    address_line2: Annotated[str, Form()] = "",
    city: Annotated[str, Form()] = "",
    region: Annotated[str, Form()] = "",
    postal_code: Annotated[str, Form()] = "",
    country: Annotated[str, Form()] = "",
    notes: Annotated[str, Form()] = "",
) -> HTMLResponse:
    """Validate and save the Organization wizard step."""

    submitted_form_data = {
        "organization_mode": organization_mode,
        "existing_organization_id": existing_organization_id,
        "organization_name": organization_name,
        "organization_code": organization_code,
        "organization_description": organization_description,
        "organization_timezone": organization_timezone,
        "organization_lifecycle_status": organization_lifecycle_status,
        "legal_name": legal_name,
        "locale": locale,
        "contact_name": contact_name,
        "contact_email": contact_email,
        "contact_phone": contact_phone,
        "address_line1": address_line1,
        "address_line2": address_line2,
        "city": city,
        "region": region,
        "postal_code": postal_code,
        "country": country,
        "notes": notes,
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

    if organization_mode.strip().upper() == "CREATE_NEW":
        organization_code = generate_entity_code(
            organization_name
        )

        submitted_form_data["organization_code"] = (
            organization_code
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
                organization_timezone=organization_timezone,
                organization_lifecycle_status=(
                    organization_lifecycle_status
                ),
                legal_name=legal_name,
                locale=locale,
                contact_name=contact_name,
                contact_email=contact_email,
                contact_phone=contact_phone,
                address_line1=address_line1,
                address_line2=address_line2,
                city=city,
                region=region,
                postal_code=postal_code,
                country=country,
                notes=notes,
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


async def build_onboarding_navigation_labels(
    request: Request,
    draft_record: dict,
) -> dict[str, str]:
    """Build optional display labels for onboarding navigation.

    Breadcrumb labels are presentation enrichment. Failure to resolve an
    existing entity must never prevent the onboarding step itself from
    rendering.
    """

    payload = draft_record.get("payload") or {}
    labels: dict[str, str] = {}
    lookup_cache: dict[str, list[dict]] = {}

    async def load_rows(
        cache_key: str,
        loader,
    ) -> list[dict]:
        if cache_key in lookup_cache:
            return lookup_cache[cache_key]

        try:
            rows = await loader()
        except (
            DatabaseError,
            RuntimeError,
            AdministrationContextError,
        ):
            rows = []

        lookup_cache[cache_key] = rows
        return rows

    def find_by_id(
        rows: list[dict],
        entity_id,
        *id_fields: str,
    ) -> dict | None:
        if not entity_id:
            return None

        for row in rows:
            for field in id_fields:
                if (
                    row.get(field) is not None
                    and str(row.get(field)) == str(entity_id)
                ):
                    return row

        return None

    organization = payload.get("organization") or {}
    organization_mode = (
        organization.get("mode") or ""
    ).upper()

    if organization_mode == "CREATE_NEW":
        labels["organization"] = (
            organization.get("name") or ""
        )
    else:
        organization_id = organization.get(
            "existing_organization_id"
        )

        if organization_id:
            organizations = await load_rows(
                "organizations",
                list_organizations,
            )

            selected = find_by_id(
                organizations,
                organization_id,
                "id",
                "organization_id",
            )

            if selected:
                labels["organization"] = (
                    selected.get("organization_name")
                    or selected.get("name")
                    or ""
                )

    site = payload.get("site") or {}
    site_mode = (site.get("mode") or "").upper()

    if site_mode == "CREATE_NEW":
        labels["site"] = site.get("name") or ""
    else:
        site_id = site.get("existing_site_id")

        if site_id:
            sites = await load_rows(
                "sites",
                lambda: list_sites_for_request(request),
            )

            selected = find_by_id(
                sites,
                site_id,
                "id",
                "site_id",
            )

            if selected:
                labels["site"] = (
                    selected.get("site_name")
                    or selected.get("name")
                    or ""
                )

    location = payload.get("location") or {}
    location_mode = (
        location.get("mode") or ""
    ).upper()

    if location_mode == "CREATE_LOCATION":
        labels["location"] = (
            location.get("space_name")
            or location.get("floor_name")
            or location.get("building_name")
            or ""
        )
    elif location_mode == "SITE_ONLY":
        labels["location"] = "Site level"
    elif location_mode == "USE_EXISTING_SPACE":
        space_id = location.get("existing_space_id")

        if space_id:
            spaces = await load_rows(
                "spaces",
                list_spaces,
            )

            selected = find_by_id(
                spaces,
                space_id,
                "id",
                "space_id",
            )

            if selected:
                labels["location"] = (
                    selected.get("space_name")
                    or selected.get("location_name")
                    or selected.get("name")
                    or ""
                )

    gateway = payload.get("gateway") or {}
    gateway_mode = (
        gateway.get("mode") or ""
    ).upper()

    if gateway_mode == "CREATE_NEW":
        labels["gateway"] = gateway.get("name") or ""
    else:
        gateway_id = gateway.get(
            "existing_gateway_id"
        )

        if gateway_id:
            gateways = await load_rows(
                "gateways",
                list_gateways,
            )

            selected = find_by_id(
                gateways,
                gateway_id,
                "id",
                "gateway_id",
            )

            if selected:
                labels["gateway"] = (
                    selected.get("gateway_name")
                    or selected.get("name")
                    or ""
                )

    device = payload.get("device") or {}
    device_mode = (device.get("mode") or "").upper()

    if device_mode == "CREATE_NEW":
        labels["device"] = device.get("name") or ""
    else:
        device_id = device.get("existing_device_id")

        if device_id:
            devices = await load_rows(
                "devices",
                list_devices,
            )

            selected = find_by_id(
                devices,
                device_id,
                "id",
                "device_id",
            )

            if selected:
                labels["device"] = (
                    selected.get("device_name")
                    or selected.get("name")
                    or ""
                )

    asset = payload.get("asset") or {}
    asset_mode = (asset.get("mode") or "").upper()

    if asset_mode == "CREATE_NEW":
        labels["asset"] = asset.get("name") or ""
    else:
        asset_id = asset.get("existing_asset_id")

        if asset_id:
            assets = await load_rows(
                "assets",
                list_assets,
            )

            selected = find_by_id(
                assets,
                asset_id,
                "id",
                "asset_id",
            )

            if selected:
                labels["asset"] = (
                    selected.get("asset_name")
                    or selected.get("name")
                    or ""
                )

    return {
        key: value.strip()
        for key, value in labels.items()
        if value and value.strip()
    }


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

        all_sites = await list_sites_for_request(request)

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
            "onboarding_navigation_labels": (
                await build_onboarding_navigation_labels(
                    request, draft_record
                )
            ),
            "organization_mode": organization_mode,
            "organization_label": organization_label,
            "sites": sites,
            "form_data": form_data or {},
            "error": error,
            **await _site_sector_edit_context(
                (form_data or {}).get("sub_sector_id")
            ),
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
        "telemetry_capture_interval_seconds": str(site.get("telemetry_capture_interval_seconds") or 60),
        "sub_sector_id": site.get("sub_sector_id") or "",
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
    telemetry_capture_interval_seconds: Annotated[str, Form()] = "60",
    sub_sector_id: Annotated[str, Form()] = "",
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

    if site_mode.strip().upper() == "CREATE_NEW":
        site_code = generate_entity_code(site_name)

    submitted_form_data = {
        "site_mode": site_mode,
        "existing_site_id": existing_site_id,
        "site_name": site_name,
        "site_code": site_code,
        "site_timezone": site_timezone,
        "site_address": site_address,
        "telemetry_capture_interval_seconds": telemetry_capture_interval_seconds,
        "sub_sector_id": sub_sector_id,
    }

    try:
        site_payload = validate_site_step(
            site_mode=site_mode,
            existing_site_id=existing_site_id,
            site_name=site_name,
            site_code=site_code,
            site_timezone=site_timezone,
            site_address=site_address,
            telemetry_capture_interval_seconds=telemetry_capture_interval_seconds,
            sub_sector_id=sub_sector_id,
            organization_mode=(
                organization.get("mode") or ""
            ),
        )

        if site_payload["mode"] == "USE_EXISTING":
            all_sites = await list_sites_for_request(request)

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
        all_sites = await list_sites_for_request(request)

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
            "onboarding_navigation_labels": (
                await build_onboarding_navigation_labels(
                    request, draft_record
                )
            ),
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

    if location_mode.strip().upper() == "CREATE_LOCATION":
        building_code = generate_entity_code(building_name)
        floor_code = generate_entity_code(floor_name)
        space_code = generate_entity_code(space_name)

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
        all_sites = await list_sites_for_request(request)

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
            "onboarding_navigation_labels": (
                await build_onboarding_navigation_labels(
                    request, draft_record
                )
            ),
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
        "gateway_model_id": (
            gateway.get("gateway_model_id") or ""
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
    gateway_model_id: Annotated[str, Form()] = "",
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
        "gateway_model_id": gateway_model_id,
    }

    try:
        gateway_payload = validate_gateway_step(
            gateway_mode=gateway_mode,
            existing_gateway_id=existing_gateway_id,
            gateway_name=gateway_name,
            gateway_external_id=gateway_external_id,
            gateway_model_id=gateway_model_id,
            organization_mode=(
                organization.get("mode") or ""
            ),
            site_mode=(
                site.get("mode") or ""
            ),
        )

        if gateway_payload["mode"] == "CREATE_NEW":
            all_gateway_models = await list_gateway_models()

            if not any(
                str(model["id"]) == gateway_payload["gateway_model_id"]
                for model in all_gateway_models
            ):
                raise GatewayStepValidationError(
                    "Select a gateway model from the catalog."
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

    effective_form_data = dict(form_data or {})
    selected_existing_device_id = str(
        effective_form_data.get("existing_device_id") or ""
    )

    if (
        (effective_form_data.get("device_mode") or "").upper()
        == "USE_EXISTING"
        and selected_existing_device_id
    ):
        selected_existing_device = next(
            (
                item
                for item in devices
                if str(item["id"]) == selected_existing_device_id
            ),
            None,
        )

        if selected_existing_device:
            effective_form_data["identifier_type"] = (
                selected_existing_device.get("identifier_type") or ""
            )
            effective_form_data["identifier_value"] = (
                (
                ""
                if selected_existing_device.get("identifier_value") is None
                else str(selected_existing_device.get("identifier_value"))
            )
            )

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
            "onboarding_navigation_labels": (
                await build_onboarding_navigation_labels(
                    request, draft_record
                )
            ),
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
            "form_data": effective_form_data,
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
        "device_model_id": (
            device.get("device_model_id") or ""
        ),
        "device_protocol": (
            device.get("protocol") or "MQTT"
        ),
        "profile_code": (
            device.get("profile_code") or ""
        ),
        "firmware_version": (
            device.get("firmware_version") or ""
        ),
        "serial_number": (
            device.get("serial_number") or ""
        ),
        "operational_policy": (
            device.get("operational_policy") or "ASSET_ASSIGNED"
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
    device_model_id: Annotated[str, Form()] = "",
    device_protocol: Annotated[str, Form()] = "MQTT",
    profile_code: Annotated[str, Form()] = "",
    firmware_version: Annotated[str, Form()] = "",
    identifier_type: Annotated[str, Form()] = "",
    identifier_value: Annotated[str, Form()] = "",
    serial_number: Annotated[str, Form()] = "",
    operational_policy: Annotated[str, Form()] = "ASSET_ASSIGNED",
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
        "device_category_id": device_category_id,
        "device_model_id": device_model_id,
        "device_protocol": device_protocol,
        "profile_code": profile_code,
        "firmware_version": firmware_version,
        "identifier_type": identifier_type,
        "identifier_value": identifier_value,
        "serial_number": serial_number,
        "operational_policy": operational_policy,
    }

    try:
        device_payload = validate_device_step(
            device_mode=device_mode,
            existing_device_id=existing_device_id,
            device_name=device_name,
            device_external_id=device_external_id,
            device_category_id=device_category_id,
            device_model_id=device_model_id,
            device_protocol=device_protocol,
            profile_code=profile_code,
            firmware_version=firmware_version,
            identifier_type=identifier_type,
            identifier_value=identifier_value,
            gateway_mode=gateway.get("mode") or "",
            serial_number=serial_number,
            operational_policy=operational_policy,
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

            stored_identifier_type = (
                selected_device.get("identifier_type") or ""
            ).strip().upper()
            stored_identifier_value = (
                (
                ""
                if selected_device.get("identifier_value") is None
                else str(selected_device.get("identifier_value"))
            )
            ).strip()

            if (
                not stored_identifier_type
                or stored_identifier_value is None
                or str(stored_identifier_value).strip() == ""
            ):
                raise DeviceStepValidationError(
                    "The selected device does not have a registered "
                    "identifier."
                )

            device_payload["identifier"] = {
                "type": stored_identifier_type,
                "value": stored_identifier_value,
            }
            submitted_form_data["identifier_type"] = (
                stored_identifier_type
            )
            submitted_form_data["identifier_value"] = (
                stored_identifier_value
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

            device_models = await list_device_models()
            selected_model = next(
                (
                    model
                    for model in device_models
                    if str(model["id"])
                    == device_payload["device_model_id"]
                ),
                None,
            )

            if selected_model is None:
                raise DeviceStepValidationError(
                    "Select a device model from the catalog."
                )

            if (
                str(selected_model["device_category_id"])
                != device_payload["device_category_id"]
            ):
                raise DeviceStepValidationError(
                    "The selected device model does not belong to the "
                    "chosen device category."
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
            "onboarding_navigation_labels": (
                await build_onboarding_navigation_labels(
                    request, draft_record
                )
            ),
            "device_label": device_label,
            "device_category_name": (
                device_category_name
            ),
            "relationships": relationships,
            "allow_existing_asset": bool(assets),
            "assets": assets,
            "asset_types": await list_asset_types(site_id),
            "metering_requirements": status_options(
                "METERING_REQUIREMENT"
            ),
            "asset_lifecycle_statuses": (
                "DRAFT",
                "COMMISSIONING",
                "ACTIVE",
                "INACTIVE",
                "DECOMMISSIONED",
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
        "lifecycle_status": (
            asset.get("lifecycle_status") or "ACTIVE"
        ),
        "parent_asset_id": (
            asset.get("parent_asset_id") or ""
        ),
    }

    try:
        return await render_asset_step(
            request,
            draft_token=draft_token,
            draft_record=draft_record,
            form_data=form_data,
        )
    except AssetStepValidationError:
        return RedirectResponse(
            url=(
                "/onboarding/device"
                f"?draft={draft_token}"
            ),
            status_code=303,
        )


@app.post("/onboarding/validate-field")
async def validate_onboarding_field_endpoint(
    request: Request,
) -> JSONResponse:
    """Validate one onboarding field before the wizard can advance."""
    actor = require_authenticated_portal_user(request)

    try:
        body = await request.json()
    except (ValueError, TypeError):
        return JSONResponse(
            {
                "valid": False,
                "code": "INVALID_REQUEST",
                "message": "The validation request is invalid.",
            },
            status_code=400,
        )

    step = str(body.get("step") or "").strip().lower()
    field = str(body.get("field") or "").strip()
    value = body.get("value")
    draft = str(body.get("draft") or "").strip() or None
    form_data = body.get("form") or {}

    if step not in {
        "organization", "site", "location", "gateway", "device", "asset"
    } or not field or not isinstance(form_data, dict):
        return JSONResponse(
            {
                "valid": False,
                "field": field,
                "code": "INVALID_REQUEST",
                "message": "The validation request is incomplete.",
            },
            status_code=400,
        )

    if draft:
        try:
            draft_token = UUID(draft)
        except ValueError:
            return JSONResponse(
                {
                    "valid": False,
                    "field": field,
                    "code": "INVALID_DRAFT",
                    "message": "The onboarding draft is invalid.",
                },
                status_code=400,
            )
        if await get_visible_onboarding_draft(request, draft_token) is None:
            return JSONResponse(
                {
                    "valid": False,
                    "field": field,
                    "code": "DRAFT_NOT_FOUND",
                    "message": "The onboarding draft is no longer available.",
                },
                status_code=404,
            )

    try:
        result = await validate_onboarding_field(
            actor_portal_user_id=actor.portal_user_id,
            draft_token=draft,
            step=step,
            field=field,
            value=None if value is None else str(value),
            form_data=form_data,
        )
    except DatabaseError:
        return JSONResponse(
            {
                "valid": False,
                "field": field,
                "code": "VALIDATION_UNAVAILABLE",
                "message": "Validation is temporarily unavailable.",
            },
            status_code=503,
        )

    return JSONResponse(result, status_code=200 if result.get("valid") else 409)


@app.get("/onboarding/asset/relationship-validation")
async def validate_onboarding_asset_relationship(
    request: Request,
    draft: str,
    asset_id: str,
    relationship_type: str,
) -> JSONResponse:
    """Return immediate, access-controlled relationship validation."""

    try:
        draft_token = UUID(draft)
        parsed_asset_id = UUID(asset_id)
    except ValueError:
        return JSONResponse(
            {
                "valid": False,
                "code": "INVALID_SELECTION",
                "message": "Select a valid asset and relationship.",
            },
            status_code=400,
        )

    draft_record = await get_visible_onboarding_draft(
        request,
        draft_token,
    )
    if draft_record is None:
        return JSONResponse(
            {
                "valid": False,
                "code": "DRAFT_NOT_FOUND",
                "message": "The onboarding draft is no longer available.",
            },
            status_code=404,
        )

    actor = require_authenticated_portal_user(request)
    device = draft_record["payload"].get("device", {})
    device_id = (
        device.get("existing_device_id")
        if (device.get("mode") or "").upper() == "USE_EXISTING"
        else None
    )

    try:
        result = await validate_asset_relationship_availability(
            actor_portal_user_id=actor.portal_user_id,
            asset_id=str(parsed_asset_id),
            relationship_type=relationship_type,
            device_id=device_id,
        )
    except DatabaseError:
        return JSONResponse(
            {
                "valid": False,
                "code": "VALIDATION_UNAVAILABLE",
                "message": "Relationship validation is temporarily unavailable.",
            },
            status_code=503,
        )

    return JSONResponse(result, status_code=200 if result.get("valid") else 409)


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
    asset_external_id: Annotated[str, Form()] = "",
    asset_type_id: Annotated[str, Form()] = "",
    metering_requirement: Annotated[str, Form()] = "",
    relationship_type: Annotated[str, Form()] = "",
    operational_notes: Annotated[str, Form()] = "",
    lifecycle_status: Annotated[str, Form()] = "ACTIVE",
    parent_asset_id: Annotated[str, Form()] = "",
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
        "lifecycle_status": lifecycle_status,
        "parent_asset_id": parent_asset_id,
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
            asset_external_id=asset_external_id,
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
            lifecycle_status=lifecycle_status,
            parent_asset_id=parent_asset_id,
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

        actor = require_authenticated_portal_user(request)
        device = draft_record["payload"].get("device", {})

        existing_device_id = (
            device.get("existing_device_id")
            if (device.get("mode") or "").upper() == "USE_EXISTING"
            else None
        )

        validation_asset_id = (
            asset_payload["existing_asset_id"]
            if asset_payload["mode"] == "USE_EXISTING"
            else None
        )

        if validation_asset_id is not None or existing_device_id is not None:
            validation = await validate_asset_relationship_availability(
                actor_portal_user_id=actor.portal_user_id,
                asset_id=validation_asset_id,
                relationship_type=asset_payload["relationship_type"],
                device_id=existing_device_id,
            )

            if not validation.get("valid"):
                raise AssetStepValidationError(
                    validation.get("message")
                    or "Choose a valid device relationship."
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
    request: Request,
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
        sites = await list_sites_for_request(request)
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
        "onboarding_navigation_labels": (
            await build_onboarding_navigation_labels(
                request, draft_record
            )
        ),
        "submission_result": submission_result,
        "error": error,
    }

    if submission_result is None:
        context.update(
            await build_review_context(
                request,
                draft_record,
            )
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

    organization_payload = (
        draft_record.get("payload", {}).get("organization", {})
    )

    if organization_payload.get("mode") == "CREATE_NEW":
        try:
            await provision_grafana_for_organization(
                organization_id=str(result["organization_id"]),
                organization_name=organization_payload["name"],
            )
        except (DatabaseError, GrafanaApiError):
            # EMS onboarding has already committed successfully.
            # Grafana provisioning failure must not roll it back.
            pass

    return RedirectResponse(
        url=(
            "/onboarding/result"
            f"?draft={parsed_draft_token}"
        ),
        status_code=303,
    )


@app.websocket("/api/live/assets/{asset_id}/ws")
async def proxy_asset_live_websocket(websocket: WebSocket, asset_id: UUID) -> None:
    """Same-origin proxy to the live-telemetry service's portal-session
    WebSocket (live_main.py::live_asset_websocket) -- the customer browser
    only ever talks to this admin-portal origin, never to live-telemetry,
    MQTT, or any internal broker directly. Chosen over exposing
    live-telemetry on its own public port because no reverse proxy exists
    yet (docs/04-architecture/deployment-architecture.md: "Reverse proxy /
    public TLS is explicitly planned, not implemented") -- this reuses the
    admin-portal origin/port the Web App is already served from instead of
    waiting on that infrastructure.

    PortalAuthenticationMiddleware does not run for WebSocket scopes (see
    its own `if scope["type"] != "http": ...` passthrough) -- this route
    performs its own identity/authorization check first, the same
    fail-closed "second gate" pattern _require_portal_user already applies
    to every /api/v1 HTTP route (analytics_api.py), using the exact same
    deserialize_authenticated_user / portal_user_can_access_asset this
    application already relies on elsewhere. This does not replace
    live_asset_websocket's own check -- the browser's session cookie is
    forwarded upstream unchanged, so live-telemetry independently
    re-derives and re-checks the same identity and authorization itself,
    exactly as it already does for any other caller. Rejecting here first
    only avoids opening a wasted upstream connection for traffic that was
    never going to be allowed.

    No new telemetry data path: this never reads MQTT, the database, or
    admin.get_portal_asset_live_state directly -- it only relays whatever
    live_asset_websocket already sends.
    """

    identity = deserialize_authenticated_user(
        websocket.scope.get("session", {}).get(SESSION_IDENTITY_KEY)
    )
    if identity is None:
        await websocket.close(code=4401)
        return

    if not await portal_user_can_access_asset(identity.portal_user_id, asset_id):
        await websocket.close(code=4404)
        return

    cookie_header = websocket.headers.get("cookie")
    upstream_url = f"{settings.live_telemetry_ws_base_url}/api/live/assets/{asset_id}/ws"

    try:
        async with websockets.connect(
            upstream_url,
            additional_headers={"Cookie": cookie_header} if cookie_header else None,
            open_timeout=5,
        ) as upstream:
            await websocket.accept()
            await _relay_asset_live_websocket(websocket, upstream)
    except (OSError, InvalidHandshake, WebSocketException, TimeoutError):
        # The upstream live-telemetry service is unreachable or refused the
        # connection (e.g. mid-deploy). 1013 = "Try Again Later" (RFC 6455
        # IANA registry) -- the same code live_main.py's own
        # fetch_grafana_asset_state_with_retry path uses for its equivalent
        # transient-failure case, so a reconnecting client sees a clean
        # close it can retry rather than a raw connection error.
        with contextlib.suppress(Exception):
            await websocket.close(code=1013)


async def _relay_asset_live_websocket(client: WebSocket, upstream) -> None:
    """Pump frames both directions until either side closes.

    upstream (live_asset_websocket) only reads client frames to detect
    disconnect -- it never acts on their content -- so forwarding the
    browser's frames upstream unexamined is harmless and keeps this a
    transparent relay rather than a second place that interprets the
    telemetry protocol. Any unexpected frame/content on either side ends
    that pump gracefully rather than crashing the connection or the
    process.
    """

    async def pump_upstream_to_client() -> None:
        try:
            async for message in upstream:
                await client.send_text(
                    message if isinstance(message, str) else message.decode("utf-8", "replace")
                )
        except (WebSocketException, RuntimeError):
            # WebSocketException (e.g. ConnectionClosed): live-telemetry
            # ended the stream. RuntimeError: the browser side is already
            # closed, so client.send_text() refuses -- Starlette's own
            # signal for that, not a WebSocketDisconnect (that's only
            # raised by receive_*()).
            pass

    async def pump_client_to_upstream() -> None:
        try:
            while True:
                message = await client.receive_text()
                await upstream.send(message)
        except (WebSocketDisconnect, WebSocketException):
            # WebSocketDisconnect: the browser closed. WebSocketException
            # (e.g. ConnectionClosed): live-telemetry already ended the
            # stream, so there is nothing left to forward to.
            pass

    tasks = [
        asyncio.create_task(pump_upstream_to_client()),
        asyncio.create_task(pump_client_to_upstream()),
    ]
    try:
        await asyncio.wait(tasks, return_when=asyncio.FIRST_COMPLETED)
    finally:
        for task in tasks:
            task.cancel()
        for task in tasks:
            with contextlib.suppress(Exception):
                await task
        with contextlib.suppress(Exception):
            await client.close()
        with contextlib.suppress(Exception):
            await upstream.close()


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
    pages, protected portal pages, or session-related responses.
    """

    response = await call_next(request)

    path = request.url.path
    content_type = response.headers.get("content-type", "")
    is_html_response = content_type.startswith("text/html")

    is_sensitive_path = (
        path in {
            "/login",
            "/logout",
            "/forbidden",
        }
        or path.startswith("/context/")
        or path == "/administration"
        or path.startswith("/administration/")
        or path == "/onboarding"
        or path.startswith("/onboarding/")
    )

    if is_sensitive_path and (
        is_html_response
        or 300 <= response.status_code < 400
    ):
        response.headers["Cache-Control"] = (
            "no-store, no-cache, must-revalidate, private, max-age=0"
        )
        response.headers["Pragma"] = "no-cache"
        response.headers["Expires"] = "0"

    return response
