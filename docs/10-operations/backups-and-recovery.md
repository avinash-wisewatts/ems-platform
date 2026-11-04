# Backup and Recovery

Status: PARTIAL — mostly UNKNOWN / NOT IMPLEMENTED · Last reviewed: 2026-11-04
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

## Production manual backup (host script, not in this repository)

Production has an operator-run script, `/opt/ems-platform/scripts/safe_production_backup.sh`
(untracked on the host, sha256 `61e6c01d…`, unchanged since 2026-08-20): a
read-only `pg_dump -Fc` of the `ems` database in one consistent snapshot,
streamed to `/opt/ems-platform/postgres/backups/` (the preferred
`/home/ubuntu/db_backups` is not writable by `emsadmin`), `chmod 600`, then
`pg_restore --list`. It refuses to start unless free disk space at the
destination is at least the live database size.

| Dump | Size | Notes |
|---|---|---|
| `prod_snapshot_2026-08-20.dump`, `-08-22`, `-08-29` | 1.08 / 1.34 / 1.77 GB | |
| `prod_snapshot_20261023T0814Z.dump` | 7.18 GB | 51 min; `.sha256`, `.done`, `.err` sidecars written by hand; `pg_restore --list` 6,955 entries. **The only recent backup.** |
| 2026-11-04 attempt | — | **Refused** by the guard: database 36 GiB, free 29 GiB. No file written. |

No dump has ever been restore-tested, and every dump is on the same disk as
the database (no off-host copy).

## Proposed one-time guard change (not approved)

Status: **proposal, needs review and explicit approval; the production script
is unchanged.** The proposed revision (tested against the disposable test
database) changes only what the guard compares and adds protection around it:

- **Guard:** free space ≥ expected compressed dump (35 % of
  `pg_database_size`; observed ~21–23 %) **+ a 10 GiB reserve** that must stay
  free afterwards. Production on 2026-11-04: 36 GiB × 35 % ≈ 12.6 GiB + 10 GiB
  = 22.6 GiB required ≤ 29 GiB free → proceeds; ~21 GiB free afterwards
  (dump ~8–9 GB expected).
- **Watchdog:** free space is checked every 15 s during the dump; below the
  reserve the dump is stopped, so a wrong estimate cannot fill the database's
  disk.
- **Failure handling:** a failed, interrupted or stopped dump removes only the
  file this run created, never an existing backup, and exits non-zero.
- **Protection and integrity:** `umask 077` (owner-only from the first byte,
  not only after the dump); sha256 sidecar; `pg_restore --list` entry count
  (must be > 0); `.done` marker with start, end and rc.
- **Unchanged:** container check, directory choice, no overwrite, single
  `pg_dump -Fc` snapshot, read-only against the database.

Tests (local, 2026-11-04): normal run (dump, sha256, 2,646 TOC entries,
`.done`); guard refusal (no file); watchdog stop next to an existing backup
(new file removed, existing backup byte-identical, no `pg_dump` left
running); `pg_dump` failure (new file removed).

### Revision v2 (2026-11-04, not approved)

v2 (sha256 `245213eae1b53a730f2500ee06782e8d95f8b9e36a4d6a45093c0e7e5ca84d92`)
adds to the above: a **mandatory 5 GiB reserve floor** (`RESERVE_BYTES` below
it, or non-numeric, is refused); `--detach`, which re-runs the script under
`setsid nohup` with an owner-only log (the production invocation); and a
documented side effect: the watchdog's `pkill -TERM -x pg_dump` stops
**every** pg_dump in the container, so only one backup may run at a time.

Evidence:
- Linux harness (Alpine, PostgreSQL 16, tmpfs, real permissions), 20/20:
  normal run (dump, `.sha256`, `.done` all `600`, sha256 verifies), floor and
  non-numeric refusals, guard refusal, watchdog stop with an existing backup
  byte-identical and no pg_dump left, pg_dump failure cleanup, `--detach` in
  its own session completing after SIGHUP with a `600` log.
- Real Docker (Windows host, `timescale/timescaledb:latest-pg16`, BusyBox
  v1.37.0 and pg_dump 16.15 as on production): normal run (2,553 TOC
  entries, sha256 OK), floor refusal; the watchdog's exact stop command
  (`docker exec <container> pkill -TERM -x pg_dump`) terminated a blocked
  pg_dump ("terminated by user"), left none running, and the client exited 1.
- Production host, read-only (2026-11-04): `setsid`, `nohup`, `numfmt`,
  GNU `df`, `sha256sum`, `pkill`, Docker 29.8.0 present; container BusyBox
  `pkill` with `-x`, pg_dump 16.15; backup directory writable by `emsadmin`
  (the preferred `/home/ubuntu/db_backups` is not); free 28.2 GiB; database
  36 GiB -> required 12.6 + 10 = 22.6 GiB: the guard would proceed, leaving
  ~19-20 GiB after an ~8-9 GB dump.

### Installation and execution plan (each phase needs its own approval)

**Phase 1 — install and validate (no dump).**
1. Copy the reviewed file to `/tmp/safe_production_backup.v2.sh` on the
   host; `sha256sum` must equal `245213ea...`; `bash -n` passes.
2. Preserve the current script:
   `cp -p scripts/safe_production_backup.sh scripts/safe_production_backup.sh.bak-20261104`;
   its sha256 must stay `61e6c01d...`.
3. Install: `install -m 0755 /tmp/safe_production_backup.v2.sh scripts/safe_production_backup.sh`;
   sha256 must equal `245213ea...`.
4. Validate without dumping (each exits before any file is written):
   `./scripts/safe_production_backup.sh --bogus` (rc 2);
   `RESERVE_BYTES=1 ./scripts/safe_production_backup.sh` (floor refusal);
   `RESERVE_BYTES=$((1024**5)) ./scripts/safe_production_backup.sh` (guard
   refusal; proves the container check, size query, `df` and arithmetic on
   the real host). Confirm no new file in `postgres/backups/`.
5. Recovery at any point: `cp -p scripts/safe_production_backup.sh.bak-20261104 scripts/safe_production_backup.sh`
   and confirm sha256 `61e6c01d...`.

**Phase 2 — run the backup (separate approval).**
6. Preconditions (read-only): free space as above, no pg_dump running in the
   container (`pgrep -x pg_dump`), a weekday window clear of 05:13 / 17:13 /
   23:00 UTC (e.g. 07:30 UTC), no other operator backup.
7. `cd /opt/ems-platform && ./scripts/safe_production_backup.sh --detach`;
   record the PID and log path.
8. Monitor read-only every ~10 min: `tail` the log, `df`, `pgrep -x pg_dump`.
   Expected ~50-60 min.
9. Verify: `.done` shows `rc=0` and `toc_entries` close to the 2026-10-23
   6,955; `sha256sum -c <dump>.sha256`; the dump, `.sha256`, `.done` and log
   are `-rw-------`; free space >= 10 GiB. A restore test is a separate
   decision.
10. On failure the script removes only its own file; existing backups are
    untouched; report the log.

**Disk trend.** The database grew from ~31.5 GB (2026-10-25) to 36 GiB
(2026-11-04), so even the revised guard leaves little margin within weeks.
Retiring old dumps or the pending storage-cleanup steps, and an off-host copy,
are separate decisions.

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
