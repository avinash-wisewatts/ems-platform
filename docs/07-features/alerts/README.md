# Feature: Alerts

Status: CURRENT · Last reviewed: 2026-09-14 · Owner: Product + Engineering
MVP stage: MVP-7 · Related decisions: [ADR-016](../../00-governance/decisions/ADR-016-q77-mvp7-basic-alerts.md), [ADR-017](../../00-governance/decisions/ADR-017-mvp7-alert-architecture.md), [ADR-010](../../00-governance/decisions/ADR-010-mvp3-attention-materiality-policy.md)

## Purpose

Notify the customer, in-product, of existing Attention conditions that
qualify (persist) for a meaningful period — "the same story Attention
already tells, delivered as a notification" (ADR-016).

## Requirements

[functional-requirements.md §Alerts](../../02-requirements/functional-requirements.md#alerts)
(`EMS-REQ-080`–`084`, `EMS-REQ-117`–`127`).

## User experience

[information-architecture.md §Alerts](../../03-ux-and-design/information-architecture.md);
header Active-alert-count indicator + dedicated Alerts area
(Active/Resolved/Ended tabs, single-select condition filter, date range,
list + detail). In-product only — no email/SMS/WhatsApp/sharing, no
analytical deep links, no customer-facing severity taxonomy.

## Business rules

Full lifecycle per ADR-016: an Attention condition qualifies after 5
continuous minutes true (gap-resetting); an Active alert resolves after 1
continuous minute false (gap-resetting); a configuration change Ends the
existing alert (never Resolves it) and requires fresh qualification under a
new identity; historical records are immutable; Resolved/Ended alerts
retain for 90 days, Active indefinitely; recurrence is derived at read
time from the condition's stable identity, never a stored counter.

## Data / API dependencies

`GET /api/v1/sites/{site_id}/alerts`, `GET /api/v1/alerts/{alert_id}`
(migration 239). Backed by `analytics.alerts` + the internal
`analytics.alert_evaluation_candidates` qualification/resolution scratch
table (migration 238), populated by `analytics.run_alert_evaluation_job` —
a TimescaleDB-native background job (ADR-017, A1), the same mechanism
already used by `postgres/jobs/69_environment_routing_job.sql` and its
siblings, registered in `postgres/jobs/238_alert_evaluation_job.sql`.
**Confirmed by live read-only staging query (2026-09-14): this job is not
registered on staging** — `analytics.alerts` and
`analytics.alert_evaluation_candidates` both exist and are empty (0 rows);
no alert has ever been evaluated. `scripts/verify/verify_jobs.sh` now
checks this job's registration/enablement/schedule/runtime/retry state on
every deployment (reported, non-blocking — see
`scripts/release/post_deploy_verify.sh`), so this state is detected
automatically going forward rather than requiring a manual live query.

**Single source of truth**: `analytics.evaluate_energy_attention_materiality`
(migration 239) is the canonical server-side implementation of the ±15%
Energy Attention rule, replicating `web/src/attention/materiality-policy.ts`
+ `energyAttention.ts` exactly (threshold 15, epsilon `1e-9`). The client
implementation is unchanged and still drives today's MVP-3 display; a
follow-on task (not scheduled) should migrate it to consume the
server-computed result, per ADR-017.

## Architecture

`Alert` is the DDS's 11th core concept, added via the five-criteria
change-control test (ADR-017) — see
[system-architecture.md](../../04-architecture/system-architecture.md) and
`docs/DDS/analytics-platform-future-state-architecture.md` §B.2a.
`analytics.insights` (Phase 14) was explicitly not reused — Attention/
Alerts and Insights remain distinct concepts.

## Scope note — Space/Asset

The only condition that exists is Site-level Energy Attention. Per the
Space/Asset reconciliation (ADR-017), Space/Asset-level Attention is
product-specified (Workshop Q99/Q100, "where supported") but not yet
built — a sequencing dependency, not a contradiction. `analytics.alerts`
reserves `space_id`/`asset_id` columns; nothing populates them today.

## Validation

Backend: `app/tests/test_analytics_api_v1_alerts_routes.py` (route
contract), `app/tests/test_alert_evaluation_contract.py` (static SQL
contract — the lifecycle procedure cannot be exercised without a live
database in this environment). Frontend:
`web/src/routes/alerts/AlertsArea.test.tsx`.

**Staging post-deploy validation (2026-09-14): FAIL.** Live, read-only
verification against the deployed staging revision found: migrations 238
and 239 applied correctly; all five alert functions present; both alert
API endpoints reachable and correctly enforcing `_require_portal_user`
authentication (401 without credentials); but the alert-evaluation
TimescaleDB job was not registered (confirmed by direct query — see "Data
/ API dependencies" above), so no alert has ever been generated, and the
deployed frontend detail view was missing hierarchy context and
threshold/reference and showed resolved fields in the wrong order (ADR-016
decision 11). This is a live-verification result, not an inference from
code — see this session's staging validation report for the full
evidence-rich matrix (deployment revision, migration timestamps, job
listing, API responses).

**Same-day corrective pass**, verified as follows (no staging/production
access): the job-registration script's first-registration config defect
(see "Known limitations" below) was fixed and verified against a
disposable local TimescaleDB container (not staging) — one execution of
the corrected `postgres/jobs/238_alert_evaluation_job.sql` now leaves the
job with the full intended `schedule_interval`/`max_runtime`/
`max_retries`/`retry_period` configuration, confirmed by querying
`timescaledb_information.jobs`; a second execution confirmed the
idempotent path still leaves exactly one job registered. The frontend
fixes were verified by `npx tsc --noEmit` (clean), `npx eslint . --max-warnings 0`
(clean), the full frontend suite (`npx vitest run`: 218/218 passed across
32 files, including 4 new/updated MVP-7 tests), and `npm run build`
(clean). Backend: `test_alert_evaluation_contract.py` and
`test_analytics_api_v1_alerts_routes.py` (28/28) unaffected and still
passing (no backend Python code changed this pass).

## Known limitations / deviations (this implementation pass)

- **No executable cross-language parity harness** between the SQL
  materiality function and the TypeScript implementation — ADR-017 names
  this as a required precondition; only static/structural checks exist so
  far (see `test_alert_evaluation_contract.py`'s own header comment).
- **Evaluation period = most recent completed site-local calendar day**
  ("yesterday"), not "today so far" — a consequence of the existing
  whole-day constraint on `analytics.get_portal_site_energy_typical_reference`
  (already documented by ADR-015), not a new product decision. Not
  explicitly specified by ADR-016; flagged, not silently assumed.
- **No live "latest value" re-fetch** in the detail view (ADR-016 decision
  34) — only persisted trigger/resolved values are shown.
- **Space/Asset cascading filters are not implemented** — no Space/Asset
  condition exists yet to filter by.
- **The date-range filter (`from`/`to`) is keyed to triggered time for all
  three tabs.** ADR-016 decision 48 specifies resolved time for the
  Resolved tab and ended time for the Ended tab;
  `analytics.get_portal_site_alerts`/`get_portal_alert_detail` (migration
  239) filter `triggered_at` unconditionally regardless of `p_state`.
  Discovered during the 2026-09-14 corrective pass; not fixed there because
  it requires a new migration to an already-applied SQL function (a
  backend/schema change, not a frontend one) — flagged for separate
  authorization, not silently left inconsistent with ADR-016.
- **"Load more" is button-triggered, not scroll-triggered** — the
  no-traditional-pagination substance of ADR-016 decision 47 is preserved;
  the trigger mechanism is simplified.
- **Header indicator count is capped at 200** (a single list call)
  rather than an exact unbounded count — immaterial given MVP-7 has only
  one possible alert per site today, but not exact in principle.
- **The TimescaleDB job itself requires a separate, manual application on
  staging/production** — `scripts/apply_migrations.sh` (the incremental
  deploy pipeline) selects files exclusively from
  `postgres/restructure_manifest.csv`'s `target_category=migration` rows,
  never by listing `postgres/migrations/` directly, and never reads
  `target_category=jobs` rows at all; `postgres/jobs/*.sql` registrations
  are applied only by `scripts/deploy_database.sh` (fresh-bootstrap only —
  used both for a real fresh install and by CI's disposable test
  database), the same as every other existing job file. **Two genuine
  deployment gaps were caught in this pass, in opposite directions**: (1)
  migrations 238/239 were entirely absent from the first staging deploy's
  own migration list (not SKIP, not APPLY — silently never selected)
  because they had not yet been added to the manifest — fixed by adding
  `migration`-category rows, regression-guarded by
  `test_migrations_are_registered_in_the_deploy_manifest`; (2) a
  `jobs`-category manifest row was then added for the job registration
  file and immediately broke CI — the fresh-bootstrap phase
  (`scripts/deploy_database.sh`) runs BEFORE the migration-application
  phase and builds from `postgres/ddl/`'s periodically-consolidated
  snapshot, which has never been updated past migration ~237, so
  registering a job whose function only migration 239 creates failed with
  "function ... does not exist" — fixed by removing that row (it has zero
  effect on real deployment either way, since `apply_migrations.sh` never
  reads it), regression-guarded by
  `test_job_registration_is_deliberately_not_in_the_manifest`. Migrations
  238/239 (schema, functions) are applied by the normal pipeline once
  registered; **the job registration
  (`postgres/jobs/238_alert_evaluation_job.sql`) itself still requires a
  separate, explicitly-authorized manual step against the live database**
  — not performed in this pass or in the 2026-09-14 corrective pass that
  followed, consistent with this repository's staging-safety practice
  (`CLAUDE.md` §4) and prior precedent in this project. **Confirmed by live
  staging query (2026-09-14): the job is not registered and no alert has
  ever been evaluated on staging.**
- **First-registration config defect in
  `postgres/jobs/238_alert_evaluation_job.sql`, fixed 2026-09-14 (before the
  job has ever been registered anywhere).** `add_job()` has no
  `max_runtime`/`max_retries`/`retry_period` parameters (TimescaleDB API) —
  only `alter_job()` does. The original file set these only in its
  `ELSE`/`alter_job` branch (mirroring every sibling routing-job file in
  `postgres/jobs/`), so a job's true first registration would have silently
  run under TimescaleDB's own defaults until the file was executed a second
  time. The `IF` branch now calls `alter_job()` immediately on the job
  `add_job()` just created, so the intended configuration applies from the
  very first registration. Verified against a disposable local TimescaleDB
  container (not staging): one execution leaves
  `schedule_interval=1min, max_runtime=5min, max_retries=3,
  retry_period=1min` fully applied; a second execution confirms the
  `ELSE`/`alter_job` idempotent path still leaves exactly one job
  registered. The sibling routing-job files (`42_*`, `48_*`, `69_*`, `70_*`,
  `74_*`) have the same first-registration gap and were **not** touched by
  this pass (out of scope — flagged, not silently fixed).
- **No live database available in this environment** — the SQL migration's
  correctness (beyond static/structural checks and manual review, which
  did catch and fix two real bugs in the lifecycle procedure — a `FOUND`-
  variable scoping error across multiple statements, and an illegal
  COMMIT/ROLLBACK inside a PL/pgSQL block with an EXCEPTION clause, which
  would have failed the job's very first run) has not been exercised
  against a real TimescaleDB instance locally. Relies on the CI "Database
  / migration / repository
  integration tests" job to validate at the SQL execution level before
  this is considered fully proven. (The 2026-09-14 corrective pass did
  exercise `postgres/jobs/238_alert_evaluation_job.sql`'s registration
  mechanics specifically against a disposable local TimescaleDB container —
  see "Validation" above — but this covers only `add_job`/`alter_job`
  behavior, not `analytics.evaluate_alerts()`'s lifecycle logic.)

## Release status

**IMPLEMENTED, DEPLOYED TO STAGING, STAGING VALIDATION FAILED (2026-09-14).**
Root cause: the alert-evaluation TimescaleDB job was never registered
(deliberately, pending a separate authorized step — see "Known
limitations"), so no alert has ever been generated on staging; the
deployed frontend also had real gaps against ADR-016 decision 11/48
(missing hierarchy context and threshold/reference, reversed Resolved
field order, no Condition/Metric/date-range/Apply-Clear filtering UI). A
same-day corrective pass (branch
`fix/mvp7-alert-job-config-and-adr016-corrections`) fixed the frontend
gaps and the job-registration script's first-registration config defect,
and added deployment-verification coverage
(`scripts/verify/verify_jobs.sh`) so the job's registration state is
detected automatically on every future deployment. **Not yet
re-validated**: the job registration step itself and a follow-up staging
validation pass both remain outstanding, each requiring separate explicit
authorization before this feature can be considered functional on
staging. MVP-7 must not be represented as functional until both have run.
