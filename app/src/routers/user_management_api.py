"""User management JSON API for the EMS Web App's Admin -> Users screen.

Mounted ONLY in the Administration App (src.main), never in the customer API
(src.customer_main, ADR-023) and never under the read-only /api/v1 Analytics
surface (ADR-007). It is the Administration App's own user management -- the
same admin.portal_users identities, the same ADMIN / OPERATOR / VIEWER roles
(src.auth.authorization) and the same controlled, audited database functions
the server-rendered /administration/users pages use (admin.*_managed_portal_user*,
migration 315) -- exposed as JSON for the SPA:

  GET    /api/admin/v1/users/options          roles, scopes, organizations, sites, password policy
  GET    /api/admin/v1/users                  users the actor may manage
  GET    /api/admin/v1/users/{id}             one of them (404 outside the actor's scope)
  POST   /api/admin/v1/users                  create
  PATCH  /api/admin/v1/users/{id}             details / role / access / status, one transaction
  POST   /api/admin/v1/users/{id}/password    administrator password reset
  POST   /api/admin/v1/me/password            change one's own password (current password required)

Security model:
- Authentication: the Administration App's signed ems_admin_session cookie
  (PortalAuthenticationMiddleware). No other session or token.
- Authorization: PortalAuthenticationMiddleware requires user.manage for every
  /api/admin/v1/users* and /api/admin/v1/me/* request; this module re-checks it.
  The database functions are authoritative: they re-derive the actor's role and
  scope from portal_user_id, refuse targets outside it
  (admin.portal_user_scope_contains_user), refuse self role / scope / status
  changes and any scope wider than the actor's own, and audit every change in
  admin.portal_user_audit.
- CSRF: every state-changing request must carry an Origin naming this host and
  a JSON body (a cross-site HTML form can do neither).
- No password, hash or session material is ever returned, except a
  server-generated temporary password, exactly once, in the response that
  created it (Cache-Control: no-store).
"""

from __future__ import annotations

from datetime import datetime
from typing import Any
from uuid import UUID

from fastapi import APIRouter, HTTPException, Request, Response
from psycopg.errors import DatabaseError
from pydantic import BaseModel, ConfigDict, Field

from src.auth.access_scope import normalize_portal_access_scope_submission
from src.auth.authorization import (
    ROLE_PERMISSIONS,
    PortalPermission,
    PortalRole,
    assignable_portal_roles,
    has_permission,
    portal_role,
)
from src.auth.customer_session import same_origin
from src.auth.dependencies import get_authenticated_portal_user
from src.auth.models import AuthenticatedPortalUser
from src.auth.repository import (
    get_portal_user_for_authentication,
    record_portal_login_failure,
)
from src.auth.security import hash_portal_password, verify_portal_password
from src.onboarding.repository import list_accessible_sites, list_organizations
from src.user_account_policy import (
    AccountPolicyError,
    generate_temporary_password,
    normalize_display_name,
    normalize_email,
    normalize_username,
    password_policy_description,
    validate_password,
)
from src.user_management_service import (
    apply_managed_user_changes,
    change_own_password,
    create_managed_user_with_status,
    list_manageable_users,
    reset_managed_user_password,
)

API_PREFIX = "/api/admin/v1"

router = APIRouter(prefix=API_PREFIX, tags=["user-management"], include_in_schema=False)

# Mirrors config.portal_role_definitions (display_name, description) -- the
# role CODES are the database's CHECK-constrained set; a DB test asserts the
# two agree.
ROLE_LABELS: dict[PortalRole, tuple[str, str]] = {
    PortalRole.ADMIN: (
        "Administrator",
        "Performs administrative operations permitted by the assigned access scope.",
    ),
    PortalRole.OPERATOR: (
        "Operator",
        "Performs operational, onboarding, commissioning, alert and analytical activities within the assigned access scope.",
    ),
    PortalRole.VIEWER: (
        "Viewer",
        "Read-only dashboard and report access within the assigned access scope.",
    ),
}

SCOPE_LABELS: dict[str, str] = {
    "GLOBAL": "All organizations (WiseWatts staff)",
    "ORGANIZATION": "Whole organization",
    "SELECTED_SITES": "Selected sites",
}

# Which scopes an administrator may grant: never wider than their own.
_GRANTABLE_SCOPES: dict[str, tuple[str, ...]] = {
    "GLOBAL": ("GLOBAL", "ORGANIZATION", "SELECTED_SITES"),
    "ORGANIZATION": ("ORGANIZATION", "SELECTED_SITES"),
    "SELECTED_SITES": ("SELECTED_SITES",),
}

