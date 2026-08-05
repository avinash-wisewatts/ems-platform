# Retired prototype bootstrap SQL

The SQL files in this directory are historical prototype bootstrap fragments.
They are **not** part of the canonical production deployment and must not be
run against a current EMS database.

Canonical deployments use:

- `scripts/deploy_database.sh`
- `postgres/restructure_manifest.csv`
- the canonical/reference/jobs categories selected by that runner
- ordered forward migrations through `scripts/apply_migrations.sh`

The current raw telemetry path is documented in
`docs/operations/TELEMETRY_PIPELINE.md`. In particular,
`telemetry.raw_messages` is a table and `public.mqtt_staging` is only an
INSERT-only adapter view.
