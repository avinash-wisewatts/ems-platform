# 21. Backup & Recovery

```
Status: PARTIAL — mostly UNKNOWN / NOT IMPLEMENTED
Last verified: 2026-08-24
Verification basis: Repository
```

## 21.1 What's actually implemented

TimescaleDB's persisted data lives in a bind-mounted host directory, not a Docker-managed volume:

```yaml
volumes:
  - ${TIMESCALEDB_DATA_PATH:-./postgres/data/pgdata}:/var/lib/postgresql/data
```

(`compose.yaml`, `timescaledb` service). This means the data directory survives `docker compose down` and container recreation as long as the host path isn't deleted — but this is a side effect of the bind-mount choice, not a designed backup mechanism.

**No backup automation was found in the repository**: no `pg_dump`/`pg_basebackup` script, no WAL-archiving configuration, no scheduled snapshot job, no off-host replication config, under `postgres/`, `scripts/`, or `compose.yaml`. `postgres/maintenance/` contains three one-off data-repair scripts (`39_load_normalized_points.sql`, `45_rebuild_normalized_history.sql`, `49_remove_legacy_energy_test_row.sql`) — these are corrective/historical, not backup tooling.

## 21.2 What this means

**STATUS: UNKNOWN / NOT IMPLEMENTED.** Do not assume standard backup practices (automated dumps, point-in-time recovery, off-site replication) exist for either staging or production based on this repository. If such a mechanism exists, it is either:
- managed entirely outside this repository (e.g. host-level snapshotting, cloud-provider volume snapshots, a separately-managed cron job not checked into version control), or
- genuinely absent.

This manual cannot distinguish between those two possibilities from repository evidence alone, and no infrastructure access (SSH, host filesystem, cloud console) was available to check directly. **This should be confirmed with whoever manages the production/staging hosts before relying on any recovery assumption.**

## 21.3 TimescaleDB-specific recovery considerations (for whenever a mechanism is designed)

These are documented as *considerations*, not as evidence that anything below is implemented:

- **Hypertables** (`telemetry.energy_measurements`, `telemetry.normalized_points`, `analytics.energy_consumption_{1min,5min,15min,hourly,daily}`, and others — see [05-database.md](05-database.md)) are chunked by time. A restore strategy needs to account for chunk boundaries, not just table-level dumps.
- **Continuous aggregates** (`telemetry.ca_energy_*`, `analytics.generic_telemetry_{15m,1h}` — see [11-aggregation.md](11-aggregation.md)) are materialized views backed by `_timescaledb_internal` hypertables. A raw-table restore does not automatically repopulate these; they need to either be restored from their own materialization or refreshed from source after a raw-table restore.
- **TimescaleDB background jobs** (e.g. `analytics.run_energy_consumption_5min_job`, registered via `timescaledb_information.jobs`) run inside the database itself. A restore that loses job scheduler state would need those jobs re-verified as active/scheduled — see `postgres/ddl/143_persisted_validated_energy_consumption_5min.sql` for the registration pattern used.

## 21.4 Recommended next action

Before this environment is treated as production-grade, someone with infrastructure access should document (in this file, replacing this section): the actual backup mechanism if one exists, its schedule, its retention, and a tested restore procedure. Until then, treat data loss on either environment as **unrecoverable** for planning purposes.