_NO_STORE = {"Cache-Control": "no-store"}


# ---------------------------------------------------------------------------
# Models
# ---------------------------------------------------------------------------


class _Strict(BaseModel):
    model_config = ConfigDict(extra="forbid")


class CreateUserRequest(_Strict):
    username: str
    display_name: str
    email: str
    role_code: str
    access_scope_mode: str
    organization_id: UUID | None = None
    site_ids: list[UUID] = Field(default_factory=list)
    is_active: bool = True
    # Omitted / null: the server generates a temporary password and returns it once.
    password: str | None = None


class UpdateUserRequest(_Strict):
    display_name: str | None = None
    email: str | None = None
    role_code: str | None = None
    access_scope_mode: str | None = None
    organization_id: UUID | None = None
    site_ids: list[UUID] | None = None
    is_active: bool | None = None


class PasswordResetRequest(_Strict):
    password: str | None = None


class OwnPasswordChangeRequest(_Strict):
    current_password: str
    new_password: str


class SiteRef(BaseModel):
    site_id: str
    site_name: str | None
    site_code: str | None


class ManagedUser(BaseModel):
    portal_user_id: int
    username: str
    display_name: str
    email: str | None
    role_code: str
    role_label: str
    access_scope_mode: str
    organization_id: str | None
    organization_name: str | None
    sites: list[SiteRef]
    is_active: bool
    created_at: datetime
    updated_at: datetime
    is_self: bool


class UsersResponse(BaseModel):
    users: list[ManagedUser]


class UserResponse(BaseModel):
    user: ManagedUser
    # Present only when the server generated the password in this request.
    temporary_password: str | None = None


class PasswordResetResponse(BaseModel):
    portal_user_id: int
    temporary_password: str | None = None


class RoleOption(BaseModel):
    role_code: str
    display_name: str
    description: str
    permissions: list[str]
    assignable: bool


class ScopeOption(BaseModel):
    access_scope_mode: str
    label: str


class OrganizationOption(BaseModel):
    organization_id: str
    organization_name: str
    organization_code: str


class SiteOption(BaseModel):
    site_id: str
    site_name: str
    site_code: str
    organization_id: str
    organization_name: str


class ActorSummary(BaseModel):
    portal_user_id: int
    role_code: str
    access_scope_mode: str
    organization_id: str | None


class UserOptionsResponse(BaseModel):
    actor: ActorSummary
    roles: list[RoleOption]
    scopes: list[ScopeOption]
    organizations: list[OrganizationOption]
    sites: list[SiteOption]
    password_policy: dict[str, int]


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _error(status_code: int, code: str, detail: str) -> HTTPException:
    return HTTPException(status_code=status_code, detail={"error": code, "detail": detail}, headers=_NO_STORE)


def _actor(request: Request) -> AuthenticatedPortalUser:
    user = get_authenticated_portal_user(request)
    if user is None:
        raise _error(401, "unauthenticated", "Authentication is required.")
    if not has_permission(user, PortalPermission.USER_MANAGE):
        raise _error(403, "forbidden", "You do not have permission to manage users.")
    return user


def _require_same_origin(request: Request) -> None:
    if not same_origin(request.headers.get("origin"), request.headers.get("host")):
        raise _error(403, "forbidden", "Cross-origin request refused.")


def _database_error(exc: DatabaseError, *, fallback: str) -> HTTPException:
    """Map a refusal from the controlled functions onto a safe JSON error.

    Messages raised by the user-management functions and the scope triggers
    are written for users (no SQL, no identifiers of other tenants); anything
    else gets the fallback.
    """

    sqlstate = getattr(exc, "sqlstate", None)
    diag = getattr(exc, "diag", None)
    message = (getattr(diag, "message_primary", None) or "").strip()
    constraint = getattr(diag, "constraint_name", None) or ""

    if sqlstate == "23505":
        if "email" in constraint:
            return _error(409, "duplicate_email", "A user with this email address already exists.")
        return _error(409, "duplicate_username", "A user with this username already exists.")
    if sqlstate == "42501":
        return _error(403, "forbidden", message or "You are not permitted to make this change.")
    if sqlstate in {"22023", "P0001"} and message:
        return _error(400, "invalid_request", message)
    return _error(409, "rejected", fallback)


def _policy_error(exc: AccountPolicyError | ValueError) -> HTTPException:
    return _error(400, "invalid_request", str(exc))


def _grantable_scopes(actor: AuthenticatedPortalUser) -> tuple[str, ...]:
    return _GRANTABLE_SCOPES.get(actor.access_scope_mode or "", ())


