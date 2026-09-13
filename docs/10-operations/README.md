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

## Design principle

Every diagnostic command in this directory is **read-only**. None mutate
metadata, telemetry, or configuration. If a diagnostic surfaces something
that needs fixing, that is a separate, deliberate, approved change — never
a diagnostic-script side effect.
