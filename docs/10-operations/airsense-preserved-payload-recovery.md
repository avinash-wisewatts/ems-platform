# Production: AirSense history recovery from preserved payloads

Status: PAYLOADS PRESERVED (2026-10-24); recovery mechanism (migration 310) IMPLEMENTED, not deployed; production backfill NOT EXECUTED, awaiting approval · Last reviewed: 2026-10-24
Verification basis: Production (read-only), Staging (read-only), local test database

## Why

On production, three AirSense sensors publish inside the gateway packets of
`Eniscope_4_Main_Kitchen`, together with eight energy meters:

| Sensor | MQTT UID | Device registered (IST) |
|---|---|---|
| E4_EM9_AirSense Seasons Restaurant Zone1 | `80:34:28:16:05:57:05:01` | 2026-10-24 13:13:31 |
| E4_EM10_AirSense Seasons Restaurant Zone2 | `80:34:28:16:05:57:05:02` | 2026-10-24 13:11:28 |
| E4_EM11_AirSense_Lobby1AHU | `80:34:28:16:05:57:05:03` | 2026-10-24 12:44:10 |

Until each sensor was registered, its elements in those packets could not be
resolved. The packets' meter elements were normalized; the sensor elements
were not. Failure capture recorded the packet in
`telemetry.raw_message_failures` (`UNRESOLVED_DEVICE_ELEMENTS`, kept 30 days).
The raw packet itself (`telemetry.raw_messages`) is kept 48 hours.

What is recoverable:

- **2026-09-24 → 2026-10-22 (failure table only).** Failure capture kept one
  packet every 5 minutes (12 an hour), while the gateway sends about 4 a
  minute. The other packets' sensor elements were never captured. Recovered
  history for this period is therefore real readings at 5-minute spacing, not
  1-minute. In the Analytics read, a 15-minute bucket then counts 3 of 15
  expected intervals (PARTIAL quality).
- **About 2026-10-22 05:30 → registration (raw_messages).** Every packet is
  still in `raw_messages`, so full 1-minute history exists. It drops from the
  48-hour retention from 2026-10-25 ~10:08 IST, one day at a time. Preserving
  it needs a second export (not done; see Approvals).
- **Gaps that stay gaps:**
  - before 2026-09-24 (failure-table retention);
  - 2026-09-30 16:30 → 2026-10-02 12:30 (gateway outage: no packets);
  - elements received after their bucket's deadline (the live loader drops
    them too).

## 1. Preserved payloads (done 2026-10-24 14:22 IST, read-only)

| | |
|---|---|
| Location (production host) | `/home/emsadmin/ems-preserved/airsense-failures-20261024/` (directory `drwx------ emsadmin`) |
| Data | `raw_message_failures_airsense_20261024.csv.gz` — 13,687,009 bytes, all columns, CSV with header, oldest first, one `COPY` statement (one snapshot) |
| Manifest | `raw_message_failures_airsense_20261024.manifest.json` — database-side counts and identity digest |
| Checksums | `raw_message_failures_airsense_20261024.sha256` (data `1f1f9d6d…258c`, manifest `6404d8de…c31b`) |
| Permissions | all three files `-r-------- emsadmin` |
| Scripts | `/home/emsadmin/ems-preserved/scripts/preserve_airsense.sh`, `verify_preserved.py` |

Filter: `failure_code = 'UNRESOLVED_DEVICE_ELEMENTS'` and `source_identifier` in
the three UIDs. Rows: 8,201 (Zone2-labelled 8,182, Zone1 14, Lobby 5),
`raw_received_at` 2026-09-24 05:31:18 → 2026-10-24 12:51:11 IST. The other
1,337 failure rows in the table are empty or invalid payloads (no readings).

Independent verification on the host:

- `sha256sum -c` OK; `gzip -t` OK.
- The file was re-read with Python: 8,201 rows; counts per source equal the
  manifest; first and last `raw_received_at` equal the manifest.
- Identity digest (md5 over `raw_message_id|md5(payload)` in file order)
  `514edd69a4b788387ee59f9fcfa9b026` equals the database-side digest.
