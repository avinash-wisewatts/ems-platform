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

## Job 1068 auto-disabled by unbounded catch-up window (2026-09-04, fix implemented 2026-09-15, NOT yet deployed)

**Status: fix implemented and locally tested on branch
`fix/job-1068-raw-message-failure-capture-bounded-catchup` (migration 243).
NOT merged, NOT deployed to staging or production, job 1068 remains disabled
on staging.** This entry records the incident and the implemented-but-not-yet-
deployed remediation together so the two are not conflated.

**Incident:** `telemetry.run_raw_message_failure_capture_job` (job 1068,
the raw-message failure quarantine/capture job that feeds job 1077's
recovery queue) stopped succeeding on staging after 2026-08-30 14:28:47 and
was auto-unscheduled by TimescaleDB itself on 2026-09-04 12:22:38
("`Job 1068 unscheduled as max_retries reached 3, consecutive failures
709`"). Root cause, read-only-investigated 2026-09-15: `telemetry.
capture_raw_message_failures_incremental` (as redefined by migration 007 —
baseline/003/006 are all superseded) computes its forward boundary as
`LEAST(v_normalized_checkpoint, clock_timestamp()-p_grace)` with **no cap**
on how far behind the checkpoint may trail — the exact same failure class
migration 205 fixed for job 1000 in the 2026-08-26 incident above. Once the
gap grew past the job's 5-minute `max_runtime`, every 5-minute attempt
re-faced an equal-or-wider window and could make no durable progress, until
TimescaleDB's own `max_retries` auto-disable kicked in. As of this
investigation, `telemetry.raw_messages`' 48-hour retention means the
~12–13 day gap between the last successful capture (2026-08-30) and the
retention floor is already **permanently unrecoverable** (never quarantined,
source rows purged); only the rolling 48-hour live window remains
capturable, and shrinks further every day the job stays disabled.

**Fix implemented (migration 243, NOT deployed):** mirrors migrations
205+212 exactly — `capture_raw_message_failures_incremental` gains an
optional third parameter `p_max_window INTERVAL DEFAULT NULL`
(`LEAST(v_window_end, v_previous_checkpoint + p_max_window)` when supplied);
the wrapper `run_raw_message_failure_capture_job` always derives and passes
a validated, positive bound from `config.max_window` (unmeasured placeholder
default `15 minutes`, explicitly not a recommendation), never `NULL`. A
read-only design study had also proposed replacing the procedure's
`produced_point_count` detection (an `EXISTS` against
`telemetry.normalized_points` keyed on `(device_id, event_time,
logical_point_id)`) with a `(platform_received_at, raw_message_id)` lookup;
**that proposal was found, on closer reading of migration 007/006, to be
incorrect and was NOT implemented** — migration 006 explicitly rejected
exactly that approach, since `normalized_points.raw_message_id`/
`platform_received_at` can be reassigned to a later replay on conflict
("must not infer missing telemetry from mutable lineage"). Only the
window-boundary computation was changed; the detection logic is byte-for-
byte unchanged from migration 007.

**Deliberately not done (per explicit instruction):** migration 243 does
**not** `alter_job` job 1068's live configuration (no `config.max_window`
merge, unlike migration 212's equivalent step for job 1000) and does **not**
re-enable the job. A real `config.max_window` value requires staging
performance evidence that has not yet been collected — see
`scripts/test/staging_measure_raw_message_failure_capture_window.sh`, a
bounded/safeguarded (60-minute cap, statement-timeout, plan-only by default,
read-only/`ROLLBACK`-wrapped, cannot write `raw_message_failures`) measurement
script, itself not yet run against staging. Job 1077 (recovery) was left
completely unchanged.

Tests: `scripts/test/assert_raw_message_failure_capture_bounded_catchup_window.sql`
(disposable-DB, rollback-only, mirrors
`assert_normalization_bounded_catchup_window.sql`'s structure) — NULL/
unbounded regression, bounded advancement, steady state, wrapper default/
override, invalid-config rejection, successive-run continuation, a contract
check that job 1068's live config was not touched, and a functional
detection-equivalence check (matching vs. non-matching
`telemetry.normalized_points` rows still classify correctly after the
window-bound change).

## Older history

The Phase 0 → Phase 1E implementation sequence, the production read-only
access design, and the Meenaxy Pharma staging commissioning migration are
preserved in full in the archived `Audit/` collection and the archived
platform manual's own change-history document — see
[../99-archive/](../99-archive/).
