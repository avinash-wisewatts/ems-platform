# Security and Tenancy

Status: PARTIAL · Last reviewed: 2026-09-13 · Owner: Architecture
Source of truth: platform manual chapters 14 & 20 (archived), consolidated here.

## Tenant hierarchy

`metadata.organizations` → `metadata.sites` → (`buildings` → `floors` →
`spaces`), with `gateways`, `devices`, and `assets` all carrying
`organization_id` (and `site_id` where applicable) as a direct, `NOT NULL`
foreign key. Every metadata/config table that participates in tenant data
carries this scoping — there is no separate "tenant" table distinct from
`organizations`.

## Tenant isolation — verified mechanisms

- **Database**: every tenant-owned row carries `organization_id` as a
  `NOT NULL` FK; triggers cross-check that relationships (device↔gateway,
  asset↔device, asset↔space/floor/building) stay within one organization/
  site (`validate_tenant_site_ownership`, `validate_device_physical_location`,
  `validate_asset_physical_location`).
- **Application**: `admin.portal_user_can_access_site(actor_id, site_id)`
  is called at the top of essentially every `admin.*` mutation and several
  read functions — access is **site-scoped**, not organisation-scoped-only.
- **Grafana**: `metadata.grafana_organization_map` maps one EMS organisation
  to one Grafana organisation ID. Every dashboard filters exclusively by
  `${__org.id}` — tenant isolation depends on which Grafana org a user is
  logged into, combined with this mapping table. See
  [../06-platform/grafana/README.md](../06-platform/grafana/README.md).
- **Analytics API**: server-side SECURITY DEFINER functions
  (`analytics.portal_user_can_access_space`, migration 231) — see
  [api-architecture.md](api-architecture.md).

## Database-role separation as a security control

| Role | Privileges | Observed behavior |
|---|---|---|
| `ems_readonly` | `SELECT` only | Could query `metadata`/`config` table contents, but **could not see any rows in `information_schema.triggers`** for tables it otherwise had full `SELECT` access to — a genuine, unexplained visibility gap, not a write-privilege difference. |
| `ems_admin` | Full DDL/DML owner-level access | `information_schema.triggers`, `pg_trigger`, `pg_proc`, `pg_get_functiondef()` all fully visible — revealed 12 active triggers `ems_readonly` could not enumerate. |

**Practical implication**: any read-only investigation or tooling that
trusts `ems_readonly`'s view of `information_schema.triggers` will falsely
conclude the database has no validation triggers. Use `ems_admin`, or query
`pg_trigger`/`pg_proc` directly, for any investigation that needs to
enumerate triggers. This is a real, unresolved open item — see
[../10-operations/troubleshooting.md](../10-operations/troubleshooting.md).

## Secrets handling

Never commit secrets anywhere (code, tests, docs, Docker images, dashboards);
never print secrets to the terminal unnecessarily. The live-telemetry
service's dedicated MQTT credentials (`MQTT_HOST`, `MQTT_PORT`,
`MQTT_USERNAME`, `MQTT_PASSWORD`, `MQTT_LIVE_CLIENT_ID`, `MQTT_TLS`,
`EMS_GRAFANA_STREAM_TOKEN`) must never reach browsers, frontend JavaScript,
Grafana dashboard variables, or public APIs — only the server-side
live-telemetry path may hold them. See
[../06-platform/README.md](../06-platform/README.md) and
[../09-release-and-deployment/environments.md](../09-release-and-deployment/environments.md)
for the environment-file boundary that enforces this structurally.

## What is not independently verified

Whether staging and production share MQTT broker credentials or routing —
evidence is suggestive but not conclusive, and inspecting MQTT broker
configuration directly was out of scope for the investigation that produced
this finding. Grafana's own internal auth/session model. Network-level
exposure (firewall rules, security groups) for either environment.