- Readings per sensor, from the payloads:

  | Sensor | Packets | Readings | Element time span (IST) |
  |---|---|---|---|
  | Zone1 | 8,183 | 8,183 | 2026-09-24 05:30:35 → 2026-10-24 12:50:59, 30 days |
  | Zone2 | 8,182 | 8,182 | 2026-09-24 05:30:34 → 2026-10-24 12:50:58, 30 days |
  | Lobby | 8,165 | 8,165 | 2026-09-24 03:42:34 → 2026-10-24 12:50:58, 30 days |

  Lobby's first element carries a ts about 2 h older than its packet's
  receipt; the live rule makes such an element LATE.
- Deletion schedule: retention job 1059 (`drop_after` 30 days, daily, next
  run 2026-10-25 10:05:06 IST) drops whole daily chunks; the first to go is
  2026-09-24.

The database rows were not altered or deleted.

## 2. Recovery mechanism (migration 310)

`postgres/migrations/310_preserved_rtdata_backfill.sql` — see its header for
the full rules:

- **Packets:** `telemetry.preserved_rtdata_packets`, loaded by an operator
  from the export.
- **Plans** (`STABLE`):
  - `telemetry.preserved_rtdata_samples(p_from, p_to, p_device_ids)` — the
    live loader's capture decision per element: `SELECTED`, `BUCKET_TAKEN`,
    `SUPERSEDED`, `LATE`, `NOT_FINAL`, `NO_POLICY` or `OUT_OF_RETENTION`.
  - `telemetry.preserved_rtdata_points(...)` — the normalized points of the
    selected samples, `INSERT` or `PRESENT`.
- **Operation:** `telemetry.backfill_preserved_rtdata(p_actor, p_from, p_to,
  p_device_ids, p_dry_run DEFAULT true, p_confirm_points DEFAULT NULL)`.
  - Dry run by default.
  - Execution needs the dry run's point count.
  - Device allow-list; at most 31 days per call.
  - Inserts only, never overwriting:
    - `capture_bucket_samples` (status `RECOVERED`);
    - `normalized_points` (`ON CONFLICT DO NOTHING`);
    - `routing_recovery_queue` entries (the hourly late sweep then writes the
      environment measurements);
    - the device state upserts.
  - Marks fully represented packets' failure rows `RECOVERED`
    (`PRESERVED_PAYLOAD_BACKFILL`).
  - Writes one `BACKFILL_PRESERVED_RTDATA` audit record per executed call.
  - Repeat-safe.

Field mappings, numeric parsing, quality codes, buckets
(`resolve_site_capture_bucket`), late-arrival exclusion and the
one-sample-per-bucket choice are the live loader's
(`load_normalized_points_incremental`, migration 221).
The two `normalized_points` lookups are bounded by event time, so only the
window's chunks are read (see job 1061 below for why that matters).

### Validation

- **Regression tests** (`app/tests/test_preserved_rtdata_backfill.py`,
  local disposable database):
  - ownership and grants;
  - invalid calls refused;
  - dry run writes nothing;
  - a confirmation mismatch changes nothing;
  - exact payload values and provenance;
  - a missing field is stored as MISSING;
  - repeat run is a no-op;
  - late element stays a gap;
  - the latest element of a bucket is the sample;
  - a live-sampled bucket is never touched;
  - only allow-listed devices are processed;
  - failure rows become RECOVERED only when fully represented.
- **Staging equivalence (read-only, 2026-10-24).** The migration's own plan
  functions were run over staging's `raw_messages` for the same three sensors
  (2026-10-24 06:00 → 09:00 IST, buckets the live loader had sampled kept for
  comparison). Result: 6,312 computed points, 6,312 identical to staging's
  live `normalized_points` (raw value, numeric value, quality code and the
  same source packet), 0 missing, 0 different. The query is generated from
  the migration text; only the packet source is swapped.

## 3. Job 1061 (failed-message recovery) — root cause

Job 1061 has hit its 10-minute `max_runtime` on every run since Zone2 was
registered (13:11):

| Run start | End | Result |
|---|---|---|
| 13:28 | 13:38 | timed out |
| 13:53 | 14:03 | timed out |
| 14:28 | — | running |

