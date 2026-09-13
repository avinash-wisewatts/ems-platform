# MQTT and Telegraf

```
Status: CURRENT
Last verified: 2026-08-24
Verification basis: Repository (telegraf/config/telegraf.conf, app/src/live_telemetry/broker.py, hub.py)
```

## Two independent MQTT subscribers

Per CLAUDE.md §7, the platform has two separate telemetry paths sharing the same MQTT broker and topic space, with different responsibilities:

### Historical path: Telegraf

`telegraf/config/telegraf.conf`. Config-driven, no code. Key facts (mechanism only — no credential values reproduced here):

- `[[inputs.mqtt_consumer]]`, connects over TLS (`ssl://${MQTT_HOST}:${MQTT_PORT}`), authenticates via `${MQTT_USERNAME}`/`${MQTT_PASSWORD}` env vars, `qos=1`.
- Subscribes to two topic patterns: `wwems/v1/+/+/+/telemetry` (gateway-consolidated payload: `wwems/v1/{organization}/{site}/{gateway}/telemetry`) and `wwems/v1/+/+/+/+/telemetry` (per-device payload, with an extra `{device}` segment).
- `data_format = "value"`, `data_type = "string"` — Telegraf does not parse the JSON payload itself; it's captured as an opaque string.
- `[[outputs.postgresql]]` writes to `public.mqtt_staging`, an insert-only adapter view (`schema = "public"`, `tags_as_jsonb = true`, `fields_as_jsonb = true`, `timestamp_column_name = "received_at"`). The view exists specifically so no telemetry is stored in `public` proper — it writes through to `telemetry.raw_messages`.
- The config file's own header states the design principle: *"Telegraf stores raw payloads. Semantic interpretation happens later through metadata mappings."* Confirmed accurate — Telegraf performs no device/profile resolution.

### Live path: `live-telemetry` (`app/src/live_telemetry/`)

A separate Python service (`broker.py` + `hub.py`), independent of Telegraf:

- `LiveTelemetryBroker` (paho-mqtt client, `MQTTv311`, TLS optional per config) subscribes to the **same two topic patterns** as Telegraf, independently.
- On each message, calls `telemetry.ingest_live_rtdata(topic, payload::jsonb, received_at)` directly (a database function, not the Telegraf/raw_messages path), which returns the resolved `device_id`.
- On successful ingest, invokes an `on_device_update(device_id)` callback, which pushes to `hub.py`'s `GrafanaAssetLiveHub` — a websocket hub keyed by `(asset_id, grafana_org_id)` — confirming CLAUDE.md's stated design: the browser receives live updates over a server-managed websocket, never MQTT credentials directly.
- `health_snapshot()` exposes non-secret operational state (connection status, subscription confirmation, message/ingest counters, last error) — this is the safe, intended way to check live-telemetry health without needing raw log access; find where this is exposed as an HTTP endpoint (not traced this pass) for `19-operations-and-diagnostics.md`.

## MQTT_UID: the physical identity

`metadata.device_identifiers`, `identifier_type='MQTT_UID'`, `identifier_value` (e.g. `80:34:28:16:22:fe:00:01`) — the hardware's own address, embedded in the MQTT topic/payload by the gateway, not assigned by the platform.

**Verified constraint**: `uq_device_identifier UNIQUE (identifier_type, identifier_value)` on `metadata.device_identifiers` — this is a **platform-wide** uniqueness constraint, not scoped to organization or site. One physical MQTT_UID can belong to exactly one device record across the entire multi-tenant platform. This is a real architectural boundary: it means the same physical hardware cannot legitimately be represented as two different devices in two different organizations (e.g., a staging clone of production data would collide on MQTT_UID if both environments' devices existed in the same database — not a concern across separate staging/production databases, but relevant to any future same-database multi-environment design).

## Where to look when ingestion seems broken

Neither Telegraf's logs nor live-telemetry's logs were accessible during this session's verification (no SSH/container access established). What *is* independently checkable via read-only SQL:
1. Does the MQTT_UID exist in `metadata.device_identifiers`? (If not, no amount of correct MQTT traffic will resolve to a device.)
2. Is `telemetry.raw_messages` receiving rows at all, for any device? (Rules out/in a broker-level or Telegraf-level problem vs. a device-specific mapping problem.)
3. Is `telemetry.device_telemetry_state.latest_received_timestamp` current for the specific device? (This reflects the live-telemetry path's own state table, separate from Telegraf's raw capture.)

See `07-telemetry-pipeline.md` for the full stage-by-stage trace and `19-operations-and-diagnostics.md` for the exact queries used.
