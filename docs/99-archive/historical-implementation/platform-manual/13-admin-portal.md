# Admin Portal

```
Status: PARTIAL
Last verified: 2026-08-24
Verification basis: Repository, Staging
```

## Purpose and service

`app/` is the EMS Administration Portal (FastAPI-style app; Docker service `admin-portal`, healthcheck expects both its own `/health` status and its database connectivity to report `"status":"ok"`, per `compose.yaml`). It is the only application permitted to write organization/site/gateway/device/asset metadata under normal operation, using the least-privilege `ems_app` PostgreSQL role — never direct table INSERT/UPDATE/DELETE, only `EXECUTE` on specific `admin.*` functions (see `08-device-onboarding.md`).

## Module layout (verified: files present, not a full code-behavior audit)

`app/src/onboarding/` — `organization.py`, `site.py`, `location.py`, `gateway.py`, `device.py`, `asset.py`, `drafts.py`, `forms.py`, `repository.py`, `result_contract.py`, `statuses.py`, plus **`grafana_provisioning_service.py`** and **`grafana_reconciliation_service.py`**. The presence of dedicated Grafana provisioning/reconciliation services in the onboarding module confirms (independent of, and consistent with, the live finding in `12-grafana.md`) that Grafana org/datasource provisioning is application-driven, not manual or DB-trigger-driven — `metadata.grafana_organization_map` is the record of what the admin portal has provisioned, kept in sync by `grafana_reconciliation_service.py`.

`app/src/auth/` — `session.py`, `middleware.py`, `security.py`, `service.py`, `repository.py`, `authorization.py`, `access_scope.py`, `dependencies.py`, `models.py`. Confirms session-based authentication and a distinct authorization/access-scope layer exist as separate modules. Internal logic (session mechanism, token format, password hashing) was **not read this session** — do not infer specifics beyond "these responsibilities are separated into distinct files."

`app/src/routers/context.py` — request-context routing scaffolding; specific route table was not enumerated this session.

`admin.v_active_device_profiles` and similar `admin.v_*` views (see `08-device-onboarding.md`) are the controlled read surface the portal's forms query — `ems_app` gets `SELECT` on these, not the underlying `config`/`metadata` tables directly.

## Where application logic ends and database enforcement begins

This is a real, deliberate two-layer design, not incidental redundancy:

- **Application layer (`admin.*` PL/pgSQL functions, `SECURITY DEFINER`)**: permission checks (`admin.portal_user_has_permission`, `admin.portal_user_can_access_site`), most business-rule validation (device-model/category match, profile/category compatibility, external_id format, protocol whitelist, lifecycle transitions), and **all `admin.onboarding_audit` writes**. These functions run as `ems_admin` internally (via `SECURITY DEFINER`) even though the portal itself connects as `ems_app`.
- **Database layer (triggers on `metadata.*` tables)**: a second, independent set of checks that fire regardless of which role or code path performed the write — org/site ownership consistency (`validate_tenant_site_ownership`), physical-location hierarchy consistency (`validate_asset_physical_location`, `validate_device_physical_location`), relationship-category compatibility (`validate_asset_device_relationship`), and lifecycle-status guards (`reject_obsolete_device_lifecycle_status`, `reject_uncommissioned_active_device`).

**The two layers do not check identical things.** Confirmed live this session: `config.device_profile_categories` compatibility is checked by the *application* function (`admin.create_device`) but has **no corresponding database trigger** — a direct SQL INSERT bypassing the app layer will not be caught by the database on this specific point (see `08-device-onboarding.md`'s trigger table for the full breakdown of what is/isn't independently DB-enforced). Treat the database triggers as the durable safety net for structural/relational integrity, and the application layer as the safety net for domain-specific business rules — they are complementary, not duplicated, and gaps between them are a real risk surface for any code path (including scripted migrations) that bypasses the application layer.

## Audit logging

`admin.onboarding_audit(id, requested_by, request_payload, result_payload, created_at)` — one row per successful `admin.*` mutation. `requested_by` is the human/service identity from `admin.portal_users`. Failed calls roll back and are **not** logged here (per the table's own comment: "Failed function calls roll back with their transaction and must be logged by the application layer") — so this table is a record of successful state changes only, not a complete request log. Verified live: real commissioning actions for the Meenaxy Pharma devices are traceable here by `requested_by`/timestamp (see `16-commissioning.md`).

## Unknowns / not verified this session
- Exact HTTP route table and request/response contracts.
- Session/token mechanism internals (cookie vs JWT, expiry, CSRF handling).
- Whether the single-call `admin.onboard_energy_asset(...)` (76_admin_onboarding_contract.sql) or the granular `admin.create_device`/`admin.assign_device_to_asset` functions are what the current UI actually calls — see `08-device-onboarding.md`.
