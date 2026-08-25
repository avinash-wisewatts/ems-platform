# Change History

Status: HISTORICAL
Last verified: 2026-08-24
Verification basis: Audit evidence, Repository, Staging (this session)

This is a narrative timeline synthesized from the `Audit/` folder's ~35
investigation documents plus this session's own verified work. It is a
**history of investigation and implementation phases**, not a live status
document — for current state, see the numbered architecture documents
(especially [23-known-issues-and-drift.md](23-known-issues-and-drift.md)).
Audit document titles are quoted for traceability; read the source
document for full detail on any phase.

## Phase 0 — Current-state baseline (multiple audit documents)

A multi-part investigation (`Phase 0 Current-State Inventory`,
`Phase 0 Complete Grafana Analytics Consumption Audit`,
`Phase 0 Metric Lineage Catalogue`, `Phase 0 Semantic Layer Audit`,
`Phase 0 Static Analytical Query-Performance Audit`,
`Phase 0 Tenant-Isolation & Authorization Audit`,
`Phase 0 Application-API Endpoint Audit`,
`Phase 0 Runtime Verification Against STAGING`) culminating in
`Phase 0 Final Deliverable: Current-State Analytics Architecture Baseline`.
This established the layered model (raw → normalized → domain measurements
→ two parallel aggregation families → analytics/semantic layer) that
[05-database.md](05-database.md) and [11-aggregation.md](11-aggregation.md)
describe. **At this baseline, staging had zero commissioned
sites/gateways/devices** — every telemetry table below the metadata layer
was empty by construction, not by failure. The baseline also recorded live
job-schedule drift (`run_normalization_job` running 5min/20min-overlap
against a canonical 1min/15min-overlap definition) and a retention-policy
discrepancy (a "do NOT add a retention policy yet" comment in source vs. an
already-configured 180-day/2-year retention observed live).

## Phase 1 — Canonical semantic model

`Phase 1 Canonical Semantic Model` and its `Final Reconciliation` document
define the target semantic model the subsequent 1A-1E phases implemented
toward.

## Phases 1A–1E — Incremental implementation

A sequence of implementation plans and reports (1A connectivity/semantic
consolidation, 1B, 1C, 1D, 1E-A, 1E-B), each pushed to `origin/staging` as
scoped, reviewed commits. Notable: `Phase 1C Scope Ambiguity (Blocking)`
and `Phase 1D Investigation (STOP — Discrepancy Found)` record cases where
implementation paused pending clarification rather than proceeding on an
assumption — consistent with this manual's own "do not infer architecture"
posture. `Phase 1D CI Failure and Corrective Commit` records a CI break and
its fix. `Phase 1E-B Implementation Report` (historical backfill of
per-flow energy-consumption quality columns) is the most recent
implementation-phase document found in `Audit/` as of this verification;
its commit (`b114c10`) matches this repository's own recent git history.

Each phase's CI/CD verification is separately recorded
(`Phase 1B CI-CD Release Verification`, `Phase 1C CI-CD Release
Verification`), distinct from the later, more complete CI/CD pipeline
implementation described in `docs/operations/CICD_PIPELINE.md` and
[17-cicd-and-deployment.md](17-cicd-and-deployment.md).

## Production access and bootstrap

`Production Read-Only Access Design` and its `Final Hardened Design`
revision, plus `Production Bootstrap Runbook`, establish the read-only
production database access model this manual's own live-verification work
(and the sessions before it) used.

## Staging commissioning investigation → Meenaxy Pharma migration (this session)

`Staging Commissioning Investigation` and its `(Corrected Topology)`
revision, plus `Staging Reference-Data Decision Report`, investigated why
staging's onboarding UI showed empty Device Model / Device Profile
dropdowns, tracing the root cause to `metadata.device_models` and
`config.device_profile_categories` both being empty on staging — a
reference-data gap, not an application bug.

**This session's own work directly followed on from that investigation**:
using production as the read-only authoritative source, it resolved the
device-model naming blocker with real production evidence
(`vendor='Best Energy'`, `model='Eniscope Energy Meter'` — correcting an
earlier test-fixture-based guess of `vendor='Eniscope'`), then built and
executed a transactional, idempotent, business-key-resolved migration
creating Meenaxy Pharma's 22 devices/22 assets/22 identifiers/22
relationships on staging. Two real staging-side surprises were found and
fixed mid-migration, not assumed away:
1. A duplicate `DISTRIBUTIONPANEL` space existed under both `GROUND` and
   `MEZZANINE` floors on staging (production only ever had it under
   `MEZZANINE`) — resolved by qualifying the space lookup by floor, not by
   modifying staging's location data.
