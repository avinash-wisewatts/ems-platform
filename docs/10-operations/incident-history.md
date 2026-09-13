# Incident History

Status: HISTORICAL narrative, kept current for recent entries · Last reviewed: 2026-08-30
Verification basis: Audit evidence, Repository, Staging, Production (read-only)

This is a record of real incidents: root cause, fix, and verification
evidence. For the current open/closed status of any item mentioned here,
check [../06-platform/](../06-platform/) and
[troubleshooting.md](troubleshooting.md) — this page is the story, not the
live status.

## Job 1077 / Job 1000 recovery-pipeline failure chain (2026-08-26/27)

**Problem 1 — job 1077's supersession search was effectively unbounded.**
The "is this raw message already superseded?" check joined through
`telemetry.v_rtdata` before any time-window filter could apply, letting the
planner build an unbounded Hash Anti Join — one real candidate measured
~467K rows / ~46.7M JSON-expanded elements / ~701M hash-side rows,
explaining the job's consistent 10-minute timeout. **Fixed** across
migrations 201–204 (bounded window, narrowly-scoped lookup function,
per-candidate commit, targeted existence check). Result: the same
candidate dropped from a multi-minute scan to 1562.5ms.

**Problem 2 — job 1000 stalled for ~15 hours, unrelated to job 1077.**
`telemetry.load_normalized_points_incremental()` always computed its
forward boundary as "catch up to right now" in one uncommitted transaction.
Once the gap exceeded the job's 5-minute `max_runtime`, every retry faced
an equal-or-wider window with zero possible durable progress. **Fixed**:
migration 205 added an optional `p_max_window INTERVAL` parameter enabling
bounded catch-up. Staging recovery: 32 sequential 30-minute bounded calls
fully drained the ~15-hour backlog.

**Problem 3 — job 1077's candidate population was inflated by a stale
existence probe.** The retention-drop job only runs once/day, so a
candidate already past the 48-hour retention window could still "physically
exist" for up to ~24h, during which job 1077 kept re-running expensive
supersession logic against it. **Fixed**: migration 206 replaced the
existence probe with an age comparison against the retention cutoff, read
dynamically from `timescaledb_information.jobs`.

All three: **resolved and live-verified on staging as of 2026-08-27.**

### Downstream blast radius (partially open)

Job 1000's stall cascaded into two further layers that don't self-heal:
`analytics.demand_intervals` finalizes each 15-minute bucket once,
permanently (`ON CONFLICT DO NOTHING`) — 1,320 stale rows were repaired via
a targeted `UPDATE` reusing the existing calculation function.
`analytics.energy_consumption_1min` uses a fixed 30-minute lookback that
can never look back far enough — 19,455 rows backfilled via the existing
refresh function. The **architectural gap itself** (neither job could
recover unattended from a future multi-hour outage) remained open until the
watermark-driven redesign below.

## Self-healing pipeline redesign (migrations 207–214, 2026-08-27)

A full design for a self-healing analytical pipeline (child watermark +
bounded catch-up + bounded reconciliation) was implemented in phases:
telemetry routing hardening (207); analytical-tier job hardening, advisory
locks (208); energy-consumption cascade made watermark-driven (209); demand
made watermark-driven + status-guarded re-finalization (210);
`environment_daily` made watermark-driven (211); job 1000's own forward
window bounded (212); a bounded trailing reconciliation layer closing
internal-hole and CAGG-overshoot gaps (213); an operator-visible health
surface, `analytics.v_pipeline_health` (214). See
[../06-platform/telemetry/pipeline.md](../06-platform/telemetry/pipeline.md)
for the full mechanism detail — this entry is the narrative; that page is
the current-state reference.

## Grafana datasource provisioning failures (2026-08-24/25)

A multi-stage investigation, triggered by staging Grafana showing errors
across dashboard tiles, live/status tiles, and charts:

1. **`update_datasource()` never existed** — an existing tenant datasource
   was never updated on credential change. Fixed by adding it, sharing one
   canonical payload builder with `create_datasource()`.
2. **The update's own success check was wrong** — it trusted an HTTP 200
   that didn't prove the write persisted (Grafana's `version` field proved
   an unreliable signal for this endpoint). Fixed with a post-write
   `/health` check.
3. **The live-datasource plugin itself had never been built and deployed**
   to staging — causing all live/canvas panels to fail with "Datasource not
   found." Fixed by running the repository's own `build-plugin.sh` and
   adding it to the bootstrap sequence so a fresh host doesn't reproduce the
   gap.

All three: **resolved and live-verified end-to-end as of 2026-08-25** —
confirmed via a fresh, successfully-authenticated PostgreSQL session opened
by Grafana, and a real live WebSocket frame received through the exact
plugin channel. Separately, staging's `max_connections=25` was found to be
a real, active connection-slot-exhaustion cause of intermittent Grafana
errors (concurrent holders reached 31 against a 22-slot usable ceiling) —
fixed via a `compose.yaml` command-line override to `max_connections=50`,
applied on a one-time, separately-authorized `timescaledb` recreate. See
[../06-platform/grafana/README.md](../06-platform/grafana/README.md).

## Production promotion: migrations 216–222 and Job 1000 recovery (2026-08-30)

`deploy-production.yml` run `33304784449` promoted migrations 216–222 to
production — `validate-promotion`, deploy-over-SSH (1m21s), and REQUIRED
post-deployment gates all passed. All seven migrations recorded
`application_mode=applied` with checksums byte-identical to the
staging-validated values in one continuous timestamp band. Production's
`telemetry.load_normalized_points_incremental` was confirmed carrying
migration 221's join fix verbatim.

Job 1000 was found still paused at its incident checkpoint (~15.5 hours
behind; raw ingestion had stayed current throughout — only normalization
was behind). The **user** re-enabled it directly
(`SELECT alter_job(1000, scheduled => true)`) — the assistant's own attempt
was correctly blocked by the Claude Code permission classifier as an
unapproved production mutation, a separate authorization boundary from the
migration promotion itself. Recovery matched the migration-212 design
exactly: the first invocation advanced the checkpoint a bounded +6 hours,
382,800 rows in ~2m15s (~2,840 rows/s vs. the pre-incident ~106 rows/s —
migration 221's plan fix confirmed live in production), and within ~25
minutes of wall-clock the backlog fully drained to a ~36-second
steady-state lag. Across the first 19 post-resume runs, `total_failures`
held at 34 (zero new failures).

## Migration 219 — AirSense environmental sensor onboarding blocker (2026-08-29)

`config.device_profile_categories` (profile↔category compatibility) and
`metadata.device_models` both had **no repository reference seed at all** —
new device types require a targeted forward migration per model/profile
pair, not a general reference-data mechanism. Migration 219 added the two
rows the Best Energy "Air Sense" sensor needed. The architectural gap
(compatibility enforced only in application code, no DB trigger; no
general reference seed) remains open — see
[../06-platform/telemetry/onboarding-and-commissioning.md](../06-platform/telemetry/onboarding-and-commissioning.md).

## Older history

The Phase 0 → Phase 1E implementation sequence, the production read-only
access design, and the Meenaxy Pharma staging commissioning migration are
preserved in full in the archived `Audit/` collection and the archived
platform manual's own change-history document — see
[../99-archive/](../99-archive/).
