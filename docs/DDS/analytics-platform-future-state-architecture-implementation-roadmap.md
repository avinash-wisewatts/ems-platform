# EMS Analytics Platform — Implementation Roadmap

```
Status: IMPLEMENTATION PLANNING — no implementation authorized by this document
Prepared: 2026-09-07
Authoritative conceptual input: docs/DDS/analytics-platform-future-state-
architecture.md (CONCEPTUALLY FROZEN). This roadmap implements that document;
it does not redefine it. No database, migration, application, Grafana,
staging, or production change was made to produce this document.
```

This is the actionable, phased backend + frontend implementation plan for the
frozen future-state architecture. It assumes the reader has the frozen
architecture document, its red-team review, and its ten-scenario stress test
as background and does not re-derive their conclusions — it only turns them
into a build sequence. Every phase requires its own explicit approval before
any staging or production change, per CLAUDE.md §§3–4 and §11; nothing here
authorizes work to begin.

---

## Roadmap principles (governing every phase below)

1. **Incremental migration, no big-bang rewrite.** Existing production energy
   analytics (raw ingestion → normalization → `energy_measurements` →
   `ca_energy_*` → `analytics.energy_consumption_*` → `v_grafana_*` → Grafana)
   remains fully operational, untouched, and customer-facing throughout every
   phase until Phase 17 explicitly migrates it, workflow by workflow.
2. **Future architecture first, compatibility built around it.** Where the
   live schema is awkward relative to the frozen model (hardcoded routing,
   dormant `asset_points`, energy-only quality semantics), this roadmap
   builds the clean concept and provides a migration/compatibility path
   *to* it — it does not let legacy shape leak back into the conceptual
   model.
3. **Energy stability is non-negotiable.** Any phase touching energy routing
   or semantics requires a numerical-parity and performance gate before any
   cutover — see Phase 4's energy sub-phase and Phase 10/17.
4. **One qualifying real domain proves the model before automation is built.**
   Phase 3 proves the reusable domain-measurement foundation using the first
   qualifying real domain, by hand (not the future codegen mechanism), before
   Phase 4 builds any routing automation, and Phase 5 proves calculations by
   hand before Phase 6 persists them — automation is built *from* a proven
   manual path, never speculatively ahead of one. AirSense / environmental
   telemetry is the current qualifying real domain; motor / asset-health
   remains a future qualifying domain/deployment rather than a prerequisite
   for the Phase 3 architectural proof.
5. **No premature tooling.** The routing code generator (Phase 4), the
   derived-parameter persisted tier (Phase 6), and the frontend application
   (Phase 8+) are each deliberately sequenced after their underlying model
   has a real, manually-verified working example.

---

## Phase 0 — Current-State Analytics Inventory

**Objective**: a complete, evidence-based inventory of every analytics object
that exists today, forming the regression contract every later phase's
parity gates are checked against. Build on the existing `Audit/` Phase 0
documents and the platform manual's reference catalogs
(`reference/database-object-catalog.md`, `reference/grafana-dashboard-
catalog.md`) — do not redo that work, reconcile and formalize it.

- **Backend**: a repeatable, read-only inventory script (SQL against
  `information_schema`/`pg_catalog`/`timescaledb_information`) enumerating
  every `analytics`/`telemetry`/`config`/`metadata` object, every
  TimescaleDB job, every `admin.*` function — deduplicated against the known
  `v_energy_*` near-duplicate finding (`23-known-issues-and-drift.md` #8).
- **Frontend**: none — audit only. Confirm the admin-portal's actual HTTP
  route inventory (open item #12 in known-issues-and-drift.md) and which of
  the 7 Grafana dashboards' panels query which objects (per
  `12-grafana.md`'s "objects defined but not consumed by any dashboard"
  finding), since both are inputs to later parity gates.
- **Dependencies**: none — first phase.
- **Migration strategy**: N/A, no schema change.
- **Backwards compatibility**: N/A.
- **Testing**: the inventory script itself is the test artifact — diffable
  against the platform manual's stated counts (84 analytics objects, 21
  metadata tables, etc.) to catch documentation drift as a side effect.
- **Staging validation**: run against staging, reconcile any discrepancy
  from the manual's documented counts before treating the inventory as
  ground truth.
- **Production rollout**: N/A — read-only.
- **Rollback**: N/A.
- **Exit criteria**: a signed-off "must remain stable" object list exists,
  versioned in the repository, and is the explicit reference every later
  phase's backwards-compatibility check is measured against.

---

## Phase 1 — Semantic Foundation

**Objective**: stand up `config.parameters` and the Point↔Parameter split,
with zero effect on ingestion.

- **Backend**: `config.parameters` (code, name, unit_id, parameter_category,
  value_kind, aggregation_method, direction_of_good, interpolation_policy,
  is_derived); `metadata.logical_points.parameter_id` (nullable FK) +
  `qualifier`; `config.parameter_asset_type_applicability`; new
  `config.status_definitions` rows under `status_domain='TELEMETRY_QUALITY'`
  and per-`STATE`-parameter vocabularies (reusing the existing table, no new
  one). A reviewed, one-time backfill script populates `parameters` and
  `logical_points.parameter_id`/`qualifier` for the 50 live
  `ENERGY_METER_ENISCOPE_V1` points and the live `ENVIRONMENT_SENSOR_
  AIRSENSE_V1` points, using `reference/telemetry-field-catalog.md` as
  ground truth. **No routing/loader code is touched.**
- **Frontend**: none.
- **Dependencies**: Phase 0.
- **Migration strategy**: purely additive DDL; `parameter_id` starts `NULL`
  everywhere until backfilled; nothing downstream reads it during this
  phase, so there is no behavioral risk.
- **Backwards compatibility**: 100% — no existing table, view, or procedure
  is read or altered.
- **Testing**: contract test asserting every existing `logical_point` has a
  `parameter_id`+`qualifier` after backfill; the "either observed or derived,
  never both/neither" parameter invariant, enforced as a cross-table trigger
  contract test.
- **Staging validation**: row-by-row diff of the backfilled points against
  `reference/telemetry-field-catalog.md`; confirm zero silently-unmapped
  `logical_points`.
- **Production rollout**: standard additive migration through the existing
  `deploy-staging.yml`/`deploy-production.yml` path; nullable column with no
  default, cheap on a hot table.
- **Rollback**: drop the new tables/columns — risk-free, since nothing reads
  them yet. The safest phase in this roadmap to roll back.
- **Exit criteria** (acceptance test): a read-only query resolves `logical_
  point → parameter + qualifier` for both live profiles (energy, environment)
  purely from configuration, demonstrated against real production data, not
  theorized.

---

## Phase 2 — Subject Binding and Relationship Foundation

**Objective**: wire point→subject binding and the asset/space relationship
graph, still without touching ingestion.