2. A live trigger (`metadata.validate_asset_physical_location`, not
   present in any repository migration) required `building_id`/`floor_id`
   to be set explicitly whenever `space_id` was set on an asset row — the
   migration's asset `INSERT` was corrected to populate all three.

Following the migration, all 22 devices were **manually commissioned
through the application's controlled commissioning action** (traced via
`admin.onboarding_audit` to a human portal user, not any automated process
in this session), and real MQTT telemetry began flowing within minutes —
verified end-to-end from raw ingestion through 1-minute/15-minute/hourly
aggregation to the Grafana-facing semantic views, for all 22 devices,
individually traced for 3 representative devices (one per gateway).

This is the first point in the audit trail where staging is confirmed to
be carrying **real, live, commissioned telemetry** rather than empty
metadata scaffolding — every prior Phase 0/1A-1E document's "0 rows" /
"staging has zero devices" observations should be read as historical,
pre-commissioning state, not current fact.

## What this timeline does not cover

Whether Phases 1A-1E's implementation work has been independently
re-verified as still-correct against the current staging schema (only the
specific objects this session directly touched — device/asset metadata,
the aggregation and analytics layers exercised by the pipeline
verification — were re-checked). Treat older phases' specific claims as
historical unless a current document in this manual explicitly re-confirms
them.

## Manual maintenance log

Ongoing entries from this point forward, one per meaningful documentation
change (not every trivial edit). Each entry: date, area, what changed, why,
evidence/source, whether verified live, related code/doc.

### 2026-08-24 — Documentation-maintenance workflow adopted

- **Area**: Manual process itself ([README.md](README.md), [23-known-issues-and-drift.md](23-known-issues-and-drift.md))
- **What changed**: Added a formal source-of-truth priority order and
  contradiction-handling format to the README; added a consolidated
  "Tracked open items" index table to `23-known-issues-and-drift.md`
  covering all 13 currently-known open items (the original 6 documented in
  that file plus 7 more that existed only in topic-specific files —
  `device_profile_categories` DB-trigger gap, possible near-duplicate
  `analytics.v_energy_*` views, uncanonicalized 15min/hourly/daily
  aggregation DDL, two differing "demand" panel semantics, unestablished
  backup/recovery, unestablished admin-portal route inventory, unconfirmed
  onboarding code path).
- **Why**: User directive establishing the manual as a continuously
  maintained artifact, with an explicit requirement to track known open
  items rather than let them go untracked or get silently marked resolved.
- **Evidence/source**: Direct user instruction; cross-checked which items
  were already documented where via targeted grep across
  `docs/platform-manual/` before adding the index (not assumed).
- **Verified live**: No — this was a documentation-structure change only,
  no new system investigation.
- **Related**: None (process change, not a code/schema change).

### 2026-08-24 — Staging Grafana failure investigation (diagnosis only, no fix applied)

- **Area**: Grafana ([12-grafana.md](12-grafana.md)), known issues ([23-known-issues-and-drift.md](23-known-issues-and-drift.md))
- **What changed**: Documented the full, tested list of 18 `grafana_reader`-executable functions (previously described only as "a handful"); added two new tracked issues (`max_connections=25` ceiling, `run_failed_message_recovery_job` actively failing since 21:45).
- **Why**: User reported staging Grafana showing errors across dashboard tiles, live/status tiles, and charts. Investigated read-only, no changes made per explicit instruction.
- **Evidence/source**: Live staging queries via `SET ROLE grafana_reader`, calling 8 of the 18 `analytics.get_grafana_*` functions directly with real Meenaxy data (asset `HVAC_UNIT_PELLET_SECTION_P1_HUV_02`) — all 8 returned correct, current results (fresh as of `22:05` IST). All 13 TimescaleDB background jobs checked via `timescaledb_information.jobs`/`job_stats` — 12 healthy, 1 (`run_failed_message_recovery_job`) failing. `metadata.grafana_organization_map` re-confirmed to have exactly one active row (Meenaxy). `admin.schema_migrations` confirmed migrations 194-197 applied hours before the reported failure.
- **Verified live**: Yes, staging, `ems_admin` + `grafana_reader` impersonation.
- **Related**: `postgres/migrations/194-197_*.sql` (reviewed, ruled out as directly implicated); no code/schema changes made.
- **Outcome**: Could not reproduce the reported failure at the database layer — every query-level, permission-level, and data-freshness check passed. Root cause not established; most likely location is Grafana's own process/container/connection layer, which this session cannot inspect (no SSH/`docker exec`/Grafana API access). See the full diagnostic report in that session's conversation for the complete VERIFIED FACTS / INFERENCE / ROOT CAUSE breakdown.

