# 19. Operations & Diagnostics

```
Status: CURRENT
Last verified: 2026-08-24
Verification basis: Repository, Staging (live queries this session)
```

Design principle for this document: **every command here is read-only.** None of them mutate metadata, telemetry, or configuration. If you need to fix something you find, that's a separate, deliberate, approved change — not a diagnostic step.

## 19.1 Connecting to a database read-only from a local shell

The staging and production Postgres hosts are not directly reachable with a locally installed `psql` in every environment this manual was written from. The pattern below runs `psql` inside a disposable `postgres:16-alpine` container instead, using the same `pgpass.conf` credential file the environment already has configured. This avoids ever printing a password: the file is piped through `tr -d '\r'` (Windows-authored pgpass files are CRLF-terminated, which silently corrupts the last field of any non-final line if not stripped) and mounted read-only.

**Staging** (via an already-open SSH tunnel on `127.0.0.1:15432`, credential keyed to that literal host:port in `pgpass.conf`, rewritten to `host.docker.internal` so the container can reach the tunnel on the host):

```bash
docker run --rm \
  -v "<path-to-pgpass.conf>:/tmp/pgpass.conf:ro" \
  --add-host=host.docker.internal:host-gateway \
  postgres:16-alpine \
  sh -c "tr -d '\r' < /tmp/pgpass.conf | sed 's/^127\.0\.0\.1:15432:/host.docker.internal:15432:/' > /root/.pgpass && chmod 600 /root/.pgpass && PGPASSFILE=/root/.pgpass psql \"host=host.docker.internal port=15432 dbname=ems user=<role> sslmode=prefer\" -c \"<query>\""
```

**Production** (direct host, read-only role only — see [23-known-issues-and-drift.md](23-known-issues-and-drift.md) and [14-authentication-and-tenancy.md](14-authentication-and-tenancy.md) for the access model):

```bash
docker run --rm \
  -v "<path-to-pgpass.conf>:/tmp/pgpass.conf:ro" \
  postgres:16-alpine \
  sh -c "tr -d '\r' < /tmp/pgpass.conf > /root/.pgpass && chmod 600 /root/.pgpass && PGPASSFILE=/root/.pgpass psql \"host=<prod-host> port=5432 dbname=ems user=ems_readonly sslmode=prefer\" -c \"<query>\""
```

For multi-statement scripts, write the SQL to a temp file and mount it, then use `-f /tmp/script.sql` instead of `-c`. Add `\timing on` at the top of the script to measure execution time (see [22-performance.md](22-performance.md)).

**Known friction**: the staging tunnel has proven unstable in practice — expect `connection refused` or `server closed the connection unexpectedly` errors requiring a reconnect. See [24-troubleshooting.md](24-troubleshooting.md).

Repository-provided verification scripts also exist under `scripts/verify/` (`verify_database.sh`, `verify_metadata.sh`, `verify_pipeline.sh`, `verify_jobs.sh`, `verify_all.sh`, plus many targeted `verify_<migration>.sql` files) and `postgres/scripts/status.sh`. These were not executed as part of producing this manual (repository presence confirmed by directory listing only — STATUS: implemented, not verified this session); read them before running to confirm they are read-only in your environment.

## 19.2 Service health (what's checkable without infra access)

This manual was written without SSH or `docker exec` access to any environment — only Postgres. What follows is what `compose.yaml` declares as the *intended* health mechanism; it was not observed live.

| Service | Healthcheck (from `compose.yaml`) |
|---|---|
| `timescaledb` | `pg_isready -U ${POSTGRES_USER} -d ${POSTGRES_DB}`, every 20s |
| `telegraf` | none defined in compose |
| `grafana` | HTTP `/api/health`, expects `"database":"ok"` |
| `live-telemetry` | HTTP `/health`, expects `"status":"ok"` |
| `admin-portal` | expects `status:"ok"` and `database.status:"ok"`; depends on timescaledb and grafana being healthy |

