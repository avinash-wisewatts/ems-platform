# Grafana

```
Status: CURRENT
Last verified: 2026-08-24
Verification basis: Repository, Staging, Audit evidence
```

## Datasource: provisioned per-tenant at runtime, not statically

`grafana/provisioning/datasources/ems-timescaledb.yaml` is **intentionally empty** (`datasources: []`), with an explicit comment in the file itself: "Datasource provisioning is tenant-managed by the EMS admin portal... Do not add fixed orgId values here. Fixed organization IDs become orphaned when tenants are removed or when the platform is installed elsewhere." The admin portal (`app/src/onboarding/grafana_provisioning_service.py`, `grafana_reconciliation_service.py`) provisions the `ems-timescaledb` datasource separately inside each Grafana organization that has a row in `metadata.grafana_organization_map`. Every dashboard query in the repo hardcodes `datasource.uid = "ems-timescaledb"` and filters by `${__org.id}` — Grafana's built-in "currently logged-in organization" variable — meaning tenant isolation for dashboards depends entirely on (a) the user being logged into the correct Grafana org and (b) that org having a working provisioned datasource pointed at the right tenant filter.

**CURRENT IMPLEMENTATION (verified live, 2026-08-24)**: Meenaxy Pharma has an active mapping row (`grafana_org_id=2`, `is_active=true`, `updated_at` within the same session window as its device commissioning). This was checked specifically because it's a real single point of failure — a migration that populates `metadata`/`config` device data but never touches `metadata.grafana_organization_map` produces devices with zero Grafana visibility regardless of telemetry health.

## Datasource lifecycle: create vs. reconcile (original defect fixed 2026-08-24; self-verification added 2026-08-25)

**Original historical finding**: `GrafanaClient.provision_organization()` (`app/src/grafana_client.py`) called `get_datasource_by_uid()`, and only ever acted on a `None` result (create). An *existing* datasource — found by UID — was left completely untouched. Consequence: if `EMS_GRAFANA_DB_PASSWORD` changed after a tenant's datasource was first created, the app had no code path that would ever push the corrected password into Grafana. **First fix (2026-08-24)**: `provision_organization()` was changed to call a new `update_datasource()` (`PUT /api/datasources/uid/ems-timescaledb`) when the datasource already exists, sharing one canonical payload builder with `create_datasource()`.