def _assignable_role_codes(actor: AuthenticatedPortalUser) -> set[str]:
    role = portal_role(actor)
    return {r.value for r in assignable_portal_roles(role)} if role else set()


async def _organizations_for(actor: AuthenticatedPortalUser) -> list[dict[str, Any]]:
    rows = await list_organizations()
    if actor.access_scope_mode == "GLOBAL":
        return list(rows)
    return [row for row in rows if str(row["id"]) == (actor.organization_id or "")]


def _resolve_scope(
    actor: AuthenticatedPortalUser,
    *,
    access_scope_mode: str,
    organization_id: UUID | None,
    site_ids: list[UUID],
) -> tuple[str, str | None, tuple[str, ...]]:
    """Normalize a requested scope and pre-check it against the actor's (UX; the DB re-checks)."""

    try:
        mode, normalized_site_ids = normalize_portal_access_scope_submission(
            access_scope_mode=access_scope_mode,
            site_ids=[str(s) for s in site_ids],
        )
    except ValueError as exc:
        raise _policy_error(exc) from exc

    if mode.value not in _grantable_scopes(actor):
        raise _error(403, "forbidden", "You cannot grant an access scope wider than your own.")

    if mode.value == "GLOBAL":
        return mode.value, None, ()

    # A tenant administrator always grants within their own organization.
    target_org = actor.organization_id if actor.access_scope_mode != "GLOBAL" else (
        str(organization_id) if organization_id else None
    )
    if not target_org:
        raise _error(400, "invalid_request", "Whole-organization and selected-site access require an organization.")

    if actor.access_scope_mode == "SELECTED_SITES" and not set(normalized_site_ids) <= set(actor.site_ids):
        raise _error(403, "forbidden", "You can grant access only to sites you can access yourself.")

    return mode.value, target_org, normalized_site_ids


def _check_role(actor: AuthenticatedPortalUser, role_code: str) -> str:
    value = (role_code or "").strip().upper()
    if value not in {r.value for r in PortalRole}:
        raise _error(400, "invalid_request", "Unknown role.")
    if value not in _assignable_role_codes(actor):
        raise _error(403, "forbidden", f"You cannot assign the {value} role.")
    return value


def _serialize(
    row: dict[str, Any],
    *,
    actor: AuthenticatedPortalUser,
    org_names: dict[str, str],
    sites: dict[str, dict[str, Any]],
) -> ManagedUser:
    organization_id = str(row["organization_id"]) if row.get("organization_id") else None
    role_code = row["role_code"]
    try:
        role_label = ROLE_LABELS[PortalRole(role_code)][0]
    except ValueError:
        role_label = role_code
    site_refs = []
    for site_id in row.get("site_ids") or []:
        key = str(site_id)
        site = sites.get(key)
        site_refs.append(
            SiteRef(
                site_id=key,
                site_name=site["site_name"] if site else None,
                site_code=site["site_code"] if site else None,
            )
        )
    return ManagedUser(
        portal_user_id=int(row["portal_user_id"]),
        username=row["username"],
        display_name=row["display_name"],
        email=row.get("email"),
        role_code=role_code,
        role_label=role_label,
        access_scope_mode=row["access_scope_mode"],
        organization_id=organization_id,
        organization_name=org_names.get(organization_id) if organization_id else None,
        sites=site_refs,
        is_active=bool(row["is_active"]),
        created_at=row["created_at"],
        updated_at=row["updated_at"],
        is_self=int(row["portal_user_id"]) == actor.portal_user_id,
    )


async def _lookups(actor: AuthenticatedPortalUser) -> tuple[dict[str, str], dict[str, dict[str, Any]]]:
    organizations = await _organizations_for(actor)
    org_names = {str(o["id"]): o["organization_name"] for o in organizations}
    site_rows = await list_accessible_sites(portal_user_id=actor.portal_user_id)
    sites = {str(s["id"]): s for s in site_rows}
    for s in site_rows:
        org_names.setdefault(str(s["organization_id"]), s["organization_name"])
    return org_names, sites


async def _manageable_rows(actor: AuthenticatedPortalUser) -> list[dict[str, Any]]:
    try:
        return await list_manageable_users(actor_portal_user_id=actor.portal_user_id)
    except DatabaseError as exc:
        raise _database_error(exc, fallback="The user list could not be loaded.") from exc


async def _manageable_row(actor: AuthenticatedPortalUser, portal_user_id: int) -> dict[str, Any]:
    row = next((r for r in await _manageable_rows(actor) if int(r["portal_user_id"]) == portal_user_id), None)
    if row is None:
        # Outside the actor's scope and nonexistent look the same.
        raise _error(404, "not_found", "User not found.")
    return row


