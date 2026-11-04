# Production release: migrations 311, 315 and 316 — checklist

Status: PREPARED 2026-11-04, **not approved, not run, BLOCKED** (see below).
Every step that touches production (dispatch, the backup, any SQL beyond the
read-only checks, rollback) needs its own explicit approval. Owner: Engineering.

## Release blockers (all must be cleared)

| # | Blocker | State 2026-11-04 |
|---|---|---|
| B1 | Fresh production backup completed and checksummed | **Open.** `safe_production_backup.sh` refused (free 29 GiB < database 36 GiB; no file written). A guard change is proposed, not approved: [../10-operations/backups-and-recovery.md](../10-operations/backups-and-recovery.md#proposed-one-time-guard-change-not-approved). |
| B2 | Production privilege exposure understood and addressed | **In progress.** Understood (read-only, below); 316 addresses the portal-user functions; the wider `ems_readonly` grants are a separate decision. |
| B3 | 311, 315 and 316 validated on staging | 311 (2026-10-25) and 315 (2026-11-04) done; 316 pending its staging deployment. |
| B4 | Production prechecks re-run immediately before dispatch, and release approval | Open. |

## What the release is

| Item | Value |
|---|---|
| Release commit | the `staging` commit that contains 316, **after** its `deploy-staging.yml` run succeeded. `3dad83a` (#174) is no longer the candidate: from it, production would not get 316. |
| Workflow | `deploy-production.yml`, `promotion_mode=staging-head`, `release_git_sha` = `confirm_release_git_sha` = that commit, **`expected_migrations=311,315,316`** (the precheck refuses `311` or `311,315`) |
| Current production (read-only, 2026-11-04) | `7e3da57`, image `ems-platform-app:7e3da57…@sha256:85fdfb5c347b657d7bc5d1a571941eb580fb2197d6b1aefe8c61e416bb7da8ca`, both services healthy; ledger 180 rows, head 308, fingerprint `e5ca12cf82fec87113098e76ab914f12`, nothing from 309 on |
| Content | the 22 `staging` commits after `7e3da57` (Reports 309/312, 310 backfill, 311, env-scoped migrations, ems-web container, customer API 313/314, edge, certificate checks) + #171 (Admin → Users, 315) + #174 (315 production-scoped) + 316 |
| Services recreated | `admin-portal` and `live-telemetry` only (`deploy_release.sh`). `ems-web`, `customer-api` and `edge` are never created; the bind-mounted `/app` bundle is not updated, so the Admin → Users **screen** does not appear on production (blocked on D6). |
| Migrations | 311, 315 and 316 apply; 309, 310, 312, 313, 314 `SKIP-ENV` |
| Inert on production | Reports, customer sessions, the web-container switch and the staff-only audience: `EMS_REPORTS_ENABLED`, `EMS_CUSTOMER_SESSION_SECRET`, `EMS_WEB_UPSTREAM`, `EMS_ADMIN_STAFF_ONLY` are all absent on production (key names checked 2026-11-04) and default off. |
| Goes live | `/api/admin/v1/*` (needs a staff session, `user.manage` except own password, same-origin JSON writes), 315's database rules, and 316's removal of `ems_readonly` EXECUTE |

### Behaviour change on production

- `/administration/users`: an administrator can no longer change their **own**
  role, access scope or status, nor reset their own password through the
  managed function (42501; the page shows the message with HTTP 409). The
  **target** of a scope change must be inside the actor's scope. Only an
  active GLOBAL ADMIN may reset another ADMIN's password.
- A database login as `ems_readonly` can no longer call the 14 portal-user
  functions (316). No application, Grafana datasource or release script
  connects as `ems_readonly` (repository search, 2026-11-04); any manual tool
  that does keeps every other grant it has today.

## Production privilege exposure (read-only, 2026-11-04)

- `ems_readonly` (LOGIN, no memberships) can EXECUTE **98 of 110** `admin.*`
  functions, almost all SECURITY DEFINER, including every onboarding,
  commissioning, Grafana-provisioning, audit-writing and portal-user write
  function. It also has SELECT on `admin.portal_users` (includes
  `password_hash`), `portal_user_site_access` and `portal_user_audit`.
  Staging and the test database grant it none of these.
- Production has **no default privileges** (`pg_default_acl` empty): 315's
  three new functions do not inherit an `ems_readonly` grant. 316 asserts the
  end state for them anyway.
- 316 covers the portal-user management and authentication functions. The
  rest (other admin write functions, `portal_users` SELECT incl. hashes, the
  read-only authorization predicates) needs a separate, staging-first change;
  whether that is required before this release is a decision.

## Migration 311 risks

| Risk | Assessment / mitigation |
|---|---|
| Changes `telemetry.recover_failed_raw_messages` (body 305 → 311) | Procedure body only; no table, data, job or grant change. Precondition met on production 2026-11-04 (body md5 `76e7c9e2`); the runner refuses otherwise. |
| Query plan of the bounded lookup | Custom plan: per-device index-only scan on one chunk (cost 5.6 / 6.4). Generic plan: Hash Join over the window's batches of all devices (~1.32 M rows, cost 46,164); `plan_cache_mode = auto` (EXPLAIN only, production 2026-10-25). Unbounded 305 scans all compressed chunks, so 311 is never worse. Staging: 5,046 ms → 11.9 ms. |
| Who runs it | Job 1061 (`run_failed_message_recovery_job`), **paused** on production (2026-11-04). Nothing exercises 311 at release time; resuming 1061 is a separate decision after the release. |
| First-deploy transition | Production runs `7e3da57`'s `deploy_release.sh` path the first time; the runner falls back to `ENVIRONMENT_NAME=production` for the scope (proven by staging's transition, run 40188640925). |
| Reversal | `postgres/maintenance/311_recovery_lookup_event_time_bound_rollback.sql`: guarded, restores 305's body exactly, no ledger change, tested in CI. Separate approval. |

## Before dispatch (read-only unless stated; each run needs approval)

1. **Exposure query**: `scripts/verify/portal_user_scope_exposure.sql`.
   Expect: one active GLOBAL ADMIN only, 0 rows in check 2 (as on 2026-11-03
   and 2026-11-04). Any other row stops the release for review. Rule until 315
   is applied: no tenant-level ADMIN is created on production.
2. **Precheck**: ledger 180 rows, head 308, fingerprint as above; image digest
   as above; 311 precondition `76e7c9e2`; 315's replaced functions present,
   its new ones absent; no customer-session or Reports objects; settings key
   names as above; `staging` HEAD = the release commit; 0 lock waiters / long
   transactions; disk; failures and failing jobs recorded as the baseline.
3. **Backup** (B1): completed, checksummed, `pg_restore --list` verified.
4. **Window**: a weekday 07:30–09:00 UTC (13:00–14:30 IST), clear of the F1
   policy runs (05:13 / 17:13 UTC) and the nightly reconcile (23:00 UTC); the
   backup (~50–60 min) finished first; no operator session in the
   Administration App. Deploy plus checks ~5–10 min.
5. **Dispatch** (approval). The workflow refuses unless the host's runner would
   apply exactly 311, 315 and 316 and no staging-only migration.

## After the release (read-only)

- Ledger: 311, 315 and 316 once each, checksums = repository files
  (311 `f6a0cb25…`, 315 `ec3e95e1…`, 316 = staging's); prior 180 rows
  unchanged; no 309 / 310 / 312 / 313 / 314 row.
- 315 functions: owner `ems_admin`, SECURITY DEFINER,
  `search_path=pg_catalog, admin[, metadata]`; body md5s equal staging's.
- 316: `ems_readonly` cannot EXECUTE any of the 14 functions; `ems_app` can
  execute every function the application calls; every other grant as before.
- 311: recovery body md5 `31f4db2f`.
- REQUIRED post-deploy gates pass, including "staging-only objects absent".
- `admin-portal` / `live-telemetry` on the pinned digest, healthy; `/health`
  200; no 5xx or tracebacks; signed-out `/api/admin/v1/users` → 401.
- Exposure query again: unchanged.
- Signed-in staff check of `/administration/users` (list loads; own role
  change refused with the message) — manual, by the operator.

## Rollback: application image only — 315 and 316 stay applied

**Procedure** (approval): `rollback.yml`, `target_environment=production`,
`image_tag=ghcr.io/avinash-wisewatts/ems-platform-app:7e3da5762ca6b69b1258f6264999ae546f7dc6a2@sha256:85fdfb5c347b657d7bc5d1a571941eb580fb2197d6b1aefe8c61e416bb7da8ca`,
`release_git_sha=7e3da57…`, **`expected_migrations=none`**.

Why this works with 311, 315 and 316 still applied:

- The rollback precheck takes its deny scope from `origin/staging`
  (`precheck_release_migrations.sh`). 311, 315 and 316 are not scoped there,
  so their ledger rows are not "leaks"; `7e3da57`'s manifest ends at 308, so
  nothing is pending (`test_rollback_to_7e3da57_after_the_311_315_316_release_is_allowed`).
  `7e3da57`'s runner only walks its own manifest and ignores later ledger rows.
- `7e3da57` calls `create_managed_portal_user` (9 args),
  `change_managed_portal_user_role` (3), `set_managed_portal_user_active` (3)
  and `set_managed_portal_user_access_scope` (5): 315 kept every signature,
  owner and grant. It never calls the three new functions. A 315 refusal
  reaches it as a `DatabaseError` and is shown as the page message (409).
- 316 removes only `ems_readonly`'s grants; `7e3da57` connects as `ems_app`.
- `7e3da57` runs on the 311 body (procedure only; job 1061 paused).

After a rollback: `/api/admin/v1/*` disappears (old image), the database rules
remain, and the post-deploy checks above are repeated for the old digest.

**Why there is no reverse migration for 315 or 316** (decision 2026-11-04):

- Reverting 315 reopens a live cross-tenant hole: an ORGANIZATION
  administrator could move a user of another organization, or a GLOBAL user,
  into their own organization, and administrators could change their own role,
  scope and status. Reverting 316 would let any `ems_readonly` login manage
  portal users again.
- Nothing needs them reversed: the previous application image runs on both.
- The migration system is forward-only by design ([rollback.md](rollback.md)).
- **Must stay true:** neither 315 nor 316 goes into
  `postgres/migration_environment_scope.csv`. If one did, every later
  production release and rollback precheck would refuse, because it would be
  "scoped away" yet recorded in production's ledger.

A defect in either is fixed by a **new forward migration** that keeps the
security rules, reviewed and released normally.
