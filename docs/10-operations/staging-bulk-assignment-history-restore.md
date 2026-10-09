# Staging: one-time history restore for the 9 October 2026 bulk assignment

Status: PLANNED (migration 294 implemented, not deployed; no restore executed) · Last reviewed: 2026-10-10
Verification basis: Repository, local test database, Staging (read-only)

## Why

On staging, 55 audited `admin.save_asset_point_assignments()` calls at
**2026-10-09 12:56:55.116554 IST** (the bulk assignment) added **3,021**
`metadata.asset_points` rows to the 54 ACTIVE assets. Save starts every new
assignment at `now()` and ACTIVE assets are never backfilled (ADR-018
decision 6, migration 287), so these points show history only from the bulk
time, although every meter has valid readings from 24–29 August.

**Decision (Product Owner, 2026-10-09):** restore this history once, as an
exception. ADR-018 is not changed. Start = the first valid reading of each
meter point within the existing 90-day limit (Amendment 8); only move starts
earlier; never `-infinity`; preserve deliberate gaps (Banquet 2 AHU Energy
Export, 2026-10-05 21:04 → 2026-10-09 12:56) and the AirSense relationship
boundary (with Banquet 1 AHU until 2026-09-09 17:22:53); keep
P1-HeatVentUnit-01 unchanged; never expose unassigned meter history.

## Mechanism (migration 294)

`admin.restore_bulk_assignment_history_20261009(actor, gateway_id, dry_run
DEFAULT true, confirm_restore_count DEFAULT NULL)` -- a one-time wrapper
around `admin.restore_bulk_assignment_history_core`. Not granted; run as
`ems_admin` by an operator, one gateway per call. The existing commissioning
backfill is not used: it refuses ACTIVE assets and its lower bound would
fill the Banquet 2 AHU gap.

Per call:

1. Refuses unless exactly 55 bulk audit records with 3,021 added rows exist
   (none → nothing to do).
2. Plans every bulk row on the gateway's meters: `RESTORE`,
   `NO_CHANGE_NO_HISTORY`, `EXCLUDED_ASSET` (P1-HeatVentUnit-01),
   `EXCLUDED_ASSET_NOT_ACTIVE`, `SKIPPED_CLOSED`, `SKIPPED_START_CHANGED`,
   `EXCLUDED_OTHER_BINDING` (another assignment of the same meter point --
   the deliberate gap), `EXCLUDED_SHARED_METER`.
3. Proposed start = first GOOD reading in [max(now − 90 days, latest archived
   relationship of the meter), current start), found with two bounded index
   probes (the GOOD-only 15-minute row, then the raw reading inside it).
4. Dry run: returns the plan, writes nothing (runs in a read-only session).
5. Execution: requires `confirm_restore_count` = the dry run's RESTORE count;
   changes `effective_from` only, only for rows still open at the bulk time;
   writes one `admin.onboarding_audit` record (`RESTORE_BULK_ASSIGNMENT_HISTORY`)
   with every row's before/after start and every other row's reason. Any
   mismatch aborts the whole call.

Read-time paths (B3 measurements, per-phase Energy, the Analytics catalogue)
show restored history immediately. Persisted asset-level results (Demand
intervals, environment routing) are not recomputed.

## Dry-run plan (staging, read-only, 2026-10-09/10)

Computed per gateway with the same rules (scoped queries, 8–20 s each). All
3,021 rows were still open at the bulk time; 55 audits intact.

