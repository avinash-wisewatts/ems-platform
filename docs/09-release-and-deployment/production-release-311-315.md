# Production release: migrations 311 and 315 — checklist

Status: PREPARED 2026-11-04, **not approved, not run**. Every step that touches
production (dispatch, any SQL beyond the read-only checks, rollback) needs its
own explicit approval. Owner: Engineering.

## What the release is

| Item | Value |
|---|---|
| Release commit | the `staging` commit that contains PR #174 (315 production-scoped), **after** its `deploy-staging.yml` run succeeded. Promoting an earlier commit (e.g. `fff7ceb`) would apply only 311: 315 is still staging-only there. |
| Workflow | `deploy-production.yml`, `promotion_mode=staging-head`, `release_git_sha` = `confirm_release_git_sha` = that commit, **`expected_migrations=311,315`** (the precheck refuses `311` alone) |
| Current production (last read 2026-10-25 / 2026-11-03, re-read at precheck) | `7e3da57`, image `ems-platform-app:7e3da57…@sha256:85fdfb5c347b657d7bc5d1a571941eb580fb2197d6b1aefe8c61e416bb7da8ca`, ledger head 308 |
| Content | the 22 `staging` commits after `7e3da57` (Reports 309/312, 310 backfill, 311, env-scoped migrations, ems-web container, customer API 313/314, edge, certificate checks) + #171 (Admin → Users, 315) + #174 |
| Services recreated | `admin-portal` and `live-telemetry` only (`deploy_release.sh`). `ems-web`, `customer-api` and `edge` are never created; the bind-mounted `/app` bundle is not updated, so the Admin → Users **screen** does not appear on production (blocked on D6). |
| Migrations | 311 and 315 apply; 309, 310, 312, 313, 314 `SKIP-ENV` |
| Inert on production | Reports (`EMS_REPORTS_ENABLED` defaults to false; no `EMS_REPORT*` key on production 2026-10-25), customer sessions (no `EMS_CUSTOMER_SESSION_SECRET`), staff-only audience (`EMS_ADMIN_STAFF_ONLY` defaults to false). All new settings have defaults. |
| Goes live | `/api/admin/v1/*` (needs a staff session, `user.manage` except own password, same-origin JSON writes) and 315's database rules |

### Behaviour change on production's existing `/administration/users`

- An administrator can no longer change their **own** role, access scope or
  status, nor reset their own password through the managed function
  (refused with 42501; the page shows the message with HTTP 409).
- The **target** of a scope change must be inside the actor's scope (the
  cross-tenant fix).
- Only an active GLOBAL ADMIN may reset another ADMIN's password.

## Migration 311 risks

| Risk | Assessment / mitigation |
|---|---|
| Changes `telemetry.recover_failed_raw_messages` (body 305 → 311) | Procedure body only; no table, data, job or grant change. Precondition: the deployed body is 305's (md5 `76e7c9e2`); the runner refuses otherwise. |
| Query plan of the bounded lookup | Custom plan: per-device index-only scan on one chunk (cost 5.6 / 6.4). Generic plan: Hash Join over the window's batches of all devices (~1.32 M rows, cost 46,164); `plan_cache_mode = auto` (EXPLAIN only, production 2026-10-25). Unbounded 305 scans all compressed chunks, so 311 is never worse. Staging: 5,046 ms → 11.9 ms. |
| Who runs it | Job 1061, **paused** on production, 0 eligible rows (155 OPEN rows are empty packets). Nothing exercises 311 at release time; resuming 1061 is a separate decision after the release. |
| First-deploy transition | Production runs `7e3da57`'s `deploy_release.sh` path the first time; the runner falls back to `ENVIRONMENT_NAME=production` for the scope (proven by staging's transition, run 40188640925). |
| Reversal | `postgres/maintenance/311_recovery_lookup_event_time_bound_rollback.sql`: guarded, restores 305's body exactly, no ledger change, tested in CI. Separate approval. |

## Before dispatch (read-only unless stated; each run needs approval)

1. **Exposure query**: `scripts/verify/portal_user_scope_exposure.sql`.
   Expect: no ORGANIZATION / SELECTED_SITES ADMIN, 0 rows in check 2 (as on
   2026-11-03: one active GLOBAL ADMIN). Any row stops the release for review.
   Rule until 315 is applied: no tenant-level ADMIN is created on production.
