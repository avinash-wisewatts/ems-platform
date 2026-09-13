# Rollback

Status: CURRENT · Last reviewed: 2026-08-30 · Owner: Engineering

## Application rollback — implemented

`.github/workflows/rollback.yml` redeploys an older, previously-pushed
image tag via the identical deploy path (`deploy_release.sh`). The EMS Web
Application specifically is designed to be independently rollbackable
without affecting the Administration App, Grafana, the database, or the
energy subsystem — see
[../00-governance/decisions/ADR-006-ems-web-app-vs-admin-portal.md](../00-governance/decisions/ADR-006-ems-web-app-vs-admin-portal.md).

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