### 2026-08-24 — Grafana datasource stale-credential bug: root cause found and fixed (code only, not yet deployed)

- **Area**: Grafana provisioning/reconciliation ([12-grafana.md](12-grafana.md))
- **What changed**: `app/src/grafana_client.py` — `provision_organization()` now calls a new `update_datasource()` method (PUT `/api/datasources/uid/ems-timescaledb`) when a tenant's datasource already exists, instead of silently leaving it untouched. `create_datasource()` and `update_datasource()` now share one `_datasource_payload()` builder so their configurations cannot drift apart. `app/tests/test_grafana_client.py` updated accordingly: rewrote the test that asserted the old skip-when-exists behavior, added dedicated update/no-drift regression tests, and added a create-path guard proving `update_datasource` is never called when the datasource is missing.
- **Why**: The staging Grafana failure investigated the same day (previous entry) turned out, once a browser-side Grafana admin check was possible, to be `password authentication failed for user "grafana_reader"` at the Grafana-stored-datasource level, despite the actual Postgres role and `EMS_GRAFANA_DB_PASSWORD` both being independently verified correct. Root cause: existing datasources were never reconciled to the current canonical configuration on any subsequent provisioning run — only ever created once and left alone.
- **Evidence/source**: Direct code inspection of `provision_organization()`'s `if datasource is None: create... ` branch with no `else`; confirmed the only other call site with datasource-touching logic (`grafana_reconciliation_service.py::reconcile_grafana_tenant`) also routes through the same unpatched `provision_organization()`.
- **Verified live**: No — this is a code fix, not yet deployed to staging. Tests run against a locally built `Dockerfile.test` image: `app/tests/test_grafana_client.py` (11/11 passed), full suite (`app/tests`: 980 passed; 57 pre-existing errors, all `psycopg.OperationalError: connection refused` against a local test Postgres this environment doesn't have running — confirmed unrelated to this change, same errors occur in unrelated `test_analytics_grafana_routing.py`/`test_analytics_grafana_electrical_routing.py` files that don't import `grafana_client` at all).
- **Related**: `app/src/grafana_client.py`, `app/tests/test_grafana_client.py`; repair path for the currently-affected Meenaxy tenant is the existing `POST /administration/organizations/{organization_id}/grafana/reconcile` route (`app/src/main.py`) — not yet invoked, pending deployment of this fix.
- **Outcome**: Code fixed and tested locally. Not committed, not pushed, not deployed, and the live Meenaxy datasource has not yet been repaired — all per explicit instruction to report before taking further action.

### 2026-08-24 — Architecture review of the datasource reconciliation fix

- **Area**: Grafana ([12-grafana.md](12-grafana.md))
- **What changed**: Added an explicit verification-status breakdown (repo/code vs. automated-test vs. Grafana-docs vs. live-instance evidence) and a minimal recommended staging smoke test (using Grafana's own `/api/datasources/uid/:uid/health` endpoint) to the datasource lifecycle section. No functional code changes — the review confirmed the prior fix's architecture is sound.
- **Why**: User requested a focused architecture/deployment review of the same-day datasource fix, explicitly asking for evidence-level honesty and confirmation that no competing datasource-mutation path exists elsewhere in the repo.
- **Evidence/source**: Repo-wide grep confirmed `provision_organization()` is the only caller of `create_datasource`/`update_datasource`, and the only code path that calls Grafana's `/api/datasources` API at all (`live_main.py`'s Grafana-adjacent routes are WebSocket endpoints for the separate `wisewatts-live-datasource` plugin, unrelated). Grafana's official HTTP API documentation for `PUT /api/datasources/uid/:uid` fetched and checked against our payload shape (confirms convention match; does not explicitly document overwrite-on-PUT semantics).
- **Verified live**: No — documentation-and-code review only, consistent with the explicit "do not deploy/call the reconciliation route/rotate passwords" instruction.
- **Related**: `app/src/grafana_client.py` (unchanged), `docs/platform-manual/12-grafana.md`.
- **Outcome**: No code changes needed. Architecture confirmed sound. One concrete follow-up recommended (the staging smoke test), not yet performed.

