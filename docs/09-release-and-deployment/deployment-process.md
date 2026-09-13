# Deployment Process

Status: PARTIAL · Last reviewed: 2026-08-30 · Owner: Engineering

## What `deploy_release.sh` does

Deploys the pre-built, SHA-tagged image via SSH to the target host, running
`scripts/release/post_deploy_verify.sh` afterward. It deliberately
**never** recreates `timescaledb`, `telegraf`, or `grafana` — `APP_SERVICES`
is always named explicitly, and those three are never in that list, so a
normal app deploy cannot accidentally disrupt the database, ingestion, or
dashboards. See [../06-platform/deployment/README.md](../06-platform/deployment/README.md)
for the service dependency graph this respects.

## One-time, separately-authorized exceptions

Some configuration changes require a `timescaledb` recreate (a `postmaster`
setting, e.g. `max_connections`, only takes effect on restart) — these are
explicitly **not** bundled into `deploy_release.sh` and are run manually,
once, after the release is otherwise on staging. Example: the
`max_connections=25` → `50` fix (2026-08-28) — see
[../10-operations/incident-history.md](../10-operations/incident-history.md).

Similarly, a Grafana plugin rebuild (`build-plugin.sh`) is not part of the
normal app deploy path — it runs once during fresh-host bootstrap
(`scripts/bootstrap/06a_build_grafana_live_plugin.sh`) and otherwise
requires a manual re-run + Grafana restart if the plugin's source changes.

## New background jobs ship disabled

Per the DDS implementation roadmap's production-safety rules: every new
TimescaleDB job starts `scheduled=false` and is enabled only after staging
validation, as its own explicit step — never bundled into the migration
that creates it.

## What is unverified

Whether `deploy-production.yml` or `rollback.yml` have been executed
against a real host beyond the specific runs cited in
[ci-cd.md](ci-cd.md) and [../10-operations/incident-history.md](../10-operations/incident-history.md).
