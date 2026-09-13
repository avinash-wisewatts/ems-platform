# Telemetry Pipeline: Physical Device → Grafana

```
Status: CURRENT
Last verified: 2026-08-30
Verification basis: Staging (live, end-to-end trace across 22 real Meenaxy Pharma devices, real timestamps, this session) + Repository (telegraf/config/telegraf.conf, app/src/live_telemetry/*) + Production (2026-08-30: migrations 216–222 promoted, Job 1000 bounded-window catch-up observed live)
```

This is the verified, currently-operating data path — not a design document. Every stage below was confirmed live this session by tracing real physical devices' data through the actual staging database, not by reading configuration and assuming it works.

## The two parallel paths

The platform has two independent consumers of the same MQTT stream (per CLAUDE.md's architecture section, confirmed against the actual services this session):

```
                          ┌─── Telegraf ────► telemetry.raw_messages ──► normalized_points ──► aggregation ──► analytics ──► Grafana (historical)
Physical Eniscope ── MQTT ┤
                          └─── live-telemetry ──► telemetry.ingest_live_rtdata() ──► websocket push ──► Grafana (live stream)
```

Both subscribe to the same topic patterns independently; neither depends on the other. The browser never receives MQTT credentials in either path (CLAUDE.md §7's rule — confirmed: the live path pushes over a server-managed websocket hub, `app/src/live_telemetry/hub.py`'s `GrafanaAssetLiveHub`, keyed by `asset_id` + `grafana_org_id`).

## Historical path, stage by stage

| Stage | Input | Output | Mechanism |
|---|---|---|---|
| MQTT | Physical Eniscope gateway publish | JSON payload on topic `wwems/v1/{org}/{site}/{gateway}/telemetry` or `.../{gateway}/{device}/telemetry` | TLS MQTT broker |
| Telegraf | MQTT message (`inputs.mqtt_consumer`, qos=1) | Row in `public.mqtt_staging` (insert-only adapter view) | `telegraf/config/telegraf.conf` — `outputs.postgresql`, `tags_as_jsonb`/`fields_as_jsonb`, stores raw payload verbatim, no interpretation |
| Raw capture | `public.mqtt_staging` insert | Row in `telemetry.raw_messages` | The adapter view writes through to this table; Telegraf never touches `telemetry.raw_messages` directly |
| Normalization | `telemetry.raw_messages` | Rows in `telemetry.normalized_points` (one row per mapped field per message) | Server-side function/process resolves `device_uid` (the MQTT_UID) to `metadata.devices`, and each raw field to a `logical_point_id` via `config.profile_field_mapping` for the device's profile — verified: 44 raw messages → 2250 normalized rows per device (≈51 fields/message) |
| Domain tables | `telemetry.normalized_points` | `telemetry.energy_measurements` (75 columns — see `reference/telemetry-field-catalog.md`), plus `environment_measurements`/`water_measurements` for other device categories | Routing by device category |
| Continuous aggregation | `telemetry.energy_measurements` | `telemetry.ca_energy_{1min,5min,15min,hourly,daily}` | TimescaleDB continuous aggregates (auto-refreshing materialized views) |
| Validated/persisted aggregation | `telemetry.ca_energy_*` | `analytics.energy_consumption_{1min,5min,15min,hourly,daily}` | Explicit refresh functions run as TimescaleDB background jobs — see `11-aggregation.md` for the full mechanism, including interval-quality/gap/rollover classification |
| Semantic/Grafana layer | `analytics.energy_consumption_*` | `analytics.v_grafana_*` views, `analytics.v_energy_latest`, etc. | Views join through org/site/asset identity for tenant-scoped, dashboard-ready queries |

**Live-verified chain for a real device** (`E1_EM1_MICROPLV_P1_1`, this session): raw message `21:38:59` → normalized point `21:39:59` → `ca_energy_1min` bucket `21:39:00` → `analytics.energy_consumption_1min` bucket `21:38:00` → `analytics.v_grafana_energy_samples` sample `21:40:02`. The lag between stages is real processing latency (batch/job intervals), not a fault.

## Watermarks and bounded catch-up (telemetry tier)

The three incremental loaders — `telemetry.load_normalized_points_incremental()`
(job `run_normalization_job`), `telemetry.load_energy_measurements_incremental()`
(job `run_energy_routing_job`), and
`telemetry.load_environment_measurements_incremental()`
(job `run_environment_routing_job`) — each keep a durable checkpoint in
`telemetry.pipeline_state.last_received_at` (one row per `pipeline_name`) and a
`pg_try_advisory_xact_lock` guard so two runs never overlap. Each run processes
`(previous_checkpoint − overlap, window_end]` in a single transaction whose
`EXCEPTION` handler re-`RAISE`s, so a failed run rolls the checkpoint back with
the data — a failed/cancelled run never advances the checkpoint.

`window_end` is the source's own high-water mark (`max(raw_messages.received_at)`
for normalization; `max(normalized_points.platform_received_at)` for the two
routing loaders). Historically that boundary was **unbounded** — one run always
tried to advance all the way to "now". When the gap between the checkpoint and
now grew wider than the job's 5-minute `max_runtime` (a multi-hour upstream
stall, then a burst), every retry faced an equal-or-wider window with zero
possible durable progress: the job stalled. This is what happened to
`run_normalization_job` (job 1000) on 2026-08-26 — see
[23-known-issues-and-drift.md](23-known-issues-and-drift.md) §8.

