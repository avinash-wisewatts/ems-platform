# Telemetry Pipeline: Physical Device → Grafana

Status: CURRENT · Last reviewed: 2026-08-30
Verification basis: Staging (live, end-to-end trace across 22 real Meenaxy Pharma devices) + Repository + Production (2026-08-30: migrations 216–222 promoted, Job 1000 bounded-window catch-up observed live)

This is the verified, currently-operating data path — not a design
document. Every stage below was confirmed live by tracing real physical
devices' data through the actual staging database.

## The two parallel paths

```text
                          ┌─── Telegraf ────► telemetry.raw_messages ──► normalized_points ──► aggregation ──► analytics ──► Grafana (historical)
Physical Eniscope ── MQTT ┤
                          └─── live-telemetry ──► telemetry.ingest_live_rtdata() ──► websocket push ──► Grafana (live stream)
```

Both subscribe to the same topic patterns independently; neither depends on
the other. The browser never receives MQTT credentials in either path — the
live path pushes over a server-managed websocket hub
(`app/src/live_telemetry/hub.py`'s `GrafanaAssetLiveHub`, keyed by
`asset_id` + `grafana_org_id`).

## Historical path, stage by stage

| Stage | Input | Output | Mechanism |
|---|---|---|---|
| MQTT | Physical Eniscope gateway publish | JSON payload on `wwems/v1/{org}/{site}/{gateway}/telemetry` (or with a `{device}` segment) | TLS MQTT broker |
| Telegraf | MQTT message (`inputs.mqtt_consumer`, qos=1) | Row in `public.mqtt_staging` (insert-only adapter view) | `telegraf/config/telegraf.conf` — stores raw payload verbatim, no interpretation |
| Raw capture | `public.mqtt_staging` insert | Row in `telemetry.raw_messages` | Write-through view; Telegraf never touches `raw_messages` directly |
| Normalization | `telemetry.raw_messages` | Rows in `telemetry.normalized_points` | Resolves `device_uid` → `metadata.devices`, each raw field → `logical_point_id` via `config.profile_field_mapping` |
| Domain tables | `telemetry.normalized_points` | `telemetry.energy_measurements` (75 columns), plus `environment_measurements`/`water_measurements` for other categories | Routing by device category |
| Continuous aggregation | `telemetry.energy_measurements` | `telemetry.ca_energy_{1min,5min,15min,hourly,daily}` | TimescaleDB continuous aggregates |
| Validated/persisted aggregation | `telemetry.ca_energy_*` | `analytics.energy_consumption_{1min,5min,15min,hourly,daily}` | Explicit refresh functions as TimescaleDB background jobs — see [aggregation.md](aggregation.md) |
| Semantic/Grafana layer | `analytics.energy_consumption_*` | `analytics.v_grafana_*`, `analytics.v_energy_latest`, etc. | Views join through org/site/asset identity — see [analytics-layer.md](analytics-layer.md) |

## Watermarks and bounded catch-up (telemetry tier)

The three incremental loaders — `telemetry.load_normalized_points_incremental()`
(job `run_normalization_job`), `telemetry.load_energy_measurements_incremental()`
(job `run_energy_routing_job`), and `telemetry.load_environment_measurements_incremental()`
(job `run_environment_routing_job`) — each keep a durable checkpoint in
`telemetry.pipeline_state.last_received_at` and a
`pg_try_advisory_xact_lock` guard so two runs never overlap. Each run
processes `(previous_checkpoint − overlap, window_end]` in a single
transaction whose `EXCEPTION` handler re-`RAISE`s, so a failed run rolls
the checkpoint back with the data.

`window_end` is the source's own high-water mark. Historically that
boundary was **unbounded** — one run always tried to advance all the way to
"now." When the gap between checkpoint and now grew wider than the job's
5-minute `max_runtime`, every retry faced an equal-or-wider window with zero
possible durable progress: the job stalled. This is what happened to
`run_normalization_job` (job 1000) on 2026-08-26.

