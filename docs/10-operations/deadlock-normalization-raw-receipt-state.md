# Deadlocks between normalization and raw-receipt-state jobs (migration 301)

Status: DEPLOYED TO STAGING, NOT ON PRODUCTION · Last reviewed: 2026-10-14
Verification basis: Production (read-only), Staging (read-only), Repository, local test database

## Symptom

Production job failures with SQLSTATE `40P01` (deadlock detected). The
retained server log (2026-10-06 → 2026-10-14) holds 8 deadlocks;
`timescaledb_information.job_errors` shows more back to 2026-09-16 (job 1000:
4, job 1060: 5 at the time of the investigation). Every one is the same pair:

| Job (production id) | Procedure | Loader |
|---|---|---|
| 1000 (every minute at :24) | `telemetry.run_normalization_job` | `telemetry.load_normalized_points_incremental` |
| 1060 (every minute at :51) | `telemetry.run_raw_receipt_state_job` | `telemetry.load_device_raw_receipt_state_incremental` |

On staging the raw-receipt-state job is **1076**, and since migration 300
normalization runs every 5 minutes at +2:40 while 1076 stays every minute.

Each log entry: both transactions wait for `ShareLock` on the other's
transaction "while inserting index tuple … in relation
`device_telemetry_state`".

## Cause

The two loaders are the only writers of `telemetry.device_telemetry_state`
(one row per device). In both, the last write before the checkpoint update is
a multi-row `INSERT … SELECT … ON CONFLICT (device_id) DO UPDATE` with no
`ORDER BY`:

- job 1000 aggregates with `GROUP BY b.device_id`; the HashAggregate emits
  devices in hash order;
- job 1060 reads `tmp_raw_receipt_batch`, which is built in device order, but
  that order is not guaranteed.

When a job 1000 run lasts longer than ~28 s it overlaps the job 1060 run and
the two lock device rows in different orders. Every production event resolved
at second :54–:56, i.e. only when job 1000 had run long. Slow checkpoint
syncs were seen near 6 of the 8 events (a correlation, not proven). The two
advisory locks use different keys, so they do not keep the jobs apart.

The backfill is not required: the 2026-10-13 and 2026-10-14 events happened
with no backfill running. This is separate from the `COMMIT` waits on the
NOTIFY queue lock seen from `telemetry.ingest_live_rtdata` (a different
session type, table and lock).

## Impact