If you have `docker exec`/SSH access this manual's author did not: `docker compose ps`, `docker compose logs --tail=200 <service>`, and `docker inspect --format='{{json .State.Health}}' <container>` are the natural next steps — not verified here.

## 19.3 Telemetry / device diagnostics (tested queries)

All queries below are parameterized by organization `code` — replace `MEENAXY_PHARMA` with the org you're checking. Every query in this section was run successfully against staging in this session (2026-08-24) and returned in well under 200ms for a 22-device fleet — see [22-performance.md](22-performance.md).

**Per-device telemetry freshness** (staleness threshold shown is 15 minutes — adjust to the site's actual capture interval, see [11-aggregation.md](11-aggregation.md)):

```sql
SELECT d.external_id, di.identifier_value AS mqtt_uid, g.external_id AS gateway,
       ts.latest_source_timestamp, ts.latest_received_timestamp,
       CASE WHEN ts.latest_received_timestamp IS NULL THEN 'NEVER_SEEN'
            WHEN ts.latest_received_timestamp < now() - interval '15 minutes' THEN 'STALE'
            ELSE 'CURRENT' END AS freshness
FROM metadata.devices d
JOIN metadata.organizations o ON o.id = d.organization_id
JOIN metadata.gateways g ON g.id = d.gateway_id
LEFT JOIN metadata.device_identifiers di ON di.device_id = d.id AND di.identifier_type = 'MQTT_UID'
LEFT JOIN telemetry.device_telemetry_state ts ON ts.device_id = d.id
WHERE o.code = 'MEENAXY_PHARMA'
ORDER BY g.external_id, d.external_id;
```

**Raw / normalized telemetry volume per device** (confirms data is actually landing, not just that a state row exists):

```sql
SELECT d.external_id, count(em.id) AS raw_row_count, max(em.source_timestamp) AS latest_raw
FROM metadata.devices d JOIN metadata.organizations o ON o.id = d.organization_id
LEFT JOIN telemetry.energy_measurements em ON em.device_id = d.id
WHERE o.code = 'MEENAXY_PHARMA'
GROUP BY d.external_id ORDER BY raw_row_count ASC;

SELECT d.external_id, count(np.*) AS normalized_row_count, max(np.event_time) AS latest_normalized
FROM metadata.devices d JOIN metadata.organizations o ON o.id = d.organization_id
LEFT JOIN telemetry.normalized_points np ON np.device_id = d.id
WHERE o.code = 'MEENAXY_PHARMA'
GROUP BY d.external_id ORDER BY normalized_row_count ASC;
```

**Device point-configuration coverage** (expect one row per device with `mapped = enabled` and `duplicate_rows = 0`; the expected `mapped` count equals the device's profile's row count in `config.profile_field_mapping` — see [07-telemetry-pipeline.md](07-telemetry-pipeline.md)):

```sql
SELECT d.external_id, count(*) AS mapped, count(*) FILTER (WHERE dpc.is_enabled) AS enabled,
       count(*) - count(DISTINCT dpc.logical_point_id) AS duplicate_rows
FROM metadata.devices d JOIN metadata.organizations o ON o.id = d.organization_id
LEFT JOIN config.device_point_configuration dpc ON dpc.device_id = d.id
WHERE o.code = 'MEENAXY_PHARMA'
GROUP BY d.external_id ORDER BY mapped;
```

## 19.4 Aggregation-layer verification

Confirm all five resolutions are populated and current for a given org (see [11-aggregation.md](11-aggregation.md) for what "populated" should mean at each resolution — some are legitimately 0 rows by design):

```sql
SELECT 'analytics.energy_consumption_1min' AS resolution, count(*) rows, count(DISTINCT ec.device_id) devices,
       min(bucket_start) earliest, max(bucket_start) latest
FROM analytics.energy_consumption_1min ec JOIN metadata.organizations o ON o.id = ec.organization_id
WHERE o.code = 'MEENAXY_PHARMA'
UNION ALL
SELECT 'analytics.energy_consumption_5min', count(*), count(DISTINCT ec.device_id), min(bucket_start), max(bucket_start)
FROM analytics.energy_consumption_5min ec JOIN metadata.organizations o ON o.id = ec.organization_id WHERE o.code = 'MEENAXY_PHARMA'
UNION ALL
SELECT 'analytics.energy_consumption_15min', count(*), count(DISTINCT ec.device_id), min(bucket_start), max(bucket_start)
FROM analytics.energy_consumption_15min ec JOIN metadata.organizations o ON o.id = ec.organization_id WHERE o.code = 'MEENAXY_PHARMA'
UNION ALL
SELECT 'analytics.energy_consumption_hourly', count(*), count(DISTINCT ec.device_id), min(bucket_start), max(bucket_start)
FROM analytics.energy_consumption_hourly ec JOIN metadata.organizations o ON o.id = ec.organization_id WHERE o.code = 'MEENAXY_PHARMA'
UNION ALL
SELECT 'analytics.energy_consumption_daily', count(*), count(DISTINCT ec.device_id), min(bucket_start), max(bucket_start)
FROM analytics.energy_consumption_daily ec JOIN metadata.organizations o ON o.id = ec.organization_id WHERE o.code = 'MEENAXY_PHARMA';
```

**Important**: before treating an empty resolution as a failure, check the site's effective capture interval — `analytics.energy_consumption_5min` is *by design* only populated for 300-second-capture sites (see [11-aggregation.md](11-aggregation.md)):

```sql
SELECT s.code, cp.*
FROM metadata.sites s JOIN metadata.organizations o ON o.id = s.organization_id
CROSS JOIN LATERAL telemetry.resolve_site_capture_bucket(s.id, now()) cp
WHERE o.code = 'MEENAXY_PHARMA';
```

## 19.5 Commissioning / lifecycle verification

```sql
SELECT g.external_id, g.lifecycle_status
FROM metadata.gateways g JOIN metadata.organizations o ON o.id = g.organization_id
WHERE o.code = 'MEENAXY_PHARMA' ORDER BY 1;

SELECT d.lifecycle_status, d.operational_policy, d.location_mode, count(*)
FROM metadata.devices d JOIN metadata.organizations o ON o.id = d.organization_id
WHERE o.code = 'MEENAXY_PHARMA' GROUP BY 1, 2, 3;

SELECT cr.entity_id, cr.commissioning_status, cr.is_ready, cr.blocking_reason_codes
FROM analytics.v_commissioning_readiness cr
JOIN metadata.devices d ON d.id = cr.entity_id AND cr.entity_type = 'DEVICE'
JOIN metadata.organizations o ON o.id = d.organization_id
WHERE o.code = 'MEENAXY_PHARMA';
```

Who actually commissioned a device (and when) is recoverable from the audit trail, not just current state:

```sql
SELECT requested_by, request_payload->>'operation' AS operation, created_at
FROM admin.onboarding_audit
WHERE request_payload->>'operation' = 'COMMISSION_DEVICE'
ORDER BY created_at DESC LIMIT 25;
```

## 19.6 Grafana diagnostics (data-side only)

Without Grafana API/UI access, the closest available check is confirming the org has an active Grafana mapping — a dashboard cannot resolve any data for a tenant without this row (see [12-grafana.md](12-grafana.md)):

```sql
SELECT gom.grafana_org_id, gom.is_active, gom.updated_at
FROM metadata.grafana_organization_map gom
JOIN metadata.organizations o ON o.id = gom.organization_id
WHERE o.code = 'MEENAXY_PHARMA';
```

Then confirm the Grafana-facing views actually return current data for that org (see [10-analytics.md](10-analytics.md) for the full view catalog):

```sql
SELECT count(*) FROM analytics.v_grafana_devices WHERE organization_id = (SELECT id FROM metadata.organizations WHERE code = 'MEENAXY_PHARMA');
SELECT count(*), max(sample_time) FROM analytics.v_grafana_energy_samples WHERE organization_id = (SELECT id FROM metadata.organizations WHERE code = 'MEENAXY_PHARMA');
```

## 19.7 Data-quality / consistency checks

All of the following should return `0` for a healthy org. Run individually or as one `UNION ALL` batch:

```sql
SELECT 'dup_mqtt_uid' chk, count(*) FROM (
  SELECT identifier_value FROM metadata.device_identifiers WHERE identifier_type = 'MQTT_UID' GROUP BY identifier_value HAVING count(*) > 1
) x
UNION ALL
SELECT 'dup_device_external_id', count(*) FROM (
  SELECT organization_id, upper(external_id) FROM metadata.devices GROUP BY 1, 2 HAVING count(*) > 1
) x
UNION ALL
SELECT 'dup_asset_external_id', count(*) FROM (
  SELECT organization_id, site_id, upper(external_id) FROM metadata.assets GROUP BY 1, 2, 3 HAVING count(*) > 1
) x
UNION ALL
SELECT 'orphaned_asset_devices', count(*) FROM metadata.asset_devices ad
  LEFT JOIN metadata.assets a ON a.id = ad.asset_id LEFT JOIN metadata.devices d ON d.id = ad.device_id
  WHERE a.id IS NULL OR d.id IS NULL
UNION ALL
SELECT 'devices_without_asset', count(*) FROM metadata.devices d
  JOIN metadata.organizations o ON o.id = d.organization_id
  LEFT JOIN metadata.asset_devices ad ON ad.device_id = d.id
  WHERE o.code = 'MEENAXY_PHARMA' AND ad.id IS NULL
UNION ALL
SELECT 'direct_meter_assets_without_device', count(*) FROM metadata.assets a
  JOIN metadata.organizations o ON o.id = a.organization_id
  LEFT JOIN metadata.asset_devices ad ON ad.asset_id = a.id AND ad.relationship_type = 'PRIMARY_METER'
  WHERE o.code = 'MEENAXY_PHARMA' AND a.metering_requirement = 'DIRECT_METER_REQUIRED' AND ad.id IS NULL
UNION ALL
SELECT 'devices_no_current_telemetry', count(*) FROM metadata.devices d
  JOIN metadata.organizations o ON o.id = d.organization_id
  LEFT JOIN telemetry.device_telemetry_state ts ON ts.device_id = d.id
  WHERE o.code = 'MEENAXY_PHARMA' AND (ts.latest_received_timestamp IS NULL OR ts.latest_received_timestamp < now() - interval '15 minutes')
UNION ALL
SELECT 'telemetry_with_no_analytics_1min_row', count(*) FROM metadata.devices d
  JOIN metadata.organizations o ON o.id = d.organization_id
  JOIN telemetry.device_telemetry_state ts ON ts.device_id = d.id
  LEFT JOIN analytics.energy_consumption_1min ec ON ec.device_id = d.id
  WHERE o.code = 'MEENAXY_PHARMA' AND ts.latest_received_timestamp IS NOT NULL AND ec.device_id IS NULL;
```

This exact batch was run against Meenaxy Pharma's 22 devices on 2026-08-24: all 9 checks returned 0.

## 19.8 Common failure modes

See [24-troubleshooting.md](24-troubleshooting.md) for symptom → cause → fix write-ups of the specific incidents this manual's underlying investigation actually hit.

## 19.9 Pipeline health & the CAGG older-backfill check

`analytics.v_pipeline_health` (migration 214, `SELECT` for `grafana_reader`) is the first stop for "is the analytical pipeline OK?" — one row per reconciliation tier, with `forward_state`, `reconcile_state`, `integrity_risk`, and an overall `health` (see [07-telemetry-pipeline.md](07-telemetry-pipeline.md) "Operator health surface"). Start here:

```sql
SELECT pipeline, health, forward_state, reconcile_state, integrity_risk, health_reason
FROM analytics.v_pipeline_health
ORDER BY health_rank DESC, domain, pipeline;
```

- `health = 'ERROR'` → a reconcile job is `FAILED`/`STALE`, the forward job is `FAILED`/wedged, or a tier keeps finding fresh deficits (`PERSISTENT_DEFICIT`). Check `reconcile_last_error_sqlstate`, then `analytics.pipeline_reconciliation_log` for the full row (`first_error_message` lives there, not in the view).
- `health = 'WARNING'` with `integrity_risk = 'CAGG_OVERSHOOT'` → the `ca_energy_1min`/`_5min` materialisation watermark is ahead of real source; the 213 reconcile will backfill the children within one reconcile cycle once source lands. Only act if it persists for days (upstream stall).
- `integrity_risk = 'OLDER_BACKFILL_UNKNOWN'` → **expected steady state** for the two native energy tiers. The view cannot cheaply prove whether source was corrected *older* than the CAGG `start_offset` (2 days for `ca_energy_1min`, 7 days for `ca_energy_5min`); run the bounded diagnostic below when you suspect an old correction/backfill (e.g. after a job-1077 replay or a manual `energy_measurements` edit).

**Older-than-`start_offset` backfill diagnostic** (bounded — scans one hour-grouped `count(*)` band between the outer horizon and the current reconcile horizon; run per native tier, per org):

```sql
-- energy_consumption_1min: source (energy_measurements) vs child, by hour,
-- over [current_date - :days_back, older_backfill_horizon) where the 213
-- reconcile can no longer see. Replace :days_back with how far back you suspect
-- a correction landed (keep it modest - this scans real chunks).
WITH horizon AS (
    SELECT older_backfill_horizon AS h
    FROM analytics.v_pipeline_health WHERE pipeline = 'energy_consumption_1min'
),
src AS (
    SELECT date_trunc('hour', em.bucket_start) AS hr, count(*) AS src_rows
    FROM telemetry.energy_measurements em
    JOIN metadata.organizations o ON o.id = em.organization_id
    CROSS JOIN horizon
    WHERE o.code = :'org_code'
      AND em.bucket_start >= current_date - make_interval(days => :days_back)
      AND em.bucket_start <  horizon.h
    GROUP BY 1
),
child AS (
    SELECT date_trunc('hour', ec.bucket_start) AS hr, count(*) AS child_rows
    FROM analytics.energy_consumption_1min ec
    JOIN metadata.organizations o ON o.id = ec.organization_id
    CROSS JOIN horizon
    WHERE o.code = :'org_code'
      AND ec.bucket_start >= current_date - make_interval(days => :days_back)
      AND ec.bucket_start <  horizon.h
    GROUP BY 1
)
SELECT COALESCE(s.hr, c.hr) AS hour, s.src_rows, c.child_rows
FROM src s FULL JOIN child c USING (hr)
WHERE s.src_rows IS DISTINCT FROM c.child_rows
ORDER BY 1;
```

Any row where `src_rows > child_rows` (or `child_rows` is NULL) is an un-repaired older-backfill hole. **Remedy** (operator, top level, *not* inside a transaction — TimescaleDB 2.29.2 rejects it otherwise):

```sql
CALL public.refresh_continuous_aggregate('telemetry.ca_energy_1min', '<old_from>', '<old_to>');
-- then wait one reconcile cycle (reconcile_energy_consumption_1min runs hourly);
-- it will re-drive the affected children once the CAGG rows exist.
```

Use `ca_energy_5min` / `energy_consumption_5min` for the 5-minute tier. Never widen `reconcile_window` past the CAGG `start_offset` to "fix" this — the automatic CAGG policy would still not have materialised the older band, so the reconcile detector would compare stale-against-stale and report `HEALTHY`.
