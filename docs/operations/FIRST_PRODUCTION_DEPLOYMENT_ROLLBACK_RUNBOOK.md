# First Production Deployment -- Manual Rollback Runbook

## 1. Purpose

This document is the manual recovery procedure for the **first** production
application deployment performed through `deploy-production.yml` /
`scripts/release/deploy_release.sh`.

It exists specifically because `.deploy-history/production.log` does not yet
exist on production. Every deployment after this one appends an entry to
that file (git SHA, image reference, timestamp), which `rollback.yml` can
target directly. The first deployment has no such prior entry to fall back
to -- this runbook is the substitute until one exists.

This is a **manual, human-executed** procedure. Nothing in this document is
automated, and nothing here should be run except by a human operator who has
read and understood it, during an active, human-watched first deployment.

## 2. What Must Not Be Touched

Under no circumstances does recovery from a failed first application
deployment involve:

- **TimescaleDB** (`ems-timescaledb`) -- must not be stopped, restarted,
  recreated, or have its volume/mount configuration changed.
- **Telegraf** (`ems-telegraf`) -- must not be stopped, restarted, or
  recreated.
- **Grafana** (`ems-grafana`) -- must not be stopped, restarted, or
  recreated.
- **TimescaleDB persistent storage** -- the bind mount at
  `${TIMESCALEDB_DATA_PATH}` (production: `./postgres/data`, resolving to
  `/opt/ems-platform/postgres/data/pgdata` on disk) must not be moved,
  deleted, or repointed.

`deploy_release.sh` itself never names any of these three services in any
`docker compose` invocation, and this runbook does not either. Recovery is
scoped exclusively to `admin-portal` and `live-telemetry`.

## 3. Current First-Deployment Baseline

The following was directly verified on production (Phase 1 and reconfirmed
in later phases) before any deployment was ever attempted:

| Service | Image | Image ID |
|---|---|---|
| `admin-portal` | `ems-platform-prod-admin-portal:latest` | `120b75297b75` |
| `live-telemetry` | `ems-platform-prod-live-telemetry:latest` | `dd8ab063ac1f` |

Both images were confirmed still present in production's local Docker image
cache (`docker images`) as of the Phase 7/9 audits -- not pruned, not
overwritten.

**These are locally-built, pre-pipeline images.** They were never pushed to
GHCR and have no immutable SHA tag or `.deploy-history` entry of their own.
They are the *only* known-good prior state to fall back to for the first
deployment.

## 4. Database Safety Baseline

A verified, valid production database backup exists from Phase 2:

- Path: `/opt/ems-platform/postgres/backups/prod_snapshot_2026-08-22.dump`
- Format: PostgreSQL custom format (`pg_dump -Fc`)
- Size: approximately 1.27 GiB (1,335,358,520 bytes)
- Integrity: independently verified via `pg_restore --list` -- exit code 0,
  2696 TOC entries, valid archive header

**Restoring this backup is a last-resort action, not the normal response to
an application-container health-check failure.** A failed health check on
`admin-portal`/`live-telemetry` means the *application container* did not
come up healthy -- it does not by itself mean the database was damaged.
Reach for this backup only if there is specific evidence of data corruption
or an unsafe migration outcome (see Section 6), not simply because the new
application containers are unhealthy.

## 5. Application Rollback

If the newly deployed `admin-portal`/`live-telemetry` containers fail their
health checks, the practical recovery is **not** a single command. This is
important and must not be assumed away.

Production's current `compose.yaml` declares both services with a single
shared variable:

```yaml
image: ${APP_IMAGE:-ems-platform-prod-app:local}
```

Both services resolve to whatever one `APP_IMAGE` value is set at deploy
time. The two *old* images being rolled back to, however, have two
**different** names (`ems-platform-prod-admin-portal:latest` and
`ems-platform-prod-live-telemetry:latest`). Setting `APP_IMAGE=<old-image>`
once and running `compose up` **cannot** restore both services
simultaneously -- there is no single value of `APP_IMAGE` that is correct
for both.

Recovery therefore requires one of:

