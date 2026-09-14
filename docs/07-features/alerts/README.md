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
(migration 239; `get_portal_site_alerts`'s date-range filter corrected by
migration 240 — see "Known limitations" below). Backed by `analytics.alerts` + the internal
`analytics.alert_evaluation_candidates` qualification/resolution scratch
table (migration 238), populated by `analytics.run_alert_evaluation_job` —
a TimescaleDB-native background job (ADR-017, A1), the same mechanism
already used by `postgres/jobs/69_environment_routing_job.sql` and its
siblings, registered in `postgres/jobs/238_alert_evaluation_job.sql`.
**Registered on staging 2026-09-14 21:04:04+05:30** (job_id 1127,
explicitly authorized), config confirmed live via
`timescaledb_information.jobs`: 1-minute schedule, 5-minute max runtime,
3 max retries, 1-minute retry period, registered exactly once —
`scripts/verify/verify_jobs.sh`'s new MVP-7 section passed all 6 checks
while the job was enabled. **Registered is not executed is not
lifecycle-validated**: it ran 3 times (21:04:04, 21:05:04, 21:06:04) and
**FAILED every time**, identically — `timescaledb_information.job_errors`:
`sqlerrcode 2D000`, `err_message "invalid transaction termination"` — 3
of 3 runs, 0 successes. **Explicitly authorized: disabled on staging
2026-09-14 21:07:xx** (`SELECT alter_job(1127, scheduled => false)`;
confirmed via `timescaledb_information.jobs.scheduled = false` and, after
waiting past a full schedule interval, `total_runs` unchanged at 3 with
no new `last_run_started_at`) — the job remains **registered** (row
exists, correct config) but is **not currently scheduled to run**.

**Root cause — confirmed by reproduction, precise location identified,
revised from an earlier, incomplete diagnosis (below).** `analytics.evaluate_alerts()`
(migration 239) is declared `SECURITY DEFINER` and
`SET search_path TO pg_catalog, analytics, admin`. PostgreSQL forbids
`COMMIT`/`ROLLBACK` inside a procedure with **either** property, in
**any** calling context — top level or nested. An earlier investigation
pass attributed the failure to nesting alone (`evaluate_alerts()` being
called via `CALL analytics.evaluate_alerts();` from *inside*
`analytics.run_alert_evaluation_job()`) — **that was incomplete**: a
follow-up deep-dive isolated the variables empirically (disposable local
TimescaleDB containers) and found nesting alone is *not* sufficient to
cause the failure (a plain nested `CALL` to a committing procedure with
neither property succeeds); `SECURITY DEFINER` alone, even called at the
true top level, *is* sufficient; the `SET` clause alone, even at the top
level, *is* also independently sufficient. The **specific statement that
actually fails on staging** is the **per-site `COMMIT;` at migration file
line 404** — immediately after the per-site
`BEGIN ... EXCEPTION WHEN OTHERS ... END;` block, inside
`FOR v_site IN ... LOOP`, reached unconditionally on every site. With ≥1
active site (staging has 3), this fires on the very first loop iteration,
well before the retention-DELETE `COMMIT` at line 412 is ever reached.
Deployed `pg_get_functiondef()` output confirmed byte-identical to the
migration 239 source throughout (no drift). Staging's own
`timescaledb_information.job_errors` retains only `sqlerrcode`/
`err_message`, not a `CONTEXT` stack (and these failures are not written
to the PostgreSQL server log at the container's default level) — the
exact statement/line and the `SECURITY DEFINER`/`SET`-clause mechanism
were both established via local reproduction against disposable
TimescaleDB containers running the exact deployed procedure bodies, not
by directly reading a staging stack trace. Neither removed property was
load-bearing: job 1127's `owner` is `ems_admin` (confirmed live,
read-only query) — the same role that owns `evaluate_alerts()` and the
tables it touches, so `SECURITY DEFINER` never actually elevated
privilege on this call path; every table/function reference in the body
is already schema-qualified, so the `SET` clause was not load-bearing for
correctness either. This is a real defect in already-applied migration
239, undetectable by the static contract tests or by testing only the
job-registration script (`add_job`/`alter_job`) in isolation — exactly
the live-execution gap ADR-017/this README already flagged as untested.
It was fully deterministic (3/3 identical failures on real data, further
confirmed by multiple independent local reproductions).

