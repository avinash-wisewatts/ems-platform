# Authentication and Tenancy

```
Status: PARTIAL
Last verified: 2026-08-24
Verification basis: Repository, Staging
```

## Tenant hierarchy

`metadata.organizations` → `metadata.sites` → (`buildings` → `floors` → `spaces`), with `gateways`, `devices`, and `assets` all carrying `organization_id` (and `site_id` where applicable) as a direct, `NOT NULL` foreign key. Every metadata/config table that participates in tenant data carries this scoping — there is no separate "tenant" table distinct from `organizations`.

## Application-layer access control (portal)

`app/src/auth/` (session.py, middleware.py, security.py, service.py, repository.py, authorization.py, access_scope.py, dependencies.py) implements session-based authentication and a distinct authorization layer, invoked by name from database functions (`admin.portal_user_has_permission(actor_id, permission_code)`, `admin.portal_user_can_access_site(actor_id, site_id)` — both called at the top of nearly every `admin.*` mutation function, confirmed by direct reading of `postgres/ddl/79_independent_device_inventory.sql`, `92_asset_device_relationship_management.sql`, `97_device_commissioning_action.sql` this session). **Never write actual credentials, tokens, or session secrets into this manual** — only the mechanism names above are documented; their internal implementation was not read this session.

## Database-role access control

Two roles were used against staging this session, with a real, verified difference in visibility, not just write privilege:

| Role | Privileges | Observed behavior |
|---|---|---|
| `ems_readonly` | `SELECT` only (INSERT/UPDATE/DELETE/CREATE all confirmed denied against production under this role) | Could query `metadata`/`config` table contents once schema `USAGE` was granted, but **could not see any rows in `information_schema.triggers`** for tables it otherwise had full `SELECT` access to — a genuine, unexplained visibility gap, not merely a privilege difference on the base tables. |
| `ems_admin` | Full DDL/DML owner-level access (used only for read-only `SELECT` throughout this session per explicit instruction) | `information_schema.triggers`, `pg_trigger`, `pg_proc`, `pg_get_functiondef()` all fully visible — revealed 12 active triggers across `assets`/`devices`/`asset_devices` that `ems_readonly` could not enumerate. |

**Practical implication, stated plainly**: if `ems_readonly` (or an application role with similarly scoped grants) is ever used for schema introspection/tooling, it will under-report the actual constraint surface of the database. This was discovered, not assumed — an earlier verification pass in this project reported "staging has zero triggers on the metadata schema" based on an `ems_readonly` query, which was later found to be wrong when the same check was re-run as `ems_admin`.

## Grafana tenancy

`metadata.grafana_organization_map(organization_id, grafana_org_id, is_active, created_at, updated_at)` maps one EMS organization to one Grafana organization ID. Every provisioned dashboard filters exclusively by `${__org.id}` (Grafana's own logged-in-org context variable) against views in the `analytics.v_grafana_*` family — there is no dashboard-level organization picker; tenant isolation for Grafana is enforced by which Grafana org a user is logged into, combined with this mapping table. Verified live this session: Meenaxy Pharma has `grafana_org_id=2`, `is_active=true`. See `12-grafana.md` for the datasource-provisioning mechanism this table drives.

## What's NOT verified this session
- Exact session/cookie/token mechanism and expiry behavior.
- Whether `admin.portal_users`/`admin.portal_user_has_permission` implements role-based, attribute-based, or some other permission model beyond what's visible in the SQL call sites (a permission code string, e.g. `'device.manage'`, `'asset.manage'`).
- Grafana's own internal user/team/role model (Grafana org membership vs Grafana user permissions) — only the org-mapping table on the EMS side was checked.