async def _user_response(actor: AuthenticatedPortalUser, portal_user_id: int, *, temporary_password: str | None = None) -> UserResponse:
    row = await _manageable_row(actor, portal_user_id)
    org_names, sites = await _lookups(actor)
    return UserResponse(
        user=_serialize(row, actor=actor, org_names=org_names, sites=sites),
        temporary_password=temporary_password,
    )


# ---------------------------------------------------------------------------
# Routes
# ---------------------------------------------------------------------------


@router.get("/users/options", response_model=UserOptionsResponse)
async def user_options(request: Request, response: Response) -> UserOptionsResponse:
    actor = _actor(request)
    response.headers.update(_NO_STORE)
    assignable = _assignable_role_codes(actor)
    organizations = await _organizations_for(actor)
    site_rows = await list_accessible_sites(portal_user_id=actor.portal_user_id)
    return UserOptionsResponse(
        actor=ActorSummary(
            portal_user_id=actor.portal_user_id,
            role_code=actor.role_code,
            access_scope_mode=actor.access_scope_mode or "",
            organization_id=actor.organization_id,
        ),
        roles=[
            RoleOption(
                role_code=role.value,
                display_name=ROLE_LABELS[role][0],
                description=ROLE_LABELS[role][1],
                permissions=sorted(p.value for p in ROLE_PERMISSIONS[role]),
                assignable=role.value in assignable,
            )
            for role in PortalRole
        ],
        scopes=[ScopeOption(access_scope_mode=m, label=SCOPE_LABELS[m]) for m in _grantable_scopes(actor)],
        organizations=[
            OrganizationOption(
                organization_id=str(o["id"]),
                organization_name=o["organization_name"],
                organization_code=o["organization_code"],
            )
            for o in organizations
        ],
        sites=[
            SiteOption(
                site_id=str(s["id"]),
                site_name=s["site_name"],
                site_code=s["site_code"],
                organization_id=str(s["organization_id"]),
                organization_name=s["organization_name"],
            )
            for s in site_rows
        ],
        password_policy=password_policy_description(),
    )


@router.get("/users", response_model=UsersResponse)
async def list_users(request: Request, response: Response) -> UsersResponse:
    actor = _actor(request)
    response.headers.update(_NO_STORE)
    rows = await _manageable_rows(actor)
    org_names, sites = await _lookups(actor)
    return UsersResponse(users=[_serialize(r, actor=actor, org_names=org_names, sites=sites) for r in rows])


@router.get("/users/{portal_user_id}", response_model=UserResponse)
async def get_user(portal_user_id: int, request: Request, response: Response) -> UserResponse:
    actor = _actor(request)
    response.headers.update(_NO_STORE)
    return await _user_response(actor, portal_user_id)


@router.post("/users", response_model=UserResponse, status_code=201)
async def create_user(body: CreateUserRequest, request: Request, response: Response) -> UserResponse:
    actor = _actor(request)
    _require_same_origin(request)
    response.headers.update(_NO_STORE)

    try:
        username = normalize_username(body.username)
        display_name = normalize_display_name(body.display_name)
        email = normalize_email(body.email)
    except AccountPolicyError as exc:
        raise _policy_error(exc) from exc

    role_code = _check_role(actor, body.role_code)
    mode, organization_id, site_ids = _resolve_scope(
        actor,
        access_scope_mode=body.access_scope_mode,
        organization_id=body.organization_id,
        site_ids=body.site_ids,
    )

    generated: str | None = None
    if body.password is None or body.password == "":
        generated = generate_temporary_password()
        password = generated
    else:
        try:
            password = validate_password(body.password, username=username)
        except AccountPolicyError as exc:
            raise _policy_error(exc) from exc

    try:
        portal_user_id = await create_managed_user_with_status(
            actor_portal_user_id=actor.portal_user_id,
            username=username,
            display_name=display_name,
            email=email,
            password_hash=hash_portal_password(password),
            role_code=role_code,
            access_scope_mode=mode,
            organization_id=organization_id,
            site_ids=site_ids,
            is_active=body.is_active,
        )
    except DatabaseError as exc:
        raise _database_error(exc, fallback="The database rejected the user request.") from exc

    return await _user_response(actor, portal_user_id, temporary_password=generated)