**Bounded catch-up** (migration 205 for the normalization loader; migration 207
for the energy and environment routing loaders) adds an optional
`p_max_window INTERVAL` parameter to each loader:

- `p_max_window = NULL` (the default): `window_end` is computed exactly as
  before — unrestricted catch-up. This is what a **direct manual** `CALL` of the
  loader gets, and is the tool an operator uses to drain a large backlog in a
  controlled sequence of bounded calls (e.g.
  `CALL telemetry.load_energy_measurements_incremental(INTERVAL '15 minutes', INTERVAL '30 minutes')`,
  repeated).
- `p_max_window` supplied **and** a previous checkpoint exists: `window_end` is
  additionally capped to `LEAST(window_end, previous_checkpoint + p_max_window)`.

The **scheduled wrappers always pass a positive bound** — `run_energy_routing_job`
and `run_environment_routing_job` (migration 207) and, since **migration 212**,
`run_normalization_job` (job 1000) — all pass `2 hours` by default, overridable
per environment via the job's `config.max_window` (an `alter_job` change with no
code). None of them ever passes `NULL`. Because the wrappers are bounded, an
unattended multi-hour backlog **self-drains** over successive 1-minute runs
(≈8 runs for a 15-hour `raw_messages` gap) instead of stalling — each bounded
run durably commits, whereas the pre-212 unbounded run could make zero durable
progress once the gap exceeded `max_runtime`. The bound is a limit on how much
*one run* advances, not a change to transaction boundaries — there is still no
intermediate `COMMIT`, and steady-state runs (checkpoint already near "now", a
`< 2h` backlog) advance to `max(received_at)` exactly as before.

**Unrestricted forward catch-up remains available** for a deliberate operator
rebuild — a direct `CALL` of any loader with a single argument or an explicit
`NULL` `p_max_window` (e.g. `postgres/maintenance/45_rebuild_normalized_history.sql`,
or `CALL telemetry.load_normalized_points_incremental(INTERVAL '15 minutes', NULL)`).
Migration 212 does not change that path.

The `run_normalization_job` default of `2 hours` was provisional pending a
staging job-1000 runtime measurement; if it had proven too large for the
5-minute `max_runtime`, the remedy would have been an `alter_job` to `1 hour`,
not a code change. **That measurement has since been taken and the default
holds.** The dedicated staging bounded-window gate (1m/5m/15m/2h) passed with
the 2 h run at ~525 ms server time, and — after migration 221 (below) and the
216–222 batch were promoted to production on 2026-08-30 (`deploy-production.yml`
run `33304784449`) — production Job 1000 was resumed from a ~15.5 h backlog and
**self-drained to a ~36-second steady-state lag within ~25 minutes**: the first
run advanced a bounded `+6 h` (3 × the 2 h window in one invocation) at ~2,840
rows/s, and steady-state 1-minute cycles now complete in ~2 s. See
[25-change-history.md](25-change-history.md) 2026-08-30 and
[23-known-issues-and-drift.md](23-known-issues-and-drift.md) §8.

Job schedule / `max_runtime` / `max_retries` / `retry_period` and
`config.overlap` are unchanged by 205 / 207 / 212.

### Analytics tier: parent → child watermark cascade (migration 209)

The persisted energy-consumption tiers extend the same idea one layer down.
Since migration 209 the five `analytics.run_energy_consumption_*_job` wrappers
are **watermark-driven**, not `now() - lookback`:

