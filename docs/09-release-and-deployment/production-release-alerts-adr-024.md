# Production release: Alerts (ADR-024, migrations 320–326) — plan

Status: PREPARED 2026-11-18 — **not approved, not run.** Every production
step (backup, prechecks beyond read-only, dispatch, rollback) needs its own
explicit approval. Owner: Engineering. Staging result:
[../07-features/alerts/README.md](../07-features/alerts/README.md) and the
"Staging release record" section below.

## What the release does on production

| Item | Value |
|---|---|
| Release commit | `e627298` (PR #179 squash; `deploy-staging` run 44282502005 succeeded 2026-11-18) — or a later `staging` commit carrying the D-1 fix, if that is approved first |
| Workflow | `deploy-production.yml`, `release_git_sha` = `confirm_release_git_sha` = that commit, **`expected_migrations=320,321,322,323,324,325,326`** (production ledger head is 319 since release `8abd023`, 2026-11-07) |
| Migrations | 320 deletes the legacy Energy Attention alerts and retires job/functions (explicitly scoped `staging|production|test`); 321–325 create the rule schema, audit actor type, functions and the evaluator job; 326 is a no-op on production (`ems_customer_api` does not exist there) |
| Services recreated | `admin-portal`, `live-telemetry` (`deploy_release.sh`) — the API change goes live in admin-portal, which serves `/api/v1` and the SPA on production |
| **Frontend** | **`deploy-production.yml` does not update the bind-mounted `/app` bundle.** The new SPA (`-web:<same SHA>`) must be placed in the same change window with `scripts/release/deploy_web_bundle.sh` (as `rollback.yml`'s `web_image_tag` does) — otherwise production would serve the retired MVP-7 Alerts UI against the new API. Release dependency R-1 below. |
| Data deletion | every row of `analytics.alerts` / `analytics.alert_evaluation_candidates` on production is a legacy Energy Attention row; migration 320 deletes them (aborting if any row cannot be classified) and records counts in `admin.migration_outcomes`. **Irreversible.** |

## Blockers (all must be cleared before dispatch)

| # | Blocker | State 2026-11-18 |
|---|---|---|
| B1 | Verified production backup (or explicit user waiver for this release) | **Open.** Last record (2026-11-08): production has no database backup. Not re-verified. |
| B2 | Staging release accepted | Database-level acceptance passed 2026-11-18 (record below). Owed: signed-in browser check of the three views on staging; decision on D-1 (ship as is, or fix first). |
| B3 | Read-only production precheck | Open: legacy row counts by state, whether a `run_alert_evaluation_job` job exists (it was registered manually), ledger head 319, `telemetry.device_live_point_state` freshness for bound points (the evaluator's source), disk/memory. |
| B4 | Frontend bundle step (R-1) agreed and scripted for the window | Open. |
| B5 | Release approval | Open. |

## Database permissions on production

- New functions are owned by `ems_admin`, granted to `ems_app` only
  (migrations 323/324); `ems_customer_api` grants (326) skip — the role is
  staging/test only. Internal helpers and the evaluator are granted to no
  application role. `ems_readonly` gets nothing new (no default privileges on
  production).
- `alert.configure` is inserted for `ADMIN` only (migration 321).
- 322 adds a nullable `admin.audit_events.actor_type` column and a BEFORE
  INSERT trigger; `admin.write_audit_event` is unchanged.

## Sequence (proposed)

1. Read-only precheck (B3) — expected deletion counts recorded beforehand.
2. Backup (B1) or written waiver.
3. Dispatch `deploy-production.yml` with the expected migrations above.
4. Immediately place the `-web:<SHA>` bundle (R-1) and confirm `/app` serves it.
5. Postchecks: ledger head 326; `admin.migration_outcomes` row for 320
   (counts match step 1); legacy job absent; `run_alert_rule_evaluation_job`
   registered and logging runs (`verify_jobs.sh`); `GET /api/v1/me` shows
   `alert.configure` for ADMIN; Alerts page renders the three views.
6. Operator signed-in check of the Alerts page.

## Rollback / recovery

- **Data:** legacy alert records cannot be restored without a backup (B1).
- **Application:** `rollback.yml` to the previous image restores the old code
  but the old Alerts code calls functions migration 320 dropped — it would
  return errors on the Alerts area only. Roll forward is the recovery path;
  a schema rollback is a forward migration (each migration header states its
  rollback).
- **Evaluator:** can be paused with `alter_job(<id>, scheduled => false)`
  (approval needed) without affecting any other job.

## Expected production impact (to confirm in B3)

- Production last read (2026-11-07 release) had the legacy evaluator
  running; staging deleted 79 legacy rows, production's count is unknown
  until B3. The evaluator's source on production is the same live-value
  cache; its freshness for bound points has not been measured there.
- The customer API, edge proxy and `ems_customer_api` role do not exist on
  production — 326 skips, and the Alerts API is served by admin-portal only.

## Staging release record (2026-11-18)

- Commit `e627298` (PR #179). `deploy-staging` run 44282502005 (CI gates,
  images, deploy, post-deployment verification: all success);
  `deploy-customer-api` run 44284913192 (success). admin-portal,
  customer-api, live-telemetry and ems-web all on `e627298`, healthy.
- Migrations 320–326 applied 15:51 IST; ledger 198 rows, head 326.
- Migration 320: 79 alerts deleted (ENDED 76 / ACTIVE 2 / RESOLVED 1),
  0 candidates, job 1127 removed; legacy functions absent.
- Job 1143 `run_alert_rule_evaluation_job`: every minute, 134 runs, 0
  failures, mean 51 ms / p95 45 ms; the first two runs after deploy took
  926 ms and 1,810 ms (cold) — expect the same right after the production
  migrations. Host: 724 MiB available of 1.9 GB after acceptance.
- Grants: public alert functions EXECUTE for `ems_app` and
  `ems_customer_api`, not PUBLIC; internal helpers and the evaluator for no
  application role. `alert.configure` ADMIN only; `alert.acknowledge`
  ADMIN + OPERATOR.
- Acceptance results and gaps: [Alerts README](../07-features/alerts/README.md)
  ("Staging release record").

## Known defects

- **D-1 (timing, minor):** qualification takes 5–6 min and resolution
  1–2 min (sub-millisecond job-start jitter versus an exact `<=` test).
  Recorded alert times are correct. Fix = grace in two comparisons in
  `analytics.evaluate_alert_rules` (new migration).
- **Observation D-2 (product decision):** an alert's "previous
  occurrences" count only occurrences of the same rule *version*
  (`condition_key` = `RULE:<id>:v<version>`). An edit resets the count
  (condition changed); a plain disable / re-enable also resets it,
  because re-enabling bumps the version. Seen on staging: the freezer's
  second occurrence (17:39:55) showed 0 previous after the 17:28
  disable / re-enable.