No data loss. The failed run rolls back and its checkpoint does not move; the
next run re-reads its window (overlap 15 min / 2 min). Cost: about one minute
of delay per event, and one job failure each (which counts against the 1h
backfill's job-failure gate).

## Change (migration 301)

One line in each loader; everything else byte-identical (md5 pre- and
postconditions):

```sql
-- telemetry.load_normalized_points_incremental (was migration 221)
    GROUP BY b.device_id
    ORDER BY b.device_id          -- added
    ON CONFLICT (device_id) DO UPDATE

-- telemetry.load_device_raw_receipt_state_incremental (was migration 007),
-- device_telemetry_state upsert only
    FROM tmp_raw_receipt_batch
    ORDER BY device_id            -- added
    ON CONFLICT (device_id) DO UPDATE
```

Both writers now lock `device_telemetry_state` rows in ascending
`device_id`, so they cannot deadlock on that table: the later one waits for
the earlier one to commit. Neither holds a lock the other needs on any other
table at that point, so no shared advisory lock is needed. Not changed: job
schedules, configs, `log_lock_waits`, any other statement, table, data or
grant.

| Body | md5 before (live staging and production, 2026-10-14) | md5 after |
|---|---|---|
| `load_normalized_points_incremental` | `cb1b3f00129bbc2c6c8e85b06905e540` | `f1b39ab20a2cd3a4059147d0bb1bef8e` |
| `load_device_raw_receipt_state_incremental` | `e9b3522a2e4189ad8d34eb885b875303` | `7e2112edee424957ea00289ce449a622` |

## Validation

- `scripts/test/assert_device_telemetry_state_upsert_lock_order.sh`
  (integration suite) runs multiple sessions. A blocker holds the middle of
  40 fixture rows; a probe (`FOR UPDATE SKIP LOCKED`) shows which rows the
  waiting writer already holds:
  - both installed upserts hold exactly rows 1–19 (ascending), even with
    descending or shuffled input and HashAggregate forced;
  - pre-fix statements: job 1060's follows its input order (21–40), and job
    1000's follows hash order (not ascending);
  - **deadlock reproduction:** the pre-fix job 1060 upsert and the job 1000
    upsert, both blocked and then released, give exactly one `40P01`;
  - **fixed pair:** both installed upserts complete with no error;
  - end-to-end `CALL load_device_raw_receipt_state_incremental` locks in
    ascending order and finishes `SUCCESS`.
- `app/tests/test_device_telemetry_state_upsert_lock_order.py` pins the
  migration file: only the two loaders change, one line each, md5 pins,
  manifest.
- Not run end to end: `CALL load_normalized_points_incremental`, which needs a
  full mapping and capture-policy fixture. The test runs the installed
  statement text instead, and the md5 check proves that text is the
  procedure's.

## Staging results (2026-10-14, read-only)

PR #135 squash-merged as `b1c8b09` at 13:08 UTC. "Deploy to Staging" run
38569347439 succeeded: all CI gates passed, the artifact was deployed and
post-deployment verification passed.

- **Migrations:** the runner printed `SKIP` for 298–300 (already applied) and
  `APPLY` for 301 only. In the ledger, 301 was applied 2026-10-14 13:17:00 UTC
  by `ems_admin` in 65 ms (sha256 `3568c0a8ba7f…`). The 299/300 rows still have
  their 2026-10-14 11:36 UTC times.
- **Gates:** the required Database Structure, Metadata Integrity and Energy
  Routing gates passed, as did the advisory Job Verification. The advisory
  Telemetry Pipeline check failed, but only because `energy_consumption_5min`
  reports `NO_SOURCE_DATA`, a known staging commissioning gap that predates
  this change.
- **Bodies:**

  | Procedure | md5 now | md5 with the added line removed |
  |---|---|---|
  | `load_normalized_points_incremental` | `f1b39ab20a2cd3a4059147d0bb1bef8e` | `cb1b3f00129bbc2c6c8e85b06905e540` |
  | `load_device_raw_receipt_state_incremental` | `7e2112edee424957ea00289ce449a622` | `e9b3522a2e4189ad8d34eb885b875303` |

  Both "now" values equal the 301 pins. Removing the one added line gives
  exactly the previous md5, so the added line is the only difference. Owner
  (`ems_admin`), `SECURITY INVOKER` and `proconfig` (none) are unchanged.
- **Plans:** plain `EXPLAIN` was run on the installed upsert text, with the
  temporary batch table replaced by a `generate_series` subquery. Before 301,
  the job 1000 plan fed the Insert straight from a `HashAggregate`, and the
  raw-receipt plan had no Sort. After 301, both plans put a
  `Sort (Sort Key: device_id)` directly under the Insert; in job 1000 it sits
  above the `HashAggregate`.
- **Jobs**, from the 301 apply (13:17 UTC) to 14:01 UTC:

  | Staging job | Function | Runs | New failures | Cumulative failures |
  |---|---|---|---|---|
  | 1000 `run_normalization_job` | every 5 min at +2:40, about 2.4 s | 9 | 0 | 106 (unchanged) |
  | 1076 `run_raw_receipt_state_job` | every minute | about 44 | 0 | 81 (unchanged) |
  | 1060 `policy_refresh_continuous_aggregate` | `ca_energy_1min` refresh; on production, 1060 is the raw-receipt job | 9 | 0 | 0 |

  - No `job_errors` entry for these jobs in the last 24 h.
  - Staging has never recorded a `40P01`.
  - `timescaledb.enable_job_execution_logging` is off, so `job_history` holds
    failures only, and it has none since 301 was applied.
  - Run counts are derived from the schedule and from `job_stats` (last run
    `Success`, failure counts unchanged).
- **Limit of this evidence:** staging cannot reproduce the race. Job 1000
  runs at second :40 for about 2.4 s, and 1076 starts at second :49, so the two
  never overlap and staging never deadlocked. Staging shows that 301 applies
  cleanly, installs the intended bodies and plans, and causes no regressions.
  The lock-order fix itself is proven by the multi-session integration test
  (above). On production, the proof is days with no `40P01`.

Production results are recorded here when they exist.

## Checks after deploying (read-only)

```sql
-- migration applied, bodies are the 301 bodies
SELECT migration_id, applied_at FROM admin.schema_migrations
WHERE migration_id = '301_device_telemetry_state_upsert_lock_order';
SELECT p.oid::regprocedure, md5(replace(p.prosrc, E'\r', ''))
FROM pg_proc p
WHERE p.oid IN ('telemetry.load_normalized_points_incremental(interval,interval)'::regprocedure,
                'telemetry.load_device_raw_receipt_state_incremental(interval)'::regprocedure);

-- both jobs keep succeeding; no new 40P01 from either
SELECT job_id, last_run_status, last_successful_finish, total_failures
FROM timescaledb_information.job_stats
WHERE job_id IN (SELECT job_id FROM timescaledb_information.jobs
                 WHERE proc_name IN ('run_normalization_job', 'run_raw_receipt_state_job'));
SELECT job_id, start_time, sqlerrcode FROM timescaledb_information.job_errors
WHERE sqlerrcode = '40P01' ORDER BY start_time DESC LIMIT 10;
```

Production had about one deadlock per day before the fix, so it takes days
without a `40P01` to show the fix works, not hours.

## Rollback

There is no data component. Re-issue the previous bodies (migration 221 for
the normalization loader, migration 007 for the raw-receipt-state loader;
md5 values above) in a new forward migration through the normal pipeline.
Do not edit migration 301 (the ledger checksum would fail). Rolling back
brings back the deadlock risk and nothing else.

## Remaining risks

- A future change that adds a writer of `device_telemetry_state`, or another
  table written by both jobs, must lock rows in the same `device_id` order.
- The fix stops the deadlock, not the waiting: when job 1000 runs long, the
  later job now waits until the earlier one commits (at most one run of the
  other job).
- Long job 1000 runs (slow WAL/disk) are tracked separately with the
  `COMMIT`/WAL contention investigation.
