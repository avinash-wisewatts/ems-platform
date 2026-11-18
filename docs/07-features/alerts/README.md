# Feature: Alerts

Status: CURRENT · Last reviewed: 2026-11-18 (ADR-024 rule-based alerts LIVE ON STAGING `e627298`, not on production; Phase 0 alignment + read-only staging baseline; sections below "Staging baseline" are the 2026-09-14/15 implementation record, kept as history) · Owner: Product + Engineering
MVP stage: MVP-7 (legacy, **retired on staging 2026-11-18**, still live on production) → replaced by ADR-024 customer-configurable rules · Related decisions: [ADR-016](../../00-governance/decisions/ADR-016-q77-mvp7-basic-alerts.md), [ADR-017](../../00-governance/decisions/ADR-017-mvp7-alert-architecture.md), [ADR-010](../../00-governance/decisions/ADR-010-mvp3-attention-materiality-policy.md), [ADR-024](../../00-governance/decisions/ADR-024-customer-configurable-alert-rules.md) (customer-configurable rules, acknowledgement — decided and implemented 2026-11-18; on staging, not production)

## Purpose

**Current product (ADR-024 — on staging since 2026-11-18, production pending approval):** notify the
customer, in-product, when an alert rule configured for one of their
assets is breached for a meaningful period — rules are configured by the
site's administrators in the EMS Web App ([ADR-024](../../00-governance/decisions/ADR-024-customer-configurable-alert-rules.md)).
This **replaces MVP-7 Basic Alerts entirely**.

*Legacy (running on staging, to be retired by the replacement release):*
notify the customer of existing Attention conditions that qualify
(persist) for a meaningful period — "the same story Attention already
tells, delivered as a notification" (ADR-016). Its UI, ±15% evaluator,
scheduled job and records are retired and deleted (§ "Legacy retirement"
below); the Energy Attention **display** on Site Overview, Main Dashboard
and the Site Performance Report is not affected.

## Requirements

