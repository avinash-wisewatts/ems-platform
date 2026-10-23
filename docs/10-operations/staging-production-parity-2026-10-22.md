# Staging–production parity audit (2026-10-22)

Status: CURRENT · Prepared: 2026-10-22 · Owner: Engineering

A read-only comparison of staging and production after Release C1, followed by
R0, a read-only catalog inspection that resolved the five unexplained findings
(U1–U5). **Nothing was changed** on either environment. Every production
session was separately approved and ran `default_transaction_read_only=on`
inside a `READ ONLY` transaction ending in `ROLLBACK` (30 s statement / 2 s
lock timeouts), as `ems_admin@ems` via `docker exec ems-timescaledb psql`.

Labels: **[V]** verified by query or repository evidence on 2026-10-22,
**[H]** hypothesis, **[Q]** unresolved.

## 1. Baseline

| | Staging | Production |
|---|---|---|
| Deployed commit | `8490e48` (docs-only on top of `e844e2a`, migration 306) | `105c6c1` (Release C1, run `39726655853`) |
| App image | `ems-platform-app:8490e48…@sha256:04bc0246…` | `ems-platform-app:105c6c1…@sha256:eee59511…` |
| Ledger | 178 rows, head 306, all `applied` | 164 rows (digest `0591dde9…`), head 291; 139 `applied` + 25 `baseline` |
| Ledger vs repository | 0 checksum mismatches | 0 checksum mismatches |
| Staging-only migrations | 292–295, 297–306 | — |
| PostgreSQL / TimescaleDB | 16.15 / **2.29.2** | 16.15 / **2.28.2** (same image digest `289d5570…`) |
| Server `timezone` | Asia/Kolkata (`postgresql.conf`) | Asia/Kolkata (`postgresql.conf`) |

All [V].

## 2. Differences and classification

**Job IDs differ between the environments.** Example: the demand reconciler
is staging **1121** and production **1119**; production 1121 is a compression
policy. Migrations 298–306 find jobs by `proc_name` [V]. Compare jobs by
procedure, never by ID.

| Area | Difference | Class |
|---|---|---|
| Schema from 292–306 | Point series, recovery queue, late sweep, 299 policy column, 301 lock order, 302/304/306 functions | Expected (staged promotion) |
| CAgg views and policy configs | Internal `_materialized_hypertable_N` / `hypertable_id` values | Expected |
| Job schedules | Staging: 5-minute batch (300) on 1000/1001/1012, the 1-minute CAgg refreshes and the 1-minute tier; demand every 15 min (298). Production: 1 minute | Expected (C2′ / D) |
| Production-only pauses | 1053; reconcilers 1114–1120 (demand reconciler 1119 since 2026-10-17); dew point 1123/1124 | Decision (production-only state, preserve) |
| Routing `max_runtime` | Staging 5 min; production 30 min | Decision D7 |
| Staging-only jobs | 1127 alert evaluation; 1142 late sweep (303) | Decision / expected |
| Staging hand tuning | 1068 `max_window 60 minutes`; 1077 `limit 1000`. Production uses the repository defaults | Decision |
| TimescaleDB | 2.29.2 vs 2.28.2 | Decision |
| `ems_investigator` role | Staging only | Expected |
| Staging working tree | Uncommitted edit of `scripts/verify/smoke_mqtt_energy.sh` (+46/−4) and `.bak` files from 2026-09-15 | Decision |
| Production working tree | Untracked `grafana/org1_fix.sql`, `scripts/safe_production_backup.sh`, backup files | Preserve |
| Env keys | Production root `.env` adds `ENVIRONMENT PGDATA PGTZ TIMESCALEDB_DATA_PATH TZ` (+ password); staging `grafana/.env` adds `GF_SECURITY_ALLOW_EMBEDDING`, `GF_SERVER_ROOT_URL` | Expected (preserve) |
| Frontend | Staging serves the Web SPA; production is API-only | Decision D6 |
| DB counters | Production `deadlocks` = 18 (cumulative) | Known 40P01, fixed by 301 (Release D) |

## 3. R0: resolution of U1–U5

