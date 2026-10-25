# Production release of migration 311 — checklist (PREPARED, not executed)

Status: prepared 2026-10-25, **not approved, not run**. Every step that touches
production needs its own explicit approval. Job 1061 stays paused throughout;
resuming it is a separate decision after this release.

| Item | Value |
|---|---|
| Release | `staging` HEAD `a32921a2afb29c3ee4b3f138e2882921de7efccb` (PR #155 on top of #152) |
| Workflow | `deploy-production.yml`, `promotion_mode=staging-head`, `release_git_sha` = `confirm_release_git_sha` = the SHA above, **`expected_migrations=311`** |
| Image | `ghcr.io/avinash-wisewatts/ems-platform-app:a32921a…@sha256:d690097a6eca28c702b40bb4e0a1237f7c1e1b7a62c65559cea6d40cb168d391` (pushed by staging run `40188640925`; the workflow re-resolves and pins it — must match) |
| Current production | `7e3da57` (image `…@sha256:85fdfb5c…`), ledger 180 rows, head 308 |
| Database change | `311_recovery_lookup_event_time_bound` only: `CREATE OR REPLACE PROCEDURE telemetry.recover_failed_raw_messages` (body 305 → 311). No table, data, job or grant change |

## 1. Evidence already gathered [M, read-only, 2026-10-25]

| Check | Result |
|---|---|
| Pending set (merged `check_pending_migrations.sh` on `a32921a`'s manifest + scope, production ledger read 11:4x UTC) | **Would apply (1): `311_recovery_lookup_event_time_bound`** — precheck OK |
| 309 / 310 / 312 | `staging|test` in `a32921a`'s scope file → `SKIP-ENV`, no ledger row; none of their objects exists on production |
| 311 precondition | Production recovery body md5 `76e7c9e2` (= 305) |
| Reports off | No `EMS_REPORT*` key in production `app/.env` or in the running `ems-admin-portal` env → `EMS_REPORTS_ENABLED` defaults to false: routes not mounted, worker not started. The 309 / 312 objects are referenced only by the Reports modules |
| Web bundle | `deploy-production.yml` never deploys it (CI contract test) |
| First-deploy transition | Production runs `7e3da57`'s `deploy_release.sh` (no `DEPLOY_ENVIRONMENT`); the runner falls back to the exported `ENVIRONMENT_NAME=production` — proven by staging's real transition deploy (run `40188640925`, "Environment: staging", 184 SKIP) |
| Host | Checkout clean at `7e3da57`; `git ls-remote` sees `staging` = `a32921a`; `admin-portal` service present; disk 64 %, 37.0 GB free |
| Job 1061 backlog | 0 rows eligible for the recovery path; 155 OPEN rows are empty packets (`EMPTY_RTDATA_ARRAY` 154, `INVALID_JSON` 1; no source identifier). Nothing waits on 311 |
| Query plan (TimescaleDB 2.28.2, EXPLAIN only) | Unbounded 305: Hash Join over a sequential scan of all 13 compressed chunks. Bounded 311, custom plan: per-device index-only scan on one chunk, cost 5.6 / 6.4. Bounded 311, generic plan: Hash Join over the window's batches of all devices (~1.32 M rows, cost 46,164). `plan_cache_mode = auto` |

## 2. Before dispatch (each needs approval)

1. **Backup decision** (section 6). Proceed with or without a fresh dump.
2. **Window**: avoid the F1 policy runs (05:13 / 17:13 UTC) and the nightly
   reconcile (23:00 UTC), as for C1 / C2′; no operator session running.
3. **Re-run the read-only precheck** immediately before dispatch: production
   ledger (180, head 308, digest unchanged), 305 body md5, no `EMS_REPORT*`
   key, `staging` HEAD still `a32921a`, 0 lock waiters / long transactions,
   failures (excl. 1114) and failing jobs recorded as the baseline, disk.
4. **Dispatch** with the inputs above. The workflow then: operator allowlist →
   SHA double entry → staging-HEAD check → image pin → **pending-migration
   precheck on the host (origin/staging's copy; refuses anything but 311 and any
   staging-only migration)** → `deploy_release.sh` → post-deploy verification.

## 3. Abort conditions (the workflow stops; nothing after it runs)

| Where | Refuses when |
|---|---|
| Precheck (before any change) | the target runner would apply anything other than 311; a staging-only migration would be applied; a staging-only migration is already in the production ledger |
| Runner | `DEPLOY_ENVIRONMENT` / `ENVIRONMENT_NAME` missing; invalid scope file; checksum mismatch; 311 precondition (body ≠ 305) |
| REQUIRED post-deploy gates | database structure, metadata integrity, energy routing identity, **staging-only objects absent** (no 309 / 310 / 312 ledger row or object, no Reports route in the running admin portal) |

The post-deploy gates detect, they do not prevent: a failure after
`deploy_release.sh` means the release is in place and needs the rollback below.

## 4. Postcheck (read-only, right after the run)

- Ledger 181 rows; 311 once, checksum = repository file (`f6a0cb25…`); the 180
  prior rows unchanged; no 309 / 310 / 312 row.
- Recovery body md5 `31f4db2f`; owner / grants / COMMENT unchanged.
- `ems-admin-portal` / `ems-live-telemetry` on `…@sha256:d690097a…`, healthy;
  `/health` 200; running app: `reports_enabled=False`, 0 report-export routes.
- Job 1061 still unscheduled; no job changed; failures (excl. 1114) and job
  errors unchanged since dispatch; 0 lock waiters.

## 5. Rollback

- **Image**: `rollback.yml`, `target_environment=production`,
  `image_tag=ghcr.io/avinash-wisewatts/ems-platform-app:7e3da5762ca6b69b1258f6264999ae546f7dc6a2@sha256:85fdfb5c347b657d7bc5d1a571941eb580fb2197d6b1aefe8c61e416bb7da8ca`,
  `release_git_sha=7e3da57…`, **`expected_migrations=none`**. Its precheck:
  `7e3da57`'s manifest ends at 308, nothing pending. The 7e3da57 app runs on the
  311 body (procedure only).
- **Database** (separate approval): `postgres/maintenance/311_recovery_lookup_event_time_bound_rollback.sql`
  — guarded (deployed body must be 311's, `31f4db2f`), restores 305's body
  exactly (`76e7c9e2`), postcondition-checked, no ledger change. Tested in CI
  (`test_recovery_lookup_event_time_bound.py`, 303 rollback chain).

## 6. Fresh backup — feasibility (not created)

| Aspect | Assessment |
|---|---|
| Mechanism | `/opt/ems-platform/scripts/safe_production_backup.sh` (untracked on the host, sha256 `61e6c01d…`): checks the container, requires free space ≥ live DB size, `pg_dump` custom format streamed to the host, then `pg_restore --list` |
| Space | DB 31.50 GB, free 37.01 GB → passes the script's check with ~5.5 GB margin. Expected file ~7.5–8 GB (10-23: 7.18 GB), leaving ~29 GB free |
| Duration / load | ~50–60 min (10-23: 08:14 → 09:05 UTC), one long read-only snapshot on the IO-limited host; schedule outside the windows in section 2 |
| Checksum | Not computed by the script: add `sha256sum` → `.sha256` sidecar, then `pg_restore --list` TOC count (10-23: 6,955 entries) |
| Gaps | Same disk as the database (no off-host copy; no AWS access here). Roles / globals not included. Never restore-tested: a test restore needs an isolated environment (e.g. local Docker with production image `289d55704b1b`, TimescaleDB 2.28.2), which means copying production data off the host — separate approval |
| Need | 311 changes one procedure body and has a tested, guarded rollback script; a dump is not required to reverse it. The 10-23 dump (pre-Release D) remains the only backup |

## 7. After the release (separate approvals)

1. Resume job 1061 (`alter_job(1061, scheduled => true)`) and watch its first runs.
2. Release D production acceptance window (`release_d_observation_procedure.md`).