**Bounded catch-up** (migration 205 for normalization; migration 207 for
energy/environment routing) adds an optional `p_max_window INTERVAL`
parameter to each loader: `NULL` (default) preserves unrestricted catch-up
(what a manual `CALL` gets); a positive value caps `window_end` to
`LEAST(window_end, previous_checkpoint + p_max_window)`. **The scheduled
wrappers always pass a positive bound** — `run_energy_routing_job` and
`run_environment_routing_job` (migration 207), and since **migration 212**,
`run_normalization_job` (job 1000) — all pass `2 hours` by default,
overridable per environment via `config.max_window`. Because the wrappers
are bounded, an unattended multi-hour backlog **self-drains** over
successive 1-minute runs instead of stalling.

**Unrestricted forward catch-up remains available** for a deliberate
operator rebuild — a direct `CALL` with an explicit `NULL` `p_max_window`
(e.g. `postgres/maintenance/45_rebuild_normalized_history.sql`).

The `run_normalization_job` default of `2 hours` was provisional pending a
staging runtime measurement — **that measurement has since been taken and
the default holds**: the dedicated staging bounded-window gate (1m/5m/15m/
2h) passed with the 2h run at ~525ms server time, and after migration 221
and the 216–222 batch were promoted to production on 2026-08-30, production
Job 1000 was resumed from a ~15.5h backlog and **self-drained to a
~36-second steady-state lag within ~25 minutes** (first run advanced a
bounded +6h at ~2,840 rows/s; steady-state 1-minute cycles now complete in
~2s). See [../../10-operations/incident-history.md](../../10-operations/incident-history.md).

### Failure quarantine and recovery (jobs 1076/1068/1077)

Three further jobs sit alongside the loaders above: `run_raw_receipt_state_job`
(job 1076, every 1 minute) maintains an independent raw-ingestion watermark;
`run_raw_message_failure_capture_job` (job 1068, `telemetry.
capture_raw_message_failures_incremental`, migration 007) scans raw messages
the normalization checkpoint has already passed and quarantines any that
produced zero/partial normalized output into `telemetry.raw_message_failures`
(a 30-day-retention hypertable) before `telemetry.raw_messages`' own 48-hour
retention purges them; `run_failed_message_recovery_job` (job 1077,
`telemetry.recover_failed_raw_messages`, migrations 201/202/204/206/218/220)
consumes that quarantine hourly and retries normalizing each candidate,
independently re-checking whether the point now exists before marking it
`RECOVERED`. Job 1068 is upstream of 1077 — 1077 has nothing to do until 1068
captures new candidates.

**Job 1068 carried the same unbounded-window defect job 1000 had before
migration 205/212** (see above): its forward boundary had no `p_max_window`
cap, so once its checkpoint fell behind, every 5-minute attempt re-faced an
equal-or-wider window. On staging this ran job 1068 into TimescaleDB's own
`max_retries` auto-disable on 2026-09-04, after 709 consecutive failures —
see [../../10-operations/incident-history.md](../../10-operations/incident-history.md)
for the full incident record. **Status as of 2026-09-15: the identical
migration-205/212 bounded-window pattern has been implemented for job 1068
(migration 243, branch `fix/job-1068-raw-message-failure-capture-bounded-catchup`)
and passed its disposable-DB regression suite — but this fix is NOT yet
merged, NOT deployed to staging or production, and job 1068 remains
disabled.** Unlike job 1000's `2 hours`, job 1068's wrapper default
(`config.max_window`, code fallback `15 minutes`) is an unmeasured
placeholder only — a real value requires a staging runtime measurement not
yet taken (a bounded, safeguarded measurement script exists at
`scripts/test/staging_measure_raw_message_failure_capture_window.sh` but has
not been run). This section should be updated once that measurement is
taken and the fix is actually deployed and job 1068 is re-enabled.