- Each tier keeps its own checkpoint in `telemetry.pipeline_state`
  (`energy_consumption_1min` / `_5min` / `_15min` / `_hourly` / `_daily`),
  meaning "this tier has successfully processed through here". It is **not**
  the same as "the parent contains data through here" — those are separate.
- `parent_available_through` is read live each run: for
  `energy_consumption_1min` / `_5min` it is the `telemetry.ca_energy_1min` /
  `ca_energy_5min` **materialization watermark** (`analytics.cagg_available_through()`);
  for `_15min` it is `LEAST(cp_1min, cp_5min)`; for `_hourly` and `_daily` it
  is `cp_15min` (daily reads `analytics.energy_consumption_15min` directly, not
  the hourly tier).
- Per run: `v_to = LEAST(now_binned, parent_available_through,
  checkpoint + max_catchup_window)`; `v_from = checkpoint - overlap`; the
  unchanged `refresh_energy_consumption_*` function processes `[v_from, v_to)`;
  the checkpoint advances to `v_to` only on success. `lookback` is now only the
  first-run floor. A failed / cancelled / timed-out run rolls back the whole
  transaction, checkpoint included — it never skips its own failed interval.
- A child can never outrun its parent, so a backlog drains naturally
  (parent catches up → child catches up → next child catches up).
- Per-tier `max_catchup_window` / `overlap` / `reconcile_window` live in each
  job's `config`. `reconcile_window` is consumed by the **migration 213**
  bounded trailing reconciliation pass, which repairs internal holes a
  high-water mark cannot represent (see "Trailing reconciliation tier" below).

Job cadence / `max_runtime` / `max_retries` / `retry_period` and the
`refresh_energy_consumption_*` calculation functions are unchanged by 209.
`telemetry.environment_daily` became watermark-driven in migration 211 (see
"environment_daily tier" below).

### Demand tier: watermark + status-guarded re-finalization (migration 210)

Since migration 210 `analytics.run_demand_calculation_job` (`pipeline_name =
'demand_intervals'`) follows the same bounded-catch-up model, with demand-specific
inputs:

- `parent_available_through = LEAST(max(telemetry.energy_measurements.bucket_start),
  max(telemetry.normalized_points.event_time))` — the actual closed-bucket source
  frontier. **Not** a routing `pipeline_state` watermark (those are keyed on
  `platform_received_at`, ingest time, which is not comparable to a demand bucket
  boundary).
- `v_to = date_bin('15 minutes', LEAST(clock_timestamp() - grace,
  parent_available_through, checkpoint + max_catchup_window))`, where
  `grace = max(config.site_demand_policies.late_arrival_tolerance_seconds
  WHERE is_enabled) + 300 s`. The `grace` clamp keeps the checkpoint from
  advancing past `refresh_demand_analytics`'s own internal
  `interval_end + late_arrival_tolerance + 5 min > now` grace check, which would
  otherwise leave a permanent hole below the watermark.
- `v_from = checkpoint - overlap` (`overlap` default `30 min`); `lookback`
  (`3 h`) is only the first-run floor. `config` keys: `max_catchup_window`
  (`6 h`), `overlap` (`30 min`), `reconcile_window` (`6 h`, migration 213 only).
- `analytics.refresh_demand_analytics` gained optional `p_finalize_from` /
  `p_finalize_to` bounding **only** the historical finalization loop
  (`NULL/NULL` = the exact pre-210 `(now - lookback, now]` window). The live
  `analytics.demand_state` block still keys off `p_now`, so a historical
  catch-up never accumulates into `demand_state`.
- Finalization is now a **status-guarded upsert** per scope
  (`ON CONFLICT (<site_id|asset_id>, interval_start, demand_policy_id)
  WHERE scope_type = '<SITE|ASSET>' DO UPDATE … WHERE
  demand_intervals.quality_status <> 'VALID' AND (materially-changed)`), so a
  finalized `VALID` interval is frozen while a `NO_DATA` / `INCOMPLETE` interval
  is repaired once late source data lets `analytics.calculate_demand_window`
  (rules unchanged) produce a better result — without churning `finalized_at`
  on stable rows.

`analytics.calculate_demand_window` / `analytics.resolve_demand_interval` /
demand quality rules / demand interval grain / job cadence are unchanged by 210.

### environment_daily tier: watermark over site-local days (migration 211)

