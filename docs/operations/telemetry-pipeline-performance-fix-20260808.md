# Telemetry Pipeline Performance Fix — 2026-08-08

## Scope

This change fixes the three production performance defects identified during the
pre-client admin portal investigation while preserving the existing raw-message
failure quarantine design.

1. `telemetry.normalized_points` no longer stores the full per-element JSON
   payload. The full raw MQTT message remains in `telemetry.raw_messages` for
   seven days; failed messages remain in `telemetry.raw_message_failures` for
   thirty days.
2. Device telemetry availability, gateway connectivity, and device
   commissioning readiness use compact persistent state tables instead of
   aggregating the historical `telemetry.normalized_points` hypertable on admin
   page loads.
3. Normalization, energy routing, environment routing, and failure capture use
   a bounded one-minute receipt-time replay rather than repeatedly scanning the
   fifteen-minute late-arrival tolerance. Late source timestamps remain safe
   because a late message has a new platform receipt timestamp and therefore
   enters the incremental window when it actually arrives.

## New objects

- `telemetry.device_point_state`
- `telemetry.device_telemetry_state`
- `telemetry.normalized_points.raw_message_id`
- `normalized_points_raw_lineage_idx`

`raw_message_id` is intentionally not a foreign key. `raw_messages` is a
seven-day operational archive, while normalized telemetry and compact state may
outlive it.

## Existing quarantine preserved

`telemetry.raw_message_failures` remains the failed raw archive/quarantine:

- full failed raw payload retained;
- compression after seven days;
- retention after thirty days;
- diagnostic metadata retained;
- `produced_point_count` now uses durable lineage
  `(platform_received_at, raw_message_id)` instead of JSON containment against
  `normalized_points.payload`.

## Existing data migration

The migration performs one bounded production-safe state seed:

- one sequential aggregation of existing `normalized_points` into compact
  device/point state;
- compact device telemetry state is then derived from that temporary aggregate;
- raw-message lineage is backfilled only for the most recent one hour, which is
  enough to cover the twenty-minute failure-capture grace period without
  rewriting the entire historical hypertable.

The old durable `payload` column is then dropped logically. Existing disk pages
are reclaimed when TimescaleDB compresses old normalized chunks. A one-day
compression policy is installed for `normalized_points`; no `VACUUM FULL` is
required.

## Deployment safety

Keep telemetry jobs 1000, 1001, 1012 and 1052 paused during the migration.
Stop only the admin portal while applying the migration. Telegraf can continue
to write raw MQTT messages; normalization catches the backlog after validation.

Do not edit baseline migration `001_ems_platform_baseline_20260807.sql`.
The production change is migration `003_telemetry_pipeline_performance_state.sql`.

## Required validation before jobs are re-enabled

Confirm:

- migration 003 is applied;
- `normalized_points.payload` is absent;
- `normalized_points.raw_message_id` exists;
- state-table row counts are non-zero for currently observed devices;
- Device list/detail and commissioning-readiness queries return promptly;
- normalized state and routing procedures run manually without error;
- failure capture still retains a full payload for a quarantined failure;
- energy/environment routing uses the new receipt watermark;
- only then re-enable jobs 1000, 1001, 1012 and 1052.


## Clean-build compatibility correction

The canonical performance DDL explicitly adds `platform_received_at` before creating
raw-lineage indexes. Production already has this column from the historical receipt-lineage
migration, while a clean canonical build may not. `ADD COLUMN IF NOT EXISTS` makes the
forward migration safe in both cases.

## Clean-build ordering correction

`postgres/ddl/122_telemetry_pipeline_performance_state.sql` is a `canonical_mirror`, not a foundation `canonical` file. The repository's canonical deployment intentionally excludes later canonical mirrors and then replays baseline migration 001 before applying forward migration 003. This keeps 003's prerequisites, including `config.device_point_configuration`, in their established order.

## Payload-column dependency safety

Migration 003 recreates `telemetry.v_energy_measurements_full_resolution` with an explicit normalized-point projection before dropping `telemetry.normalized_points.payload`. This removes the historical dependency introduced by `SELECT np.*`.

Immediately before the drop, migration 003 queries `pg_catalog.pg_depend`. If any untracked database object still depends on the payload column, the migration raises an exception and the migration runner rolls the entire transaction back.