[functional-requirements.md §Alerts](../../02-requirements/functional-requirements.md#alerts)
(`EMS-REQ-080`–`084`, `EMS-REQ-117`–`127`; customer-configurable rules
`EMS-REQ-082`, `EMS-REQ-140`–`152`).

## User experience

[information-architecture.md §Alerts](../../03-ux-and-design/information-architecture.md).
*Legacy UI (to be replaced entirely — no legacy view is retained):*
header Active-alert-count indicator + dedicated Alerts area
(Active/Resolved/Ended tabs, single-select condition filter, date range,
list + detail). In-product only — no email/SMS/WhatsApp/sharing, no
analytical deep links, no customer-facing severity taxonomy.
*(2026-11-18: still in-product only for delivery; ADR-024 adds Email and
WhatsApp only as "Coming Soon" placeholders that send nothing.)*

## Customer-configurable alert rules (ADR-024) — on staging 2026-11-18, not on production

Implemented by PR #179 (squash `e627298`, migrations 320–326) and
deployed to staging 2026-11-18 (`deploy-staging` run 44282502005,
`deploy-customer-api` run 44284913192). Design:
[phase-1-technical-design.md](phase-1-technical-design.md) (approved; the
evaluator reads the live-value cache, see its implementation note); plan:
[phase-1-implementation-plan.md](phase-1-implementation-plan.md).
Production: [prepared plan](../../09-release-and-deployment/production-release-alerts-adr-024.md),
not approved.

**Staging release record (2026-11-18).**

- Migration 320 deleted **79** legacy alerts (ENDED 76, ACTIVE 2,
  RESOLVED 1) and **0** candidates, removed job **1127**; recorded in
  `admin.migration_outcomes`. New evaluator job **1143** (every minute).
- Evaluator (134 runs to 18:06 IST): mean 51 ms, p95 45 ms, 0 failures;
  the first two runs after the deploy took 926 ms and 1,810 ms (cold, 0
  rules), every later run ≤ 104 ms. Observation pass at 75 rules: 16.5 ms
  (read-only measurement). Host after acceptance: 724 MiB available of
  1.9 GB, disk 57%.
- Acceptance (database functions as `ems_app`, actor `admin_avinash`,
  rules named "ADR-024 acceptance - …", Coimbatore): validation refusals
  (equal-to without tolerance, duplicate name ignoring case, stale
  version); counters absent from eligible parameters; real qualification
  (Freezer > 1 kW, Chiller1 > 10 kW); stale point counted unavailable with
  no alert; acknowledgement shown as "WiseWatts Support", stored as staff,
  second acknowledgement refused; natural resolution when the freezer
  compressor cycled off; edit ended the Active alert with
  CONFIGURATION_CHANGED and kept the history snapshot; disable / re-enable
  (version bump); history and detail views; every write audited
  `WISEWATTS_STAFF`, older audit rows untouched; overnight schedule
  (18:00–06:00) started watching at the first run after 18:00 and qualified
  18:05:55. Clean-up 18:06 IST: all acceptance rules soft deleted (plus a
  temporary rule proving a deleted name is reusable); no visible rules, no
  Active alerts; the 4 occurrences remain in History marked
  `rule_deleted`.
- Browser path: a signed-in `admin_avinash` session used the deployed
  web app through the customer API during acceptance (Active, History,
  rules and parameter reads, and `POST …/disable` on the stale-pump rule —
  all 200, audited `WISEWATTS_STAFF`). Second freezer occurrence
  qualified 17:45:55 unacknowledged (acknowledgement does not carry over).
- Not exercised on staging: customer, operator and viewer roles (no such
  active users on staging); a telemetry gap during an Active alert; the
  90-day purge (covered by automated tests).
- **Known defect D-1 (timing):** qualification takes 5–6 minutes and
  resolution 1–2 minutes instead of exactly 5 and 1, because the
  once-a-minute runs start a few milliseconds either side of 60 s apart and
  the `since <= now - interval` test then waits one extra run. Recorded
  times are correct. Fix: a small grace in the two comparisons (new
  migration).
- **Observation D-2 (product decision):** an alert's "previous
  occurrences" count only occurrences of the same rule *version*
  (`condition_key` = `RULE:<id>:v<version>`). An edit resets the count
  (condition changed); a plain disable / re-enable also resets it,
  because re-enabling bumps the version. Seen on staging: the freezer's
  second occurrence (17:39:55) showed 0 previous after the 17:28
  disable / re-enable.

Full record: [ADR-024](../../00-governance/decisions/ADR-024-customer-configurable-alert-rules.md).
Supersedes the earlier "configuration stays in the Administration App
(Q67)" and "no acknowledgement" decisions for alerts, and **replaces the
MVP-7 Energy Attention alerts entirely** (ADR-024 §17).

- **Screens.** Alerts gains an Active Alerts view (Name, Asset, Status,
  Acknowledge; detail with triggered time, triggering condition, asset,
  parameter, threshold/value, status, acknowledgement), a **Create
  Alert** subtab (rule list with Name, Asset, Parameter, Value/condition,
  enabled toggle, Edit, Delete; Create New Alert) and a read-only
  **Resolved/Ended history** (last 90 days, including occurrences of
  deleted rules).
- **Permissions.** View = every authorised user of the site. Configure
  (create, edit, enable/disable, delete) = **customer site administrators
  and WiseWatts `GLOBAL` `ADMIN` staff** (new dedicated permission,
  `ADMIN`). Acknowledge = **those administrators, customer operators and
  WiseWatts `GLOBAL` `OPERATOR` staff** (`alert.acknowledge`); operators
  cannot configure. Staff act on any
  customer site with no additional support authorisation for now; a
  WiseWatts `GLOBAL` `VIEWER` is read-only.
  Enforced at the API route and in the database function;
  `dashboard.view` alone never authorises a write.
- **Rule.** One site, one asset, one parameter available for that asset;
  greater than / less than / equal to (explicit tolerance in the
  parameter's unit, no default; not offered for cumulative counters);
  fixed value first, mean over a configurable window in a later
  increment; schedule = daily time range + every day or weekdays, in the
  site's timezone; reminder frequency; Email/WhatsApp preferences (Coming
  Soon); enabled flag. At most 25 active rules per site (subject to
  staging performance validation).
- **Lifecycle.** 5 minutes continuously true → Active (inside the
  schedule window only); 1 minute continuously false on valid data →
  Resolved; telemetry unavailable → stays Active, keeps its
  acknowledgement, shows "data unavailable", evaluation resumes on valid
  data (never Ended `DATA_UNAVAILABLE`); edit, disable or delete while
  Active → Ended `CONFIGURATION_CHANGED`; schedule close never resolves or
  ends an Active alert; soft delete keeps every historical occurrence
  (90-day retention for Resolved/Ended occurrences).
- **Acknowledgement is not resolution.** It records who and when, stops
  reminders, and leaves the alert Active until its condition resolves or a
  configuration change ends it; telemetry unavailability does not remove
  it. "Acknowledged" is an attribute, not a fourth state.
- **Delivery and reminders.** Nothing is sent in this release: no email,
  no WhatsApp, no reminder, no delivery status. Reminder generation and
  any delivery channel are later phases.
- **Write path.** EMS Web App → customer API (dedicated permission,
  same-site JSON only) → SECURITY DEFINER function (re-checks permission,
  site, asset, parameter) → change + `admin.audit_events` row in one
  transaction, recording the actual acting user and whether it was a
  customer user or WiseWatts staff. Evaluation is server-side, bounded,
  set-based and monitored, with the 25-rule per-site limit and a staging
  performance check before release.

### Legacy retirement (ADR-024 §17–§20) — decided, not executed

Nothing has been deleted, disabled or changed; the legacy mechanism is
still running on staging (baseline below).

| Legacy component | Disposition |
|---|---|
| TimescaleDB job running `analytics.run_alert_evaluation_job` (job 1127 on staging; production unknown — registered manually) | **Retire** in the retirement migration, located by procedure name; absent is not an error |
| `postgres/jobs/238_alert_evaluation_job.sql` | **Retire** — removed so it cannot be re-registered |
| `analytics.run_alert_evaluation_job`, `analytics.evaluate_alerts()`, `analytics.evaluate_energy_attention_materiality` | **Retire** — no other caller (verified); the ADR-010 client Attention does not use them |
| Legacy `analytics.alerts` rows (`ENERGY_ATTENTION:…`) and `analytics.alert_evaluation_candidates` rows | **Delete** — legacy only |
| `analytics.alerts` table / constraints / unique index | **Reuse (recommended)** for rule-based occurrences, extended in Phase 1, with a guard against legacy-shaped rows; or replace — Phase 1 design |
| `analytics.alert_evaluation_candidates` table | Reuse or replace for rule timers — Phase 1 design. Its gap-reset timers are reusable; its "still material on recovery → Ended" branch is not (ADR-024 §4A) |
| `get_portal_site_alerts` / `get_portal_alert_detail`, `/api/v1/sites/{site_id}/alerts`, `/api/v1/alerts/{alert_id}`, `AlertSummary` | **Replace** with rule-aware contracts (re-grant after DROP/CREATE, guarded for production where `ems_customer_api` is absent) |
| `AlertsArea.tsx`, legacy `Alert` types and endpoints | **Replace** with Active Alerts / Create Alert |
| `useActiveAlertCount`, nav entries, `/features/alerts` route | **Reuse** for rule-based alerts |
| `verify_jobs.sh` MVP-7 section, legacy alert tests and `assert_mvp7_alert_*` scripts | **Replace/retire** with the objects they test — never weakened |
| Migrations 238–242 and their ledger rows | **Keep** — history is never edited; retirement is a forward migration |
| ADR-010 Attention (`web/src/attention/*`), `analytics.energy_consumption_daily`, typical-reference read | **Keep** — not part of the alerting layer |

**Retirement migration (proposed scope, ADR-024 §20):** explicitly listed
in `postgres/migration_environment_scope.csv` as `staging|production|test`;
pre-check that every row classifies as legacy or rule-based (abort
otherwise) → remove the legacy job(s) and retire the legacy procedures →
delete legacy candidates, then legacy alerts (`condition_key LIKE
'ENERGY_ATTENTION:%'` and `metric = 'ENERGY_CONSUMPTION'` and no rule
reference) → constraint against legacy-shaped rows → record per-table and
per-state counts durably and in the release record → post-check.
Staging deletes in the replacement release; production deletes
automatically within the separately approved production deployment of the
same replacement, never ahead of it. For scale: staging held 79 legacy
alert rows (2 ACTIVE, 1 RESOLVED, 76 ENDED) and 0 candidates on
2026-11-18; the count at release time will differ (one new ENDED row per
site per day; 90-day retention ageing). Production counts were not
checked.

## Staging baseline (2026-11-18)

Read-only checks against staging on **2026-11-18 03:56–03:57 UTC
(09:26–09:27 IST; staging DB `TimeZone` = Asia/Kolkata)**. Each psql
session was forced read-only (`default_transaction_read_only=on`,
`statement_timeout=30 s`, `lock_timeout=2 s`); host checks used `free`,
`df`, `uptime`, `nproc` and `docker stats --no-stream` only. Nothing was
changed. Production was not accessed. **[V]** = verified live; **[I]** =
inferred from repository code.

**Job 1127 [V]** — `analytics.run_alert_evaluation_job`, owner
`ems_admin`, `scheduled = true`, schedule 1 minute, max runtime 5 min,
3 retries, 1-minute retry period. `job_stats`: last run started
09:27:04 IST, finished successfully (`last_run_status = Success`,
duration 0.059 s), `job_status = Scheduled`, next start 09:28:04 IST;
`total_runs` 91,040 / `total_successes` 91,036 / `total_failures` 3.
`timescaledb_information.job_errors` holds **0** rows for the job — the 3
failures are the 2026-09-14 pre-migration-241 failures recorded above,
whose error rows have since aged out **[I]**. No stall: evaluation runs
every minute and `analytics.alerts.last_evaluated_at` for Active rows is
the current minute.

**`analytics.alerts` [V]** — 79 rows, all `ENERGY_ATTENTION` condition
keys, 2 sites, `asset_id` never populated:

| State | Rows | Notes |
|---|---|---|
| ACTIVE | 2 | one per site, both triggered 2026-11-18 00:23:04 IST; `data_unavailable = false` |
| RESOLVED | 1 | triggered 2026-09-23 00:23 IST, last evaluated 2026-09-26 — a real Active → Resolved transition (the resolution case the 2026-09-14 validation could not observe) |
| ENDED | 76 | **all** `ended_reason_code = DATA_UNAVAILABLE`; triggered 2026-09-14 → 2026-11-17 across 42 distinct days; none `CONFIGURATION_CHANGED` |

`analytics.alert_evaluation_candidates`: 0 rows.

**Daily Ended/re-trigger churn [V pattern / I mechanism].** For both
sites, each day's Active alert is Ended `DATA_UNAVAILABLE` at ~00:23 IST
and a new Active alert is created with `triggered_at` equal to that same
instant (e.g. 2026-11-17 00:23:04 → Ended 2026-11-18 00:23:04, next alert
triggered 2026-11-18 00:23:04). Mechanism from the migration 242 code:
the evaluator judges the most recently completed site-local day; after
midnight the new "yesterday" has no daily energy yet, so the Active alert
is flagged `data_unavailable`; when that day's data lands (~00:23) and is
still material, ADR-016 §4 Ends the old alert and starts a fresh
qualification whose `triggered_at` is the recovery observation. This is
the decided §4 behaviour working as specified, but it means an Energy
Attention alert never survives a site-local midnight — relevant to
acknowledgement (an acknowledgement would be lost daily) and to rule
alerts on live telemetry. Resolved for rule-based alerts by ADR-024 §4A
(they keep the Active occurrence and its acknowledgement); Energy
Attention alerts are retired and their records deleted by the replacement
release (ADR-024 §17), so the question no longer arises (former T-1).

**Migration ledger [V]** — `admin.schema_migrations`: 191 rows, head
`319_portal_user_audit_history_read`. All **76** repository migration
files numbered 238–319 on `origin/staging` `8abd023` are in the ledger;
none missing, no extra ledger rows in that range. 238/239 applied
2026-09-14 19:12 IST, 240 20:35, 241 22:29, 242 2026-09-15 14:59 (all
`applied`). Production's ledger was **not** checked (outside this
authorisation).