@router.patch("/users/{portal_user_id}", response_model=UserResponse)
async def update_user(portal_user_id: int, body: UpdateUserRequest, request: Request, response: Response) -> UserResponse:
    actor = _actor(request)
    _require_same_origin(request)
    response.headers.update(_NO_STORE)

    current = await _manageable_row(actor, portal_user_id)
    is_self = portal_user_id == actor.portal_user_id
    fields = body.model_fields_set

    details: tuple[str, str] | None = None
    if "display_name" in fields or "email" in fields:
        try:
            display_name = normalize_display_name(
                body.display_name if body.display_name is not None else current["display_name"]
            )
            email = normalize_email(body.email if body.email is not None else (current.get("email") or ""))
        except AccountPolicyError as exc:
            raise _policy_error(exc) from exc
        if display_name != current["display_name"] or email != (current.get("email") or None):
            details = (display_name, email)

    role_code: str | None = None
    if body.role_code is not None:
        requested = (body.role_code or "").strip().upper()
        if requested != current["role_code"]:
            role_code = _check_role(actor, requested)

    access_scope: tuple[str, str | None, tuple[str, ...]] | None = None
    if body.access_scope_mode is not None:
        mode, organization_id, site_ids = _resolve_scope(
            actor,
            access_scope_mode=body.access_scope_mode,
            organization_id=body.organization_id,
            site_ids=body.site_ids or [],
        )
        current_org = str(current["organization_id"]) if current.get("organization_id") else None
        current_sites = sorted(str(s) for s in (current.get("site_ids") or []))
        if (mode, organization_id, sorted(site_ids)) != (current["access_scope_mode"], current_org, current_sites):
            access_scope = (mode, organization_id, site_ids)

    is_active: bool | None = None
    if body.is_active is not None and body.is_active != bool(current["is_active"]):
        is_active = body.is_active

    if is_self and (role_code is not None or access_scope is not None or is_active is not None):
        raise _error(403, "forbidden", "You cannot change your own role, access or account status.")

    if details is None and role_code is None and access_scope is None and is_active is None:
        return await _user_response(actor, portal_user_id)

    try:
        await apply_managed_user_changes(
            actor_portal_user_id=actor.portal_user_id,
            target_portal_user_id=portal_user_id,
            details=details,
            role_code=role_code,
            access_scope=access_scope,
            is_active=is_active,
        )
    except DatabaseError as exc:
        raise _database_error(exc, fallback="The database rejected the change.") from exc

    return await _user_response(actor, portal_user_id)


@router.post("/users/{portal_user_id}/password", response_model=PasswordResetResponse)
async def reset_user_password(
    portal_user_id: int, body: PasswordResetRequest, request: Request, response: Response
) -> PasswordResetResponse:
    actor = _actor(request)
    _require_same_origin(request)
    response.headers.update(_NO_STORE)

    if portal_user_id == actor.portal_user_id:
        raise _error(403, "forbidden", "Use Change my password to change your own password.")

    target = await _manageable_row(actor, portal_user_id)

    generated: str | None = None
    if body.password is None or body.password == "":
        generated = generate_temporary_password()
        password = generated
    else:
        try:
            password = validate_password(body.password, username=target["username"])
        except AccountPolicyError as exc:
            raise _policy_error(exc) from exc

    try:
        await reset_managed_user_password(
            actor_portal_user_id=actor.portal_user_id,
            target_portal_user_id=portal_user_id,
            password_hash=hash_portal_password(password),
        )
    except DatabaseError as exc:
        raise _database_error(exc, fallback="The database rejected the password reset.") from exc

    return PasswordResetResponse(portal_user_id=portal_user_id, temporary_password=generated)


@router.post("/me/password", status_code=204)
async def change_my_password(body: OwnPasswordChangeRequest, request: Request) -> Response:
    actor = _actor(request)
    _require_same_origin(request)

    try:
        new_password = validate_password(body.new_password, username=actor.username)
    except AccountPolicyError as exc:
        raise _policy_error(exc) from exc
    if new_password == body.current_password:
        raise _error(400, "invalid_request", "The new password must differ from the current one.")

    record = await get_portal_user_for_authentication(actor.username)
    if record is None or record.portal_user_id != actor.portal_user_id or not record.is_active:
        raise _error(403, "forbidden", "Your account cannot change its password.")
    if not verify_portal_password(record.password_hash, body.current_password):
        # Counts towards the sign-in lockout, so this cannot be used to guess passwords.
        await record_portal_login_failure(record.portal_user_id)
        raise _error(400, "invalid_current_password", "The current password is incorrect.")

    try:
        await change_own_password(
            portal_user_id=actor.portal_user_id,
            password_hash=hash_portal_password(new_password),
        )
    except DatabaseError as exc:
        raise _database_error(exc, fallback="The database rejected the password change.") from exc

    return Response(status_code=204, headers=_NO_STORE)