It processes failure rows oldest-first and commits after each one. The
deferred Zone2 rows became eligible once the device was ACTIVE.

Observed read-only on the 14:28 run:

- The session spent its whole transaction (4 min 41 s at the snapshot) on
  one message, in `IO / DataFileRead`.
- It held locks on every `telemetry.normalized_points` chunk (13 compressed
  weekly chunks back to July, plus the open one).
- `EXPLAIN` of the procedure's lookup — capture sample of the candidate
  `JOIN normalized_points ON device_id = … AND event_time = …` (the
  RECOVERED update and `v_has_normalized`) — plans a Hash Join over a
  sequential decompressing scan of every chunk.
- The key is only known at run time, so no chunk is excluded.

One message therefore costs more than 10 minutes, rolls back, and the next
run starts over: the backlog never moves, and each hourly run reads about 90
days of compressed points on the 1.9 GB host. The standard path also cannot
reach messages older than 48 hours.

Recommendation (needs approval):

- Pause job 1061 until the backfill has run.
- Then fix the two lookups with an event-time bound, as migrations 202 / 204
  / 220 did for the other parts, and resume.

Pausing loses nothing today. Its queue holds only these sensors' packets
(covered by the export and, for the last 48 h, by `raw_messages`) and
empty / invalid payloads with nothing to recover.

## 4. Procedure (each step needs explicit approval)

1. **Deploy migration 310 through CI/CD.** Production is at migration 308.
   310 follows 309 (Reports export tables), which is outside the production
   scope. Decide before promoting:
   - promote 309 with 310 (309 is database-only and inert without the
     Reports app code); or
   - run 310's reviewed function bodies as session-only `pg_temp` functions
     (no schema change).
2. **Load the export** into `telemetry.preserved_rtdata_packets` in one
   session:
   - `CREATE TEMP TABLE f (LIKE telemetry.raw_message_failures)`, then
     `\copy f FROM STDIN WITH (FORMAT csv, HEADER)` fed by `zcat`.
   - `INSERT INTO telemetry.preserved_rtdata_packets SELECT raw_received_at,
     raw_message_id, source_identifier, payload, '<file name>' FROM f`.
   - Verify 8,201 rows and the identity digest against the manifest.
3. **Dry run per day** (30 calls, 2026-09-24 → 2026-10-24, the three device
   ids). Review the totals (expected about 288 SELECTED per sensor-day,
   12 points each).
4. **Execute per day** with the confirmation count, in its own transaction
   (`lock_timeout` 5 s, `statement_timeout` 120 s), oldest first. Capture
   before/after fingerprints of unrelated data first.
5. **Rebuild the point tiers** for the backfilled window:
   `CALL analytics.backfill_point_telemetry_15m(from, to, INTERVAL '1 day')`
   and `CALL analytics.backfill_point_telemetry_1h(...)`.
6. **Routing.** The hourly late sweep routes at most 10,000 queue entries per
   run (about 25,000 expected, so about 3 runs) into the environment
   measurement tables.
7. **Verify:**
   - per-day counts and values against the export;
   - the Analytics point series;
   - unrelated fingerprints unchanged;
   - failure rows RECOVERED.
8. **Asset history (separate approval).** The three AHUs' AirSense points
   start at their 2026-10-24 assignment. Restoring their history is a
   separate, audited change. Seasons AHU-1 needs the same override as
   Banquet 2: the closed 1 µs AHU-2 Zone1 rows make the restore function
   refuse it.

## Rollback

- Drop migration 310's functions and table.
- Each executed call's audit record lists its window and counts. Removing
  inserted points is a separate, explicitly approved operation.
- The export files are kept until the recovery is verified; their removal is
  a separate decision.

## Related

- [staging-bulk-assignment-history-restore.md](staging-bulk-assignment-history-restore.md) — the asset-history restores and the Banquet 2 AHU correction.
- Migrations 202, 203, 204, 206, 218, 220 (failed-message recovery), 221
  (normalization), 264 (15-minute tier), 305 (routing recovery queue).
