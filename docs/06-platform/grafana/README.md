# Grafana

Status: CURRENT · Last reviewed: 2026-08-25
Verification basis: Repository, Staging, Audit evidence
Related decisions: [ADR-008](../../00-governance/decisions/ADR-008-grafana-ops-role.md)

## Datasource: provisioned per-tenant at runtime, not statically

`grafana/provisioning/datasources/ems-timescaledb.yaml` is **intentionally
empty** (`datasources: []`) — datasource provisioning is tenant-managed by
the admin portal (`app/src/onboarding/grafana_provisioning_service.py`,
`grafana_reconciliation_service.py`), which provisions the
`ems-timescaledb` datasource inside each Grafana organization that has a
row in `metadata.grafana_organization_map`. Every dashboard query hardcodes
`datasource.uid = "ems-timescaledb"` and filters by `${__org.id}` — tenant
isolation for dashboards depends on (a) the user being logged into the
correct Grafana org and (b) that org having a working provisioned
datasource.

A second datasource, `wisewatts-live-datasource` (custom Grafana plugin,
UID `ffuz5sq2fe9s0a`), serves live/canvas panels over the `live-telemetry`
service's WebSocket hub — provisioned/reconciled alongside `ems-timescaledb`
in the same `provision_organization()` call, sharing generic create/verify
internals so the two cannot drift in verification behavior.

## Datasource provisioning was found broken and fixed (2026-08-24/25)

A multi-stage investigation found and fixed: (1) an existing datasource was
never updated on credential change (`update_datasource()` added); (2) the
update's own success check trusted an HTTP 200 that didn't prove
persistence — replaced with a post-write `/health` check, since Grafana's
`version` field was found to be an unreliable signal for this endpoint; (3)
the live-datasource *plugin itself* had never been built and deployed to
staging, causing all live/canvas panels to fail with "Datasource not
found," fixed by running the repository's own `build-plugin.sh` and adding
it to the bootstrap sequence (`06a_build_grafana_live_plugin.sh`) so a
fresh host no longer reproduces the gap. All three are **resolved and
live-verified end-to-end** as of 2026-08-25. Full incident detail:
[../../10-operations/incident-history.md](../../10-operations/incident-history.md).

**Repair path for an already-affected tenant**: the existing reconciliation
route, `POST /administration/organizations/{organization_id}/grafana/reconcile`
— never manually edit Grafana's internal datasource record or rotate
`grafana_reader`'s Postgres password as a substitute.

## Dashboard catalog

7 dashboards, all under `grafana/dashboards/core/`, all sharing an
identical "EMS Navigation" text panel with hardcoded links between them.
All query only `analytics.v_grafana_*` and `analytics.get_grafana_*`
functions — never `analytics.energy_consumption_*` or `telemetry.*`
directly.

| Dashboard | Purpose | Key objects |
|---|---|---|
| `alarms.json` | Live view of active alarm-equivalent conditions, org-wide | `v_grafana_active_alarms`, `v_grafana_sites` |
| `organization-overview.json` | Portfolio landing page | `v_grafana_sites`/`assets`/`devices`/`active_alarms`/`energy_samples` |
| `site-overview.json` | Single-site drill-down | Same family, filtered by `site_id` |
| `area-overview.json` | One asset-hierarchy branch within a site | `v_grafana_assets`, `v_grafana_asset_devices`, recursive asset-tree walk |
| `asset-overview.json` | Single-asset deep dive (energy, power, demand, electrical quality) | The richest object set — `v_grafana_asset_identity_context`, `get_grafana_asset_demand_summary()`, `get_canonical_energy_read()` (its only confirmed call site) |
| `device-diagnostics.json` | Per-device technical/operational diagnostics | `v_grafana_devices`, `v_grafana_normalized_points` — closest existing thing to a commissioning-readiness view, though it does not query `analytics.v_commissioning_readiness` directly |
| `analytics-explorer.json` | Ad-hoc multi-asset/multi-metric exploration | `get_grafana_explorer_intervals()` — the only dashboard built around a function-driven flexible query |

`grafana_reader` has `EXECUTE` on exactly 18 functions
(`information_schema.role_routine_grants`, verified); see
[../telemetry/analytics-layer.md](../telemetry/analytics-layer.md) for the
semantic-layer object catalog.

## Objects defined but not consumed by any dashboard

`v_energy_demand_15min`, `v_energy_peak_demand_daily`/`_monthly`,
`v_asset_peak_demand_*`, `v_energy_site_demand_kpis`,
`v_site_energy_balance_daily`, the entire environment-analytics family, and
the `v_energy_reporting_*` lineage. Not confirmed dead code — only that no
*current* dashboard queries them.

## Known dashboard-level inconsistency (open, not fixed)

`site-overview.json` has two panels both labeled "demand" using genuinely
different aggregation semantics — "Current demand kW" (latest single
sample per device, summed) versus "Site demand profile" (15-minute
time-bucketed sum) — **neither is the platform's dedicated demand-
calculation engine** (`analytics.demand_intervals`/`demand_state`).
Recorded per [../../00-governance/source-of-truth.md](../../00-governance/source-of-truth.md)
as a known, open contradiction — not resolved by this documentation
reorganization.

## Troubleshooting approach

1. Confirm the tenant has an `is_active=true` row in
   `metadata.grafana_organization_map`.
2. Confirm the underlying `analytics.v_grafana_*` view returns rows for that
   `grafana_org_id` directly via SQL (bypassing Grafana) — if it does and
   the dashboard still shows nothing, the problem is Grafana-side, not
   data-side.
3. Check whether the panel's expected time range matches how much telemetry
   history actually exists.

See [../../10-operations/troubleshooting.md](../../10-operations/troubleshooting.md).
