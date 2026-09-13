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