### 2026-08-25 — Grafana datasource reconciliation: self-verification and observability fix

- **Area**: Grafana ([12-grafana.md](12-grafana.md))
- **What changed**: `app/src/grafana_client.py` — `create_datasource()`/`update_datasource()` now re-read the datasource via `get_datasource_by_uid()` immediately after every write and raise `GrafanaApiError` if it's missing (create) or if `version` didn't strictly increase past the pre-write value (update). `provision_organization()` now returns a structured result dict (`grafana_org_id`, `datasource_action`, `datasource_uid`, `datasource_name`, `datasource_version`) instead of a bare int. All 4 call sites updated (`grafana_provisioning_service.py`; 3 branches of `grafana_reconciliation_service.py`). `app/src/templates/organizations.html` now renders the reconciliation result (previously silently dropped) using the template's existing `alert` convention.
- **Why**: The 2026-08-24 fix (create-vs-update branching) was deployed and live-tested against Meenaxy Pharma (staging, Grafana org 2). The reconciliation route returned `HTTP 200`, but the datasource's `version` stayed at `1` and its health check kept reporting `password authentication failed for user "grafana_reader"`, unchanged, across two separate reconciliation attempts. Investigation (live, this session) ruled out organization-scoping as the cause (`GET /api/orgs`, `GET /api/datasources` under org 1 = `[]`, admin user's own default `orgId` already `2`) — the header-based org-targeting mechanism this app relies on was confirmed working correctly. The DB audit trail that would show the exact prior outcome couldn't be checked (intermittent tunnel connectivity). Root cause identified from first principles instead: Grafana's `PUT` returning a non-error status is not proof of a persisted write — only `version` incrementing is. The code trusted the former.
- **Evidence/source**: Live staging investigation (`GET /api/orgs`, `/api/datasources` under multiple org headers, `/api/user`) via the established SSH-tunnel + `.netrc`/cookie-jar mechanisms from this session. Code inspection of `provision_organization()`, `reconcile_grafana_tenant()`, `reconcile_organization_grafana_tenant()` (main.py route), and `organizations.html` (confirmed via grep: zero references to `grafana_reconciliation`, `result.`, or `if result` before this fix).
- **Verified live**: Partially — the *investigation* (org-scoping, admin user context, datasource inventory) is live-verified. The *fix itself* was verified by the full automated test suite (988 passed, 0 failed, 57 pre-existing environment-only errors unchanged) but **not yet verified against staging Grafana** as of this entry — see the follow-up entry for the deployment/live-verification result, or the `NOT yet verified` line in `12-grafana.md` if that entry doesn't yet exist.
- **Related**: `app/src/grafana_client.py`, `app/src/onboarding/grafana_provisioning_service.py`, `app/src/onboarding/grafana_reconciliation_service.py`, `app/src/templates/organizations.html`, `app/tests/test_grafana_client.py`, `app/tests/test_grafana_reconciliation_service.py`, `app/tests/test_grafana_reconciliation_routes.py`, `app/tests/test_grafana_provisioning_service.py`.
- **Outcome**: Code fixed, tested, documented. Deployed as commit `c40516627588bb671628db0a054de56d29e606b4`, followed by a diagnostic-enrichment commit `7b1ed136f392a4aa2b44754e506468323399ac99` (same day) that added write-response detail — both deployed via the normal `deploy-staging.yml` pipeline.

### 2026-08-25 — Staging credential drift: root-caused, rotated, and ruled out as the sole cause