| Gateway | Assets | Rows | Restore | of which B3 points | Excluded | Proposed starts (IST) | ~15-min periods per point |
|---|---|---|---|---|---|---|---|
| ENISCOPE_1_CHILLER | 8 | 447 | 447 | 255 | 0 | 08-28 12:14:58–59 | 3,595 |
| Eniscope_3_AHU | 8 | 457 | 456 | 254 | 1 (Banquet 2 AHU Energy Export gap) | 08-28 12:37:24; AirSense 09-09 17:23:00 | 3,566 |
| Eniscope_4_Main_Kitchen | 8 | 448 | 448 | 256 | 0 | 08-28 12:25:58–59 | 3,044 |
| Eniscope_2_Plumbing | 8 | 448 | 448 | 256 | 0 | 08-29 11:33:57–11:35:57 | 1,839 (outages) |
| Eniscope_1_Meenaxy_Unit2 | 8 | 448 | 448 | 256 | 0 | 08-24 20:55:58 – 08-25 16:31:59 | 3,719 |
| Eniscope_2_Meenaxy_Unit2 | 8 | 437 | 381 | 213 | 56 (P1-HeatVentUnit-01) | 08-24 20:55:58 – 08-25 16:31:59 | 3,719 |
| Eniscope_3_Meenaxy_Unit2 | 6 | 336 | 336 | 192 | 0 | 08-24 20:55:58 – 08-25 16:31:59 | 3,363 |
| **Total** | **54** | **3,021** | **2,964** | **1,682** | **57** | | |

No row lacks history. The function recomputes the plan at run time; its dry
run is the authoritative count for the confirmation.

Out of scope: the 15 assignments saved on 2026-10-05 (Banquet 2 AHU Power,
Power Factor, temperature, humidity; EN-AirCompressor-01's 11 points) keep
their 10-05 start (separate investigation), and the 108 System Energy
stand-in rows (separate proposal, below).

## Procedure (each step needs explicit approval)

1. Deploy migration 294 through the normal staging pipeline.
2. Per gateway, in this order (Unit 2 first: its history is the oldest and
   expires first): Eniscope_1/2/3_Meenaxy_Unit2, ENISCOPE_1_CHILLER,
   Eniscope_3_AHU, Eniscope_4_Main_Kitchen, Eniscope_2_Plumbing.
   1. Dry run in a read-only session with `statement_timeout` 120 s:
      `SELECT action, count(*) FROM admin.restore_bulk_assignment_history_20261009('<operator>', '<gateway id>') GROUP BY 1;`
   2. Review against the table above; approve the RESTORE count.
   3. Execute in its own transaction, `statement_timeout` 120 s, `lock_timeout` 5 s:
      `SELECT count(*) FROM admin.restore_bulk_assignment_history_20261009('<operator>', '<gateway id>', FALSE, <count>);`
   4. Verify read-only: a re-run dry run shows the restored rows as
      `SKIPPED_START_CHANGED`; the Analytics catalogue and a B3 series for one
      asset show history from the proposed start; the excluded rows are
      unchanged. Stop at the first error or dropped connection.

## Deadline

Raw readings (`telemetry.normalized_points`, 90 days) for Unit 2 from
08-24 20:55 fall outside the 90-day window on **2026-11-22**, Coimbatore's
from 08-28 on **2026-11-26** (chunks drop from about 11-25). Complete by
**2026-11-15**. The 15-minute tier (120 days) keeps history to about
2026-12-22/26.

## Rollback

The audit record of each executed call lists every restored row with
`effective_from_before` (the bulk time). Restoring them is an explicit,
separately approved write. Dropping migration 294's four functions removes
the capability without touching data.

## System Energy stand-in rows (separate proposal; unchanged)

The 108 `-infinity` rows (Energy Import/Export of every asset, written
2026-09-25 21:06) are left untouched. Assessed one meter at a time
(6–7 s each, read-only): narrowing each to its meter's first good register
reading would hide **no** 15-minute and **no** 1-minute System Energy rows on
any of the 54 meters; the only rows near the boundary are the first 15-minute
periods that straddle the first reading (7.408 kWh in total), which stay with
the assignment that starts inside them (the Energy read's rule, see
`test_binding_change_inside_a_15m_bucket_incoming_source_owns_it`).

## Related

- [incident-history.md](incident-history.md) -- the 2026-10-09 staging
  crash-restart caused by an unscoped read-only query during this analysis.
- ADR-018 decisions 4–8, Amendments 6 and 8; migrations 255, 256–258, 287.
