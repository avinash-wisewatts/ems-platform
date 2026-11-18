# Alerts — Phase 1 implementation plan (customer-configurable rules, ADR-024)

Status: IN PROGRESS — Step 0 design approved; steps 1–6 implemented on the integration branch `feature/alerts-rules` (one coordinated merge to `staging`, design Q1); staging release and acceptance pending at the time of this note · Written 2026-11-18 · Owner: Engineering
Decision record: [ADR-024](../../00-governance/decisions/ADR-024-customer-configurable-alert-rules.md) ·
Requirements: [functional-requirements.md §Alerts](../../02-requirements/functional-requirements.md#alerts)
(`EMS-REQ-082`, `EMS-REQ-140`–`EMS-REQ-152`) · Feature: [README.md](README.md)

This is a plan, not an authorisation. Phase 1 starts only on explicit
Product Owner approval; every staging change beyond read-only checks, and
every production step, needs its own approval as usual (CLAUDE.md §3–§4).

## 1. Phase 0 baseline (2026-11-18)

- **Repository:** `origin/staging` `8abd023` (migration head
  `319_portal_user_audit_history_read`; next free number 320 at the time
  of writing — re-check when the branch is cut).
- **Staging (read-only check, 09:26 IST):** legacy job 1127 healthy (1-minute
  schedule, 91,040 runs, 0 retained errors); `analytics.alerts` = 79 legacy
  rows (2 ACTIVE, 1 RESOLVED, 76 ENDED — all `DATA_UNAVAILABLE`, daily
  ~00:23 IST churn); 0 candidates; ledger 238–319 complete; 745 MiB RAM
  available of 1,905; disk 57 % used. Production not checked.
- **Decisions:** all product and architecture decisions are closed —
  permissions incl. staff, explicit tolerance, telemetry-gap behaviour,
  schedules, 5 min / 1 min, acknowledgement ≠ resolution, Coming Soon
  delivery, soft delete, 90-day history, three UI views, 25 active rules
  per site, audited writes, legacy replacement and deletion, **DDS
  classification approved** (rules and occurrences stay within `Alert`).
- **Open design items (decided inside Phase 1, step 0):** evaluator data
  source and the "telemetry unavailable" definition; cumulative-counter
  eligibility source; reuse vs. replacement of `analytics.alerts`; actor-type
  representation in `admin.audit_events`; job runtime budget.

## 2. Ground rules

- Branch from a freshly fetched `origin/staging`, never from the dirty
  local branch; one coherent PR per step below.
- Windows worktrees: keep LF endings in `postgres/` and `scripts/` (CRLF
  breaks the local test-database migrations).
- Every new migration is registered in `postgres/restructure_manifest.csv`.
  Feature migrations run in **all** environments (not staging-only); the
  retirement migration is **explicitly** listed `staging|production|test`
  in `postgres/migration_environment_scope.csv`.
- Grants to `ems_customer_api` are guarded (the role exists on
  staging/test only).
- Migrations 238–242 are never edited; every change is a forward migration.
- Tests are never weakened; legacy tests are retired only together with the
  objects they cover.
- A clean local test database shows no plan problems: heavy reads and the
  evaluator get a read-only `EXPLAIN`/timing check on staging before merge.

## 3. Workstreams

| WS | Scope | Main artefacts |
|---|---|---|
| A — Design note | Close the open design items; fix API contract and schema shape | short design note under `docs/07-features/alerts/` |
| B — Data foundation | Rule table, occurrence extensions (rule reference, acknowledgement who/when, history snapshot), constraints, 25-rule limit, permission `alert.configure` (+ explicit `ADMIN` grant) | migrations 320+ |
| C — Write functions + audit | SECURITY DEFINER create / update / enable / disable / soft-delete / acknowledge, each re-checking permission, site, asset, parameter; same-transaction `admin.audit_events` with actor type; `CONFIGURATION_CHANGED` ending | migrations; DB tests |
| D — API | Rule-aware reads (Active, history, rules, parameters per asset) replacing `GET …/alerts` and `GET /alerts/{id}`; enumerated write routes with route permission + same-site JSON; `required_permission_for_request` entries; mounted in both apps | `app/src/routers/`, `app/src/auth/authorization.py`, service module |
| E — Evaluator + monitoring | New set-based procedure and TimescaleDB job: schedule windows in site timezone, 5 min / 1 min timers, gap handling per ADR-024 §4A, 90-day retention, run metrics; `verify_jobs.sh` checks | migration + `postgres/jobs/` file + `scripts/verify/` |
| F — Legacy retirement | One migration: pre-check/abort, remove legacy job(s) by procedure name, retire legacy procedures, delete legacy candidates then alerts, guard constraint, record counts; remove `postgres/jobs/238_alert_evaluation_job.sql`; retire legacy tests | migration (`staging|production|test`); tests |
| G — Frontend | Replace `AlertsArea` with Active Alerts, Create Alert (form, toggle, edit, delete-confirm), Resolved/Ended history; reuse header indicator; Coming Soon channels; permission-aware controls; site-timezone formatting | `web/src/routes/alerts/`, `web/src/api/` |
| H — Release | Staging release, staging performance and acceptance checks, release record with deletion counts; production promotion prepared for separate approval | `docs/09-release-and-deployment/` |

## 4. Proposed sequence

Each step is one PR to `staging` unless noted. "Local" = local tests and
the disposable test database only.

| # | Step | Depends on | Tests | Acceptance criteria |
|---|---|---|---|---|
| 0 | **Design note** (WS-A) | Phase 1 approval | — | **Proposed:** [phase-1-technical-design.md](phase-1-technical-design.md) (2026-11-18), with questions Q1–Q8 for the user. Open items decided and recorded; API contract, schema and evaluator source agreed by the user |
| 1 | **Schema foundation** (WS-B) | 0 | Migration applies on a fresh test DB and on a copy of the current schema; constraint tests | Rule table + occurrence extensions exist; acknowledgement is an attribute, not a state; `alert.configure` granted to `ADMIN` only (DB and API); no legacy behaviour changed yet |
| 2 | **Write functions + audit** (WS-C) | 1 | DB tests per role/scope: customer `ADMIN`/`OPERATOR`/`VIEWER`, `GLOBAL` `ADMIN`/`OPERATOR`/`VIEWER`; cross-tenant asset; parameter not on asset; 26th active rule; acknowledge non-Active | Exactly the ADR-024 §2 matrix is enforced in the database; every successful write has exactly one audit row with actual actor and customer-vs-staff actor type, in the same transaction; edit/disable/delete ends an Active occurrence `CONFIGURATION_CHANGED`; soft-deleted rule history intact |
| 3 | **Read + write API** (WS-D) | 2 | Route tests (401/403/404/415/422, cross-site 403), OpenAPI test, customer-API role test | Routes enforce the dedicated permission before the DB call; inaccessible = 404; no internal identifiers beyond the existing resource-id convention; both `main` and `customer_main` serve the same contract |
| 4 | **Evaluator + monitoring** (WS-E) | 1 (and 2 for config transitions) | Live-execution test on the disposable DB (qualify at 5 min, resolve at 1 min, gap resets, schedule close keeps Active, telemetry gap keeps Active + acknowledgement, no duplicate Active, equal-to with tolerance, 90-day retention); staging read-only `EXPLAIN`/timing at 25 rules × sites | Set-based (no per-rule loop of queries); runtime within the agreed budget on staging; job registered once and reported by `verify_jobs.sh`; never ends a rule alert `DATA_UNAVAILABLE` |
| 5 | **Legacy retirement migration** (WS-F) | 1, 4 (same release) | Test on a DB seeded with legacy rows + rule rows: legacy deleted, rule rows untouched, unknown row → abort, re-run is a no-op, missing job is not an error | Legacy job(s) and procedures gone; zero legacy rows; guard prevents legacy-shaped inserts; counts recorded durably; scope file lists it `staging|production|test`; `verify_jobs.sh` asserts the legacy job is absent |
| 6 | **Frontend** (WS-G) | 3 | Vitest: three views, permission-aware controls per role, form validation (explicit tolerance required for equal-to; no equal-to for cumulative counters; 25-rule limit message), delete confirmation, Coming Soon shows no delivery state, history includes deleted-rule occurrences, site-timezone times; tsc, eslint, build | `AlertsArea` replaced; header indicator counts rule-based Active alerts; no legacy view; exercised locally against staging data through the tunnel |
| 7 | **Staging release** (WS-H) | 1–6 merged as one releasable SHA | Post-deploy verification; staging performance check; read-only acceptance queries | Deployment green; legacy deletion counts recorded in the release record; a real rule qualifies, is acknowledged, survives a gap, resolves and appears in history; audit rows show actor and actor type; no new job errors |
| 8 | **Production promotion — prepared only** | 7 accepted | — | Release plan with precheck, backup confirmation, expected deletion counts (read-only, once approved) and rollback limits; **executed only on separate explicit approval** |

Migration numbering follows the technical design §8: the retirement
migration is numbered first (320) so that `rule_id NOT NULL` can follow it
(321). PR review order and migration order are independent, provided the
whole set reaches `staging` as one merge (technical design §9 Q1).

Steps 1–6 can overlap where dependencies allow (for example, 6 can start on
a mocked contract after 3's contract is fixed), but steps 4 and 5 must
reach staging in the same release as 3 and 6 so customers are never left
without an Alerts area.

## 5. Testing approach

- **Database:** disposable test DB (`make test-db`, `scripts/test/run_integration_environment.sh`);
  SQL assert scripts in `scripts/test/` following the
  `assert_mvp7_alert_*_executes` live-execution pattern; role/scope matrix
  tests.
- **Backend:** pytest in the app test image (`make test-app`); route,
  contract, OpenAPI and customer-API role tests.
- **Frontend:** `npm run typecheck`, `npm run lint`, `npm test`,
  `npm run build`; local UI against staging data through the existing
  read-only tunnel.
- **Staging (read-only, pre-authorised):** `EXPLAIN` without `ANALYZE`
  first, short statement timeouts, bounded queries (1.9 GB host).
- **CI:** all `ci.yml` jobs green before merge.

## 6. Risks

| Risk | Mitigation |
|---|---|
| Deletion is irreversible; production had no DB backup at the last record (2026-11-08) | Confirm backup at production release; abort-on-unknown pre-check; legacy-only predicate; counts recorded |
| Evaluator load on a 1.9 GB staging host | Set-based design, 25-rule limit, timing check before merge, monitoring |
| Customers without alerts if retirement ships ahead of the replacement | Same releasable SHA for steps 3–6; production promotion of that SHA only |
| `ems_customer_api` absent on production | Guarded grants; production path reviewed in step 8 |
| Recreated read functions lose grants | Re-grant in the same migration; customer-API role test |
| Staff actions indistinguishable in audit | Actor type mandatory, derived server-side; tested in step 2 |