Since migration 211 `telemetry.run_environment_daily_job` (`pipeline_name =
'environment_daily'`) is watermark-driven, with two properties that distinguish
it from the energy and demand tiers:

- **Parent availability = `max(telemetry.environment_measurements.bucket_start)`**
  — the actual newest closed environment source bucket. It is a real persisted
  timestamp and **cannot run ahead of real data**. It is explicitly **not** a
  `ca_environment_*` CAGG watermark (`telemetry.refresh_environment_daily` reads
  `environment_measurements` directly, never a CAGG) and **not** the routing
  `pipeline_state('environment_measurements')` checkpoint (that is
  `platform_received_at` / ingest time, not a bucket boundary).
- **Grace comes from `config.telemetry_capture_policies`, not
  `config.site_demand_policies`**: `v_grace = make_interval(secs =>
  max(late_arrival_tolerance_seconds) + max(capture_interval_seconds) + 300)`
  over enabled capture policies — mirroring
  `telemetry.capture_bucket_correction_deadline` (`bucket_start +
  capture_interval + late_arrival_tolerance`) so a site-local day is never
  finalized while one of its buckets could still be corrected.
- `v_to = date_bin('1 day', LEAST(LEAST(now - grace, parent_available),
  checkpoint + max_catchup_window), '2000-01-01 00:00:00+00')` — floored to a
  **UTC day boundary** (deterministic regardless of session `TimeZone`). The
  checkpoint therefore means exactly *"every site-local day whose
  `local_day_end` (next local midnight, in UTC) is `<= last_received_at` has
  been finalized"* and can never jump past a finalizable local-day frontier.