| # | Finding | Evidence | Risk | Disposition |
|---|---|---|---|---|
| **U1** Energy functions | Staging's `analytics.refresh_energy_consumption_1min`, `refresh_energy_consumption_5min` and `run_energy_consumption_hourly_job` are the repository bodies of migrations 216 / 217 **with carriage returns added**. With CR removed they are byte-identical to production, which holds the exact repository bodies [V]. CRs are only in line endings and comments: 0 inside string literals, no dynamic SQL [V]. Staging's ledger records 216 at 2026-08-28 11:59 and 217 at 2026-08-29 08:35 UTC, before both first reached `staging` in `e0c1f97` (2026-08-29 20:53 UTC), so they reached staging outside the deploy pipeline [V]. The ledger checksums equal the LF files [V]. Loading them from a Windows CRLF working copy is consistent with the evidence [H]; the exact mechanism is not recorded [Q] | prosrc md5 with CR removed: 5min `87d2652f…`, hourly `672ed129…`, 1min `25aabb53…` on both. Production has 0 routines containing CR; staging has exactly these 3, which are the routines last defined by 216/217 | None at runtime. Any `md5(prosrc)` comparison or migration precondition on these routines must remove CR first (267, 270, 291, 297, 301, 303, 305 and 306 already do) | Accept. **Do not hot-patch.** The CRs disappear when a migration next replaces these functions |
| **U2** Views | Production's `analytics.v_energy_latest` (75 columns) and `v_energy_raw` (73) lack `current_thd_total_percent` and `pulse_count`; definitions are otherwise identical [V]. `ddl/55` defines both views with `em.*`, which expands once, at creation. Staging's `energy_measurements` was created by `ddl/08` with those columns inline. On production they were added later by `ADD COLUMN` (they follow `raw_archive_id`), after the views existed [V] | View definition diff; column positions of `telemetry.energy_measurements` | Low. Only dependent object: `v_asset_energy_latest` (same on both, does not use them). No repository Grafana/app/web consumer [V]. Dashboards stored only in the Grafana database not checked [Q] | Accept. Adding them means dropping and recreating both views and `v_asset_energy_latest` (columns cannot be inserted mid-list); only if a consumer needs them |
| **U3** Legacy schema | Production is **not** missing these guards: staging has **duplicates** [V]. `device_identifiers_device_id_fkey` = production's `fk_device_identifier_device`; `assets_metering_requirement_check` = `assets_metering_requirement_ck`; `idx_raw_messages_received_at` (ASC) duplicates `raw_messages_received_at_idx` (DESC). Sources: inline `REFERENCES` in canonical `ddl/04_01` plus archived migration 33; archived 98/121; canonical `ddl/41` [V]. Staging replaying both canonical DDL and historical migrations explains the duplicates [H] | Full constraint and index listings on both | None for production. Staging pays a small write cost (extra index on `raw_messages`, double FK check) | No production change. Optionally drop the three duplicates on staging (a write; separate approval) |
| **U4** Ledger | Only difference: production's `admin.schema_migrations.application_mode` has `DEFAULT 'applied'`; staging has no default. Columns, constraints, indexes, comments and owner are otherwise identical [V]. No commit on any branch contains that default; canonical `ddl/01_01` has none [V]. How it was added is unknown [Q] | `pg_attribute` / `pg_attrdef` / `pg_constraint` / `pg_indexes` on both | None. `scripts/apply_migrations.sh` always writes `'applied'` or `'baseline'` explicitly | Accept as production-only drift. **Do not change production's default** |
| **U5** Timezone | **Server `timezone` and `log_timezone` are Asia/Kolkata on both** (`postgresql.conf` lines 722 / 608; boot value GMT); no database or role overrides [V]. Staging sessions inherit it. Production sessions get the same value from the client, because the timescaledb container sets `TZ`/`PGTZ=Asia/Kolkata`. App containers have no `TZ`/`PGTZ` and the app sets no session time zone, so app sessions and background jobs run in Asia/Kolkata on both [V]. Host / OS: production host IST, production Telegraf `TZ=Asia/Kolkata`; staging host and containers UTC [V] | `pg_settings`, `pg_file_settings`, `pg_db_role_setting`, container `printenv TZ PGTZ` | Low for SQL (same on both). Host scripts, cron and logs differ. Telegraf time parsing only if timestamps lack an offset [H] | Parity at the database level. Keep testing SQL in Asia/Kolkata and UTC sessions |

Corrections to the first audit pass: staging's database time zone is
Asia/Kolkata, not UTC as first assumed; `refresh_energy_consumption_1min`
differs only by CR and was not changed by migration 304.

## 4. Read-only queries used

Scripts were kept outside the repository (session scratchpad):
`parity_inventory.sql` (catalog inventory), `r0_inspect.sql` (U1–U5
definitions and settings), `r0_cr.sql` (routines/views containing `chr(13)`),
and `SELECT md5(replace(prosrc, chr(13), ''))` for the 1-minute refresh. Host:
`git rev-parse HEAD`, `git status --short`, `docker ps/inspect/images`,
env-file key names only, `docker exec <c> printenv TZ PGTZ`, `df`, `free`,
`/proc/pressure/io`.

## 5. Open decisions (each needs its own approval)

Release D scope (299–303 at `bc6346b`, then 304–306, or one release at
`e844e2a`); PR #140 merge; production paused jobs (1053, 1114–1120,
1123/1124); D7 routing `max_runtime`; alert evaluation job on production;
1068 / 1077 tuning (adopt or revert, then record in a migration); TimescaleDB
2.28.2 → 2.29.2 on production (maintenance window; restore-only rollback);
optional removal of staging duplicates (U3); staging smoke-script edit; D6
production frontend.