`produced_point_count` (job 1068's zero-output detection) is deliberately
**not** keyed on `(platform_received_at, raw_message_id)` against
`telemetry.normalized_points` — migration 006 established that
`raw_message_id`/`platform_received_at` on a `normalized_points` row are
mutable (reassignable to a later replay on `ON CONFLICT`), so that lookup
can under-report real failures. It is instead keyed on the row's stable
identity, `(device_id, event_time, logical_point_id)`. This was re-verified,
not changed, during the migration-243 work.

### Analytics tier: parent → child watermark cascade (migration 209)

Since migration 209 the five `analytics.run_energy_consumption_*_job`
wrappers are **watermark-driven**, not `now() - lookback`. Each tier keeps
its own checkpoint in `telemetry.pipeline_state`. `parent_available_through`
is read live each run: for `_1min`/`_5min` it is the corresponding CAGG's
materialization watermark (`analytics.cagg_available_through()`); for
`_15min` it is `LEAST(cp_1min, cp_5min)`; for `_hourly`/`_daily` it is
`cp_15min`. Per run: `v_to = LEAST(now_binned, parent_available_through,
checkpoint + max_catchup_window)`; the checkpoint advances only on success.
A child can never outrun its parent, so a backlog drains naturally.

### Demand tier: watermark + status-guarded re-finalization (migration 210)

`analytics.run_demand_calculation_job` follows the same model, with
`parent_available_through = LEAST(max(energy_measurements.bucket_start),
max(normalized_points.event_time))` — the actual closed-bucket source
frontier, distinct from a routing ingest-time watermark. Finalization is a
**status-guarded upsert**: a finalized `VALID` interval is frozen, while a
`NO_DATA`/`INCOMPLETE` interval is repaired once late source data allows a
better result.

### environment_daily tier: watermark over site-local days (migration 211)

`telemetry.run_environment_daily_job`'s parent availability is
`max(telemetry.environment_measurements.bucket_start)` — a real persisted
timestamp that cannot run ahead of real data, floored to a UTC day boundary
so the checkpoint always means "every site-local day whose local midnight
has passed is finalized."

### Trailing reconciliation tier (migration 213)

A high-water mark cannot represent `09:00 OK / 10:00 missing / 11:00 OK`,
and a CAGG's materialization watermark can advance across empty source
periods. Migration 213 adds a bounded, observable, idempotent trailing
re-drive for all seven analytical tiers: one `reconcile_*` procedure per
tier, on the **same advisory key as its forward job** (never overlapping
it), detecting deficits from persisted fingerprints (never a watermark
position), re-driving through the unchanged `refresh_*` function bounded by
`n_max`. It **never advances a forward checkpoint** — enforced by a
`pg_get_functiondef` contract test. Backfill older than a native tier's CAGG
`start_offset` (2 days for `ca_energy_1min`, 7 for `ca_energy_5min`) is a
documented **operator-remediation** condition, not auto-repaired — see
[../../10-operations/monitoring.md](../../10-operations/monitoring.md).

### Operator health surface (migration 214)

`analytics.v_pipeline_health` — one row per reconciliation tier,
`forward_state`/`reconcile_state`/`integrity_risk`/`health` — turns the
above into an at-a-glance operator status. Read-only, ~7ms whole-view cost.
See [../../10-operations/monitoring.md](../../10-operations/monitoring.md).

## Correlation identity: MQTT_UID

`metadata.device_identifiers` maps an `identifier_type='MQTT_UID'` value to
exactly one `metadata.devices.id`. The uniqueness constraint is **global
across the platform, not per-organization**. This is the only identity the
physical hardware carries; everything else (device name, external_id) is an
internal label assigned during onboarding.

## Failure modes and where to look

| Symptom | Where to check |
|---|---|
| No raw messages at all for a device | Confirm the MQTT_UID exists in `metadata.device_identifiers`; confirm the topic org/site/gateway segments match the gateway's `external_id` |
| Raw messages exist, no normalized points | Check `config.profile_field_mapping` exists for the device's `profile_id`; check `device_model_id`/`profile_id` are both set |
| Normalized points exist, no `energy_measurements` rows | Check device category resolves correctly through `device_models.device_category_id` |
| Aggregates missing at one resolution but present at another | Read [aggregation.md](aggregation.md) first — often a capture-interval design distinction, not a bug |
| Grafana shows nothing for an org that has data in `analytics.*` | Check `metadata.grafana_organization_map` has an active row — see [../grafana/README.md](../grafana/README.md) |

See [../../10-operations/monitoring.md](../../10-operations/monitoring.md)
for the actual read-only SQL used to produce the live-verified chain above.