2. **Precheck**: ledger rows and head 308, image digest as above, 305 body md5
   `76e7c9e2`, no `EMS_REPORT*` / `EMS_CUSTOMER_SESSION_SECRET` / `EMS_WEB_UPSTREAM`
   key, `staging` HEAD = the release commit, 0 lock waiters / long transactions,
   disk free, failures and failing jobs recorded as the baseline.
3. **Window**: avoid the F1 policy runs (05:13 / 17:13 UTC) and the nightly
   reconcile (23:00 UTC); no operator session in the Administration App.
4. **Backup decision**: proceed with or without a fresh dump
   ([../10-operations/backups-and-recovery.md](../10-operations/backups-and-recovery.md);
   assessed 2026-10-25: ~50–60 min, same disk as the database, the 2026-10-23
   dump is the only backup). 315 replaces three function
   bodies and adds three functions; 311 replaces one procedure body; no data
   changes.
5. **Dispatch** (approval). The workflow refuses unless the host's runner would
   apply exactly 311 and 315 and no staging-only migration.

## After the release (read-only)

- Ledger: 311 and 315 once each, checksums = repository files
  (311 `f6a0cb25…`, 315 `ec3e95e1…`, as on staging); prior rows unchanged;
  no 309 / 310 / 312 / 313 / 314 row.
- 315 functions: run the staging verification query set (owner `ems_admin`,
  SECURITY DEFINER, `search_path=pg_catalog, admin[, metadata]`, EXECUTE for
  `ems_app` only; body md5s equal staging's).
- 311: recovery body md5 `31f4db2f`.
- REQUIRED post-deploy gates pass, including "staging-only objects absent".
- `admin-portal` / `live-telemetry` on the pinned digest, healthy; `/health`
  200; no 5xx or tracebacks; signed-out `/api/admin/v1/users` → 401;
  `reports_enabled=False`.
- Exposure query again: unchanged.
- Signed-in staff check of `/administration/users` (list loads; own role
  change refused with the message).

## Rollback: application image only — 315 stays applied

**Procedure** (approval): `rollback.yml`, `target_environment=production`,
`image_tag=ghcr.io/avinash-wisewatts/ems-platform-app:7e3da5762ca6b69b1258f6264999ae546f7dc6a2@sha256:85fdfb5c347b657d7bc5d1a571941eb580fb2197d6b1aefe8c61e416bb7da8ca`,
`release_git_sha=7e3da57…`, **`expected_migrations=none`**.

Why this works with 311 and 315 still applied:

- The rollback precheck takes its deny scope from `origin/staging`
  (`precheck_release_migrations.sh`). 311 and 315 are not scoped there, so
  their ledger rows are not "leaks"; `7e3da57`'s manifest ends at 308, so
  nothing is pending. `7e3da57`'s runner only walks its own manifest and
  ignores later ledger rows.
- `7e3da57` calls `create_managed_portal_user` (9 args),
  `change_managed_portal_user_role` (3), `set_managed_portal_user_active` (3)
  and `set_managed_portal_user_access_scope` (5): 315 kept every signature,
  owner and grant. It never calls the three new functions. A 315 refusal
  reaches it as a `DatabaseError` and is shown as the page message (409).
- `7e3da57` runs on the 311 body (procedure only; job 1061 paused).

After a rollback: `/api/admin/v1/*` disappears (old image), the database rules
remain, and the post-deploy checks above are repeated for the old digest.

**Why there is no reverse migration for 315** (decision 2026-11-04):

- Reverting it reopens a live cross-tenant hole: an ORGANIZATION administrator
  could move a user of another organization, or a GLOBAL user, into their own
  organization, and administrators could change their own role, scope and
  status.
- Nothing needs it reversed: the previous application image runs on 315 (above).
- The migration system is forward-only by design ([rollback.md](rollback.md)).
- **Must stay true:** 315 never goes back into
  `postgres/migration_environment_scope.csv`. If it did, every later
  production release and rollback precheck would refuse, because 315 would
  be "scoped away" yet recorded in production's ledger.

If a defect is ever found in 315 itself, the fix is a **new forward
migration** that keeps the security rules, reviewed and released normally.