- **Backend**: revive `metadata.asset_points` (exists, unused) with
  `effective_from`/`effective_to` + a GiST exclusion constraint (`btree_gist`,
  already an installed extension per `config.interval_quality_rules`);
  new `metadata.space_points`, same shape; new `config.asset_relationship_
  types` (seeded: `COMPONENT_OF`, `DRIVEN_BY`, `SUPPLIED_BY`, `PART_OF`, each
  with a directionality convention) and `metadata.asset_relationships`
  (effective-dated, GiST exclusion, a new per-type-scoped cycle-prevention
  trigger — cannot reuse `trg_validate_asset_hierarchy`, which is
  single-parent-tree-shaped); `config.asset_relationship_type_compatibility`
  + trigger, mirroring `trg_validate_asset_device_relationship`; the mirror
  set for `asset_space_relationships` (`SERVES`/`LOCATED_IN`/`COOLS`/`HEATS`/
  `VENTILATES`/`SUPPLIES`/`EXHAUSTS`/`MONITORS`); `metadata.assets.
  asset_nature` (`PHYSICAL`/`VIRTUAL`, default `PHYSICAL`). A limited,
  honest backfill for the live Meenaxy Pharma fleet — only relationships
  that are physically real, never invented to populate the table.
- **Frontend**: none — read-only `v_grafana_asset_relationships`/
  `v_grafana_asset_space_relationships` views for manual verification via
  Grafana Explore only, not a built panel.
- **Dependencies**: Phase 1 (can run largely in parallel with it — the two
  touch disjoint tables; sequenced after only so the end-to-end identity
  chain has both halves to test together).
- **Migration strategy**: additive; effective-dating defaults are moot for
  now since these are new, currently-empty tables.
- **Backwards compatibility**: 100% — `asset_devices` (the existing
  relationship mechanism) is completely untouched.
- **Testing**: contract tests per stress-test failure scenario — "sensor
  moved" (a time-aware join attributes readings correctly on both sides of
  an effective-dating boundary), "asset replaced," "AHU starts/stops serving
  a space" — each asserting both the exclusion constraint's rejection of an
  overlapping insert and correct point-in-time resolution.
- **Staging validation**: construct one real relationship graph on staging
  from actual Meenaxy Pharma equipment (or a clearly-labeled synthetic pair
  if no real `DRIVEN_BY`/`COMPONENT_OF` case exists yet) and simulate an
  "asset replaced" event, verifying historical query results are preserved.
- **Production rollout**: standard additive migration; no invented
  production data.
- **Rollback**: drop new tables — zero downstream impact, nothing but ad hoc
  Grafana Explore queries consumes them yet.
- **Exit criteria**: all four of the stress test's "History" scenarios
  (sensor moved, asset replaced, point remapped, AHU serving-space change)
  demonstrated live with before/after query evidence.

---

## Phase 3 — Domain Measurement Foundation

> **Scope clarification (wording only, not a change to architecture or
> sequencing):** Phase 3 proves the reusable domain-measurement foundation
> using the first qualifying real domain. AirSense / environmental telemetry
> is the current qualifying real domain. Motor / asset-health via
> `telemetry.asset_health` remains a future qualifying domain/deployment
> rather than a prerequisite for the Phase 3 architectural proof; the
> `asset_health` / `generic_point_measurements` / `water_measurements` items
> below are that later, still-additive scope.

**Objective**: take the first qualifying real domain end-to-end using
hand-written routing (not the future codegen mechanism), and — as later,
additive scope — wire the remaining dormant domain tables and stand up the
generic landing table. This is the roadmap's "one qualifying real domain"
acceptance test.

- **Backend**: `telemetry.environment_measurements.space_id` (nullable,
  populated going forward at routing time; historical backfill only where
  a device→asset→`SERVES` chain cheaply resolves as of each row's own
  timestamp — not forced); `telemetry.generic_point_measurements` (new
  hypertable, `segmentby(parameter_id)` compression); a hand-written loader
  for `telemetry.asset_health` (populating its already-existing
  vibration/thermal/runtime/status columns for one real motor
  profile/device), matching today's `load_energy_measurements_incremental`
  style exactly, **watermark-driven from day one** — bounded `p_max_window`
  catch-up, advisory lock, `check_config` validator, finite `max_runtime`/
  `max_retries`/`retry_period` — do not repeat the pre-migration-207 mistake
  of shipping unbounded and retrofitting under incident pressure. A
  `water_measurements` loader is deferred unless a real water-metering
  profile exists to test against — no loader is built against invented data.
- **Frontend**: none — confirm the grant on the already-existing
  `analytics.v_grafana_asset_health_history` view, no new panel.
- **Dependencies**: Phase 1 (parameters), Phase 2 (relationship/subject
  tables, though this phase's `asset_id` population can also come from the
  existing `asset_devices`/`PRIMARY_METER` path independent of `asset_
  points`).
