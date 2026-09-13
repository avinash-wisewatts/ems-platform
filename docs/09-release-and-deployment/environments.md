# Environment Management

Status: CURRENT · Last reviewed: 2026-08-24
Verification basis: Repository. No real secret value is reproduced anywhere in this document.

## Env file boundaries

The repository deliberately splits environment configuration across six
files rather than one, so a credential compromise or config change in one
boundary doesn't require touching unrelated services.

| File | Consumed by | Purpose |
|---|---|---|
| root `.env` | `timescaledb`, `telegraf` (partially) | `POSTGRES_USER`, `POSTGRES_DB`, `TIMESCALEDB_DATA_PATH`, `ADMIN_PORTAL_BIND_HOST`, `GRAFANA_BIND_HOST`. Template: `.env.example`. |
| `telegraf/.env` | `telegraf` | MQTT input connection details for `telegraf.conf`. No example file exists — see [../10-operations/troubleshooting.md](../10-operations/troubleshooting.md). |
| `app/.env` | `live-telemetry`, `admin-portal` | Shared application configuration for both services (same image). |
| `app/live-telemetry.env` | `live-telemetry` only | **Server-side-only** HiveMQ credentials (`MQTT_HOST`, `MQTT_PORT`, `MQTT_USERNAME`, `MQTT_PASSWORD`, `MQTT_LIVE_CLIENT_ID`, `MQTT_TLS`) and `EMS_GRAFANA_STREAM_TOKEN`. Template: `app/live-telemetry.env.example`. Header comment: "Do not reuse these credentials in Grafana or any browser." |
| `grafana/.env` | `grafana` | Grafana-specific configuration. |
| `grafana/live-stream.env` | `grafana` | Live-stream/live-telemetry datasource plugin configuration. |

None of the six real files are committed to Git; only the two `.example`
templates exist in the repository.

## Why this boundary exists

Per project instructions: "Do not merge environment responsibilities
without architectural justification. Do not copy credentials between
environments." The specific reason for isolating `app/live-telemetry.env`
from every other file: MQTT broker credentials must never reach the browser
or Grafana directly — keeping them in a file consumed by *only* the
`live-telemetry` service (not `admin-portal`, despite sharing the same
image) structurally enforces that boundary. See
[../04-architecture/security-and-tenancy.md](../04-architecture/security-and-tenancy.md).

## Gap noted, not fixed

No `telegraf/.env.example` template exists, unlike the root and
`app/live-telemetry` boundaries. A documentation-completeness gap in the
repository itself — not silently filled in.

## CI's placeholder approach

`ci.yml`'s `config-validation` job creates non-secret placeholder files for
all six env files purely so `docker compose config -q` doesn't fail on a
missing file. Only `POSTGRES_USER`/`POSTGRES_DB` are actually interpolated
at validation time; the other five files are left empty placeholders.
