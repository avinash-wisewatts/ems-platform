# Production Release Plan: Migrations 266 → 301

Status: PROPOSED, awaiting product-owner decisions · Prepared: 2026-10-14 · Owner: Engineering
Nothing in this plan has been executed. Every dispatch, precheck and operator
step below needs its own explicit approval
([release-process.md](release-process.md#every-phase-requires-its-own-explicit-approval)).

This plan promotes production from migration 265 to staging's migration 301
in three normal `deploy-production.yml` runs with
`promotion_mode=staging-milestone` ([ci-cd.md](ci-cd.md#promotion-modes)).
It continues the 223–290 staged promotion, whose Stages 1–3 (223–265) were
deployed on 2026-10-08. Releases A, B and C replace that plan's Stages 4–6
and keep the same commit boundaries.

Evidence labels used in this document:

- **[V]** verified from the repository, GitHub Actions or a read-only
  staging query on 2026-10-14.
- **[P]** production state from the last read-only production checks
  (2026-10-08 to 2026-10-14). Not re-checked for this document; the
  prechecks below re-check them.
- **[E]** estimate. **[A]** assumption.

## 1. Starting point

| Item | Value | Basis |
|---|---|---|
| Last production release | `9ca461e` (Stage 3, migrations 264–265), run `37746225677`, 2026-10-08 | [V] newest `deploy-production.yml` run |
| Production ledger | 131 rows, head 265 | [P] |
| Staging HEAD | `b1c8b09` (migration 301), `deploy-staging.yml` run `38569347439` | [V] |
| Staging ledger | 173 rows, head 301, applied in manifest order, all 42 pending checksums equal to the repository files | [V] read-only query |
| Pending manifest rows | 42 | [V] |

**Manifest order, not numeric order [V].** `scripts/apply_migrations.sh`
applies every `postgres/restructure_manifest.csv` row that has no ledger
row, in manifest order, each in its own transaction, and stops on a
checksum mismatch. The pending rows are:

```text
266 267 268 269 263 270 279 275 276 277 278 280 281 282 283 284 285 286
253 254 255 256 257 258 259 260 261 262 287 288 289 290 291 292 293 294
295 297 298 299 300 301
```

271–274 and 296 are not in the manifest. 296 is an unmerged draft (PR #122).

**No checksum risk [V].** Each of the 42 files was added by one commit
and never edited. No applied migration (≤265) changed between `9ca461e` and
`b1c8b09`.

**Migration 266 is first in every later milestone [V].** No commit
after `9ca461e` can be promoted without applying 266. Its precondition (G1
below) therefore gates every release.

## 2. Releases

| Release | Milestone (full SHA) | `deploy-staging.yml` | Migrations, in apply order | Ledger after |
|---|---|---|---|---|
| **A** | `f06683d957b285754df2cebb1db5b737e2eb8d03` | `36022033311` success, 2026-09-24 | 266, 267 (2) | 133 |
| **B** | `ba2cb4be254644c3ebd4a30b02b68f1d1ae4d601` | `37273913405` success, 2026-10-05 | 268, 269, 263, 270, 279, 275, 276, 277, 278, 280, 281, 282, 283, 284, 285, 286 (16) | 149 |
| **C** | `b1c8b0956ddecbdcbfe7d474bfeb1b7eae8cb485` | `38569347439` success, 2026-10-14 | 253–262, 287, 288, 289, 290, 291, 292, 293, 294, 295, 297, 298, 299, 300, 301 (24) | 173 |
| C1 (fallback) | `105c6c15e66785151b20ca4b605e797bc558973e` | `37738437514` success, 2026-10-08 | 253–262, 287–291 (15) | 164 |
| C2 (after C1) | `b1c8b0956ddecbdcbfe7d474bfeb1b7eae8cb485` | as C | 292–295, 297–301 (9) | 173 |

All [V]. Each milestone is a strict descendant of `9ca461e` and of the
milestone before it, so the forward-only gate accepts them in this order.

**Never promote these commits [V]:**

- `59ba395` (266 alone): its staging post-deploy verification failed.
- `dfdb379` (263 without 270): CI failed. On staging, 263 alone made the
  canonical Energy read take about 25 minutes for fingerprint reads.
- `96d2893` (253–262 without 287): the assignment Save path moves ACTIVE
  assets into COMMISSIONING. 287 fixes this.

**Why three releases.** A cannot be merged into anything: 266 is first.
B and C are separate because their main risks differ (B: chunk locks and
the Grafana Energy read switch; C: ingest cadence, the new F1 job and the
deadlock fix). On the IO-limited production host, combining them would make
a regression hard to attribute. **Migration 301 ships last in C**, in its
manifest position. No pending migration changes the two loader bodies that
301 replaces, and nothing depends on 301 [V].

**Non-migration content [V].** The releases also deploy the app image and
the repository at the milestone commit. There are no `compose.yaml`,
Grafana, Telegraf or env-file changes in any range.

- A: generated env-loader code.
- B: Analytics API.
- C: Analytics API, Admin Portal asset point assignment
  (`app/src/main.py`, `asset_detail.html`, `asset_point_assignment*.py`),
  `verify_jobs.sh`, `deploy-production.yml`.

`deploy-production.yml` does not deploy the Web SPA bundle. Production
therefore gets the Analytics API but not the Analytics UI. This is by
design until a production frontend rollout is separately authorized
([PHASE8_FRONTEND_DEPLOYMENT.md](../operations/PHASE8_FRONTEND_DEPLOYMENT.md#production-promotion--later-same-immutable-artifact)).

## 3. Migration readiness

Every migration below is applied and verified on staging [V].

| Migration | Change | Production dependency or risk | Status |
|---|---|---|---|
| 266 | Activates the four `point_telemetry_1h` jobs (forward every 15 min, reconcile 22:30 UTC, compression, retention) | **G1.** The forward job's first run looks back only 2 days, so the 1h backfill must reach (activation − 2 days) first. That first run refreshes about 50 hours in one call under a 10-minute `max_runtime`, and compression of chunks older than 30 days starts right after activation: both are IO-heavy (section 4) | **Blocked** |
| 267 | Routing loaders bound `window_end` to `event_time ≥ now() − 1 day` | Asserts the loader bodies and `compress_after = 1 day` | Ready, precheck P4 |
| 268 | Reconstruction columns and NOT VALID checks on compressed `analytics.energy_consumption_1min/5min`; `config.energy_reconstruction_scope` (disabled) | **ACCESS EXCLUSIVE lock on every chunk. No pending migration sets `lock_timeout`** [V] | Ready, dispatch window (B) |
| 269 | Measured-vs-reconstructed views and refresh functions; switch stays OFF | Output unchanged | Ready |
| 263 | `analytics.get_canonical_energy_read` (used by Grafana) moves from PRIMARY_METER to `asset_points` | Needs the 112-row production parity bridge [P] and 269 | Ready, **G2** |
| 270 | Selective device reads for 263 | Must ship with 263 | Ready |
| 279, 275–278, 280 | Analytics v1 reads. 275 blocks site timezone edits once a site has telemetry | 280 drops 278's function; the app changes in the same milestone | Ready |
| 281 | Fixes 279's 15m checkpoint boundary | Must ship with 280 | Ready |
| 282–286 | Analytics fixes and read performance. 282 replaces a 6-argument function with a 7-argument one | App changes in the same milestone | Ready |
| 253–262 | Asset point assignment: Save path, commissioning backfill (job registered, **left unscheduled**), unit categories | Must ship with 287 | Ready with 287 |
| 287 | Save commissions DRAFT assets only; removes defective PENDING records | Raises if more than 2 defective records. The table is new on production | Ready |
| 288, 289 | Catalogue assignment periods; power units W→kW, VA→kVA, VAR→kvar (metadata) | None | Ready |
| 290 | F1 register-delta 15m tier. Its forward job backfills history oldest-first, 1 day per run | **Deadline.** Production IO cost unknown (staging: 4.2 s average per run) | Ready, deadline |
| 291 | Environment loader UPDATE bounded to correctable buckets ([pipeline.md](../06-platform/telemetry/pipeline.md)) | **Deadline.** The production loader fails once compressed rows exceed 100,000 | Ready, deadline |
| 292, 293 | B3 point series and plan fixes | Must ship together (292 alone timed out on staging) | Ready |
| 294, 295 | Staging-only one-time history restores | No-op on production: 0 rows at both anchors [P]. **Never call these functions on production**: they hard-code staging UUIDs | Ready (inert) |
| 297 | Reconcile windows aligned to the tier grain | md5 preconditions on the migration-213 bodies | Ready, precheck P6 |
| 298 | Demand job every 15 min at :07/:22/:37/:52 UTC | Needs exactly one demand job; staging 24 h acceptance passed 2026-10-14 | Ready, precheck P7 |
| 299 | `normalized_receiving_threshold_seconds` = 600 | Changes customer-visible freshness; prerequisite of 300 | Ready, decision D4 |
| 300 | Six ingest jobs to fixed 5-minute batches | Raises unless all six run every minute, 298 is in place and 299's threshold is ≥ 480. **Staging 24 h acceptance due 2026-10-15 ~11:53 UTC** | **Blocked (G3)** |
| 301 | Deadlock fix: `device_telemetry_state` upserts ordered by `device_id` | md5 pins on the two loader bodies (identical on staging and production [P]). Only production can show the effect: no new 40P01 | Ready, ships last |

Reverse steps are described in the headers of 298, 299 and 300 (and other
migration headers); none is a tested script. 297's header points to
`docs/10-operations/prepared/T1.1/297_rollback.sql`, which is **not
committed** to `staging` [V] (it exists only as uncommitted local work).

## 4. Gates

### G1: 1h backfill frontier (blocks Release A and therefore everything)

- [P] Production `analytics.point_telemetry_1h` is filled from 2026-09-04
  00:00 to 2026-09-24 06:00 UTC (1,248,796 rows, validated per hour). The
  backfill is **paused**.
- The backfill runner is an operator tool installed on the production host,
  outside this repository. It calls `analytics.backfill_point_telemetry_1h`
  hour by hour and stops on health gates.
- [P] One of those gates is a job-failure baseline: the sum of
  `timescaledb_information.job_stats.total_failures` for every job except
  1114. The runner records the current value at launch and stops the run if
  it rises. The last accepted baseline was 2832 (2026-10-13). Production is
  now at **2834** after two 40P01 deadlocks on 2026-10-14 (job 1060 at
  04:57 IST, job 1000 at 05:22 IST), with no backfill running. This plan does
  not change the baseline; the policy below needs a decision (D1).
- [P] These deadlocks are the lock-order race that migration 301 fixes.
  About eight were seen in the week to 2026-10-14. Until Release C they will
  keep raising the count, so a fixed baseline blocks every future run, and
  any run lasting several hours has a real chance of being stopped by one [E].

**Proposed baseline policy (not approved).**

1. Before each launch, run R4 from the fact refresh (section 5). Accept the
   current count as the new baseline only if every job error since the last
   accepted baseline is SQLSTATE 40P01 in job 1000 (`run_normalization_job`)
   or job 1060 (`run_raw_receipt_state_job`), and no job's last run failed
   (`failed_non1114 = 0`). Record the accepted value and time.
2. Any other job, any other SQLSTATE, or a job still in a failed state: do
   not launch; report.
3. During a run the runner's gate stays strict: any increase stops the run.
   Archiving the STOP file and resuming still need approval each time.
4. The exception ends at Release C. After 301, any 40P01 is a regression to
   investigate, not a known cause.

**Timing rule for the activation frontier [V from migration 265 code].**

- The forward job's first run (checkpoint NULL) starts at `now − 2 days` on
  the hour and also re-derives a 2-hour overlap before it.
- [P] The runner refuses windows ending within 48 hours of the latest closed
  15m hour.
- So the final top-up must finish no more than about 1.5 hours before the
  first forward run, which is the next :07/:22/:37/:52 UTC slot after the
  deploy. In practice: top up, then dispatch A immediately.
- [E] The first run refreshes about 50 hours in one call against a 10-minute
  `max_runtime`. [P] Production call times at baseline IO were 2.6–76 s per
  hour, so the call may time out at baseline. It then rolls back and retries
  (3 retries, 5 minutes apart) without losing data. In burst windows calls
  took 0.3–1.8 s per hour. Dispatch A in a burst window.
- [E] For a dispatch on about 2026-10-20, about 580 hours remain (from Sep 24
  07:00 UTC). At observed rates that is roughly 25–45 hours of runner time
  at baseline IO, much less in burst windows. Each day of delay adds 24
  hours of backlog.

**Why not activate 266 with the gap and let reconcile fill it [V from
migration 265 code and 266's job settings].**

- The reconcile job repairs at most 7 days per night, at 22:30 UTC (04:00
  IST), with a 30-minute `max_runtime`. The whole run is one transaction: a
  timeout rolls back every day it repaired.
- [P] At baseline IO one backfill day took 25–59 minutes. A 7-day repair is
  very unlikely to finish in 30 minutes, so the gap would probably never
  shrink. Each attempt (up to 4 per night) holds the forward job's advisory
  lock, so the 1h tier stops advancing meanwhile, and every timeout adds job
  failures.
- [V] On staging the nightly reconcile has never had to repair anything
  (0 mismatches every night since 2026-09-25, 45–64 s per run), so large
  repairs are untested anywhere.
- It only looks back 35 days from the checkpoint. Gap hours older than that
  are never examined: Sep 24 07:00 UTC leaves the window if activation is
  later than about 2026-10-29.
- [A] Gaps stay repairable while the 15m tier holds the source data
  (120-day retention, so until about early January 2027 for 2026-09-04).

### G2: Energy parity for 263 (Release B)

Before dispatch, capture a parity baseline of
`analytics.get_canonical_energy_read` for the 56 PRIMARY_METER assets and
confirm bridge coverage. After deploy, compare against the same ranges. The
pass criterion is decision D3.

### G3: Migration 300 staging acceptance (Release C)

The staging 24-hour acceptance for 299/300 must pass. It is due
2026-10-15 ~11:53 UTC. If it fails, or is not passed by about
2026-10-26, use C1 then C2 so that 290 and 291 are not held back.

## 5. Read-only production prechecks

Each needs explicit authorization.

**Fact refresh (once, before the Release A decision is acted on).**
`scripts/diagnostics/prod_release_266_301_fact_refresh.sql` re-checks every
[P] fact in this document in one read-only transaction that ends in
ROLLBACK. It was validated read-only on staging (about 7 seconds).

| Query | Refreshes |
|---|---|
| R1 | Ledger 131 rows, head 265; digest of applied rows. Expected digest, from staging's matching 131 rows: `86ddfe42b46b281cb77491133d839909` |
| R2 | 1h frontier and row count |
| R3 | The four 1h jobs (unscheduled, 265 settings) and their NULL checkpoint |
| R4 | Failure counter as the runner computes it, and every job error since the 2832 baseline |
| R5 | 267 preconditions (P4) |
| R6 | 301 md5 pins (P8) |
| R7 | Retention policies (90-day raw, 120-day 15m source) |
| R8 | Oldest `energy_measurements` chunks up to the first with two or more devices (F1 deadline) |
| R9 | Rows in compressed `environment_measurements` chunks (291 deadline) |
| R10 | Parity bridge: 112 rows, 56 assets, no other `asset_points` rows |

**Release prechecks.** Run them immediately before the release that depends
on them.

| Check | Confirms | Release |
|---|---|---|
| P1 | Ledger row count and head; checksums of applied rows match the repository | Every release |
| P2 | `scripts/apply_migrations.sh --status` lists exactly that release's migrations as pending, in manifest order (call the script directly, not a test wrapper) | Every release |
| P3 | 1h jobs still unscheduled with their 265 configuration; 1h frontier meets G1 | A |
| P4 | Routing loader bodies match migrations 215/228; `normalized_points` `compress_after` = 1 day | A |
| P5 | Bridge coverage and parity baseline (G2) | B |
| P6 | Migration-213 function md5s expected by 297 | C |
| P7 | Exactly one job for each 298/300 target; all six 300 targets on 1-minute schedules; capture policies within 60 + 60 s | C |
| P8 | Loader md5s expected by 301 | C |
| P9 | Compressed `environment_measurements` row count (291) and oldest non-empty `energy_measurements` chunk (290) | C |
| P10 | No backfill or STOP active; failure count unchanged since the last check; job 1053 (compression) not running or due | Every release |

## 6. Deployment procedure (each release)

1. Get explicit approval for the release, its gate and its prechecks.
2. Run the prechecks (section 5). Stop on any mismatch.
3. Dispatch `deploy-production.yml` from GitHub Actions with
   `release_git_sha` and `confirm_release_git_sha` both set to the full SHA
   from section 2, and `promotion_mode=staging-milestone`. Never use
   `staging-head` for these releases: staging may move ahead.
4. The workflow checks the operator allowlist, the SHA confirmation, the
   staging deploy run, ancestry and forward-only movement. It then pins the
   image digest, checks out the commit on the host, applies the pending
   manifest rows and recreates `admin-portal` and `live-telemetry` only.
5. `verify-production` must pass its three REQUIRED gates: Database
   Structure, Metadata Integrity and Energy Routing Metric-Identity. The
   pipeline and job suites are advisory.

**No out-of-band path.** Do not apply migrations by hand, edit the manifest
or patch the host. If the workflow refuses, stop and investigate.

**A release can stop partway.** Each migration commits on its own. If one
fails (for example a precondition), the earlier migrations of that release
stay applied. `deploy_release.sh` (`set -e`) then stops before step 5, so the
running containers keep the old image while the host checkout is already at
the release commit [V]. That is why the md5 and
job prechecks run before dispatch, not after.

### Stop conditions

Stop and report, without retrying, if any of these happen:

- a precheck mismatch;
- the workflow refuses the dispatch;
- a migration error or checksum mismatch;
- a failed REQUIRED gate;
- new job failures after deploy (other than the known 40P01 pattern before C);
- routing lag that does not return to its pre-deploy range;
- an Energy parity mismatch after B.

### Evidence of success

| Release | Required evidence |
|---|---|
| All | Run succeeded; REQUIRED gates passed; ledger shows exactly the release's migrations as `applied` with checksums equal to staging; no new job failures |
| A | First 1h forward run succeeds (checkpoint no longer NULL) and later runs advance it; no 1h hour missing between Sep 4 and the checkpoint; first nightly reconcile succeeds; routing jobs 1001/1012 show lower runtime; observe ≥ 48 h before B |
| B | Parity comparison passes D3; Grafana Energy panels load; no lock waits from 268 left behind; Analytics API endpoints respond |
| C | Six ingest jobs on the 5-minute phases; demand job at :07/:22/:37/:52; F1 forward job advancing through history; environment routing succeeds; no 40P01 over the following days |

## 7. Rollback limits

- `rollback.yml` redeploys an earlier image only. It does **not** reverse
  migrations ([rollback.md](rollback.md)).
- Database changes are forward-only. Reversal means a new forward migration
  or the reverse steps in a migration header (section 3), each with its own
  approval.
- An image rollback leaves the new database functions in place. 280 and
  282 drop `get_portal_analytics_energy_series` (6 arguments) and
  `get_portal_asset_energy_series` (6 arguments). The `9ca461e` app calls
  neither [V], so rolling back to it after B is compatible. For any other
  target image, check its calls against the functions changed since.
- 268's columns and constraints stay after any rollback.

## 8. Target dates (all [E])

| Release | Earliest | Depends on |
|---|---|---|
| A | about 2026-10-20 | G1 and D1 |
| B | about 2026-10-22 | A + 48 h, G2, D3 |
| C | about 2026-10-24, target no later than 2026-10-27 | B, G3, D2, D4, D5 |

The product-owner target for F1 (290) is 2026-10-27, with no retention
changes. [P] Evidence from 2026-10-11 shows `energy_measurements` chunks
before 2026-08-04 are empty, so real loss starts about 2026-11-03 (one row)
and becomes multi-device about 2026-11-08. Migration 291's failure point is
about early-to-mid November [E] (about 43,600 compressed rows on 2026-10-08,
growing about 10,000 per week). Re-measure both with P9.

## 9. Product-owner decisions (unresolved)

None of these is assumed approved.

| # | Decision | Options |
|---|---|---|
| D1 | How to meet G1 | (a) Resume the 1h backfill under the proposed baseline policy, then top up and dispatch A in one burst window (recommended). (b) Activate 266 with the gap and rely on the nightly reconcile (section 4: likely never completes at baseline IO). (c) Activate 266 and leave a permanent 1h gap from Sep 24 07:00 UTC to activation − 2 days |
| D2 | F1 deadline and fallback | Keep 2026-10-27 or set it from the 2026-11-03 evidence; approve the C1/C2 split if 300 is not ready |
| D3 | Release B parity pass criterion | Proposed: zero mismatches against the baseline |
| D4 | 299/300 on production | Accept the 600 s freshness rule and 5-minute ingest batches |
| D5 | Admin Portal assignment on production | Release C makes "Assign Data Points" Save live |
| D6 | Analytics UI on production | Confirm production stays API-only until a separate frontend rollout |
| D7 | Routing job runtime limits | After A, whether to restore jobs 1001/1012 `max_runtime` from 30 to 5 minutes (separate approval) |