- **Migration strategy**: additive tables/columns/jobs. Historical backfill
  from `raw_messages`/`normalized_points` into `asset_health` (mirroring
  `postgres/maintenance/45_rebuild_normalized_history.sql`'s precedent) is a
  separate, explicitly-approved one-time task, never bundled into initial
  rollout.
- **Backwards compatibility**: `energy_measurements`/`environment_
  measurements`'s existing procedures, jobs, and every downstream consumer
  are completely untouched.
- **Testing**: `assert_asset_health_routing_*` contract tests mirroring
  `assert_recovery_*`'s style; a bounded-catchup test mirroring
  `assert_normalization_bounded_catchup_window.sql`.
- **Staging validation**: one real device, real profile, demonstrated
  end-to-end (raw MQTT → normalized_points → asset_health, correct
  bucket_start/quality_code/row counts) using the same live-verification
  method `19-operations-and-diagnostics.md` already documents for energy.
- **Production rollout**: new jobs ship `scheduled=false`; enabled only
  after staging validation passes, as an explicit, separately-approved step
  — mirroring exactly how job 1000 was found and deliberately re-enabled in
  the 2026-08-30 incident, never auto-enabled by the migration itself.
- **Rollback**: `alter_job(..., scheduled=>false)`; tables have no
  downstream consumer to break.
- **Exit criteria**: one real device's telemetry flows end-to-end into the
  qualifying real domain's measurement table, verified live, to the same
  rigor the platform manual holds energy to.

---

## Phase 4 — Routing Architecture

**Objective**: build `config.parameter_routing` and its codegen execution
mechanism — only after Phase 3 proved a domain by hand.

- **Backend**: `config.parameter_routing` (parameter_id/logical_point_id,
  destination_table, destination_column, applicable_profile_id or
  device_category_id, `accounting_role_required`) as the configuration
  layer. Execution: an offline, CI-time generator (`scripts/codegen/` or
  `postgres/tools/`) reading `parameter_routing` and emitting a `CREATE OR
  REPLACE PROCEDURE` migration file in the same hand-reviewable
  `FILTER`-pivot shape used today — **never runtime-dynamic SQL**, which
  would risk silently losing the deliberate `LATERAL`-probe query shape
  `postgres/ddl/124_parameterized_domain_routing.sql` already forces for
  performance. Migrate the Phase-3 `asset_health` loader onto the generator
  first, as its proof case. **The accounting-role routing rule is enforced
  here**: `parameter_routing` resolution for any energy-shaped parameter
  requires the source point to be reached via a `PRIMARY_METER`/`SECONDARY_
  METER` relationship to a device of an accounting-meter category — checked
  at config/generation time, not left to runtime judgment.
- **Frontend**: none.
- **Dependencies**: Phase 3.
- **Migration strategy**: the generator is tooling; its output is ordinary
  reviewed migrations. No existing procedure is touched until the explicit
  energy sub-phase below.
- **Backwards compatibility**: the hand-written Phase-3 loader's behavior
  must be bit-for-bit reproduced by its generated replacement before
  cutover — a diff/parity test, not "it compiles."
- **Testing**: generator unit tests (fixture `parameter_routing` rows →
  expected SQL), a golden-file comparison against a known-good procedure
  body, and the existing `assert_*` contract tests re-run unchanged against
  the generated procedure.
- **Staging validation**: run the hand-written and generated versions of the
  same loader side by side on staging over a real time window; require a
  zero-diff row-for-row match before cutover.
- **Production rollout**: swap via a normal `CREATE OR REPLACE PROCEDURE`
  migration, same signature — no job re-registration needed.
- **Rollback**: revert to the prior migration's hand-written body.
- **Energy/environment routing migration onto this mechanism is its own
  later, separately-approved sub-phase**, gated on: (a) the generator proven
  on ≥2 non-energy domains first; (b) an explicit `EXPLAIN`+output-diff
  parity gate over a representative multi-day staging window, matching the
  rigor of the already-on-record migration-221 N1 validation; (c) its own
  explicit approval, never bundled with any other phase.
- **Exit criteria**: a second new domain onboarded end-to-end purely through
  `parameter_routing` configuration rows plus a generator run — zero
  hand-written procedure logic — proving the architecture's stated
  objective.

---

## Phase 5 — Derived Calculation Foundation

**Objective**: implement the corrected `ParameterCalculation` model,
view-based only, no persisted tier.

- **Backend**: `config.parameter_calculations` (full corrected shape —
  `calculation_version`, `input_parameter_refs` with `SELF`/`RELATED`/
  `AGGREGATE_CHILDREN` traversal, `null_handling`, `required_resolution`,
  `applicable_asset_type_id`, effective dating). A small, reviewed library of
  plain SQL/window-function calculations, **no DSL**: runtime-from-status
  (`SELF`), ΔT (`SELF`), pump specific-energy (`RELATED` — proves cross-asset
  traversal), plant/virtual COP or energy rollup (`AGGREGATE_CHILDREN` —
  proves rollup + `PARTIAL` quality). Each exposed as a plain view initially.
- **Frontend**: none.
- **Dependencies**: Phase 2 (`AssetRelationship`, for `RELATED`/`AGGREGATE_
  CHILDREN` to have something to traverse), Phase 3 (`asset_health`, so
  ΔT/runtime have real inputs).
- **Migration strategy**: additive config table + views; no ingestion path
  touched.
- **Backwards compatibility**: complete — this phase only reads already-
  landed telemetry.
- **Testing**: per-calculation unit tests (a required-input-missing fixture
  correctly degrades `quality_code`; an `AGGREGATE_CHILDREN` fixture with one
  missing child correctly reports `PARTIAL`); the parameter-existence
  invariant as a contract test.
- **Staging validation**: compute all four proof calculations against real
  (or realistic) staging telemetry; hand-verify at least one value per
  calculation independently.
- **Production rollout**: view-based, low-risk; deploy alongside its
  inputs' normal release cadence.
- **Rollback**: drop the views/config rows — no stored state to reconcile.
- **Exit criteria**: all three traversal modes demonstrated against real
  data, including one `PARTIAL`-quality case — closing the stress test's
  single largest open design question.

---

## Phase 6 — Persisted Derived Analytics

**Objective**: persist derived values for calculations proven valuable in
Phase 5, on the existing watermark/reconciliation pattern.

- **Backend**: `analytics.derived_parameter_values` (calculation_id,
  calculation_version, quality_code, input_quality_summary); per-calculation
  `refresh_derived_parameter_*` procedures + `run_derived_parameter_*_job`
  wrappers, **watermark-driven from day one** (learn from the pre-209 energy
  mistake, do not ship fixed-lookback and retrofit); reconciliation via the
  recency-based (`calculated_at`) fingerprint, mirroring migration 213's
  15min/hourly/daily approach, on its own slow-cadence job.
- **Frontend**: none yet.
- **Dependencies**: Phase 5.
- **Migration strategy**: additive; the Phase-5 views remain available as a
  cross-check during bake-in.
- **Backwards compatibility**: complete.
- **Testing**: watermark/bounded-catchup contract tests mirroring
  `assert_normalization_bounded_catchup_window.sql`; reconciliation
  contract tests mirroring migration 213's own never-advances-a-forward-
  checkpoint contract (`pg_get_functiondef`-based).
- **Staging validation**: pause a domain's routing job to simulate an
  upstream outage; confirm the derived-parameter tier's watermark stalls
  correctly and self-drains afterward, to the same standard energy already
  meets.
- **Production rollout**: jobs ship `scheduled=false`, enabled after
  staging bake-in.
- **Rollback**: disable jobs; the persisted table can be truncated/dropped
  without affecting anything else, since nothing downstream depends on it
  yet.
- **Exit criteria**: at least one derived-parameter tier runs unattended in
  staging through a real or simulated upstream gap and self-heals without
  operator intervention.

---

## Phase 7 — Analytics API / Query Boundary

**Objective**: the stable contract between the data model and any consumer.

- **Backend**: extend `v_grafana_*` (not a redundant REST layer) with
  `v_grafana_asset_relationships`, `v_grafana_asset_space_relationships`,
  `v_grafana_asset_condition_summary`, `v_grafana_space_environment_
  summary`, `v_grafana_asset_efficiency_*` — same `security_barrier`/grant/
  `${__org.id}`-filtering conventions as every existing `v_grafana_*`
  object. A thin FastAPI layer only for what a view cannot express — writes
  to `asset_points`/`asset_relationships`/`asset_space_relationships`/
  `parameter_calculations` — extending the existing `admin.*` function +
  `admin.onboarding_audit` pattern, not a new paradigm.
- **Frontend**: none built — this phase defines the contract Phase 8+
  consumes.
- **Dependencies**: Phases 2–6 (real relationships/derived values to
  expose).
- **Migration strategy**: additive views/functions; no existing
  `v_grafana_*` object is altered.
- **Backwards compatibility**: complete.
- **Testing**: per-view tenant-isolation contract tests (cross-org query
  returns zero rows); `admin.*` write-function tests (permission checks,
  audit log rows) mirroring `08-device-onboarding.md`'s existing pattern.
- **Staging validation**: exercise every new object against real staging
  tenant data, re-running the platform's own tenant-isolation verification
  method explicitly.
- **Production rollout**: standard additive deploy.
- **Rollback**: drop new views/functions — no consumer depends on them yet.
- **Exit criteria**: everything Phase 8+ will need exists, is tenant-
  isolated, and is independently verifiable via Grafana Explore before any
  frontend code is written against it.

---

## Phase 8 — Frontend Foundation

**Objective**: the React/TypeScript application shell — no feature
dashboards yet.

- **Backend**: none new — consumes Phase 7.
- **Frontend**: project scaffold; authentication (reuse/extend admin-
  portal's existing session mechanism, no parallel auth system);
  tenant/organization context; site navigation shell; permission-gated
  routing (surfacing `admin.portal_user_has_permission`-equivalent checks);
  a shared time-range/resolution-selection component (mirroring Grafana's
  own time-range UX); one charting foundation, used consistently;
  loading/error/empty-state components (a newly-commissioned device's empty
  history reads as "no data yet," never an error, per `24-troubleshooting.
  md`'s guidance); quality-indicator components rendering `GOOD`/`GAP`/
  `ESTIMATED`/`INVALID`/`PARTIAL` consistently everywhere.
- **Dependencies**: Phase 7 — a stable contract to build against; building
  ahead of it is the single most common source of rework.
- **Migration strategy**: N/A — new application; admin-portal's Jinja2
  templates and Grafana are both untouched.
- **Backwards compatibility**: admin-portal and Grafana continue exactly as
  today; the new frontend is additive.
- **Testing**: component tests for shared primitives; an auth/permission
  integration test against a real staging tenant.
- **Staging validation**: deploy the shell behind an access-gated URL
  (internal only), verify auth/tenancy/navigation against real staging
  orgs.
- **Production rollout**: behind a feature flag or internal-only route — no
  customer exposure until Phase 9+ exists behind it.
- **Rollback**: a separate deployable; rollback has zero effect on
  admin-portal/Grafana.
- **Exit criteria**: an internal user logs in, selects an organization/site,
  and sees a correctly-scaffolded, empty shell against real staging data —
  every foundation piece proven once, reused everywhere after.

---

## Phase 9 — Core Site / Asset / Space UX

**Objective**: the first real feature surface — navigation and relational
views, no energy/efficiency analytics yet.

- **Backend**: none new beyond Phase 7, unless a gap is found — in which
  case it's a small, targeted view addition, not a new phase.
- **Frontend**: Site overview (energy/performance placeholders, spaces list,
  systems list); Asset hierarchy/component-tree view (`AssetRelationship`);
  Asset-space "serves" map (`AssetSpaceRelationship`); Device/Point
  diagnostic view (raw telemetry, mapped parameter, subject, quality) —
  hiding raw table names and routing configuration throughout, per the
  frozen architecture's explicit rule.
- **Dependencies**: Phase 8, Phase 7.
- **Migration strategy**: N/A.
- **Backwards compatibility**: complete.
- **Testing**: end-to-end tests against real staging relationship data —
  Phase 2's exit-criteria examples become this phase's UI fixtures.
- **Staging validation**: an internal reviewer navigates a real multi-asset,
  multi-space staging site end-to-end and confirms every Phase 2
  relationship/binding renders correctly.
- **Production rollout**: internal-only or limited-beta, still behind a
  flag.
- **Rollback**: flag off.
- **Exit criteria**: a real staging site's full asset/space/relationship
  graph is navigable and matches database ground truth exactly.

---

## Phase 10 — Energy Analytics

**Objective**: replicate (not yet replace) customer-facing energy workflows,
run in parallel with Grafana.

- **Backend**: none new — reads `analytics.energy_consumption_*`/`demand_
  intervals` through Phase 7's boundary, exactly as Grafana does today.
- **Frontend**: consumption, demand, load profile, comparisons, energy
  breakdown — matching, not innovating beyond, the 7 existing Grafana
  dashboards, as the parity baseline.
- **Dependencies**: Phase 9.
- **Migration strategy**: N/A — additive frontend only; the entire energy
  backend is completely untouched.
- **Backwards compatibility**: Grafana's energy dashboards remain the
  customer-facing system of record until parity is proven.
- **Testing**: numerical-parity tests — computed/displayed values must match
  Grafana's panel output exactly for a representative sample of real
  sites/assets/time-ranges, including DST-boundary and multi-resolution-tier
  cases.
- **Staging validation**: side-by-side Grafana vs. new frontend on identical
  staging data for every energy workflow, with an explicit tolerance
  definition (exact-match expected here, since both read the same
  already-validated `energy_consumption_*` tables).
- **Production rollout**: **parallel run only** — Grafana remains
  customer-facing; the new frontend's energy views are internal/beta-only
  until Phase 17's acceptance gate.
- **Rollback**: disable the new frontend's energy routes; zero impact on
  Grafana.
- **Exit criteria**: numerical parity formally signed off across a
  representative sample — the gate Phase 17 requires per-workflow before
  any Grafana dashboard can be retired.

---

## Phase 11 — Asset Performance

**Objective**: condition-monitoring UX, using the motor domain as the first
production-quality reference implementation.

- **Backend**: none new beyond Phases 3–6's motor/asset_health work — this
  phase is where that domain gets its first real customer-facing consumer,
  closing the Point→Parameter→Subject→Domain measurement→Derived
  calculation→Quality loop the roadmap principles required before broad
  automation.
- **Frontend**: asset performance/condition views (runtime, vibration,
  temperatures, operating status, per-asset efficiency) for the motor
  domain first; extend to other `asset_health`-backed domains only after the
  motor reference implementation is validated in production use.
- **Dependencies**: Phases 3, 5, 6, 9.
- **Migration strategy**: N/A for this phase — consumption of already-built
  backend.
- **Backwards compatibility**: complete — new capability, nothing existing
  displaced.
- **Testing**: end-to-end tests against real motor telemetry where it
  exists, otherwise a clearly-labeled representative fixture.
- **Staging validation**: an internal reviewer validates one real motor's
  full condition-monitoring picture against the underlying database rows,
  by hand, at least once.
- **Production rollout**: beta with the specific customer/site whose motor
  telemetry is the reference, with their awareness, before wider rollout.
- **Rollback**: flag off the asset-performance routes.
- **Exit criteria**: one real motor's complete chain is demonstrated
  end-to-end in the production frontend.

---

## Phase 12 — Real-Time and Data Quality

**Objective**: telemetry health/freshness/quality surfaces, reusing existing
mechanisms — no new health-tracking mechanism invented.

- **Backend**: none new — reads `telemetry.device_telemetry_state`/`device_
  status`/`device_live_point_state` (already live) through Phase 7.
- **Frontend**: live status, freshness, communication health, point-level
  quality (`GOOD`/`GAP`/`INVALID`/`ESTIMATED`/`PARTIAL`), telemetry
  diagnostics — using Phase 8's quality components, applied consistently.
- **Dependencies**: Phase 8, Phase 9.
- **Migration strategy**: N/A.
- **Backwards compatibility**: complete.
- **Testing**: frontend indicators verified against `device_telemetry_
  state` ground truth for both a healthy and a deliberately-stale staging
  device.
- **Staging validation**: same, including a real or simulated
  device-offline scenario.
- **Production rollout**: standard, low-risk (read-only).
- **Rollback**: flag off.
- **Exit criteria**: an operator can diagnose a stale/failed device from the
  new frontend alone — `19-operations-and-diagnostics.md`'s SQL playbook
  remains the ops-team fallback, not the only path.

---

## Phase 13 — Advanced Efficiency Analytics

**Objective**: baseline/expected-performance, normalized performance,
operating envelope, cross-asset comparisons.

- **Backend**: baseline calculations as a `parameter_calculations`
  specialization (a fit/regression `formula_definition.engine`, per the
  frozen architecture's §B.7) — reusing the exact Phase 5/6 mechanism, no
  parallel baseline schema; cross-asset comparison views (comparing derived
  values across assets sharing an `asset_type_id`, per the frozen
  architecture's explicit fairness rule).
- **Frontend**: baseline overlays on Phase 11's asset-performance views;
  cross-asset/cross-system comparison views.
- **Dependencies**: Phase 6 (stable persisted derived-parameter tier), Phase
  11 (a real domain's condition data mature enough to fit against).
- **Migration strategy**: additive — new `parameter_calculations` rows of
  the fit/regression kind; no schema change beyond Phase 5/6.
- **Backwards compatibility**: complete.
- **Testing**: baseline-fit validation against held-out historical data (a
  standard train/validate split, reviewed like any other calculation).
- **Staging validation**: fit a baseline for one real asset/parameter pair;
  confirm sane predictions against real staging history before any
  production exposure.
- **Production rollout**: internal/beta first — baselines are explicitly
  probabilistic and need a bake-in period.
- **Rollback**: deactivate the calculation (`is_active=false`); no data loss,
  purely derived.
- **Exit criteria**: at least one baseline live, monitored, and
  demonstrably sane over a real multi-week window before wider rollout.

---

## Phase 14 — Cost / Benchmarking / Intelligence Foundations

**Objective**: tariffs, cost, benchmarking, anomaly detection, insights,
recommendations — deliberately thin.

- **Backend**: `config.tariffs`/`analytics.cost_values` (a straightforward
  rate × consumption model, not a generalized billing engine), only if a
  real customer requirement exists; `analytics.insights` (the narrow,
  evidence-referencing event log from the red-team review —
  `subject_ref, insight_type, severity, evidence_refs, generated_by,
  status`) — detection logic (thresholds/rules/ML) lives outside the schema
  in application/analytics code, never as database objects.
- **Frontend**: cost views (if tariffs are built), benchmarking comparisons
  (reusing Phase 13's mechanism), an insights/notifications surface reading
  `analytics.insights`.
- **Dependencies**: Phase 13.
- **Migration strategy**: additive; `analytics.insights` starts empty.
- **Backwards compatibility**: complete.
- **Testing**: `analytics.insights` write-path contract tests (a
  malformed evidence reference fails loudly); detection-accuracy testing is
  explicitly out of scope for this database-contract suite.
- **Staging validation**: run one real or realistic detector against
  staging data, confirm insights rows carry correct evidence references and
  are queryable through Phase 7.
- **Production rollout**: each new detector ships behind its own explicit
  approval — the layer most likely to surface false positives and most
  likely to need iteration.
- **Rollback**: deactivate the detector; `analytics.insights` rows are
  marked `DISMISSED`, not deleted.
- **Exit criteria**: one real insight, generated from real data, reviewed
  and confirmed non-spurious by a human before the detector runs
  unattended.

---

## Phase 15 — Reporting

**Objective**: reports/exports/scheduled reporting, using the by-now-stable
analytics/API layer.

- **Backend**: report-definition storage + a scheduled-generation job,
  reusing existing job-scheduling conventions — reading exclusively through
  Phase 7, never raw tables.
- **Frontend**: report builder/viewer, export UX, schedule management.
- **Dependencies**: Phase 7, Phase 10 (energy parity — reports will likely
  include energy figures that must match what customers already see).
- **Migration strategy**: additive.
- **Backwards compatibility**: complete.
- **Testing**: report-output correctness (generated content matches the
  underlying view query, exactly, on the numeric content).
- **Staging validation**: generate a real report against real staging data,
  hand-verify against the source views.
- **Production rollout**: standard, low-risk.
- **Rollback**: disable report generation; no data-model risk.
- **Exit criteria**: a scheduled report runs unattended in staging for at
  least one full cycle and produces correct output.

---

## Phase 16 — Hardening and Scale

**Objective**: performance, tuning, security, observability, recovery —
under representative production-scale workloads, not prematurely.

- **Backend**: `EXPLAIN (ANALYZE, BUFFERS)` review of every new view/query
  family under realistic multi-tenant, multi-week volumes (not just
  current staging scale); a deliberate compression/retention policy for
  every new table (`generic_point_measurements`, `derived_parameter_
  values`, `asset_health`, `water_measurements`) — closing out, for both old
  and new tables, the platform manual's own open finding that no retention
  policy exists yet for several persisted tiers (`11-aggregation.md`);
  tenant-isolation penetration-style tests against every new API/view;
  backup/recovery validation extended to the new tables, addressing the
  manual's open item that backup/recovery is "not established or verified"
  today (`21-backup-and-recovery.md`).
- **Frontend**: bundle-size/load-performance review; caching strategy for
  the new API boundary.
- **Dependencies**: Phases 1–15 substantially complete — deliberately late,
  measuring a real system rather than a hypothetical one.
- **Migration strategy**: index/compression/retention-policy additions only
  — no structural schema change.
- **Backwards compatibility**: complete — this phase must change performance
  characteristics only, never behavior.
- **Testing**: load tests at representative production scale (multiple
  tenants, realistic device counts, multi-year volumes where retention
  allows).
- **Staging validation**: a dedicated performance pass with
  production-representative synthetic volume, following the same
  `EXPLAIN`-evidence discipline as migration 221's N1 fix.
- **Production rollout**: index/policy changes are typically low-risk and
  additive (`CREATE INDEX CONCURRENTLY`, new retention policies); any change
  touching an existing hot table's access path still requires the full
  staging-parity discipline.
- **Rollback**: drop new indexes/policies; no data risk.
- **Exit criteria**: every object introduced by this roadmap has a
  documented, tested retention policy and passes a representative-scale
  performance review.

---

## Phase 17 — Grafana Customer Workflow Migration

**Objective**: migrate each customer-facing workflow only after parity is
proven; Grafana remains for ops/engineering indefinitely.

- **Backend**: none new — process, not data-model work.
- **Frontend**: none new — consumes everything built in Phases 8–15.
- **Process, per workflow** (energy consumption, demand, load profile, asset
  performance, etc.): (1) numerical parity, (2) timestamp/timezone parity
  (including DST boundaries, per the platform's existing site-timezone-aware
  daily-boundary precedent), (3) tenant-scope parity, (4) filtering parity,
  (5) acceptable performance, (6) explicit stakeholder/customer acceptance,
  (7) migrate the workflow (default customer entry point switches), (8)
  retain rollback capability — the Grafana dashboard stays live through a
  defined bake-in period, not deleted.
- **Dependencies**: every prior phase, per-workflow — workflows migrate
  independently, never all at once.
- **Migration strategy**: workflow-by-workflow, never a full cutover.
- **Backwards compatibility**: Grafana remains fully functional throughout;
  nothing is removed until its own parity gate and bake-in period both pass.
- **Testing**: the full parity suite, re-run immediately before every
  individual migration decision.
- **Staging validation**: side-by-side comparison on staging for the
  specific workflow, immediately before the production migration decision.
- **Production rollout**: one workflow's default entry point at a time; the
  Grafana dashboard remains reachable through the bake-in period.
- **Rollback**: point the default entry point back at Grafana — trivial,
  since it was never removed.
- **Exit criteria (whole program)**: every customer-facing workflow has
  migrated with explicit acceptance and completed its bake-in period;
  Grafana's customer-facing role is fully retired; Grafana continues serving
  ops/engineering (`v_pipeline_health`, operational diagnostics) indefinitely.

---

## Migration order (dependency graph)

```
Phase 0 (inventory)
   │
   ├──────────────┐
   ▼              ▼
Phase 1        Phase 2        ← can run in parallel (disjoint tables);
(semantic)     (subject/rel)     sequenced together only for the combined
   │              │              end-to-end identity-chain acceptance test
   └──────┬───────┘
          ▼
      Phase 3 (domain measurement — the "one qualifying real domain" acceptance test)
          │
          ▼
      Phase 4 (routing architecture, incl. the separately-gated energy sub-phase)
          │
          ▼
      Phase 5 (derived calculations, view-based)
          │
          ▼
      Phase 6 (persisted derived analytics)
          │
          ▼
      Phase 7 (analytics API / query boundary)
          │
          ▼
      Phase 8 (frontend foundation)
          │
    ┌─────┼─────────────┐
    ▼     ▼             ▼
 Phase 9  (can begin scaffolding in parallel with late Phase 7 work once
          the API *shape* is stable, even before every view is fully populated)
    │
    ├──────────────┬──────────────┐
    ▼              ▼              ▼
Phase 10        Phase 11        Phase 12   ← energy, asset-performance, and
(energy)        (asset perf)   (real-time/    real-time/quality UX can develop
    │               │           quality)      in parallel once Phase 9 exists;
    │               ▼              │          each depends only on Phase 9 +
    │           Phase 13            │          its own specific backend phase
    │        (advanced efficiency)  │
    │               │               │
    └───────┬───────┴───────────────┘
            ▼
       Phase 14 (cost/benchmarking/intelligence)
            │
            ▼
       Phase 15 (reporting) ── depends on Phase 7 + Phase 10 specifically,
            │                  can otherwise run alongside 11–14
            ▼
       Phase 16 (hardening) ── incremental EXPLAIN/index review can start as
            │                  early as Phase 3–7; formal exit criteria sits
            │                  here, once there is a real system to measure
            ▼
       Phase 17 (Grafana customer workflow migration, workflow-by-workflow)
```

Phases 1–2 are the only formally parallel pair; every other "parallel"
opportunity noted above (Phase 9's early scaffolding, Phases 10–12's
independent UX tracks, Phase 16's incremental performance review) is
opportunistic, not required — no phase is forced into artificial
sequentiality, but none is required to run early either.

---

## Backwards compatibility strategy

| | Existing | Future | Coexistence approach |
|---|---|---|---|
| Energy ingestion/routing | `load_energy_measurements_incremental`, hardcoded pivot | `config.parameter_routing` + codegen'd procedure | **Untouched** until Phase 4's separately-gated, separately-approved energy sub-phase; parity-gated cutover, no dual-write needed (same table, same shape, only the procedure body's provenance changes) |
| `analytics.energy_consumption_*` (5 tiers) | Persisted, register-semantics-classified | Unchanged | **Untouched, permanently** — remains the authoritative energy semantic layer per the frozen architecture's §E |
| `demand_intervals`/`demand_state` | Status-guarded upsert, migration 210 | Unchanged | **Untouched, permanently** |
| Grafana dashboards (7) | Customer-facing | New frontend (Phases 8–15) | **Read-through, parallel-run** until Phase 17's per-workflow parity gate; retained for ops/engineering indefinitely regardless |
| `metadata.asset_points`/`device_field_mapping`/`point_categories` | Dormant, schema-only | Live, effective-dated, wired | **Extended in place** (add columns/constraints), not replaced — these were designed for this purpose and were simply never finished |
| `telemetry.asset_health`/`water_measurements` | Schema-only, unpopulated | Wired to real loaders | **Extended in place** — no rename, no new table |
| `metadata.grafana_organization_map`/Grafana provisioning | Live | Unchanged | **Untouched** — the new frontend's own auth/tenancy (Phase 8) is a parallel mechanism, not a replacement of Grafana's org-mapping model |
| `admin-portal` (Jinja2 onboarding) | Live, sole write path for metadata | Extended with new `admin.*` functions for the new relationship tables | **Extended in place** — new functions follow the exact existing pattern (permission check, audit log); the portal itself is not rewritten by this roadmap |
| `config.energy_register_semantics` | Electrical-only | Broadened `flow_interpretation` for fuel/thermal | **Extended in place**, additive `flow_interpretation` values only — no existing row's meaning changes |

**What gets dual-written**: nothing, by design — every new table/column is
either genuinely new (no prior data to reconcile) or additively populated
going forward (e.g., `environment_measurements.space_id`), avoiding the
complexity and failure modes of a dual-write period entirely.

**What gets backfilled**: `logical_points.parameter_id`/`qualifier` (Phase
1), `asset_points` for real existing relationships (Phase 2), optionally
`asset_health` historical data via the existing rebuild-script precedent
(Phase 3, explicitly separate from initial rollout).

**What gets read through a compatibility view**: nothing is currently
identified as needing one — every new object is additive read/write surface,
not a replacement requiring an old-shape adapter. If Phase 4's energy
sub-phase cutover ever needed a transitional compatibility view, it would be
scoped and approved at that time, not assumed here.

**What eventually gets deprecated**: only Grafana's *customer-facing* role
(Phase 17, workflow-by-workflow, each with its own bake-in period) — no
database table, view, or procedure is deprecated by this roadmap; that
decision is explicitly out of scope and would require its own future,
separately-approved cleanup pass once every dependency is proven, per
CLAUDE.md's rule against destructive changes without explicit approval.

---

## Staging validation strategy (standard gate, every phase)

- **Schema**: migration succeeds cleanly on a fresh copy of staging;
  constraints (including new GiST exclusion constraints) validated with a
  deliberate violating-insert test; indexes valid; triggers valid
  (re-verified via `pg_trigger`/`ems_admin`, never via `information_schema.
  triggers`/`ems_readonly` alone, per the platform's own documented
  role-visibility gap); no unexpected object changes outside the migration's
  stated scope.
- **Data**: row counts before/after; `quality_code`/`is_estimated`
  distribution sanity check; historical mapping correctness (a sampled
  point-in-time join against effective-dated tables matches expected
  history); backfill counts reconciled against source; duplicate detection
  on every new unique/exclusion constraint.
- **Numerical**: old vs. new calculation outputs (where applicable — Phase 4's
  energy sub-phase, Phase 10); explicit tolerance definitions stated per
  comparison (exact-match where both paths read the same persisted table;
  a stated epsilon only where floating-point computation order could
  legitimately differ); timestamp alignment and timezone/DST behavior
  checked explicitly, reusing the platform's existing site-timezone-aware
  daily-boundary precedent as the correctness reference.
- **Performance**: representative `EXPLAIN (ANALYZE, BUFFERS)` plans for
  every new or changed query path; query latency and ingestion throughput
  measured, not assumed; continuous-aggregate/derived-tier refresh behavior
  observed under a real or simulated backlog.
- **Tenant/security**: organization isolation (a cross-org query returns
  zero rows) and site isolation re-verified per new view/function;
  asset-level permission checks exercised; an explicit unauthorized-access
  attempt against every new write path (`admin.*` function) confirmed
  rejected.
- **Failure/recovery**: missing telemetry, invalid values, delayed
  telemetry, device replacement, mapping changes, calculation failure, and
  partial aggregate inputs (`PARTIAL` quality) each exercised deliberately,
  not merely assumed to work because the mechanism is "the same as energy's."

---

## Production rollout strategy (repeatable pattern, every phase)

1. Additive migration (no rename/drop).
2. Deploy code supporting both the old and new path where both currently
   coexist (rare under this roadmap's additive-by-design approach, but
   applicable to Phase 4's eventual energy cutover).
3. Backfill only where explicitly scoped and separately approved.
4. Verify against the staging validation gate above.
5. Enable the new path behind controlled activation (`scheduled=false` →
   `true` for new jobs; a feature flag for new frontend surfaces).
6. Monitor.
7. Compare against the existing path where one exists (Phase 10/17's
   numerical parity).
8. Migrate consumers only once comparison passes.
9. Retain rollback capability throughout — no phase's rollout removes the
   ability to revert.
10. Deprecate the old path only after explicit acceptance — and, per this
    roadmap, the only "old path" ever actually deprecated is Grafana's
    customer-facing role in Phase 17; no database object is dropped by this
    roadmap without its own separate, explicit, future approval.

**No destructive schema change (rename/drop) is proposed anywhere in this
roadmap.** Any such cleanup is a later, explicitly approved pass after every
dependency is proven — consistent with CLAUDE.md's git-safety and
production-safety rules.

---

## Testing strategy (layered)

- **Unit**: calculation logic (per `ParameterCalculation`), mapping/routing
  decision logic, quality-propagation logic (worst-wins, `PARTIAL`).
- **Database contract**: constraints (including new GiST exclusions),
  tenant isolation, effective-dating correctness, relationship-type
  compatibility validation — following the existing `scripts/test/
  assert_*` convention throughout.
- **Integration**: the full pipeline, telemetry → normalization → semantic
  mapping → domain storage → aggregation → analytics, for every new domain
  onboarded.
- **Historical correctness**: sensor moves, asset replacement, point
  remapping, relationship changes — the stress test's own "G. History"
  scenarios, re-run as regression tests at every phase that touches
  effective-dated tables.
- **Numerical parity**: old vs. future energy analytics (Phase 4's energy
  sub-phase, Phase 10, Phase 17) — the highest-stakes test category in this
  roadmap, given energy's maturity and customer-facing role.
- **Performance**: representative real production-scale workloads (Phase
  16, with incremental checks throughout).
- **Frontend**: API contract tests, permission tests, empty/error/loading
  state tests, time-range/resolution tests, quality-state rendering tests.
- **End-to-end**: real EMS workflows exercised through the full stack, per
  phase, culminating in Phase 17's per-workflow acceptance process.

---

## Explicit non-goals

None of the following are part of the initial implementation, per the frozen
architecture's own change-control rule — unless a later, separately-approved
requirement changes the decision:

- A generalized polymorphic Subject model.
- A Site-level subject-binding table (`site_points`).
- `System`/`Plant`/`Zone`/`Process` as new entity types.
- A dynamic tag/asset-type-based virtual-grouping mechanism.
- `component_asset_id` on `asset_points`.
- A single universal cumulative-register-semantics table spanning energy and
  non-energy counters without the energy/non-energy split.
- Runtime dynamic SQL for telemetry routing.
- A general-purpose formula/expression DSL for derived parameters.
- Core (Foundation-stage) energy-allocation/attribution modeling.
- A rich Baseline/Anomaly/Insight schema beyond the thin derived-parameter
  reuse + narrow event log specified in Phases 13–14.
- Effective-dating on `config.parameters`/`engineering_units` themselves.
- Domain-specific entities for individual equipment types (lighting-,
  refrigeration-, or boiler-specific tables — every domain tested reuses the
  same core concepts, per the stress test).
- Premature AI/ML infrastructure ahead of Phase 14's deliberately thin
  intelligence foundation.
- Wholesale replacement of the mature energy architecture at any point in
  this roadmap.

---

## Architecture freeze rules (restated for implementation-time reference)

A proposal to add a new core entity or abstraction during implementation
must demonstrate all five of the following (identical to the frozen
architecture document's own change-control section) — otherwise, it is not
added:

1. A real EMS requirement cannot be represented cleanly with the existing
   model.
2. The requirement is not merely a legacy-compatibility problem (those
   belong in this roadmap's migration/compatibility strategy, not in the
   conceptual model).
3. The concept cannot reasonably be represented using Asset, Space, Point,
   Parameter, Relationship, or Calculation.
4. Simpler alternatives have been considered and documented.
5. The new concept has a clear lifecycle, ownership, tenant boundary, and
   analytical purpose.

A phase discovering what looks like a genuine contradiction in the frozen
model should stop, document the specific contradiction against the five
criteria above, and seek explicit architectural re-approval — it should not
quietly work around it in code, and it should not proceed on the assumption
that the contradiction is real without documenting it first.

---

## Final output

### 1. Architecture freeze summary

The EMS future-state architecture is frozen around ten concepts:
Organization/Site/Building/Floor/Space (unchanged physical hierarchy);
Asset (physical or virtual, `asset_nature`-flagged); Device (unchanged);
Point (a telemetry channel, via existing profile/device field mapping);
Parameter (canonical meaning, with `qualifier` for simultaneous-instance
readings only); AssetPoint/SpacePoint (effective-dated, exclusion-
constrained subject binding — Asset and Space are the *only* optional
subjects; Site is structural context, never a bindable subject);
AssetRelationship/AssetSpaceRelationship (typed, effective-dated,
exclusion-constrained, history-safe); domain-specific measurement storage
(energy/environment/asset_health/water, plus one narrow, promotion-governed
generic landing table); and ParameterCalculation (SELF/RELATED/AGGREGATE_
CHILDREN input resolution, versioned, quality-propagating including
`PARTIAL`). Energy accounting (`site_energy_meter_roles`) is deliberately
kept independent of physical asset topology. No formula DSL, no
polymorphic Subject, no dynamic routing SQL, no premature allocation or
insight schema.

### 2. Implementation sequence

Phase 0 (inventory) → Phase 1 + Phase 2 (semantic + subject/relationship
foundations, parallel) → Phase 3 (domain measurement, one qualifying real domain proven
by hand) → Phase 4 (routing architecture, energy migration separately gated)
→ Phase 5 (calculations, view-based) → Phase 6 (persisted derived analytics)
→ Phase 7 (API boundary) → Phase 8 (frontend foundation) → Phase 9 (core
Site/Asset/Space UX) → Phases 10–12 (energy, asset performance, real-time/
quality — independently parallel) → Phase 13 (advanced efficiency) → Phase
14 (cost/benchmarking/intelligence, thin) → Phase 15 (reporting) → Phase 16
(hardening, incrementally throughout, formally closed here) → Phase 17
(Grafana customer-workflow migration, workflow-by-workflow, indefinite
Grafana ops/engineering retention).

### 3. Critical dependencies (the handful that can actually block the program)

- **Phase 3's one-qualifying-real-domain proof** — every later automation
  phase (4, 5, 6) is sequenced *after* it specifically so nothing is built
  ahead of a proven manual example; if Phase 3 stalls (e.g., no qualifying
  real domain deployment exists to test against), the whole automation track
  stalls with it.
- **Phase 4's energy parity gate** — the one point in this roadmap where a
  mistake could regress the platform's most mature, customer-facing
  subsystem; it is the single highest-scrutiny gate in the program.
- **Phase 7's API boundary stability** — Phase 8 onward assumes it; a late
  breaking change to the view contract after frontend work begins is the
  most expensive kind of rework this roadmap can incur.
- **Phase 10's numerical-parity signoff** — the explicit precondition for
  every one of Phase 17's per-workflow migrations; without it, Grafana can
  never be safely retired for any customer-facing workflow.

### 4. Migration risks and mitigation

| Risk | Mitigation |
|---|---|
| Energy routing regresses during Phase 4's cutover | Separately-gated sub-phase, ≥2 non-energy domains proven on the generator first, mandatory `EXPLAIN`+output-diff parity gate matching migration 221's own precedent, no bundling with other work |
| Generic landing table silently becomes an unbounded EAV table | Enforced, stated promotion threshold (row volume / asset breadth), reviewed at every new-domain onboarding, not left to judgment |
| New watermark-driven jobs repeat the pre-migration-207/212 unbounded-catchup stall | Every new job (Phases 3, 6) ships bounded (`p_max_window`) and `scheduled=false` until staging-validated, from day one — never retrofitted under incident pressure |
| Frontend built ahead of a stable API contract, causing rework | Phase 8 explicitly gated on Phase 7's completion; API shape reviewed and frozen before frontend work begins in earnest |
| Effective-dating/exclusion constraints introduce a subtle historical-correctness bug | Every relationship/binding table's rollout includes the stress test's exact "History" scenarios as regression tests, not just happy-path tests |
| Baseline/insight false positives erode customer trust | Each detector/baseline ships individually behind its own approval and bake-in period (Phases 13–14), never bulk-enabled |
| Scope creep re-opens the frozen conceptual model mid-implementation | The five-criteria change-control rule applies uniformly; any proposed new entity is checked against it before any schema work begins |

### 5. Production safety rules (non-negotiable)

- No destructive schema change (rename/drop) anywhere in this roadmap;
  cleanup is a later, separately-approved pass.
- Every new job starts `scheduled=false` and is enabled only after staging
  validation, as its own explicit step.
- Energy's routing, semantics, and consumption tiers are never modified
  outside Phase 4's specifically-gated sub-phase, and never without a
  passed numerical-parity gate.
- Grafana is never removed from any customer-facing workflow without that
  workflow's individual Phase 17 acceptance and bake-in period.
- Every phase requires its own explicit approval before touching staging or
  production, per CLAUDE.md §§3–4/§11 — this roadmap is planning input to
  that approval, never a substitute for it.

### 6. Architecture change control

As stated in the frozen architecture document and restated above: a new core
entity or abstraction requires all five change-control criteria to be met,
documented, and explicitly re-approved. Absent that, the answer is: do not
add it. This applies throughout every phase of this roadmap, without
exception.

### 7. First implementation milestone

**Phase 0 (current-state analytics inventory) followed immediately by Phase
1 (semantic foundation)** — the smallest useful, lowest-risk, fully
reversible foundation: a read-only inventory establishing the regression
baseline, then a purely additive `config.parameters`/`logical_points.
parameter_id`+`qualifier` schema change with a reviewed backfill script,
touching zero ingestion code and carrying zero behavioral risk to any
existing system. Its exit criterion — resolving `logical_point → parameter +
qualifier` for real production telemetry purely from configuration — is the
first concrete, demonstrable proof that the frozen architecture works
against real data, and the natural, minimal starting point for everything
that follows.

> **Architecture conceptually frozen → implementation roadmap approved →
> implementation begins with Phase 0/1, the smallest useful foundation, not
> another architecture investigation.**

---

🤖 Generated with [Claude Code](https://claude.com/claude-code)
