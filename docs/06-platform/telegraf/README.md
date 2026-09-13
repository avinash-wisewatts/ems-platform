# MQTT and Telegraf

Status: CURRENT · Last reviewed: 2026-08-24
Verification basis: Repository (telegraf/config/telegraf.conf, app/src/live_telemetry/broker.py, hub.py)

## Two independent MQTT subscribers

The platform has two separate telemetry paths sharing the same MQTT broker
and topic space, with different responsibilities.

### Historical path: Telegraf

`telegraf/config/telegraf.conf`. Config-driven, no code:

- `[[inputs.mqtt_consumer]]`, TLS (`ssl://${MQTT_HOST}:${MQTT_PORT}`),
  `${MQTT_USERNAME}`/`${MQTT_PASSWORD}` env vars, `qos=1`.
- Subscribes to `wwems/v1/+/+/+/telemetry` (gateway-consolidated) and
  `wwems/v1/+/+/+/+/telemetry` (per-device).
- `data_format = "value"`, `data_type = "string"` — Telegraf does not parse
  the JSON payload; captured as an opaque string.
- `[[outputs.postgresql]]` writes to `public.mqtt_staging`, an insert-only
  adapter view that writes through to `telemetry.raw_messages`.
- Config header states the design principle verbatim: "Telegraf stores raw
  payloads. Semantic interpretation happens later through metadata
  mappings." Confirmed accurate.

### Live path: `live-telemetry` (`app/src/live_telemetry/`)

A separate Python service, independent of Telegraf:

- `LiveTelemetryBroker` (paho-mqtt, `MQTTv311`) subscribes to the **same
  two topic patterns**, independently.
- On each message, calls `telemetry.ingest_live_rtdata(topic,
  payload::jsonb, received_at)` directly — a database function, not the
  Telegraf/raw_messages path — which returns the resolved `device_id`.
- On success, invokes `on_device_update(device_id)`, pushing to `hub.py`'s
  `GrafanaAssetLiveHub` — a websocket hub keyed by `(asset_id,
  grafana_org_id)`. The browser receives live updates over a
  server-managed websocket, never MQTT credentials directly.
- `health_snapshot()` exposes non-secret operational state (connection
  status, subscription confirmation, message/ingest counters, last error).

## MQTT_UID: the physical identity

`metadata.device_identifiers`, `identifier_type='MQTT_UID'` — the
hardware's own address, embedded in the topic/payload by the gateway, not
assigned by the platform. `uq_device_identifier UNIQUE
(identifier_type, identifier_value)` is a **platform-wide** constraint, not
scoped to organization or site — one physical MQTT_UID can belong to
exactly one device record across the entire multi-tenant platform.

## Where to look when ingestion seems broken

Neither Telegraf's nor live-telemetry's logs are accessible via
database-only access. What's independently checkable via read-only SQL:

1. Does the MQTT_UID exist in `metadata.device_identifiers`?
2. Is `telemetry.raw_messages` receiving rows at all, for any device?
3. Is `telemetry.device_telemetry_state.latest_received_timestamp` current
   for the specific device?

See [../telemetry/pipeline.md](../telemetry/pipeline.md) for the full
stage-by-stage trace and
[../../10-operations/monitoring.md](../../10-operations/monitoring.md) for
the exact queries.
