# Staging: one-time history restore for the 9 October 2026 bulk assignment

Status: EXECUTED on staging 2026-10-10 (migration 294 deployed by PR #118, squash 47d8065) · Last reviewed: 2026-10-10
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

## Procedure (each step needed explicit approval)

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

## Execution record (staging, 2026-10-10 IST)

Each gateway: authoritative dry run of the deployed function (matched the
plan above row for row: same rows, actions and proposed starts), explicit
Product Owner approval, one transaction (`statement_timeout` 120 s,
`lock_timeout` 5 s), then read-only verification (re-run dry run shows every
restored row as `SKIPPED_START_CHANGED` at its approved start; audit
before/after consistent; other gateways, the 108 stand-in rows and the 15
rows of 2026-10-05 unchanged; staging healthy -- no crash recovery, no failed
jobs, normalization at its usual lag).

| Order | Gateway | Restored | Not restored | Audit record (`admin.onboarding_audit.id`) | Executed (IST) |
|---|---|---|---|---|---|
| 1 | Eniscope_1_Meenaxy_Unit2 | 448 | 0 | `b5099d1c-300b-47ec-8f25-7d2226e9e0a0` | 00:35:46 |
| 2 | Eniscope_2_Meenaxy_Unit2 | 381 | 56 (P1-HeatVentUnit-01) | `f463d67b-db62-4f71-894e-d2f25e7dffe9` | 00:37:43 |
| 3 | Eniscope_3_Meenaxy_Unit2 | 336 | 0 | `7f879f70-4453-4445-8783-c96c1769f04b` | 00:38:41 |
| 4 | ENISCOPE_1_CHILLER | 447 | 0 | `e0233925-311d-4787-8bb5-d99fd7141f79` | 00:39:44 |
| 5 | Eniscope_3_AHU | 456 | 1 (Banquet 2 AHU Energy Export gap) | `41672287-1e12-45c7-bae5-8acdc5fcf20f` | 00:41:28 |
| 6 | Eniscope_4_Main_Kitchen | 448 | 0 | `aa9d4224-3e90-488a-95a7-294ce1ff9cb2` | 00:42:27 |
| 7 | Eniscope_2_Plumbing | 448 | 0 | `91c9f653-6d49-4e00-a386-8f107bf0089a` | 00:43:10 |
| | **Total** | **2,964** | **57** | | |

Spot checks after the restore: Analytics history for P1-CoatingPan-01,
Chiller1 and Banquet 2 AHU starts at the restored first reading (the partial
first hour counts only readings after it; earlier hours are not assigned);
Banquet 2 AHU daily System Energy still has no Export on 10-06 to 10-08; the
AirSense points start 2026-09-09 17:23:00.72; the Plumbing assets' history
ends 2026-10-08 16:00 (gateway offline since 10-08 15:47, separate
investigation). The 15 assignments of the 2026-10-05 test Saves were restored
separately on 2026-10-10 (below).

## 2026-10-05 test assignments (restored 2026-10-10)

Three audited Saves on 2026-10-05 (21:02:56 EN-AirCompressor-01, 11 points;
21:04:25 Banquet 2 AHU Power and Power Factor -- the same Save closed Energy
Export, the deliberate gap; 21:05:25 AirSense temperature and humidity)
were not part of the bulk audits, so their points kept their 10-05 start.
With Product Owner approval they were restored with the deployed migration
294 core (`admin.restore_bulk_assignment_history_core`, one Save per call,
expected 1 audit / n rows), each after an immediate dry run matched the
approved starts:

| Package | Restored | New start (IST) | Audit record | Executed (IST) |
|---|---|---|---|---|
| A: EN-AirCompressor-01 | 11 | Power System 2026-08-25 16:31:58; others 2026-08-24 20:55:58 | `cf1bfec7-1eb7-4f81-936f-dd746663b1eb` | 2026-10-10 10:42 |
| B: Banquet 2 AHU Power, Power Factor | 2 | 2026-08-28 12:37:25 | `929fc4c0-5cff-4138-a306-bcc56a0170b1` | 2026-10-10 10:42 |
| C: AirSense temperature, humidity | 2 | 2026-09-09 17:23:00.722 (after the Banquet 1 AHU boundary 17:22:53) | `1a6f4018-8527-4023-ab10-ce051d8784b1` | 2026-10-10 10:42 |

Verified after each: the re-run dry run reports `SKIPPED_START_CHANGED`;
audit before/after consistent; Banquet 2 AHU daily System Energy still has
no Export on 10-06 to 10-08; every AirSense point starts 09-09 17:23:00.722;
the 108 stand-in rows unchanged; staging healthy.

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

## System Energy stand-in rows (migration 295; planned, not executed)

The 108 `-infinity` rows (Energy Import/Export of every asset, written
2026-09-25 21:06:21.442284 IST, no audit record) are unchanged. Assessed one
meter at a time (read-only): narrowing each to its meter point's first good
register reading hides **no** 15-minute and **no** 1-minute System Energy
row on any meter; the first 15-minute periods straddling the first reading
(7.408 kWh in total) stay with the assignment that starts inside them (the
Energy read's rule, `test_binding_change_inside_a_15m_bucket_incoming_source_owns_it`).

Migration 295 (`admin.narrow_standin_energy_assignments_20260925(actor,
gateway_id, dry_run DEFAULT true, confirm_count DEFAULT NULL)`, not granted)
narrows them one gateway per call: 92 rows in scope; the 16
Eniscope_2_Plumbing rows are refused by the wrapper. Guards: the stand-in
set must still number 108; no change when there is no reading, its raw
readings expired, a closed row ends first, or any valid System Energy
15-minute / 1-minute row would fall before the new start. Execution needs
the dry run's count and writes one `NARROW_STANDIN_ENERGY_ASSIGNMENTS`
audit record; `admin.revert_standin_energy_narrowing(actor, audit_id, ...)`
puts `-infinity` back on rows that still carry the recorded start.

Read-only plan on staging (2026-10-10): 92 NARROW, 0 refused -- Unit 2
gateways 08-24 20:55:58–59, ENISCOPE_1_CHILLER 08-28 12:14:58–59,
Eniscope_3_AHU 08-28 12:37:24–25 (Banquet 2 AHU Export, closed 10-05 21:04,
to 12:37:25), Eniscope_4_Main_Kitchen 08-28 12:25:58–59.

Consequence (Product Owner decision): narrowed rows no longer read as
stand-ins (`PARITY_BRIDGE` is derived from the `-infinity` start, migration
288) and the catalogue's assignment period starts at the first reading.

Per gateway (each needs explicit approval): dry run in a read-only session
(`statement_timeout` 120 s) and compare with the counts above; execute with
the confirmation count in one transaction (`lock_timeout` 5 s); verify the
re-run dry run shows `SKIPPED_NOT_INFINITY`, the audit record's before/after,
unchanged System Energy daily totals for one asset, and staging health.
Must run before about 2026-11-22 (Unit 2 raw readings from 08-24 expire).

## Related

- [incident-history.md](incident-history.md) -- the 2026-10-09 staging
  crash-restart caused by an unscoped read-only query during this analysis.
- ADR-018 decisions 4–8, Amendments 6 and 8; migrations 255, 256–258, 287.
