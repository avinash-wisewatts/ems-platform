# Backup and Recovery

Status: PARTIAL — mostly UNKNOWN / NOT IMPLEMENTED · Last reviewed: 2026-08-24
Verification basis: Repository

## What's actually implemented

TimescaleDB's persisted data lives in a bind-mounted host directory, not a
Docker-managed volume (`${TIMESCALEDB_DATA_PATH:-./postgres/data/pgdata}:/var/lib/postgresql/data`)
— data survives `docker compose down` and container recreation as long as
the host path isn't deleted. **This is a side effect of the bind-mount
choice, not a designed backup mechanism.**

**No backup automation was found in the repository**: no `pg_dump`/
`pg_basebackup` script, no WAL-archiving configuration, no scheduled
snapshot job, no off-host replication config. `postgres/maintenance/`
contains one-off data-repair scripts, not backup tooling.

## What this means

**STATUS: UNKNOWN / NOT IMPLEMENTED.** Do not assume standard backup
practices (automated dumps, point-in-time recovery, off-site replication)
exist for either staging or production based on this repository. If a
mechanism exists, it is either managed entirely outside this repository
(host-level snapshotting, cloud-provider volume snapshots, an unversioned
cron job) or genuinely absent — this cannot be distinguished from
repository evidence alone. **This should be confirmed with whoever manages
the production/staging hosts before relying on any recovery assumption.**

## TimescaleDB-specific recovery considerations (for whenever a mechanism is designed)

Documented as considerations, not as evidence anything below is
implemented:

- **Hypertables** are chunked by time — a restore strategy needs chunk
  boundaries, not just table-level dumps.
- **Continuous aggregates** are materialized views backed by
  `_timescaledb_internal` hypertables. A raw-table restore does not
  automatically repopulate these.
- **TimescaleDB background jobs** run inside the database itself — a
  restore that loses scheduler state needs those jobs re-verified as
  active/scheduled.

## Recommended next action

Before this environment is treated as production-grade: document the
actual backup mechanism if one exists, its schedule, its retention, and a
tested restore procedure. Until then, treat data loss on either
environment as **unrecoverable** for planning purposes.