**Host headroom [V]** — 2 vCPU; load average 0.93 / 0.50 / 0.41; memory
1,905 MiB total, 1,160 used, 122 free, **745 MiB available**; swap 288 of
2,047 MiB used; `ems-timescaledb` container 939 MiB; root disk 96 G,
54 G used, **43 G available (57 %)**; uptime 8 days 22 h, all eight
containers up (healthy where a health check exists). Memory is the
binding constraint for evaluator work — see the 2026-10-09 read-query
crash lesson; any rule evaluator must stay small, bounded and indexed.

## Open technical questions

Product decisions in ADR-024 are not reopened here. Status after the
final Phase 0 Product Owner decisions (2026-11-18):

| # | Question | Status |
|---|---|---|
| T-1 | Data-unavailable recovery vs. acknowledgement | **Resolved** (ADR-024 §4A, `EMS-REQ-150`): the Active occurrence and its acknowledgement are preserved, evaluation resumes on valid data, Resolved only when confirmed clear. The former Energy Attention residual is gone — those alerts are retired (ADR-024 §17). |
| T-2 | Equality tolerance | **Resolved** (ADR-024 §5): explicit tolerance in the parameter's unit, required, no default of any kind; "equal to" not offered for cumulative counters initially. *Phase 1 detail:* which metadata identifies a cumulative counter (`config.energy_register_semantics` / `PULSE_COUNT` vs. catalogue category). |
| T-3 | Who counts as a site administrator | **Resolved** (ADR-024 §2): customer `ADMIN` with scope covering the site, plus WiseWatts `GLOBAL` `ADMIN` staff on any customer site, no additional support authorisation for now; every action audited with customer-vs-staff actor type. `GLOBAL` `VIEWER` is read-only (decided). `GLOBAL` `OPERATOR` acknowledges on any customer site, cannot configure (decided 2026-11-18). **Closed.** |
| T-4 | Evaluator source and limits | **Partly resolved**: at most 25 active rules per site (subject to staging validation); bounded, set-based, monitored evaluation (ADR-024 §13). *Open, Phase 1 design:* which read supplies the current value (live-state cache vs. 1-minute tier), when telemetry counts as unavailable, and the job runtime budget — proven by staging performance checks. |
| T-5 | Production path | **Open, not a Phase 1 blocker**: `ems_customer_api` (migration 313) and customer-api exist on staging only; on production `/api/v1` is served by admin-portal as `ems_app`. Grants and migration scope are decided at production-release time. |
| T-6 | DDS classification | **Approved 2026-11-18** — rules and occurrences remain within the existing `Alert` DDS concept. **Closed**; no longer a Phase 1 entry condition. |
| T-7 | Legacy replacement details | **Resolved 2026-11-18**: rule-based history retained 90 days; the UI includes a Resolved/Ended history view (ADR-024 §8, §11; `EMS-REQ-152`). Deletion of legacy records is decided (ADR-024 §17–§20). **Closed.** |

