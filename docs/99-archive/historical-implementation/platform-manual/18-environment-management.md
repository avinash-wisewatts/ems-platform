# Environment Management

Status: CURRENT
Last verified: 2026-08-24
Verification basis: Repository

No real secret value is reproduced anywhere in this document. Variable
*names* only.

## Env file boundaries

The repository deliberately splits environment configuration across six
files rather than one, so that a credential compromise or a config change
in one boundary doesn't require touching unrelated services. Each file's
existence, purpose, and consumer:

| File | Consumed by | Purpose |
|---|---|---|
| root `.env` | `timescaledb`, `telegraf` (partially) | `POSTGRES_USER`, `POSTGRES_DB` (interpolated into `compose.yaml`'s healthcheck and referenced by Telegraf's Postgres output), `TIMESCALEDB_DATA_PATH`, `ADMIN_PORTAL_BIND_HOST`, `GRAFANA_BIND_HOST`. Template: `.env.example`. |
| `telegraf/.env` | `telegraf` | Telegraf-specific configuration referenced by `telegraf/config/telegraf.conf` (MQTT input connection details). No example file was found in this repository as of verification — see gap note below. |
| `app/.env` | `live-telemetry`, `admin-portal` | Shared application configuration for both services (they run the same image). |
| `app/live-telemetry.env` | `live-telemetry` only | **Server-side-only** HiveMQ MQTT credentials (`MQTT_HOST`, `MQTT_PORT`, `MQTT_USERNAME`, `MQTT_PASSWORD`, `MQTT_LIVE_CLIENT_ID`, `MQTT_TLS`) and `EMS_GRAFANA_STREAM_TOKEN`. Template: `app/live-telemetry.env.example`. Per this file's own header comment: "Do not reuse these credentials in Grafana or any browser." |
| `grafana/.env` | `grafana` | Grafana-specific configuration. |
| `grafana/live-stream.env` | `grafana` | Configuration for the live-stream/live-telemetry datasource plugin integration. |

None of these six real files are committed to Git (`.gitignore`); only
`.env.example` and `app/live-telemetry.env.example` exist as templates in
this repository.

## Why this boundary exists (per CLAUDE.md, project instructions)

> "Do not merge environment responsibilities without architectural
> justification. Do not copy credentials between environments."

The specific architectural reason for isolating `app/live-telemetry.env`
from every other file: MQTT broker credentials must never reach the
browser or Grafana directly (see [07-telemetry-pipeline.md](07-telemetry-pipeline.md)
and [20-security.md](20-security.md)) — keeping them in a file consumed by
*only* the `live-telemetry` service (not `admin-portal`, despite sharing
the same image) is a structural enforcement of that boundary, not just a
convention.

## Gap noted, not fixed

No `telegraf/.env.example` template exists in this repository as of this
verification, unlike the root and `app/live-telemetry` boundaries, which
both have one. This is a documentation-completeness gap in the repository
itself, not something this manual should silently fill in with invented
content — flagged in
[23-known-issues-and-drift.md](23-known-issues-and-drift.md).

## CI's placeholder approach

`ci.yml`'s `config-validation` job creates non-secret placeholder files for
all six env files purely so `docker compose config -q` doesn't fail on a
missing file (Compose requires `env_file:` targets to exist even if
`docker compose config` doesn't start any containers). Its own comment
notes only `POSTGRES_USER`/`POSTGRES_DB` are actually interpolated by
`compose.yaml` at validation time; the other five files are left empty
placeholders since nothing at that stage reads their contents.
