# Deadlocks between normalization and raw-receipt-state jobs (migration 301)

Status: STAGING VALIDATION PENDING (production unchanged) · Last reviewed: 2026-10-14
Verification basis: Production (read-only), Repository, local test database

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

Staging and production results are recorded below when they exist.

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
