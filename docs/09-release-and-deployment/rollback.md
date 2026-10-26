# Rollback

Status: CURRENT · Last reviewed: 2026-08-30 · Owner: Engineering

## Application rollback — implemented

`.github/workflows/rollback.yml` redeploys an older, previously-pushed
image tag via the identical deploy path (`deploy_release.sh`). The EMS Web
Application specifically is designed to be independently rollbackable
without affecting the Administration App, Grafana, the database, or the
energy subsystem — see
[../00-governance/decisions/ADR-006-ems-web-app-vs-admin-portal.md](../00-governance/decisions/ADR-006-ems-web-app-vs-admin-portal.md).

**EMS Web App container (on staging since 2026-10-26; rollback/roll-forward
verified).** Rolling the `ems-web` container back is the same operation as
deploying it: dispatch `.github/workflows/deploy-web.yml` (staging only)
with the previous `-web` Git SHA, or on the host run
`EMS_WEB_IMAGE=<previous ref@digest> PROJECT_PATH=<path> ENVIRONMENT_NAME=staging scripts/release/deploy_web.sh`.
Only `ems-web` is recreated; no migration, no `admin-portal` restart. The
previous reference is printed by the script and recorded in
`<PROJECT_PATH>/.deploy-history/<env>-web-container.log`. An unhealthy new
image is replaced by the previously running one automatically. Reverting
from container mode to the bind-mounted bundle is a host `.env` change
(unset `EMS_WEB_UPSTREAM`) plus an `admin-portal` recreate with `APP_IMAGE`
pinned to its running image (the root `.env` has no `APP_IMAGE`; a bare
`docker compose up` would resolve `ems-platform-prod-app:local`) — see
[../operations/PHASE8_FRONTEND_DEPLOYMENT.md](../operations/PHASE8_FRONTEND_DEPLOYMENT.md).

A rollback declares `expected_migrations` (normally `none`) and passes the
same pending-migration precheck as a production release before anything
changes: the target commit's runner may not apply any migration other than
the declared ones, and never a staging-only one
([ci-cd.md](ci-cd.md#environment-scoped-migrations)).

## Database rollback — deliberately not implemented

The migration system (`scripts/apply_migrations.sh`) is **forward-only,
checksum-verified, with no reverse-migration mechanism.** Undoing a
migration requires writing a new forward migration that reverses its
effect, or a database restore. This is a stated, deliberate choice — an
incorrect reverse migration is considered more dangerous than no rollback
mechanism, not an oversight.

## Backup/recovery — status largely unknown

See [../10-operations/backups-and-recovery.md](../10-operations/backups-and-recovery.md).
No backup automation was found in the repository as of the last
verification pass; treat data loss on either environment as
**unrecoverable** for planning purposes until this is independently
confirmed with whoever manages the hosts.
