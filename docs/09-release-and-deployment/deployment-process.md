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

Migrations run with `DEPLOY_ENVIRONMENT=${ENVIRONMENT_NAME}`, so staging-only
migrations (`postgres/migration_environment_scope.csv`) are skipped on
production; production releases first pass the pending-migration precheck
(`expected_migrations`). See [ci-cd.md](ci-cd.md#environment-scoped-migrations).

**Next production release: migrations 311, 315, 316 and 317.** 315 (user-management
hardening) is not staging-only, because it closes a cross-tenant scope move
that exists on production today. 316 and 317 remove `ems_readonly`'s EXECUTE on
every `admin` function and all its access to `admin.portal_users`, grants only
production has. From production head 308, the release must declare
`expected_migrations=311,315,316,317`; the precheck refuses any subset.
Checklist and blockers:
[production-release-311-315-316-317.md](production-release-311-315-316-317.md).

- **Before the release:** re-run
  `scripts/verify/portal_user_scope_exposure.sql` (read-only). Until then, no
  ORGANIZATION or SELECTED_SITES ADMIN may be created on production
  ([../10-operations/portal-user-provisioning.md](../10-operations/portal-user-provisioning.md)).
- **After the release (read-only):** expect 311, 315, 316 and 317 ledger rows;
  the three new `admin.*` functions are SECURITY DEFINER with EXECUTE for
  `ems_app` only; `ems_readonly` executes no `admin` function except the
  PUBLIC one and cannot read `admin.portal_users`.

315 has no dependency on 309–314: a production-mode apply to a scratch
database (canonical deploy, then `DEPLOY_ENVIRONMENT=production`) applied
311 and 315 and skipped 309, 310 and 312–314.

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