## Business rules

*(Legacy MVP-7 Energy Attention alert behaviour — superseded by
ADR-024 and kept as history; the current rule-based behaviour is in
"Customer-configurable alert rules" above.)*

Full lifecycle per ADR-016: an Attention condition qualifies after 5
continuous minutes true (gap-resetting); an Active alert resolves after 1
continuous minute false (gap-resetting); historical records are immutable;
Resolved/Ended alerts retain for 90 days, Active indefinitely; recurrence
is derived at read time from the condition's stable identity, never a
stored counter. Ended has exactly two causes (ADR-016 §4/§7/§8, the
second added by the 2026-09-15 amendment — **implemented and locally
tested (migration 242); not yet deployed to staging/production** *(superseded:
242 applied on staging 2026-09-15 14:59 IST and producing
`DATA_UNAVAILABLE` Ended rows — see "Staging baseline (2026-11-18)")*, see
"Known limitations"): a configuration change, or
an Active alert recovering from a data-unavailable gap while its
condition is still material. Either cause Ends the existing alert (never
Resolves it) and requires fresh qualification under a new identity —
recovering while the condition is **no longer** material still follows
the original, already-implemented normal resolution path instead.

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
+ `energyAttention.ts` exactly (threshold 15, epsilon `1e-9`).
**Classification parity between the two is now confirmed by an executable
12-fixture harness (12/12 pass on both sides)** — see "Known limitations"
below for the one documented, harmless numeric-representation asymmetry it
found (`NUMERIC` vs. IEEE-754 `double`; classification unaffected). The
client implementation is unchanged and still drives today's MVP-3 display;
a follow-on task (not scheduled) should migrate it to consume the
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
`SECURITY DEFINER`/`SET search_path` on `evaluate_alerts()`). Implemented,
tested locally, deployed to staging (PR #61), and job 1127 re-enabled and
confirmed executing successfully there — see "Release status" below for
the live post-deployment/post-re-enable evidence.**
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

- **ADR-016 §4 (data-unavailable-while-Active) messaging and the
  recovery-while-still-material Ended transition: IMPLEMENTED and locally
  tested (migration 242, 2026-09-15). NOT YET deployed to staging/
  production; NOT YET observed against real data.** A read-only
  investigation traced the then-deployed `analytics.evaluate_alerts()`
  (migration 239/241) and found: (a) the "remains Active during a gap"
  half was correctly implemented, but the required customer messaging
  ("Unable to evaluate — data unavailable" / "Latest value: Data
  unavailable") did not exist at any layer; (b) recovery while the
  condition is still material silently continued the same Active row with
  no fresh qualification, contradicting the original decision text (found
  ambiguous about the required end state — see ADR-016's 2026-09-15 §4/§7
  amendment). A three-option product decision (Resolved / Ended / new
  fourth state) was presented without a recommendation; **Ended was
  selected**, with a controlled (`CONFIGURATION_CHANGED` /
  `DATA_UNAVAILABLE`) reason code, not free text.
  **Migration 242** adds `analytics.alerts.data_unavailable` /
  `ended_reason_code` (DB-enforced enum), extends `evaluate_alerts()` with
  the flagging and Ended-transition logic, and extends
  `get_portal_site_alerts`/`get_portal_alert_detail` to return both
  columns; the frontend (`AlertsArea.tsx`) renders the required messaging
  and a controlled reason-label mapping. **Tests, all passing**: 16 static
  SQL contract assertions
  (`app/tests/test_mvp7_alert_data_unavailable_lifecycle_contract.py`), a
  live-execution lifecycle test against a disposable TimescaleDB instance
  (`scripts/test/assert_mvp7_alert_data_unavailable_lifecycle_executes.sql`
  — the full qualify → Active → data-unavailable → recovery → Ended →
  fresh-qualification → new-Active sequence, plus a negative/guard
  scenario for recovery-while-not-material), extended API route tests (13
  total) and frontend tests (11 total, `tsc`/`eslint` clean). **The live-
  execution test caught a real, previously-latent PL/pgSQL defect** in the
  exact pattern migration 239/241 already used
  (`v_active_alert := NULL;` on a bare `RECORD` variable, which reverts it
  to PostgreSQL's "not yet assigned" state) — never triggered before
  because that branch was unreachable; fixed in both the pre-existing and
  the new branch by a safe zero-row `SELECT * INTO ... WHERE FALSE`
  instead. See ADR-016 §4/§7 and [ADR-017](../../00-governance/decisions/ADR-017-mvp7-alert-architecture.md)
  for the full record.
- ~~No executable cross-language parity harness between the SQL materiality
  function and the TypeScript implementation.~~ **Built and passing (later
  pass, see ADR-017 §"A1 — Single-source-of-truth arrangement," item 3).**
  `scripts/test/assert_energy_attention_materiality_parity.sql` (12
  fixtures, run only against the disposable `compose.test.yaml`/
  `timescaledb-test`/`ems_test` database) and
  `web/src/attention/materialityParity.test.ts` (same 12 fixtures, the
  real `evaluateEnergyAttention`) both pass 12/12. One fixture
  (`FLOAT_NOISE_REALISTIC_HIGH`, the `e64c1e3` regression case) surfaced a
  real, previously-undocumented asymmetry — SQL's `NUMERIC` arithmetic
  computes an exact `15.0` for a pair TypeScript's IEEE-754 `number`
  computes as `14.999999999999988` — but **both classify `HIGH`**; this is
  expected numeric-representation asymmetry between a decimal and a
  binary-floating-point pipeline, not classification drift. The parity
  requirement is classification/decision parity (same verdict for the same
  `(current, typical)` pair), not bit-identical intermediate arithmetic.
- **ADR-016 §8 (Configuration-change transitions, ACTIVE → ENDED):
  NOT YET TESTED / NOT CURRENTLY TESTABLE, not VERIFIED.** The
  ACTIVE → ENDED transition logic exists in `analytics.evaluate_alerts()`
  (migration 239: an Active alert's stored `condition_key` is compared
  against the freshly-evaluated one; a mismatch sets `state='ENDED'`), and
  the simultaneous configuration-change-plus-condition-clearing precedence
  (Ended, not Resolved) is structurally implemented — this check runs
  unconditionally before the resolution path can begin. However, Attention
  configuration is currently **static/hardcoded** (threshold `15` fixed in
  both SQL and TypeScript source; no config table, Admin Portal page, or
  API exists to change it) — so `condition_key` can never actually change
  for a live site, and this branch is **unreachable in normal operation
  today**, exactly as its own inline comment states. Existing tests
  (`test_alert_evaluation_contract.py`, `test_analytics_api_v1_alerts_routes.py`)
  provide only static string-presence / router-level mock-fixture
  coverage, never executing the real `condition_key`-diff logic — no
  executable lifecycle coverage exists either. Closing this gap requires
  building a real Attention configuration mechanism first — a
  product/architecture scope addition, not a test-data or staging
  limitation.
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
  registered on staging.~~ **Fixed by migration 241 — implemented, tested
  locally, deployed to staging (PR #61), and confirmed working under real
  execution.** Root cause: `SECURITY DEFINER` and a `SET search_path`
  clause on `evaluate_alerts()` (migration 239) — PostgreSQL forbids
  transaction control inside a procedure with either property, in any
  calling context. Neither was load-bearing (job runs as `ems_admin`, the
  procedure's own owner; every reference is schema-qualified) — see "Data
  / API dependencies" above for the full root-cause account. **Staging job
  1127 was explicitly re-enabled and confirmed executing successfully**
  (`job_stats.last_run_status = 'Success'`; `job_errors` shows zero new
  rows since re-enabling) — see "Release status" below for the full live
  evidence. MVP-7's broader lifecycle behavior remains unvalidated.
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

> **Current (2026-11-18, read-only):** migrations 238–242 applied on
> staging; job 1127 enabled and succeeding every minute; 2 Active /
> 1 Resolved / 76 Ended alerts — see
> [Staging baseline (2026-11-18)](#staging-baseline-2026-11-18). The
> account below is the 2026-09-14 record, kept as history. Production
> state was not checked in Phase 0. **This whole legacy mechanism is to be
> retired and its records deleted by the ADR-024 replacement release**
> (see "Legacy retirement" above).

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

**Migration 241 (the fix) is deployed to staging (PR #61, revision
`a533773`) and job 1127 has been explicitly authorized, re-enabled, and
confirmed executing successfully there — 2026-09-14.**
**MVP-7 is still NOT functional as a released customer feature and is
NOT lifecycle-validated.** Four states, kept distinct and none conflated:
- **Registered**: yes — job 1127, config unchanged throughout (1-minute
  schedule, 5-minute max runtime, 3 max retries, 1-minute retry period),
  confirmed live post-deployment and again post-re-enable.
- **Enabled**: yes — explicitly authorized and re-enabled
  (`SELECT alter_job(1127, scheduled => true)`) 2026-09-14; confirmed live
  (`scheduled = true`) immediately after.
- **Executed successfully**: yes — confirmed directly, not inferred.
  `timescaledb_information.job_stats` for job 1127: `last_run_status =
  'Success'`, `last_run_started_at = 2026-09-14 22:38:04+05:30`; 3 new
  runs occurred in the observation window, `total_successes` moved 0→3,
  `total_failures` stayed at 3 (the original 3 pre-fix runs — no new
  failures added). `timescaledb_information.job_errors` for job 1127:
  still exactly the same 3 pre-fix rows (21:04-21:06, all `2D000`) — **zero
  new errors of any kind**, confirming the transaction-control fix holds
  under real execution, not just the disposable-container test. Deployed
  `pg_get_functiondef('analytics.evaluate_alerts()')` fetched and byte-diffed
  against migration 241's source: identical, confirming no drift between
  what was deployed and what was tested.
- **Lifecycle-validated**: **no** — proving the procedure now *executes*
  successfully is not the same as validating what it *produces* over real
  qualification/resolution/recurrence cycles. Observed (read-only, nothing
  manufactured): `analytics.alerts` = 0 rows;
  `analytics.alert_evaluation_candidates` = 2 rows — real qualification
  timers the running job has organically started against real staging
  site data (not created or forced by this session). 0 Active alerts is
  expected at this point regardless of outcome: qualification requires 5
  continuous minutes, and only a few evaluation cycles have elapsed since
  re-enabling. Whether either candidate reaches qualification, and what
  the full lifecycle then does, is exactly the broader MVP-7 lifecycle
  validation this pass deliberately does not perform.

**Lifecycle validation, Part 1 (qualification → Active): PASS**, using
real staging data, nothing manufactured — both real candidates naturally
qualified (5 continuous minutes) and became exactly 2 `ACTIVE` alerts
(`Unit 2`, `Coimbatore`), persisted fields verified against the MVP-7
contract, duplicate suppression confirmed live across multiple further
evaluation cycles, zero evaluator errors throughout. **Part 2
(Active → Resolved): BLOCKED by staging data, not attempted around** —
both sites' Energy Attention evaluation is pinned to a fixed prior
calendar day ("yesterday"), confirmed live, which cannot change intraday
regardless of how many more 1-minute cycles run; no naturally-clearing
condition was available to time a resolution against, and none was
manufactured. Full evidence:
[08-verification/mvp7-alerts-staging-lifecycle-validation.md](../../08-verification/mvp7-alerts-staging-lifecycle-validation.md).
**Not yet validated**: resolution (blocked, see above), recurrence beyond
zero-prior-occurrence, data-gap/recovery, retention, and UI/frontend
rendering of these real alerts — each remains a separate, explicitly
authorized next step. **Configuration-transition (§8) is NOT YET TESTED /
NOT CURRENTLY TESTABLE**, not merely unvalidated — see "Known limitations"
above: the transition logic exists and is structurally sound, but no
runtime Attention configuration mechanism exists to ever invoke it, so
building one is a prerequisite, not a test-scheduling matter. MVP-7 is
still not released as a functional customer feature.