- `v_from = checkpoint - overlap` (`overlap` default `1 day` — re-scans one
  already-finalized local day per run for late arrivals within grace + one run
  interval; older late arrivals are migration 213's job). `lookback` (`8 days`)
  is only the first-run floor. `config` keys: `max_catchup_window` (`2 days`),
  `overlap` (`1 day`), `reconcile_window` (`35 days`, migration 213 only).
- `telemetry.refresh_environment_daily` is **unchanged**: it localises each
  `environment_measurements.bucket_start` to `metadata.sites.timezone` (IANA,
  DST-aware), groups by `(device_id, site-local calendar day)`, and emits a row
  only for **complete** local days (`local_day_end > p_from AND local_day_end <=
  p_to`); a day with no source rows produces no row (there is no `NO_DATA`
  sentinel). Write is `ON CONFLICT (device_id, bucket_start) DO UPDATE`.

`environment_daily` currently has **no downstream consumer** (no Grafana / view
/ app / API) — it is a durable historian kept beyond `environment_measurements`
retention — so a silent gap there would be invisible; the conservative,
truthful watermark is deliberate.

### Trailing reconciliation tier (migration 213)

A high-water mark is a single scalar. It cannot represent `09:00 OK / 10:00
missing / 11:00 OK`, it cannot see source that is corrected or backfilled
*below* an already-advanced checkpoint, and — for the two CAGG-fed native
tiers — it can *overshoot*: the TimescaleDB refresh policy advances the
`ca_energy_1min` / `ca_energy_5min` materialization watermark across empty
source periods, so a migration-209 energy child can advance its checkpoint over
a range that has no CAGG rows and never re-read it once real source arrives.

Migration 213 adds a **bounded, observable, idempotent trailing re-drive** for
all seven analytical tiers. It is a corrective safety net, **not** a second
forward pipeline:

- **One `reconcile_*` procedure per tier**
  (`analytics.reconcile_energy_consumption_{1min,5min,15min,hourly,daily}`,
  `analytics.reconcile_demand_intervals`, `telemetry.reconcile_environment_daily`),
  each on its own slow-cadence job: energy `1min` / `5min` and demand hourly;
  `15min` 6-hourly; `hourly` 12-hourly; `daily` and `environment_daily` daily.
  Per-tier phase offsets keep a reconcile from perpetually losing the
  advisory-lock race to a forward run.
- **Same advisory key as the forward job.** Each reconcile takes
  `pg_try_advisory_xact_lock(hashtextextended('<forward run_*_job proc>', 0))` —
  the exact transaction-scoped key its forward wrapper uses — so a reconcile and
  its forward job (or two reconcile runs of one tier) can never overlap; the
  loser records `SKIPPED_LOCKED`. There is no second serialization hierarchy.
- **Never advances a forward checkpoint.** A reconcile reads
  `telemetry.pipeline_state(tier).last_received_at` **only** to derive
  `window_start = checkpoint − reconcile_window`; it never writes it. The
  complete set of `last_received_at` writers is unchanged (the seven forward
  wrappers + five telemetry loaders). A `NULL` checkpoint records
  `NO_CHECKPOINT` and returns.
- **Detects from persisted fingerprints, never a watermark position.**
  `1min` / `5min`: `energy_consumption_{1,5}min.source_sample_count` vs
  `telemetry.ca_energy_{1,5}min.sample_count` per `(device, minute)`, honouring
  the calc function's `resolve_site_capture_bucket` capture-interval eligibility
  filter (`<= 60` / `= 300`). `15min` / `hourly` / `daily`:
  `source_interval_count` count/`SUM` mismatch **plus** a recompute-recency
  check `max(parent.calculated_at) > child.calculated_at` (these tiers have no
  `source_sample_count` column; `ca_energy_1min` has no `calculated_at`).
  "Child present, parent absent" (source retracted) is **not** flagged.
- **Re-drives through the unchanged `refresh_*` function, bounded by `n_max`.**
  The energy tiers loop the affected 1-hour coarse buckets (or, for `daily` /
  `environment_daily`, site-local days computed from `metadata.sites.timezone`,
  DST-aware) and call `refresh_energy_consumption_*` / `refresh_environment_daily`
  per unit; exceeding `n_max` (ships 6, environment_daily 8) records `PARTIAL`
  and leaves the remainder for the next run. Demand has no source-count
  fingerprint — the repair *is* the re-run:
  `CALL analytics.refresh_demand_analytics(clock_timestamp(), lookback,
  p_finalize_from => checkpoint − reconcile_window, p_finalize_to => checkpoint)`
  (migration-210 status guard: `VALID` rows frozen, SITE/ASSET partial-index
  upsert; the live `demand_state` block stays keyed to `p_now`).
- **Per-unit failure isolation.** Each `refresh_*` call is wrapped in its own
  `BEGIN … EXCEPTION` subtransaction: one unit's failure stops the loop and is
  logged (`FAILED`, `first_error_sqlstate` / `first_error_message`), but earlier
  successful re-drives in the same run persist. The procedure is otherwise a
  single transaction with no `COMMIT` / `ROLLBACK`, so `max_runtime`
  cancellation repairs nothing and advances nothing.
- **`analytics.pipeline_reconciliation_log`** — hypertable on `ran_at`, PK
  `(run_id, ran_at)`, 180-day retention, one row per run (`window_start` /
  `window_end` = the exact inspected interval; `outcome ∈ {HEALTHY, REPAIRED,
  PARTIAL, FAILED, SKIPPED_LOCKED, NO_CHECKPOINT}`). Granted to `grafana_reader`
  (and, inertly, `ems_readonly`). Read by `analytics.v_pipeline_health`
  (migration 214).
- **No `refresh_continuous_aggregate` anywhere in the automated path**
  (TimescaleDB 2.29.2 rejects it inside a transaction / subtransaction).
  `reconcile_window` for `1min` = `2 days` and `5min` = `7 days` = each CAGG's
  automatic-refresh `start_offset`, so within the reconcile window the automatic
  policy keeps the CAGG truthful. **Backfill older than the `start_offset` is an
  operator-remediation condition** — the operator runs a top-level
  `CALL public.refresh_continuous_aggregate(...)`, and the next reconcile pass
  then repairs the children. It is neither auto-repaired nor reported `HEALTHY`.
- **N2:** `analytics.run_energy_consumption_15min_job` `config.reconcile_window`
  was raised 3 d → 8 d (the 15-min tier consumes
  `energy_consumption_1min UNION ALL energy_consumption_5min`; a
  `ca_energy_5min`-fed 5-min repair can be up to that CAGG's 7-day `start_offset`
  old). No `refresh_*` body, forward wrapper, CAGG, retention policy, or forward
  job schedule is changed by 213.

### Operator health surface (migration 214)

`analytics.v_pipeline_health` is a **read-only, system-scoped** view — one row
per reconciliation tier — that turns the signals above into an at-a-glance
operator status. It is a plain view (owner `ems_admin`, not `security_invoker`),
`SELECT` to `grafana_reader` only (the sole role with `USAGE ON SCHEMA
analytics`; `ems_readonly` cannot query any `analytics.v_*` view). It **writes
nothing**, calls no `refresh_*` / `reconcile_*` / `refresh_continuous_aggregate`,
takes no lock, and runs no detector — it reads `telemetry.pipeline_state`, the
latest `pipeline_reconciliation_log` row per tier (via the 213 `(tier, ran_at
DESC)` index) plus a bounded last-10-rows window, `timescaledb_information.jobs` /
`job_stats`, the `ca_energy_1min` / `ca_energy_5min` materialisation watermark
(read inline from `_timescaledb_catalog` by name), and a handful of
newest-chunk `MAX(bucket_start)` scans. Whole-view cost ≈ 7 ms.

Four explicit columns, never collapsed:

- **`forward_state`** — `NOT_INITIALIZED` / `FAILED` / `RUNNING_STALE` / `STALE`
  / `NO_SOURCE_DATA` / `RUNNING` / `OK`. `STALE` = checkpoint age `> 4 ×
  schedule_interval + max_catchup_window`; `RUNNING_STALE` = `RUNNING` for `> 2 ×
  max_runtime`. Thresholds come from the job's own row.
- **`reconcile_state`** — `NOT_INITIALIZED` (no run, or `NO_CHECKPOINT`) /
  `FAILED` / `STALE` (last run `> 3 × reconcile schedule_interval`, or job
  `Paused`) / `BACKLOGGED` (two consecutive `PARTIAL`) / `CONTENDED` (three
  consecutive `SKIPPED_LOCKED`) / `PARTIAL` / `SKIPPED_LOCKED` / `OK`. The raw
  reconcile error message is **not** exposed — only `first_error_sqlstate`.
- **`integrity_risk`** — `N/A` (demand, `environment_daily`) / `PERSISTENT_DEFICIT`
  (last three reconcile runs all repaired rows) / `CAGG_OVERSHOOT`
  (`energy_consumption_1min`/`_5min`: watermark ahead of
  `max(energy_measurements.bucket_start)` by more than
  `capture_interval + late_arrival_tolerance + end_offset + 2 × routing
  schedule + 120 s`, ≈ 21 min today) / `OLDER_BACKFILL_UNKNOWN` (native tiers,
  default — the older-than-`start_offset` condition has no cheap reliable
  persisted signal, so the view reports the limitation + `older_backfill_horizon`
  and defers to the operator diagnostic in `19-operations-and-diagnostics.md`).
- **`health`** — `ERROR` > `WARNING` > `UNKNOWN` > `OK`, plus `health_rank`
  (3/2/1/0) and `health_reason`.

214 adds no job, index, table, or Grafana dashboard, and changes no 209–213
object. An operator "Pipeline Health" dashboard and a one-row system roll-up, if
wanted, are separate follow-ups.

## Correlation identity: MQTT_UID

`metadata.device_identifiers` maps an `identifier_type='MQTT_UID'` value (e.g. `80:34:28:16:22:fe:00:01`) to exactly one `metadata.devices.id`. The uniqueness constraint (`uq_device_identifier` on `(identifier_type, identifier_value)`) is **global across the platform, not per-organization** — see `15-mqtt-and-telegraf.md`. This is the only identity the physical hardware carries; everything else (device name, external_id) is an internal label assigned during onboarding.

## Failure modes and where to look

| Symptom | Where to check |
|---|---|
| No raw messages at all for a device | Telegraf logs (not accessible via this manual's verification method — needs container/SSH access); confirm the MQTT_UID exists in `metadata.device_identifiers` and the topic org/site/gateway segments match the gateway's `external_id` |
| Raw messages exist, no normalized points | Check `config.profile_field_mapping` exists for the device's `profile_id`; check the device's `device_model_id`/`profile_id` are both set (both nullable at the schema level — see `05-database.md`) |
| Normalized points exist, no `energy_measurements` rows | Check device category resolves correctly through `device_models.device_category_id` |
| Aggregates missing at one resolution but present at another | Read `11-aggregation.md` first — this is very often a capture-interval design distinction (a 60-second site legitimately has zero rows in the "native 5-minute" persisted table), not a bug. Confirmed misleading-if-misread this session. |
| Grafana shows nothing for an org that has data in `analytics.*` | Check `metadata.grafana_organization_map` has an active row for that org — see `12-grafana.md` |

See `19-operations-and-diagnostics.md` for the actual read-only SQL used to produce the live-verified chain above.
