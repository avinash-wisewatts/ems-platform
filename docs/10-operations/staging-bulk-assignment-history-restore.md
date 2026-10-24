# One-time asset point assignment history restores (staging 2026-10-10 and 2026-10-24; production 2026-10-24)

Status: EXECUTED on staging 2026-10-10 (migration 294 deployed by PR #118, squash 47d8065); second use EXECUTED 2026-10-24 (AirSense, 15 rows) · Last reviewed: 2026-10-24
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

## 2026-10-23/24 AirSense assignments (restored 2026-10-24)

**Why.** On 2026-10-23 three ACTIVE Coimbatore AHUs were given their AirSense
sensor's Temperature, Relative Humidity, Occupancy Activity and Illuminance
(one audited Save each), and on 2026-10-24 the PIR interval (Time Since Last
Occupancy Event, `OCCUPANCY_SECONDS_SINCE_LAST_PIR_EVENT`; one Save each).
Each point started at its Save, so the Analytics page and Reports showed these
points only from then, although every sensor has GOOD readings from
2026-09-09.

**Decision (Product Owner, 2026-10-24):** restore this history once, as an
exception (ADR-018 Amendment 13; decision 6 is not changed). Product Owner
confirmation: Seasons Restaurant Zone 1 serves AHU-1 and Zone 2 serves AHU-2,
and neither sensor has moved since 2026-09-09. Audit actor `admin_avinash`.

**Investigation (read-only, 2026-10-24).**

- The older readings were never lost. `telemetry.normalized_points` (90 days)
  and `analytics.point_telemetry_15m` (120 days) hold every sensor from
  2026-09-09 18:23-18:26 IST, one GOOD reading a minute. The Analytics read
  (migrations 292/293) attributes a reading to an asset only inside its
  `asset_points` window, so the history was stored and processed, but not
  returned. No telemetry stage needed reprocessing.
- `telemetry.raw_messages` keeps 48 hours and cannot be replayed further. No
  AirSense message failed normalization in the 30 days of
  `raw_message_failures`.
- `telemetry.environment_measurements` / `environment_daily` hold the same
  readings by space (from 18:37-18:40 IST). Their loader always writes a NULL
  `asset_id`, so they are not asset-attributed and were not changed.
- Attribution: before 2026-10-23 ~12:43 IST none of the three sensors had a
  current or archived device-to-asset relationship or an `asset_points` row
  on any asset. Each has been bound to its space (Lobby, Seasons Restaurant)
  since 2026-09-09 22:22, with no change. The sensors were registered
  2026-09-09 18:40-18:43 IST.
- Banquet 2 AHU is out of scope: its points were restored on 2026-10-10 to
  2026-09-09 17:23:00.722, after its Banquet 1 AHU period
  (until 17:22:53). Its earlier readings (from 08:27:59) stay with that period.
- No other site or asset had new associations in the 14 days before the
  restore.

**Mechanism.** The deployed migration 294 core,
`admin.restore_bulk_assignment_history_core`, one Save per call (expected 1
audit / n rows), gateway `Eniscope_4_Main_Kitchen`, no excluded assets, as-of
`now()`. No new code, migration or telemetry rebuild.

**Dry run (read-only, 2026-10-24 ~12:25 IST):** 15 `RESTORE`, nothing
excluded. Each point's first GOOD reading was found separately; the PIR
interval's equals its sensor's other points.

**Execution (2026-10-24 12:29:16 IST).** Six calls, each in its own
transaction (`lock_timeout` 5 s, `statement_timeout` 60 s,
`p_confirm_restore_count` = the dry run's count). Only `effective_from`
changed.

| Save (IST) | Asset | Points | Restored | Start before -> after (IST) | Audit record (`admin.onboarding_audit.id`) |
|---|---|---|---|---|---|
| 2026-10-23 12:44:01.999783 | Lobby Area AHU-1 | Temperature, Relative Humidity, Occupancy Activity, Illuminance | 4 | 10-23 12:44:01.999783 -> 09-09 18:23:00.71148 | `07c57bda-b59d-45db-b6ef-7680670d6b0a` |
| 2026-10-23 12:45:25.468999 | Seasons Restaurant AHU-1 | same four | 4 | 10-23 12:45:25.468999 -> 09-09 18:25:01.3296 | `cfc75ba9-d7b3-4a61-be54-d4080238c37b` |
| 2026-10-23 12:46:10.954358 | Seasons Restaurant AHU-2 | same four | 4 | 10-23 12:46:10.954358 -> 09-09 18:26:00.14984 | `59841a87-d92e-4878-9f28-71e0202a5df4` |
| 2026-10-24 12:16:04.087256 | Lobby Area AHU-1 | PIR interval | 1 | 10-24 12:16:04.087256 -> 09-09 18:23:00.71148 | `0b3dd4c5-08a3-4771-87b9-89ef6a6a204c` |
| 2026-10-24 12:16:36.748557 | Seasons Restaurant AHU-1 | PIR interval | 1 | 10-24 12:16:36.748557 -> 09-09 18:25:01.3296 | `9886fe52-3126-43ba-82bf-94084769b419` |
| 2026-10-24 12:17:01.878952 | Seasons Restaurant AHU-2 | PIR interval | 1 | 10-24 12:17:01.878952 -> 09-09 18:26:00.14984 | `95dbf56b-a75f-473a-a07e-3cf174b2788b` |
| | **Total** | | **15** | | |

**Verification (read-only, after execution).**

- Repeat-safe: the re-run dry run reports all 15 rows `SKIPPED_START_CHANGED`
  at the new starts. Each audit record lists every row's
  `effective_from_before` / `effective_from_after`.
- Unchanged, compared with fingerprints taken just before the restore: every
  other `asset_points` row (3,145, all sites, including Banquet 2 AHU's),
  Coimbatore `energy_consumption_daily` 09-09 to 10-22, Coimbatore
  `demand_intervals` 10-15 to 10-22, `analytics.alerts`, the sensors'
  `point_telemetry_15m` rows and `environment_measurements` (still no asset).
- Analytics / Reports (deployed read path, portal-scoped): for the three AHUs
  the five restored columns now hold values from the 2026-09-09 18:00 IST
  hour on 44 of 45 days; every other column of these AHUs, Banquet 1 AHU and
  Banquet 2 AHU is identical to before.
- Gaps stay empty, never zero: no data at all from 2026-09-30 16:30 to
  2026-10-02 12:30 IST (gateway `Eniscope_4_Main_Kitchen` sent nothing; its
  energy meters have no point data either), 43 of the 54 hours in that window
  empty; partial days (e.g. 2026-09-21, about 21 of 96 quarter-hours) stay
  partial. About 88 % (Lobby) and 92 % (Seasons) of quarter-hours hold data.
- Raw = 15-minute tier = API: Seasons Restaurant AHU-1 Temperature and PIR
  interval daily means on 2026-09-10, 09-21 and 10-15 are identical in
  `normalized_points`, `point_telemetry_15m` and the Reports read (unit
  conversion 1 / 0).
- Staging healthy: no failed jobs (103), containers healthy, no database
  restart.

**Deadline / retention.** The 2026-09-09 readings leave `normalized_points`
around 2026-12-08 (1-minute history) and `point_telemetry_15m` around
2027-01-07 (15-minute and coarser history). That is normal retention, not a
consequence of the restore.

**Rollback.** Each audit record holds every row's previous start. Putting
them back is a separate, explicitly approved write.

## Production: bulk meter-point assignment and history restore (2026-10-24)

**Decision (Product Owner, 2026-10-24):** assign every enabled point of each
ACTIVE asset's `PRIMARY_METER` on production, in all organizations, as the
2026-10-09 staging bulk assignment did. Then restore each new point's history
to its first GOOD reading within 90 days, as a one-time exception
(ADR-018 Amendment 13). The AirSense points had already been assigned by
hand and were out of scope.

**Before (read-only).**

- 56 ACTIVE assets in 4 organizations, each with one `PRIMARY_METER` (55
  ACTIVE devices, 1 REGISTERED: Home Lift's Lift Energy Meter). Each meter has
  58 enabled points. No meter is shared with another asset, and none has an
  archived relationship.
- 132 `asset_points` rows: 112 System Energy stand-ins (`-infinity`
  Energy Import/Export on every primary meter) and 20 AirSense rows saved by
  hand on 2026-10-24.
- The four functions used (`save_asset_point_assignments`,
  `restore_bulk_assignment_history_core`, `bulk_assignment_restore_plan`,
  `bulk_restore_first_reading`) are byte-identical to staging.
- Demand cannot change method: no primary meter has native demand registers,
  every site's demand basis is `ACTIVE_POWER_KW`, and Energy Import (the
  highest available method's point) was already assigned.

**Assignment (2026-10-24 13:29:38.746483 IST).** One transaction, 56
audited `admin.save_asset_point_assignments` calls (actor `admin_avinash`,
portal user 1), one per (asset, primary meter), each submitting the
meter's 58 enabled points with no friendly name. A rolled-back rehearsal
matched first. A guard aborted the commit unless there were exactly 56
audits, 3,136 added and 0 removed. Result: 3,136 rows added (the 112
stand-ins kept unchanged), no commissioning triggered, 3,268 rows in total.

**History restore (13:3x IST).** Migration 294 core,
`restore_bulk_assignment_history_core('admin_avinash',
'2026-10-24 13:29:38.746483+05:30', 56, 3136, <gateway>, '{}', now(), ...)`,
one gateway per transaction, after a read-only dry run per gateway
(2-5 s each).

| Gateway | Restored | New start (IST) | Audit record |
|---|---|---|---|
| Eniscope_1_Chiller | 448 | 2026-09-04 05:30:53-54 | `04162b61-cdae-4993-a804-99253ce34be0` |
| Eniscope_2_Plumbing | 448 | 2026-09-06 03:31:55-03:38:47 | `fddb6aaf-ce79-4bb6-8339-64eb16fbd88c` |
| Eniscope_3_AHU | 448 | 2026-09-04 05:30:44-59 | `9ba07493-2f32-404b-8fe0-d31fd43e9cf5` |
| Eniscope_4_Main_Kitchen | 448 | 2026-09-04 05:30:44-59 | `7b165846-d8b4-4e15-9f24-8bf1302a2038` |
| Eniscope_1_Meenaxy_Unit2 | 448 | 2026-09-04 05:30:54-56 | `4e08c57d-3397-48c2-ab6f-6b5e672c3cdd` |
| Eniscope_2_Meenaxy_Unit2 | 448 | 2026-09-04 05:30:54-59 | `4663976a-37d4-41bd-8da6-626008dbfb36` |
| Eniscope_3_Meenaxy_Unit2 | 336 | 2026-09-04 05:30:57-59 | `6e8eaa93-f677-4f45-ae1d-4bd5ab14be17` |
| SVSS Gateway, Eniscope Home | 0 (112 `NO_CHANGE_NO_HISTORY`) | assignment time | not called |
| **Total** | **3,024** | | |

2026-09-04 05:30 IST (00:00 UTC) is the oldest data `normalized_points`
holds on production, so earlier meter history is not recoverable through the
point-level foundation. System Energy (the stand-ins) is unaffected and keeps
its own history. The two home meters have no GOOD readings in the window;
their points start at the assignment time.

**Verification (read-only).**

- Repeat-safe: re-run dry runs report 3,024 `SKIPPED_START_CHANGED` and the
  112 home rows `NO_CHANGE_NO_HISTORY`.
- Unchanged against fingerprints taken twice before (both identical): the
  132 earlier `asset_points` rows; `energy_consumption_daily` 2026-09-01 to
  10-21 per site; `demand_intervals` 2026-10-15 to 10-21 per site; alerts
  (none); the asset Energy series (`get_portal_asset_energy_series`, daily,
  2026-10-10 to 10-21, fixed as-of) for every site.
- The Analytics catalogue grew as expected (Coimbatore 79 -> 1,583 rows,
  Unit 2 44 -> 1,078, each home site 2 -> 49).
- The point series serves the restored history: for example Seasons
  Restaurant AHU-1 and EN-AirCompressor-01 Power are `NOT_ASSIGNED` until
  2026-09-03 and `MEASURED` from 2026-09-04.
- Production healthy: no failed jobs (102), containers healthy, no database
  restart.

**AirSense Zone1 correction (2026-10-24 13:46:21 IST, Product Owner
approved).** The hand-made AirSense assignment gave Seasons Restaurant AHU-2
the Zone1 sensor's five points (saved 13:15:58), as well as Zone2's. Zone1's
device relationship had since moved to AHU-1 (13:17:56), which had none.
That contradicts the confirmed mapping (Zone 1 -> AHU-1). Because the
relationship was gone, the Save path could not remove them, and the open
rows blocked assigning them to AHU-1 (one physical point, one asset at a
time). One guarded transaction (rehearsed with a rollback first):

1. Closed exactly those five AHU-2 rows at their own start + 1 microsecond
   (`ck_asset_points_effective_window` needs `effective_to > effective_from`).
   AHU-2 never shows Zone1 data; the rows remain as history.
2. Recorded it in `admin.onboarding_audit`
   `efcde5b8-13b0-4c47-aad6-04420e69ea8a` (`CLOSE_ORPHANED_ASSET_POINTS`,
   before/after for every row).
3. Saved the same five points on Seasons Restaurant AHU-1 with
   `admin.save_asset_point_assignments` (audit
   `0429560a-52af-4e6d-93c6-798d5dbbc591`; 5 added, 0 removed). They start
   at 13:46:21, unrestored, like the other hand-made AirSense points.

Verified: AHU-2's Temperature comes from Zone2 only; AHU-1 lists the five
Zone1 points; 3,273 rows, 5 closed. The catalogue still lists AHU-2's closed
1-microsecond Zone1 period, as it lists every past assignment period.

Product gap: removing or moving a device relationship does not close that
device's open `asset_points` on the old asset, and the Save path then cannot
close them.

**Rollback.** Each restore audit holds every row's previous start. The
assignments can be closed (never deleted) by a Save. Either is a separate,
explicitly approved write.

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
- ADR-018 decisions 4–8, Amendments 6, 8 and 13 (the one-time restore
  exceptions); migrations 255, 256–258, 287.