- **Temporarily editing `compose.yaml`** to point each service's `image:`
  field at its own old image (`ems-platform-prod-admin-portal:latest` for
  `admin-portal`, `ems-platform-prod-live-telemetry:latest` for
  `live-telemetry`) instead of the shared `${APP_IMAGE}` variable, then
  running a service-scoped `docker compose up -d --no-build admin-portal
  live-telemetry`, then reverting `compose.yaml` back once stable; or
- **Manually recreating each container with `docker run`**, reconstructing
  its port mappings, environment (`env_file` entries), and network
  attachment from the current `compose.yaml` and this audit's records,
  bypassing `docker compose` entirely for the recovery step.

Either path requires deliberate, careful, manual work by the operator -- it
is not a one-liner, and must not be treated as one under pressure.

## 6. Migration Warning

**Critical condition:** if the failed deployment's database migrations
*succeeded* before the new application containers failed their health
checks, restoring the old application containers (Section 5) is not
automatically safe.

- Migrations in this system are forward-only, checksum-verified, and applied
  transactionally via `scripts/apply_migrations.sh` (`docker compose exec`
  into the already-running `timescaledb` container -- it is never restarted
  or recreated by this process).
- The *old* application binary was built and tested against the schema as
  it existed *before* this deployment's migrations ran. Whether it remains
  compatible with the *new* schema state is not something this audit has
  proven, migration-by-migration, for every past migration in this
  repository.
- Therefore: **application rollback is not equivalent to database
  rollback.** Before restoring the old application containers after a
  migration has already succeeded, the operator must assess whether the
  newly-applied migration(s) are additive/backward-compatible (new columns,
  new tables, new views -- generally safe) or destructive/renaming
  (generally unsafe for old code).
- If there is doubt, treat the database backup (Section 4) as the
  last-resort recovery path rather than assuming the old application
  binary will work correctly against the new schema.

## 7. Human-Watched First Deployment

The first production deployment must be **actively monitored end-to-end by
the operator**, from workflow dispatch through post-deployment
verification. It must not be started and left unattended ("fire-and-forget").

The operator must be prepared, in real time, to:

- Recognize a failed health check as it happens (the deployment workflow
  itself will report this).
- Immediately begin the manual recovery procedure in this document rather
  than re-dispatching or attempting an unplanned fix.
- Stop and escalate rather than improvise if the situation deviates from
  what this runbook describes.

## 8. Success Criteria

Recovery (or a successful first deployment) is only considered complete
once **all** of the following are verified, not assumed:

- `admin-portal` and `live-telemetry` are running and passing their Docker
  healthchecks.
- `ems-timescaledb` is healthy, with its container ID and `StartedAt`
  timestamp unchanged from before the deployment began.
- `ems-telegraf` is running, unchanged.
- `ems-grafana` is healthy, unchanged.
- The database is accessible (`SELECT 1` succeeds against `ems`).
- No unexpected restart or recreation of `ems-timescaledb`, `ems-telegraf`,
  or `ems-grafana` occurred at any point (verify via `docker inspect`
  container ID / `StartedAt` before-and-after comparison).

Recovery must not be reported or assumed successful based on the
application layer alone -- the three protected services must be positively
reconfirmed unchanged every time.

## Release Pairing Convention (applies to every dispatch, not just the first)

Production may only be dispatched with an `image_tag` / `release_git_sha`
pair that corresponds to a **known, successful staging release**, as
recorded in `.deploy-history/staging.log` on the staging host. Before
dispatching `deploy-production.yml`, the operator must:

1. Confirm the intended release's entry exists in
   `.deploy-history/staging.log` (format:
   `timestamp|environment|git_sha|image`).
2. Confirm `release_git_sha` exactly matches that entry's `git_sha` field.
3. Confirm `image_tag` exactly matches that entry's `image` field (a
   GHCR reference tagged with that same git SHA).
4. Copy both values exactly into the `workflow_dispatch` form -- do not
   retype or reconstruct them from memory.

This is currently a **procedural** control, not one enforced by the
workflow itself. There is no automated cross-check between `image_tag` and
`release_git_sha` in `deploy-production.yml` as of this writing.
