# 10 — Operations

Status: CURRENT · Last reviewed: 2026-08-30 · Owner: Engineering

Canonical source for **how the platform is operated day to day.**
Consolidated from platform manual chapters 19, 21, 23, 24, 25 (archived).

| Document | Purpose |
|---|---|
| [monitoring.md](monitoring.md) | Read-only diagnostic queries and the `analytics.v_pipeline_health` operator surface. |
| [backups-and-recovery.md](backups-and-recovery.md) | Backup/recovery posture — mostly unestablished, documented honestly. |
| [troubleshooting.md](troubleshooting.md) | Symptom → likely cause → diagnostic steps → what NOT to do, built from real incidents. |
| [incident-history.md](incident-history.md) | The detailed record of real incidents: root cause, fix, and verification evidence. |
| [deadlock-normalization-raw-receipt-state.md](deadlock-normalization-raw-receipt-state.md) | Job 1000 vs raw-receipt-state job `40P01` deadlocks on `device_telemetry_state`: cause, migration 301 fix, checks, rollback. |
| [staging-production-parity-2026-10-22.md](staging-production-parity-2026-10-22.md) | Read-only staging–production parity audit after Release C1, with the R0 resolution of U1–U5 (CR-only Energy bodies, view column drift, staging duplicates, ledger default, time zone). |

## Design principle

Every diagnostic command in this directory is **read-only**. None mutate
metadata, telemetry, or configuration. If a diagnostic surfaces something
that needs fixing, that is a separate, deliberate, approved change — never
a diagnostic-script side effect.
