# Canonical telemetry pipeline

## Production data path

1. Telegraf writes its PostgreSQL output contract to `public.mqtt_staging`.
2. `public.mqtt_staging` is an **INSERT-only compatibility view**. Its `INSTEAD OF INSERT` trigger calls `telemetry.capture_telegraf_mqtt_insert()`.
3. `telemetry.raw_messages` is the canonical durable raw-message table.
4. `telemetry.v_rtdata` parses Eniscope `rtdata` arrays from `telemetry.raw_messages`.
5. `telemetry.v_normalized_points` resolves device identity and profile mappings.
6. `telemetry.normalized_points` stores deduplicated logical points using `(event_time, device_id, logical_point_id)` uniqueness.
7. Domain loaders route data into `telemetry.energy_measurements`, `telemetry.environment_measurements`, and other domain tables.

## Rules for developers and operators

- Never query `public.mqtt_staging` to confirm receipt; it intentionally returns no retained rows.
- Query `telemetry.raw_messages` for raw persistence.
- Query `telemetry.v_rtdata` for parsed device payloads.
- Query `telemetry.normalized_points` for durable deduplicated point data.
- Query the applicable domain table for final routed data.
- Treat `postgres/migrations/157_clean_raw_telemetry_cutover.sql` and later migrations as the deployed cutover history.
- Historical migrations are immutable records. Do not execute an old migration manually against a current database.

## UID trace example

```sql
SELECT received_at, mqtt_topic, device_uid, device_identifier,
       source_timestamp, payload
FROM telemetry.v_rtdata
WHERE lower(device_uid) = lower(:mqtt_uid)
ORDER BY received_at DESC
LIMIT 20;
```