- **Area**: Grafana ([12-grafana.md](12-grafana.md))
- **What changed**: Rotated `grafana_reader`'s PostgreSQL password and staging `app/.env`'s `EMS_GRAFANA_DB_PASSWORD` to a new, identical, generated value (staging only). No code changes in this entry.
- **Why**: A checksum-only comparison (SHA-256 hash and length only — neither value ever displayed, logged, or committed) proved the running admin-portal container's live password did not authenticate as `grafana_reader`. Investigating the credential-provisioning model found *why*: no script or migration in this repository ever sets `grafana_reader`'s password past the `CHANGE_ME_GRAFANA` placeholder in `postgres/ddl/02_roles.sql`, and `EMS_GRAFANA_DB_PASSWORD` is never validated or kept in sync with it — both were manually, independently set at different times with nothing to prevent drift.
- **Evidence/source**: Live, on the staging host, via SSH — password hash comparison and a real `psycopg` connection attempt run from inside the container both before and after rotation; `ALTER ROLE` executed via the same `docker compose exec ... psql -U ems_admin` mechanism `scripts/apply_migrations.sh` already uses (no new access pattern introduced). Full repository search confirmed no `ALTER ROLE`/`ALTER USER` exists anywhere for any role.
- **Verified live**: Yes — new password confirmed authenticating successfully, twice (immediately after rotation, and again after correcting an intermediate wrong-image deploy — see below). **However, re-running the Meenaxy reconciliation with the new, verified-correct password still failed identically** (`version remained 1`, same HTTP 200 write-response body) — this is direct proof the credential was not the sole, or even primary, cause of the reconciliation failure. Root cause of *that* remains open; see `12-grafana.md` for the leading hypothesis (missing `id` field in the PUT payload) and the operational incident (a wrong-image intermediate deploy, caught and corrected via the existing `rollback.yml` `workflow_dispatch` path).
- **Related**: `postgres/ddl/02_roles.sql` (read, not modified — confirms the unmanaged placeholder), `scripts/bootstrap/02_validate_env.sh` (read, not modified — confirms no validation exists for this credential pair), `.github/workflows/rollback.yml` (used, not modified — the non-code-change redeployment path).
- **Outcome**: Credential drift real and fixed. Reconciliation still fails. The investigation continues — this is documented as an open item, not a resolved one.

### 2026-08-25 — Grafana datasource UPDATE payload: added missing `id`/`orgId` fields (code only, not yet deployed or live-verified)

