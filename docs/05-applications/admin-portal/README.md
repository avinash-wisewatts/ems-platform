# Administration Portal

Status: PARTIAL · Last reviewed: 2026-09-13 · Owner: Engineering
Source of truth: platform manual chapter 13 (archived), consolidated here.
Related decisions: [ADR-006](../../00-governance/decisions/ADR-006-ems-web-app-vs-admin-portal.md)

## Purpose and service

`app/` is the EMS Administration Portal (FastAPI, server-rendered Jinja2
templates; Docker service `admin-portal`). It is the **only** application
permitted to write organisation/site/gateway/device/asset metadata under
normal operation, using the least-privilege `ems_app` PostgreSQL role —
never direct table INSERT/UPDATE/DELETE, only `EXECUTE` on specific
`admin.*` functions. See [../../06-platform/database/README.md](../../06-platform/database/README.md).

## Module layout

`app/src/onboarding/` — `organization.py`, `site.py`, `location.py`,
`gateway.py`, `device.py`, `asset.py`, plus `grafana_provisioning_service.py`
and `grafana_reconciliation_service.py` (Grafana org/datasource provisioning
is application-driven, not manual or DB-trigger-driven).

`app/src/auth/` — `session.py`, `middleware.py`, `security.py`, `service.py`,
`repository.py`, `authorization.py`, `access_scope.py`, `dependencies.py` —
session-based authentication and a distinct authorization/access-scope
layer as separate modules. Internal mechanism (token format, password
hashing) is documented only at the level of "these responsibilities are
separated into distinct files," never with implementation specifics that
would risk exposing a security control's internals.

## User-management JSON API (EMS Web App Admin → Users)

`app/src/routers/user_management_api.py`, mounted only here (ADR-023
Amendment 2; implemented 2026-11-03, not deployed). `GET/POST
/api/admin/v1/users`, `GET/PATCH /api/admin/v1/users/{id}`, `POST
/api/admin/v1/users/{id}/password`, `GET /api/admin/v1/users/options`, `POST
/api/admin/v1/me/password`. `ems_admin_session`; `user.manage` for every
`/api/admin/v1/users*` and `/api/admin/v1/me/*` request (anything else under
`/api/admin/` is denied); same-origin `Origin` + JSON body on writes;
`Cache-Control: no-store`. It reuses the Users pages' controlled functions
and audit (`admin.portal_user_audit`); migration 315 adds the
self-protection, target scope containment and the details / password-reset /
own-password functions, which the server-rendered Users pages inherit. Roles
are the existing ADMIN / OPERATOR / VIEWER (only ADMIN holds `user.manage`;
only ADMIN may assign roles), scopes GLOBAL / ORGANIZATION / SELECTED_SITES,
never granted wider than the actor's own. Initial administrator:
`python -m src.provision_portal_admin`
([../../10-operations/portal-user-provisioning.md](../../10-operations/portal-user-provisioning.md)).

## Two-layer enforcement

- **Application layer** (`admin.*` PL/pgSQL functions, `SECURITY DEFINER`):
  permission checks, most business-rule validation, and all
  `admin.onboarding_audit` writes.
- **Database layer** (triggers on `metadata.*` tables): a second,
  independent set of checks that fire regardless of which code path
  performed the write.

**The two layers do not check identical things** — see
[../../06-platform/database/README.md](../../06-platform/database/README.md)
for the specific gap (`config.device_profile_categories` compatibility is
checked only in application code, with no corresponding database trigger).

## Audit logging

`admin.onboarding_audit(id, requested_by, request_payload, result_payload,
created_at)` — one row per successful `admin.*` mutation. Failed calls roll
back and are **not** logged here — this table records successful state
changes only, not a complete request log.

## Unknowns

Exact HTTP route inventory; session/token mechanism internals; whether the
UI currently calls the single-call `admin.onboard_energy_asset(...)` or the
granular `admin.create_device`/`admin.assign_device_to_asset` functions —
see [../../10-operations/troubleshooting.md](../../10-operations/troubleshooting.md).