**Second historical finding — the first fix was insufficient on its own (2026-08-25)**: deployed to staging (commit `e89146f`), then live-tested against the actual Meenaxy Pharma tenant (Grafana org 2). The reconciliation route returned `HTTP 200` (proving `GrafanaClient`'s `PUT` did not raise `GrafanaApiError`), yet the datasource's `version` field stayed at `1` and its health check kept reporting `password authentication failed for user "grafana_reader"`, unchanged. **Root cause**: a `PUT` that Grafana accepts (any HTTP status `< 400`) only proves the request was well-formed — it is not proof the write was actually persisted. The original `update_datasource()` trusted "no HTTP error" as its only success signal. Grafana's own `version` field is the actual proof: it increments by exactly 1 on every write Grafana genuinely persists, unconditionally of whether the embedded credential later turns out to be valid (password validity is checked separately, at query/health-check time, never at write time). A live `version` that never moved off `1` across two separate reconciliation attempts is direct proof the PUT never took effect, despite the app reporting success both times.

**Investigation that ruled out org-scoping** (checked live before concluding this): Grafana's `X-Grafana-Org-Id` header — the mechanism `_request()` uses for every org-scoped call — was directly verified correct: `GET /api/orgs` showed exactly two orgs (`1: "Main Org."`, `2: "Meenaxy Pharma"`); `GET /api/datasources` under org 1 returned `[]` (no stray datasource landed there); the authenticated admin account's own default `orgId` (via `GET /api/user`) was already `2`; and the single `ems-timescaledb` datasource was confirmed to exist only in org 2. This eliminated "wrote to the wrong organization" as the explanation. The DB-side audit trail (`admin.onboarding_audit`) that would have shown the exact recorded outcome of the earlier reconciliation attempt could not be checked in the same session due to intermittent tunnel connectivity — the fix below does not depend on that evidence; it closes the gap regardless of the exact mechanism, because it no longer trusts an unverified success signal at all.

**Current implementation**: `update_datasource(org_id, previous_version)` and `create_datasource(org_id)` now **re-read the datasource via `get_datasource_by_uid()` immediately after every write** and verify the result before returning:
- `update_datasource`: raises `GrafanaApiError` if the datasource is missing after the `PUT`, or if `version` did not strictly increase past `previous_version`.
- `create_datasource`: raises `GrafanaApiError` if the datasource is missing after the `POST`.

`provision_organization()` now returns a structured `dict` (`grafana_org_id`, `datasource_action` — `"created"`/`"updated"`, `datasource_uid`, `datasource_name`, `datasource_version`) instead of a bare integer, so callers and the admin UI can observe *what actually happened*, not just "no exception was raised." All 4 call sites (`grafana_provisioning_service.py`, and 3 branches of `grafana_reconciliation_service.py::reconcile_grafana_tenant`) were updated accordingly; `reconcile_grafana_tenant`'s returned dict now includes `datasource_action`/`datasource_uid`/`datasource_name` directly, and its `repair_reason` audit text now records the verified action and version.

**Observability fix (the second gap discovered)**: the reconciliation route (`app/src/main.py::reconcile_organization_grafana_tenant`) always computed `result["grafana_reconciliation"]` and passed it into `render_organization_administration()` — but `app/src/templates/organizations.html` had **no markup referencing it at all**. An `HTTP 200` therefore communicated nothing to an administrator; a genuine failure returned by `reconcile_grafana_tenant()` (as opposed to a raised exception) was equally invisible. Fixed by adding a result block to `organizations.html` (using the template's existing `alert`/`alert-success`/`alert-error` convention, matching `device_detail.html`'s established pattern — no new UI framework introduced) that renders: organization id, datasource uid/name, `datasource_action`, success/failure, `reconciliation_status`, and `failure_reason` when present. It renders **only** these non-secret fields — `secureJsonData`/`password` are never part of the result dict in the first place, and dedicated tests pin both facts (the block exists, and it never references a secret field name).

**Repair path for an already-affected tenant**: use the existing reconciliation route, `POST /administration/organizations/{organization_id}/grafana/reconcile` — unchanged, still the sole supported repair mechanism. **Do not** manually edit Grafana's internal datasource record or rotate `grafana_reader`'s Postgres password as a substitute.

**Regression coverage** (`app/tests/test_grafana_client.py`, `test_grafana_reconciliation_service.py`, `test_grafana_reconciliation_routes.py`, `test_grafana_provisioning_service.py`): create/update payload parity; org-id threading through `_request()` (pins the org-scoping investigation's conclusion); `create_datasource`/`update_datasource` raising when the post-write re-read shows the write didn't take effect (**the exact regression test for the failure mode discovered live** — simulates Grafana returning `200` for the `PUT` while `version` stays unchanged); `update_datasource` raising when the datasource disappears after write; a failing write's `GrafanaApiError` message never containing the password; `reconcile_grafana_tenant` propagating a `GrafanaApiError` uncaught (so the route's existing exception handler renders it, rather than a false success); the reconciliation result being rendered in the template plus never referencing a secret field name.

**Verification status** (read this distinction carefully before relying on it):
- **Verified from repository/code**: all of the above, confirmed by direct inspection.
- **Verified by automated tests**: full suite green (988 passed; 57 pre-existing environment-only DB-connection errors, unrelated files, unchanged count) — this proves the *client's own logic*, not that Grafana's live behavior matches every assumption encoded in the mocks.
- **NOT yet verified against a live Grafana instance as of writing this section**: whether the *actual* live root cause (still not 100% pinned down — see above) is something this fix's verification step will catch and loudly report, or whether it will now surface an entirely new, more specific error message. Either outcome is progress over the previous silent-false-positive behavior. See the change-history entry for this date for the live deployment/verification result once performed.

## Dashboard catalog

7 dashboards, all under `grafana/dashboards/core/`, all sharing an identical "EMS Navigation" text panel with hardcoded links between them. See `reference/grafana-dashboard-catalog.md` for the full per-dashboard breakdown (panels, queries, resolution).

## What each dashboard actually queries

All 7 query only the `analytics.v_grafana_*` family and a set of `analytics.get_grafana_*`/`analytics.get_canonical_energy_read` functions — never `analytics.energy_consumption_*` or `telemetry.*` directly. This is the intended architectural boundary: Grafana never scans raw or mid-tier aggregate tables itself; the `v_grafana_*` views and these functions are the only sanctioned read surface.

**CURRENT IMPLEMENTATION (verified live, 2026-08-24, during a Grafana-failure investigation)**: `grafana_reader` (the actual DB role Grafana's datasource connects as, defined in `postgres/ddl/02_roles.sql`) has `EXECUTE` on exactly these 18 functions — confirmed via `information_schema.role_routine_grants`:

| Function | Signature | Tested this session |
|---|---|---|
| `get_grafana_asset_live_state` | `(p_grafana_org_id bigint, p_asset_id uuid, p_at timestamptz)` | ✅ live/status tile source — returns current point-level state |
| `get_grafana_asset_telemetry_context` | `(p_grafana_org_id, p_asset_id, p_at)` | ✅ returns `telemetry_state`/freshness |
| `get_grafana_asset_connectivity_context` | `(p_grafana_org_id, p_asset_id, p_at)` | ✅ returns `connectivity_state` |
| `get_grafana_asset_energy_intervals` | `(p_grafana_org_id, p_asset_id, p_from, p_to)` | ✅ chart source, native/15m/1h/1d routed |
| `get_grafana_assets_energy_intervals` | `(p_grafana_org_id, p_asset_ids uuid[], p_from, p_to)` | not directly tested (multi-asset variant of the above) |
| `get_grafana_asset_electrical_trend` | `(p_grafana_org_id, p_asset_id, p_from, p_to)` | ✅ voltage/current/power-factor/THD chart source |
| `get_grafana_assets_electrical_trend` | `(p_grafana_org_id, p_asset_ids uuid[], p_from, p_to)` | not directly tested |
| `get_grafana_asset_demand_summary` | `(p_grafana_org_id, p_asset_id, p_at)` | ✅ aggregate/analytics panel source |
| `get_grafana_explorer_intervals` | `(p_grafana_org_id, p_asset_ids uuid[], p_logical_points text[], p_from, p_to)` | ✅ Analytics Explorer dashboard source |
| `get_grafana_short_history` | `(p_grafana_org_id, p_site_id, p_asset_ids uuid[], p_logical_point_ids uuid[], p_from, p_to)` | not directly tested |
| `get_canonical_energy_read` | `(p_grafana_org_id, p_asset_id, p_from, p_to, p_requested_resolution text, p_fallback_policy text)` | called correctly; `p_fallback_policy` must be `'native'`/`'coarser'`/`'strict'` |
| `resolve_demand_capability`, `resolve_demand_interval`, `resolve_asset_demand_policy`, `resolve_device_demand_method`, `resolve_interval_quality_rule`, `resolve_site_capture_bucket`, `classify_energy_register_delta` | internal helpers invoked by the above | not directly tested |

All 8 directly-tested functions returned correct, current data for a real Meenaxy asset (`HVAC_UNIT_PELLET_SECTION_P1_HUV_02`) as of `2026-08-24 22:05` IST — this rules out permissions, missing objects, and query-level failures as the cause of any Grafana-reported error at that time. See [23-known-issues-and-drift.md](23-known-issues-and-drift.md) for what was **not** ruled out.

**Time resolution actually used**: `analytics.v_grafana_energy_samples` (the workhorse for "demand"/power panels across area/site/org-overview) returns per-sample rows, bucketed in-panel via Grafana's `$__timeGroupAlias(sample_time, '15m')` — i.e. dashboards do their own 15-minute bucketing over what is effectively near-1-minute-resolution sample data, rather than reading a pre-aggregated 15-minute table directly. `analytics-explorer.json` uses `analytics.get_grafana_explorer_intervals()` (a function, not a view) for flexible multi-asset/multi-metric queries. No dashboard currently queries the `hourly` or `daily` resolution objects.

## Objects defined but not consumed by any dashboard

Per a full line-by-line audit of all 7 dashboard JSON files (`Audit/EMS Analytics Platform — Phase 0 Complete Grafana Analytics Consumption Audit.txt`, cross-checked against a fresh grep of the live JSON this session — still accurate, not stale): `analytics.v_energy_demand_15min`, `v_energy_peak_demand_daily`/`_monthly`, `v_asset_peak_demand_*`, `v_energy_site_demand_kpis`, `v_site_energy_balance_daily`, the entire environment-analytics family (`v_environment_15min`/`hourly`, `environment_daily`, `v_environment_latest`, `v_environment_sensor_kpis`), and the `v_energy_reporting_{5min,15min,hourly,daily}` "semantic reporting" lineage. These exist in the schema and are presumably intended for future dashboards or other consumers (not confirmed) — **do not assume they're dead code**, only that no *current* dashboard queries them.

## Known dashboard-level inconsistencies (Historical finding → Current state)

**Historical finding** (same audit document): the `alarms.json` dashboard's four severity stat tiles (Critical/High/Medium/Low) are hardcoded to one fixed severity value each and are structurally disconnected from the dashboard's own `$severity` template variable — selecting a severity in the picker does not change what the tiles show, only the table below them.
**Current state**: not re-verified this session (dashboard JSON was re-read for object/query inventory, not for this specific interactive-behavior claim). **STATUS: unconfirmed whether still true — flagged for re-check, not asserted as fixed or still-broken.**

**Historical finding**: `site-overview.json` has two panels both labeled "demand" using genuinely different aggregation semantics — "Current demand kW" (latest single sample per device, summed) versus "Site demand profile" (15-minute time-bucketed sum) — neither is the platform's dedicated demand-calculation engine (`config.demand_register_semantics`/`analytics.demand_intervals`/`analytics.demand_state`, discovered this session as separate hypertables in the `analytics` schema, not yet cross-referenced against any dashboard panel).
**Current state**: confirmed still present in the live dashboard JSON this session (panel titles and query structure match the audit's description exactly). **STATUS: not fixed, current.**

## Grafana org mapping — resolved concern from earlier in this project

**Historical finding** (raised during post-migration verification, this session): the Meenaxy Pharma metadata migration touched only `metadata`/`config` schemas and never checked `metadata.grafana_organization_map` — raised as a plausible root cause if Grafana showed no data for the tenant.
**Current state**: checked directly and live — the mapping exists and is active.
**Resolution**: not a defect; the mapping had evidently already been provisioned (by the admin portal, presumably during an earlier organization-onboarding step, not by the device/asset migration itself — org/site onboarding and device/asset onboarding are separate operations, see `08-device-onboarding.md`).

## Troubleshooting approach (derived from the above, not a separate untested procedure)

1. Confirm the tenant has an `is_active=true` row in `metadata.grafana_organization_map`.
2. Confirm the underlying `analytics.v_grafana_*` view returns rows for that `grafana_org_id` directly via SQL (bypassing Grafana) — if it does and the dashboard still shows nothing, the problem is Grafana-side (wrong org selected, datasource UID mismatch, provisioning failure), not data-side.
3. Check whether the panel's expected time range matches how much telemetry history actually exists — a newly commissioned device with only minutes of history will legitimately show "no data" on a `now-24h` panel range for most of that window; this is not a query or backend failure. See `19-operations-and-diagnostics.md`.
