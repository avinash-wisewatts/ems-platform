# WiseWatts EMS Platform

A multi-tenant energy management system: TimescaleDB/PostgreSQL telemetry and
analytics backend, a FastAPI admin portal for organization/site/asset/device
onboarding, and Grafana dashboards (including a custom live-telemetry
datasource plugin) for energy, demand, and environmental monitoring.

## Layout

- `app/` — FastAPI admin portal and live-telemetry service (Python).
- `postgres/` — schema DDL, forward migrations, and seed data. See
  `postgres/restructure_manifest.csv` for the authoritative migration ledger.
- `grafana/` — provisioned dashboards, datasources, and the
  `wisewatts-live-datasource` plugin source.
- `docs/` — architecture decisions, design docs, and operational notes.
- `scripts/` — migration and operational tooling.

## Getting started

See `compose.yaml` (production-like local stack) and `compose.test.yaml`
(test database). Run the app test suite with `make test-app` or via the
`.venv-test` virtualenv and `pytest app/tests`.