**Fixed by migration 241 (implemented and tested locally; NOT yet
deployed to staging — see "Release status").** `CREATE OR REPLACE PROCEDURE analytics.evaluate_alerts()`
with the exact same body, removing only `SECURITY DEFINER` and the `SET`
clause. `analytics.run_alert_evaluation_job()`, the job registration SQL,
job 1127's registration/configuration (still explicitly disabled), the
alert schema, API contracts, and alert lifecycle semantics are all
unchanged. Verified locally: the real, unmodified `run_alert_evaluation_job()`
→ `evaluate_alerts()` nested-`CALL` path now succeeds against a
disposable TimescaleDB container; a new live-execution integration test
(`scripts/test/assert_mvp7_alert_evaluation_job_executes.sh`) proves this
via `CALL analytics.run_alert_evaluation_job(1, '{}'::jsonb)` against the
CI disposable database, exercising both the retention `COMMIT` (always)
and the per-site `COMMIT` (with a guaranteed fixture site) — see
"Validation" below for full results.

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
database in this environment), `app/tests/test_alert_date_filter_state_keying_contract.py`
(migration 240's static SQL contract), `app/tests/test_alert_evaluation_transaction_control_fix_contract.py`
(migration 241's static SQL contract). Live execution:
`scripts/test/assert_mvp7_alert_evaluation_job_executes.sh` (real
TimescaleDB, not static text). Frontend:
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

**Second same-day corrective fix — migration 240 (date-range state
keying).** `app/tests/test_alert_date_filter_state_keying_contract.py`
(9/9 passed) plus the unaffected 28/28 above (38/38 total). Also verified
functionally against a disposable local TimescaleDB container (not
staging): migrations 238, 239, and 240 applied cleanly in sequence
against stub `metadata.sites`/`spaces`/`assets` tables and an
`admin.portal_user_can_access_site` stub; three fixture alerts (Active
triggered January 2026, Resolved and Ended both triggered in 2025 but
resolved/ended in January 2026) were inserted directly, then
`get_portal_site_alerts` was called with a January-2026 `from`/`to`
range per state — the Resolved and Ended rows were correctly returned
(found via `resolved_at`/`ended_at`, not `triggered_at`), and a control
query with a 2025 range for the Resolved state correctly returned zero
rows (proving the old unconditional-`triggered_at` bug is gone, not just
that the new code compiles).

**Third corrective fix — migration 241 (transaction-control defect,
`SECURITY DEFINER`/`SET search_path` on `evaluate_alerts()`). Implemented
and tested locally; NOT yet deployed to staging.**
`app/tests/test_alert_evaluation_transaction_control_fix_contract.py`
(7/7 passed; static contract, plus the unaffected 38/38 above — 45/45
total). **Live-execution proof, not just static text**: the new
`scripts/test/assert_mvp7_alert_evaluation_job_executes.sh` was run
against the real disposable TimescaleDB test database
(`compose.test.yaml`, not the ad hoc containers used for migrations
238-240's local checks), through the actual deployment path
(`scripts/test/deploy_test_database.sh` +
`scripts/test/apply_test_migrations.sh`, not a hand-built stub schema).
Result: `CALL analytics.run_alert_evaluation_job(1, '{}'::jsonb)`
succeeded with no exception, both as a baseline call (exercising the
retention `COMMIT` unconditionally) and with a fixture active site
present (exercising the per-site `COMMIT` — the exact statement that
failed on staging). The full `scripts/test/run_integration_environment.sh`
suite (all 30+ existing assertions plus this new one, in sequence) passed
end-to-end, exit code 0 — confirming the new assertion's insertion point
and fixture cleanup do not disturb any other test. Migration-apply
idempotency independently confirmed: re-running
`scripts/test/apply_test_migrations.sh` reported
`SKIP 241_mvp7_alert_evaluation_transaction_control_fix (applied)` — the
standard checksum-guard correctly recognizes it as already applied, no
re-execution, no duplicate, no error.

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
- ~~The date-range filter (`from`/`to`) was keyed to triggered time for all
  three tabs.~~ **Fixed by migration 240 (2026-09-14).** ADR-016 decision 48
  specifies resolved time for the Resolved tab and ended time for the Ended
  tab; `analytics.get_portal_site_alerts` (migration 239) filtered
  `triggered_at` unconditionally regardless of `p_state`. Discovered during
  the same-day corrective pass, deliberately deferred rather than editing
  already-applied migration 239. Migration 240 `CREATE OR REPLACE`s the
  function with the same signature/return shape, now keying `p_from`/`p_to`
  on each row's own state (`triggered_at` for ACTIVE, `resolved_at` for
  RESOLVED, `ended_at` for ENDED); the infinite-scroll cursor (`p_before`)
  and ordering remain `triggered_at`-based (a pagination concern, not the
  date-range filter). `analytics.get_portal_alert_detail` was never
  affected — it takes no `p_from`/`p_to` (single-row lookup by
  `alert_id`). Verified functionally against a disposable local
  TimescaleDB container (not staging): a Resolved alert triggered in 2025
  but resolved in January 2026 is correctly returned by a January-2026
  query and correctly absent from a 2025 query — see
  `app/tests/test_alert_date_filter_state_keying_contract.py` for the
  static contract and this session's report for the live local evidence.
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
- ~~`analytics.evaluate_alerts()`'s `COMMIT` statements were illegal
  (SQLSTATE `2D000`), so job 1127 failed on every execution once
  registered on staging.~~ **Fixed by migration 241 — implemented and
  tested locally, NOT yet deployed to staging.** Root cause:
  `SECURITY DEFINER` and a `SET search_path` clause on `evaluate_alerts()`
  (migration 239) — PostgreSQL forbids transaction control inside a
  procedure with either property, in any calling context. Neither was
  load-bearing (job runs as `ems_admin`, the procedure's own owner; every
  reference is schema-qualified) — see "Data / API dependencies" above for
  the full root-cause account and "Validation" below for local test
  evidence. **Staging job 1127 remains explicitly disabled** — this fix
  has not been deployed or executed there.
- **No live database available in this environment (for most of this
  session)** — the SQL migration's
  correctness (beyond static/structural checks and manual review, which
  did catch and fix two real bugs in the lifecycle procedure — a `FOUND`-
  variable scoping error across multiple statements, and an illegal
  COMMIT/ROLLBACK inside a PL/pgSQL block with an EXCEPTION clause, which
  would have failed the job's very first run) has not been exercised
  against a real TimescaleDB instance locally. Relies on the CI "Database
  / migration / repository
  integration tests" job to validate at the SQL execution level before
  this is considered fully proven. (The 2026-09-14 corrective passes did
  exercise `postgres/jobs/238_alert_evaluation_job.sql`'s registration
  mechanics, migration 240's `get_portal_site_alerts` redefinition with
  fixture data, and — via migration 241's live-execution integration test,
  `scripts/test/assert_mvp7_alert_evaluation_job_executes.sh` — that
  `evaluate_alerts()` now *executes* without error, against disposable
  local TimescaleDB containers; see "Validation" above. None of this
  exercises the qualification/resolution/recurrence *timing* semantics
  themselves — proving the procedure runs cleanly is not the same as
  lifecycle-validating what it produces over multiple evaluation cycles.)

## Release status

**IMPLEMENTED, DEPLOYED TO STAGING, STAGING VALIDATION FAILED (2026-09-14).**
Root cause: the alert-evaluation TimescaleDB job was never registered
(deliberately, pending a separate authorized step — see "Known
limitations"), so no alert has ever been generated on staging; the
deployed frontend also had real gaps against ADR-016 decision 11/48
(missing hierarchy context and threshold/reference, reversed Resolved
field order, no Condition/Metric/date-range/Apply-Clear filtering UI;
the date-range filter was also found, separately, to key on
`triggered_at` unconditionally instead of per-tab per ADR-016 decision
48). A same-day corrective pass (branch
`fix/mvp7-alert-job-config-and-adr016-corrections`) fixed the frontend
gaps, the job-registration script's first-registration config defect,
and (migration 240) the date-range keying defect, and added
deployment-verification coverage (`scripts/verify/verify_jobs.sh`) so the
job's registration state is detected automatically on every future
deployment.

**Job explicitly authorized and registered on staging 2026-09-14
21:04:04+05:30** (job_id 1127; correct config confirmed live: 1-minute
schedule, 5-minute max runtime, 3 max retries, 1-minute retry period,
registered exactly once). **Every execution FAILED deterministically**
(3/3 runs, 0 successes) with `invalid transaction termination` — a real,
newly-discovered defect in already-applied migration 239
(`analytics.evaluate_alerts()`'s `COMMIT` statements are illegal because
the procedure is `SECURITY DEFINER` and has a `SET search_path` clause —
see "Data / API dependencies" above for the full root-cause account,
including the correction of an earlier, incomplete "nesting is the cause"
diagnosis). No alert has been or can currently be generated;
`analytics.alerts` remains 0 rows with no partial writes. **Explicitly
authorized: the job was then disabled on staging** (`scheduled = false`,
confirmed live; still registered, config intact; confirmed no further
executions after disabling) **to stop the recurring failures** while root
cause was investigated.

**Migration 241 (the fix) is now implemented and tested locally — it has
NOT been deployed to staging and staging job 1127 remains disabled.**
**MVP-7 is NOT functional, NOT released, and NOT lifecycle-validated.**
Five states, kept distinct and none conflated:
- **Implemented**: yes — migration 241 exists, on branch
  `fix/mvp7-alert-evaluation-transaction-control`, not yet merged.
- **Tested locally**: yes — static contract (7/7) and, critically, a real
  live-execution integration test against the disposable CI-equivalent
  TimescaleDB database (not staging) — see "Validation" above.
- **Deployed**: **no** — migration 241 has not been applied to staging or
  production.
- **Operational**: **no** — staging job 1127 remains explicitly disabled
  (`scheduled = false`); it has not been re-enabled, and it must not be
  re-enabled or claimed to be operational until migration 241 is actually
  deployed and executed there.
- **Lifecycle-validated**: **no** — proving the procedure now *executes*
  without error is not the same as validating what it *produces* over
  real qualification/resolution/recurrence cycles; that broader MVP-7
  lifecycle validation remains deferred pending a working, deployed,
  re-enabled job.

Next required steps, each needing separate explicit authorization: deploy
migration 241 to staging, re-enable job 1127, confirm it executes
successfully there, and only then perform the broader MVP-7 lifecycle
validation.