- **Area**: Grafana ([12-grafana.md](12-grafana.md))
- **What changed**: `app/src/grafana_client.py` — `update_datasource()` now takes a new `existing_datasource_id` parameter and adds `id` (the existing Grafana datasource's numeric ID) and `orgId` (the Grafana organization ID) to the `PUT /api/datasources/uid/ems-timescaledb` payload, on top of the unchanged fields from `_datasource_payload()`. `provision_organization()` passes `datasource.get("id")` from the record it already fetches via `get_datasource_by_uid()` before deciding create vs. update. `create_datasource()` is unchanged — a newly created datasource has no prior numeric ID to send. `app/tests/test_grafana_client.py` updated: all `update_datasource()` call sites updated for the new parameter, a new test pins `id`/`orgId` presence in the update payload, and the create/update payload-parity test now compares only the common fields (previously a full-payload equality, which would otherwise now fail because the update payload legitimately carries two extra fields).
- **Why**: Grafana 11.6's documented request body for the UID-addressed datasource update endpoint includes `id` and `orgId`; the implementation fixed on 2026-08-24/2026-08-25 (create-vs-update branching, then post-write version verification) never included either, because both fixes built the `PUT` payload from `_datasource_payload()` alone. This was flagged as the leading, untested hypothesis in the 2026-08-25 credential-drift entry above.
- **Evidence/source**: Grafana 11.6 API documentation (request body for `PUT /api/datasources/uid/:uid`); code inspection confirming `_datasource_payload()` is shared by `create_datasource()`/`update_datasource()` and intentionally excludes `id`/`orgId` (a newly created datasource has neither).
- **Verified live**: No. This is a payload-contract correction based on Grafana's documented API, not a live-confirmed fix for the specific staging symptom (`version` not advancing, stale `grafana_reader` password on the Meenaxy datasource). Live staging verification — re-running the Meenaxy reconciliation and confirming `version` advances and the datasource health check passes — is still required and has not yet been performed.
- **Related**: `app/src/grafana_client.py`, `app/tests/test_grafana_client.py`.
- **Outcome**: Code fixed and tested locally (`app/tests/test_grafana_client.py`: 19/19 passed; related onboarding/reconciliation test files: 14/14 passed; full suite: 1047/1047 passed against a local disposable test database). Not yet committed to a deployment, not deployed, and the live Meenaxy datasource has not yet been re-verified — per explicit instruction to stop after implementation and tests, pending review before the live PUT.

### 2026-08-25 — Grafana datasource verification: `version`-based check was itself a bug; replaced with a post-update health check (live-verified root cause)

- **Area**: Grafana ([12-grafana.md](12-grafana.md))
- **What changed**: This entry's commit (deployed as `4e2a5e3f765408ce90c25807c82c6eeeda318a18`, confirmed running on staging: `docker inspect` image digest matched CI's pushed digest exactly) was live-verified by running the Meenaxy reconciliation directly via `reconcile_grafana_tenant(portal_user_id=1, organization_id="c4bde6d1-6688-46f0-95df-cdc1a943d17b")` inside the running `ems-admin-portal` container (portal_user_id 1 is the sole active staging portal account, confirmed via `admin.portal_users` through the `ems_admin` DB role, since the app's own DB role has no direct grant on that table). It **failed**: `GrafanaApiError: ... version remained 1 ... Write response was HTTP 200. Body preview: '{"datasource":{"id":1,...}...'` — i.e. the `id`/`orgId` fix from the previous entry did not, by itself, make the reconciliation succeed.
- **Why**: Diagnosing directly on staging (full request/response captured, secrets excluded) showed the PUT's own response body already contained `"message": "Datasource updated"` yet echoed `"version": 1` — Grafana was reporting success while our code's `version`-must-increase gate treated it as failure. To determine which was actually wrong, `pg_stat_activity` was checked (via the `ems_admin` role) immediately after the PUT: it showed a **brand-new** PostgreSQL backend process from `grafana_reader` (~44 seconds old, i.e. opened by Grafana's own connection pool right after the write) that was successfully authenticated and idle. Because PostgreSQL accepts only the single currently-set password for a role, a fresh successful authentication is conclusive: the password Grafana now has stored for this datasource matches the current, independently-verified `EMS_GRAFANA_DB_PASSWORD`. The write **did** take effect; the `version` check was a false negative. Grafana's own HTTP API documentation's example response for this same endpoint independently corroborates this — its sample update response also shows `"version": 1`.
- **Evidence/source**: Live staging investigation via direct SSH access (explicitly authorized this session) — `docker ps`/`docker inspect` for running image verification; a Python script run inside `ems-admin-portal` (via `docker cp` + `docker exec`) using the app's own `GrafanaClient`/`psycopg`/DB-settings to read the datasource, perform the PUT, and check `pg_stat_activity`, printing only non-secret fields (uid/id/orgId/version/database/user/url, a SHA-256 prefix + length of the configured password, and success/failure markers — never the password or a session cookie); `admin.portal_users` queried read-only via `ems_admin` for `portal_user_id`/`is_active` only (no email/PII) after the auto-mode classifier appropriately declined to let this session pick a portal-user identity from the app's own restricted DB role, and the user explicitly authorized a direct, self-determined lookup. Grafana's own HTTP API docs fetched for the same endpoint's example response.
- **Fix**: `app/src/grafana_client.py` — `update_datasource()` no longer takes or checks `previous_version`; after the `PUT` and the existence re-read, it now calls `GET /api/datasources/uid/ems-timescaledb/health` (org-scoped) and raises `GrafanaApiError` unless `status == "OK"`. `create_datasource()` is unchanged. `app/tests/test_grafana_client.py`: replaced the version-based failure regression test with two tests — one pinning failure when the post-update health check reports non-`OK` (the corrected version of the original live-failure regression), one pinning that an unchanged `version` with a healthy check does **not** raise (the false-negative fix); updated the write-response-description and payload-drift tests' fakes to serve a `/health` response; updated `provision_organization()`'s call site and both of its regression tests' fakes for the now-two-argument signature.
- **Verified live**: Yes, for the diagnosis (fresh PostgreSQL session proof, described above). The health-check-based fix itself: tested locally only as of this entry (`test_grafana_client.py` 19/19, onboarding/reconciliation suite 14/14, full suite 1048/1048 against a local disposable test database) — not yet deployed or re-run live. A follow-up entry will record the live re-verification once deployed.
- **Related**: `app/src/grafana_client.py`, `app/tests/test_grafana_client.py`.
- **Outcome**: Root cause of the *reported* reconciliation failure identified and corrected: it was the verification logic, not the datasource write, that was broken. The underlying Meenaxy datasource is, on the evidence gathered here, most likely already healthy even before this fix deploys (the fresh authenticated PostgreSQL session is live proof of that) — but this has not yet been confirmed through the app's own reconciliation path succeeding end-to-end, which requires deploying this fix.
