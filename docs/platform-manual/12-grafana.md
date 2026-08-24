# Grafana

```
Status: CURRENT
Last verified: 2026-08-24
Verification basis: Repository, Staging, Audit evidence
```

## Datasource: provisioned per-tenant at runtime, not statically

`grafana/provisioning/datasources/ems-timescaledb.yaml` is **intentionally empty** (`datasources: []`), with an explicit comment in the file itself: "Datasource provisioning is tenant-managed by the EMS admin portal... Do not add fixed orgId values here. Fixed organization IDs become orphaned when tenants are removed or when the platform is installed elsewhere." The admin portal (`app/src/onboarding/grafana_provisioning_service.py`, `grafana_reconciliation_service.py`) provisions the `ems-timescaledb` datasource separately inside each Grafana organization that has a row in `metadata.grafana_organization_map`. Every dashboard query in the repo hardcodes `datasource.uid = "ems-timescaledb"` and filters by `${__org.id}` — Grafana's built-in "currently logged-in organization" variable — meaning tenant isolation for dashboards depends entirely on (a) the user being logged into the correct Grafana org and (b) that org having a working provisioned datasource pointed at the right tenant filter.

**CURRENT IMPLEMENTATION (verified live, 2026-08-24)**: Meenaxy Pharma has an active mapping row (`grafana_org_id=2`, `is_active=true`, `updated_at` within the same session window as its device commissioning). This was checked specifically because it's a real single point of failure — a migration that populates `metadata`/`config` device data but never touches `metadata.grafana_organization_map` produces devices with zero Grafana visibility regardless of telemetry health.

## Datasource lifecycle: create vs. reconcile (fixed 2026-08-24)

**Historical finding**: `GrafanaClient.provision_organization()` (`app/src/grafana_client.py`) called `get_datasource_by_uid()`, and only ever acted on a `None` result (create). An *existing* datasource — found by UID — was left completely untouched. Consequence: if `EMS_GRAFANA_DB_PASSWORD` changed after a tenant's datasource was first created (e.g. `grafana_reader`'s Postgres password rotated, or the datasource was originally created with a different value), the app had no code path that would ever push the corrected password into Grafana. The datasource's stored `secureJsonData.password` became permanently stale, causing `password authentication failed for user "grafana_reader"` at the Grafana→Postgres layer specifically — while the Postgres role itself, and the current `EMS_GRAFANA_DB_PASSWORD`, were both independently verified correct. This was root-caused live against the Meenaxy Pharma tenant's failing datasource.

**Current implementation**: `provision_organization()` now branches to `update_datasource()` — not a no-op — when the datasource already exists. Both `create_datasource()` and `update_datasource()` build their payload from one shared `_datasource_payload()` helper, so the two operations cannot drift apart. `update_datasource()` issues `PUT /api/datasources/uid/ems-timescaledb` (the UID-based endpoint — the datasource identity is never replaced) with the full canonical payload, including the *current* `self.datasource_password` (sourced from `EMS_GRAFANA_DB_PASSWORD`) every time. Provisioning is therefore fully idempotent and self-healing on every run:
- datasource missing → `create_datasource()` (`POST /api/datasources`)
- datasource exists → `update_datasource()` (`PUT /api/datasources/uid/ems-timescaledb`), always re-asserting the current password

**Repair path for an already-affected tenant**: use the existing reconciliation route, `POST /administration/organizations/{organization_id}/grafana/reconcile` (`app/src/main.py`, backed by `app/src/onboarding/grafana_reconciliation_service.py::reconcile_grafana_tenant`) — it calls `provision_organization()` with the tenant's mapped `grafana_org_id`, which now reconciles the datasource instead of skipping it. **Do not** manually edit Grafana's internal datasource record or rotate `grafana_reader`'s Postgres password as a substitute — both bypass the fix and leave the underlying bug capable of recurring on the next password rotation.

**Regression coverage**: `app/tests/test_grafana_client.py` — `test_update_datasource_uses_stable_uid_and_current_password`, `test_create_and_update_datasource_payloads_do_not_drift`, `test_provision_organization_reconciles_existing_datasource` (renamed/rewritten from the old test that asserted the buggy skip-when-exists behavior), plus an added guard in the create-path test ensuring `update_datasource` is never called when the datasource is missing.

**Verification status of this fix** (read this distinction carefully before relying on it):
- **Verified from repository/code**: `provision_organization()` branches correctly; `create_datasource()`/`update_datasource()` share one payload builder; no other code path in `app/src` calls Grafana's `/api/datasources` API — `provision_organization()` is the single funnel, confirmed by a full-repo grep.
- **Verified by automated tests**: all 11 tests in `test_grafana_client.py` pass against a mocked `_request` — this proves the *client's own logic* (which HTTP method/path/payload it builds and which branch it takes), not that Grafana actually accepts and applies that payload.
- **Verified against Grafana's own published API docs** (not a live instance): Grafana's official `PUT /api/datasources/uid/:uid` documentation shows its own example request body including `secureJsonData` (e.g. `basicAuthPassword`) for updates, with the same "define under `secureJsonData` to be stored encrypted" convention as create — confirming our payload shape follows Grafana's documented pattern. The docs do **not** explicitly state that a password included in a PUT always overwrites the previously stored value (this is standard, widely-relied-upon Grafana behavior, but it is an inference from convention, not a quoted guarantee).
- **NOT yet verified against a live Grafana instance**: whether `PUT /api/datasources/uid/ems-timescaledb` against the actual staging Grafana 11.6.0 deployment (a) succeeds with this exact payload shape, and (b) actually causes the next connection attempt to use the new password. This requires the staging smoke test below, run after deployment.

**Recommended minimal staging smoke test** (run once, after this fix is deployed and before considering the Meenaxy repair complete — uses Grafana's own built-in verification, not custom test code):
1. Confirm the current value Grafana has stored is stale by checking its health status: `GET /api/datasources/uid/ems-timescaledb/health` with header `X-Grafana-Org-Id: 2` (Meenaxy) — expect a non-OK status, reproducing the reported bug.
2. Trigger reconciliation: `POST /administration/organizations/{meenaxy_organization_id}/grafana/reconcile` (the existing admin-portal route).
3. Repeat step 1's health check — expect `"status": "OK"`. A pass here is direct, live proof of the full chain: `EMS_GRAFANA_DB_PASSWORD` → datasource `secureJsonData.password` → `grafana_reader` → TimescaleDB.
This has not been run — doing so was explicitly out of scope for this review (no deployment, no live Grafana calls, no reconciliation route invocation).

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
