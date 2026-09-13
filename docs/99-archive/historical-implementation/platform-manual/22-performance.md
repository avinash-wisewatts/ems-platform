# 22. Performance Architecture

```
Status: PARTIAL
Last verified: 2026-08-24
Verification basis: Staging (live timings, this session), Audit evidence (static analysis, not re-verified live)
```

## 22.1 Core architectural principle

The system is designed so that Grafana (and any other analytical consumer) queries a **small, pre-aggregated, indexed table** appropriate to the requested time range, rather than scanning `telemetry.energy_measurements` (raw, high-volume, one row per device per capture interval) directly. This is the entire purpose of the `analytics.energy_consumption_{1min,5min,15min,hourly,daily}` persisted tables and the `telemetry.ca_energy_*` continuous aggregates that feed them — see [11-aggregation.md](11-aggregation.md). A dashboard panel showing a month of data should read `..._daily` or `..._hourly`, not raw measurements; a panel showing "right now" reads `..._1min` or the live-state table `telemetry.device_telemetry_state`.

**This is a design principle confirmed by the schema's existence and by the audit evidence below — it is not a guarantee that every panel actually obeys it.** See 22.3.

## 22.2 Measured performance (this session, staging, 22-device fleet)

Every query below was run against live staging Postgres with `\timing on`, for the 22 Meenaxy Pharma devices, on 2026-08-24:

| Query | Time |
|---|---|
| Fleet-wide per-device telemetry-state freshness (22 devices) | 47ms |
| Fleet summary (min/max telemetry timestamp) | 14ms |
| Raw `energy_measurements` count+latest per device | 26ms |
| Normalized `normalized_points` count+latest per device | 103ms |
| `device_point_configuration` coverage per device | 27ms |
| All 5 `analytics.energy_consumption_*` resolutions, row/device/date-range summary | 44ms |
| All 5 `telemetry.ca_energy_*` continuous-aggregate summary | 51ms |
| `analytics.v_grafana_devices` count | 26ms |
| `analytics.v_grafana_assets` count | 70ms |
| `analytics.v_grafana_energy_samples` count + latest | 56ms |
| `analytics.v_energy_latest` count + latest | 52ms |
| `analytics.v_asset_energy_latest` count | 70ms |
| 3-device end-to-end trace (MQTT_UID → ... → Grafana view, all layers) | 135ms |

**Caveat, stated explicitly so this isn't over-read**: these numbers reflect a fleet that had been live for roughly two hours at measurement time (~1,000 raw rows total across 22 devices). They demonstrate the aggregate-layer queries are cheap *at this data volume*, and that the intended architecture (query the aggregate, not the raw table) is mechanically wired up correctly end-to-end. They are **not** a load test and do not by themselves confirm behavior at production data volumes (months of history, more devices).

## 22.3 Known risk from static audit evidence (not re-verified live this session)

`Audit/EMS Analytics Platform — Phase 0 Static Analytical Query-Performance Audit.txt` is a static-analysis audit (SQL bodies, index DDL, and compression/retention policy traced from source — nothing executed) that predates this session's work. Its findings, taken as **historical / not re-verified**, unless noted:

- **Indexing inventory** (Part A of that audit): `telemetry.energy_measurements` has only a PK on `(received_at, id)` plus one secondary index `energy_measurements_device_bucket_start_idx (device_id, bucket_start)`. `telemetry.normalized_points` has `(device_id, event_time DESC)`, `(logical_point_id, event_time DESC)`, `(organization_id, event_time DESC)`-style indexes. The `analytics.energy_consumption_*` tables have explicit `(organization_id, site_id, bucket_start DESC)` and `(device_id, bucket_start DESC)` indexes — consistent with what this session's live schema inspection also found for these tables (see [05-database.md](05-database.md)).
- **A specific identified risk**: at least one Grafana-facing view resolves `asset_id` via a `LEFT JOIN LATERAL` correlated subquery against `metadata.asset_devices`, executed once per matched raw row — the audit notes this scales with raw row *volume*, not device count, and that some panels apparently query raw/native resolution "always... including 30-day/3-month/1-year selections a user could pick," with "nothing in the panel SQL or view enforc[ing] a ceiling."

**CURRENT STATE vs. this session's evidence: unresolved / not re-checked.** This session's own queries never exercised a 30-day-or-longer range (the fleet is only ~2 hours old), so it cannot confirm or refute whether that specific risk is still present. Treat the audit's finding as **STATUS: Historical finding, not superseded by live evidence** — someone should re-run that specific class of query against staging or production with a realistic long time range and `EXPLAIN (ANALYZE, BUFFERS)` before considering this closed.

## 22.4 Recommendations (do not treat as implemented)

- Before onboarding a fleet larger than ~22 devices or letting real users pick long dashboard time ranges, re-run the Phase 0 static audit's flagged queries live with `EXPLAIN ANALYZE` at realistic data volumes.
- Confirm whether any dashboard panel allows a user-selected time range to fall back to raw-resolution querying without a ceiling, per the audit finding above.
- Re-run the measured-timings table in §22.2 periodically as data volume grows, to catch degradation early — the queries in [19-operations-and-diagnostics.md](19-operations-and-diagnostics.md) §19.3–19.4 are directly reusable for this.
