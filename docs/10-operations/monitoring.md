# Monitoring and Diagnostics

Status: CURRENT · Last reviewed: 2026-08-24
Verification basis: Repository, Staging (live queries)

**Design principle: every command here is read-only.**

## Connecting to a database read-only from a local shell

Staging and production Postgres are not directly reachable with a locally
installed `psql` in every environment. The pattern: run `psql` inside a
disposable `postgres:16-alpine` container, using the existing `pgpass.conf`
credential file, piped through `tr -d '\r'` (Windows-authored pgpass files
are CRLF-terminated, which silently corrupts the last field of any
non-final line if not stripped) and mounted read-only — this avoids ever
printing a password.

**Staging** (via an SSH tunnel on `127.0.0.1:15432`):

```bash
docker run --rm \
  -v "<path-to-pgpass.conf>:/tmp/pgpass.conf:ro" \
  --add-host=host.docker.internal:host-gateway \
  postgres:16-alpine \
  sh -c "tr -d '\r' < /tmp/pgpass.conf | sed 's/^127\.0\.0\.1:15432:/host.docker.internal:15432:/' > /root/.pgpass && chmod 600 /root/.pgpass && PGPASSFILE=/root/.pgpass psql \"host=host.docker.internal port=15432 dbname=ems user=<role> sslmode=prefer\" -c \"<query>\""
```

**Production** (direct host, read-only role only):

```bash
docker run --rm \
  -v "<path-to-pgpass.conf>:/tmp/pgpass.conf:ro" \
  postgres:16-alpine \
  sh -c "tr -d '\r' < /tmp/pgpass.conf > /root/.pgpass && chmod 600 /root/.pgpass && PGPASSFILE=/root/.pgpass psql \"host=<prod-host> port=5432 dbname=ems user=ems_readonly sslmode=prefer\" -c \"<query>\""
```

**Known friction**: the staging tunnel has proven unstable — expect
`connection refused` or `server closed the connection unexpectedly`
requiring a reconnect. See [troubleshooting.md](troubleshooting.md).

Repository-provided verification scripts also exist under `scripts/verify/`
(`verify_database.sh`, `verify_metadata.sh`, `verify_pipeline.sh`,
`verify_jobs.sh`, `verify_all.sh`) and `postgres/scripts/status.sh` — read
them before running to confirm they are read-only in your environment.

## Service health (what's checkable without infra access)

| Service | Healthcheck (from `compose.yaml`) |
|---|---|
| `timescaledb` | `pg_isready`, every 20s |
| `telegraf` | none defined |
| `grafana` | HTTP `/api/health`, expects `"database":"ok"` |
| `live-telemetry` | HTTP `/health`, expects `"status":"ok"` |
| `admin-portal` | expects `status:"ok"` and `database.status:"ok"` |

No documented verification session has had `docker exec`/SSH access —
only PostgreSQL. `docker compose ps`, `docker compose logs`, and `docker
inspect --format='{{json .State.Health}}'` are the natural next steps if
that access exists.

## Telemetry / device diagnostics (tested query patterns)

Per-device freshness, raw/normalized volume, and point-configuration
coverage queries, parameterized by organization code, are documented with
full SQL in the archived platform manual at
[../99-archive/historical-implementation/platform-manual/19-operations-and-diagnostics.md](../99-archive/historical-implementation/platform-manual/19-operations-and-diagnostics.md) —
every query there was run successfully against staging and returned under
200ms for a 22-device fleet.

## Aggregation-layer verification

Confirm all five resolutions populated and current for an org (see
[../06-platform/telemetry/aggregation.md](../06-platform/telemetry/aggregation.md)
for what "populated" should mean at each resolution — some are legitimately
0 rows by design). Full SQL in the archived source, above.

## Data-quality / consistency checks

A batch of 9 checks (duplicate MQTT_UID, duplicate external_ids, orphaned
asset_devices, devices without an asset, direct-meter assets without a
device, devices with no current telemetry, telemetry with no analytics
row) should all return `0` for a healthy org — confirmed for Meenaxy
Pharma's 22 devices, all 9 returning 0.

## Pipeline health surface

`analytics.v_pipeline_health` (migration 214) is the first stop for "is the
analytical pipeline OK?" — one row per reconciliation tier, with
`forward_state`/`reconcile_state`/`integrity_risk`/`health`. See
[../06-platform/telemetry/pipeline.md](../06-platform/telemetry/pipeline.md)
"Operator health surface."

```sql
SELECT pipeline, health, forward_state, reconcile_state, integrity_risk, health_reason
FROM analytics.v_pipeline_health
ORDER BY health_rank DESC, domain, pipeline;
```

- `health = 'ERROR'` → a reconcile job is `FAILED`/`STALE`, the forward job
  is `FAILED`/wedged, or a tier keeps finding fresh deficits.
- `integrity_risk = 'CAGG_OVERSHOOT'` → the reconcile will backfill within
  one cycle once source lands; only act if it persists for days.
- `integrity_risk = 'OLDER_BACKFILL_UNKNOWN'` → **expected steady state**
  for the two native energy tiers — run the bounded older-backfill
  diagnostic (full SQL in the archived platform manual, above) when you
  suspect an old correction landed.
