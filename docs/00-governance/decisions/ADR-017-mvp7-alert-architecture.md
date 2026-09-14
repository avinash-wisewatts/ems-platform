# ADR-017: MVP-7 Alert architecture — evaluation mechanism (A1) and domain concept (B1)

Status: **Decided (architecture) and implemented** — ratified and built
2026-09-14, deployed to staging 2026-09-14. Staging post-deploy validation
performed 2026-09-14: **FAIL** (alert-evaluation TimescaleDB job not
registered; frontend detail/filtering gaps against ADR-016 decision 11/48).
A same-day corrective pass addressed the frontend gaps and a
first-registration config defect in
`postgres/jobs/238_alert_evaluation_job.sql`, and extended
`scripts/verify/verify_jobs.sh` to detect the job's registration state on
every future deployment. **The job registration step itself remains
deliberately not performed** pending separate explicit authorization — see
[07-features/alerts/README.md](../../07-features/alerts/README.md) for
current status and evidence.
Date: 2026-09-14
Decision owners: Product/Architecture (ratification of the two options
identified in this session's architecture investigation brief)
Related requirements: [ADR-016](ADR-016-q77-mvp7-basic-alerts.md) (Q77/MVP-7
product decision — this ADR resolves its two "Architecture questions
identified"); [ADR-010](ADR-010-mvp3-attention-materiality-policy.md)
(Energy Attention materiality — qualified by this ADR, not superseded);
[ADR-007](ADR-007-analytics-api-boundary.md) (Analytics API boundary,
verified compliant below)
Related architecture: [system-architecture.md](../../04-architecture/system-architecture.md);
`docs/DDS/analytics-platform-future-state-architecture.md` (formally
amended by this ADR — see "DDS amendment")

## Context

ADR-016 identified two genuine, unresolved architecture questions blocking
MVP-7 implementation and explicitly declined to guess at either:

- **Question A**: no server-side Attention/alert evaluation mechanism
  exists in any form — Attention is a stateless client-side computation.
- **Question B**: no `Alert` entity exists in the frozen DDS ten-concept
  model or anywhere in the schema.

A follow-up architecture investigation brief (this session, 2026-09-14)
inspected the repository and presented options for both, without deciding
either. **Product/Architecture has now ratified: A1 (extend the existing
TimescaleDB-native background-job mechanism) and B1 (introduce a minimal,
dedicated Alert domain concept, formally amending the DDS from 10 to 11
concepts).** This ADR records that ratification, resolves the specific
follow-on consequence the brief flagged (materiality-rule duplication risk
against [ADR-010](ADR-010-mvp3-attention-materiality-policy.md)), and
defines the resulting design in enough detail to code against — without
writing any code or schema in this pass.

## Decision

### A1 — Evaluation mechanism

**MVP-7 Attention/alert evaluation runs as a TimescaleDB-native background
job**, the same mechanism already operating `telemetry.run_environment_routing_job`
and its siblings (`postgres/jobs/42_normalization_background_job.sql`,
`48_energy_background_job.sql`, `69_environment_routing_job.sql`) — a SQL
procedure registered via `add_job`/`alter_job`, running on an interval with
native `max_runtime`, `max_retries`, `retry_period`, and `overlap` support.
**A new Python worker is explicitly not introduced** unless repository
analysis during design demonstrates A1 cannot satisfy the requirements —
per direct instruction, this is a conditional escape hatch, not a fallback
to design toward.

### A1 — Single-source-of-truth arrangement for the materiality rule

This directly resolves the consequence the brief flagged:
[ADR-010](ADR-010-mvp3-attention-materiality-policy.md) deliberately keeps
the ±15% Energy Attention rule "defined in exactly one place"
(`web/src/attention/materiality-policy.ts`) specifically so it would not
drift. A1 requires a second, independent implementation of that same rule
in SQL — this is **not** resolved by silently duplicating it. The
arrangement:

1. **A single canonical SQL function becomes the rule's new source of
   truth**: a function (name/signature to be finalized at implementation;
   working shape `analytics.evaluate_energy_attention(site_id, as_of
   timestamptz) → boolean`) that wraps the **already-existing**
   `analytics.get_portal_site_energy_typical_reference(...)` function
   (`postgres/migrations/236_analytics_api_energy_typical_reference.sql:151`)
   and applies the identical rule ADR-010 already specifies: inclusive
   both directions (`|deviation%| >= 15`), with the same `1e-9`
   (`THRESHOLD_EPSILON`) floating-point tolerance that commit `e64c1e3`
   established client-side. This function is the one place the rule's
   *logic* lives going forward for the alerting concern.
2. **The existing client-side implementation
   (`web/src/attention/materiality-policy.ts`, `energyAttention.ts`)
   remains unchanged in this pass** — it continues to drive today's shipped
   MVP-3 Attention/Site-Health display. It is not silently left to drift:
   this ADR records a **tracked follow-on requirement** (not scheduled or
   implemented here) to migrate that display to consume the server-computed
   evaluation result via the Analytics API, retiring the client-side
   recomputation once the alert-evaluation function exists — restoring true
   single-sourcing, with the server as the one canonical implementation.
3. **Until that migration lands, the two implementations' coexistence is a
   documented, deliberate, time-bounded exception, gated by a mandatory
   parity safeguard**: before the alert-evaluation job may be enabled, a
   contract/fixture test must verify the SQL function's true/false
   classification agrees with the TypeScript function's classification
   across the same class of fixtures that caught the original `e64c1e3`
   boundary defect (values mathematically exactly at ±15%, non-round
   floating-point inputs). This test is an implementation task, not
   performed in this pass, but its existence is now a **required
   precondition**, recorded here so it cannot be silently skipped.

This is the "appropriate source-of-truth/evaluation arrangement": SQL
becomes canonical for the concern that now needs it (alerting), the client
is put on an explicit (if not yet scheduled) migration path to stop
independently recomputing the rule, and the interim coexistence is
contractually verified rather than assumed to agree.

### B1 — Alert domain concept: five-criteria test, formally applied

Applying `docs/DDS/analytics-platform-future-state-architecture.md:79-97`
(restated at [04-architecture/README.md:37-45](../../04-architecture/README.md)):

1. **A real requirement not cleanly representable by the existing
   model.** ADR-016 requires an immutable, dated, stateful occurrence
   record (condition identity, context, trigger/resolution values and
   timestamps, Active/Resolved/Ended state, ended-reason, recurrence
   linkage, 90-day retention). None of the ten frozen concepts represent a
   *dated event with lifecycle state* — they represent structure
   (hierarchy, topology) or *derived values* (Parameter, ParameterCalculation).
   **Met.**
2. **Not merely legacy-compatibility.** New capability, no migration/compat
   angle. **Met, trivially.**
3. **Cannot reasonably be expressed as Asset (incl. `VIRTUAL`), Space,
   Point, Parameter, Relationship, or Calculation.** Asset/`VIRTUAL` Asset
   models equipment or composite/calculated things related via
   `SERVES`/`COMPONENT_OF`-style edges, not dated occurrences — one
   `VIRTUAL` asset per alert would have no physical or calculated-quantity
   meaning. `AssetRelationship`/`AssetSpaceRelationship` are typed,
   effective-dated M:N graphs between physical/virtual entities — they
   have no field shape for trigger/resolution values or an
   Active/Resolved/Ended state machine. `ParameterCalculation` derives a
   **value**, not a persisted, immutable historical occurrence with a
   retention window. **Met.**
4. **Simpler alternatives considered and documented.** (a) No persisted
   entity, recompute state the way Attention is computed today — rejected:
   cannot satisfy ADR-016's already-decided immutable-history/90-day-
   retention/recurrence requirements. (b) Reuse
   `telemetry.generic_point_measurements` — rejected: it is explicitly a
   point-*measurement* landing table; repurposing it for lifecycle events
   is exactly the "generalized polymorphic" pattern
   `docs/DDS/...architecture.md`'s "Explicit non-goals" section rejects.
   (c) Repurpose `analytics.insights` (Phase 14) — **explicitly rejected by
   this ratification**: Attention/Alerts and Insights remain distinct
   concepts (reaffirming [attention/README.md](../../07-features/attention/README.md)'s
   pre-existing statement), and `analytics.insights`' `severity` field
   directly conflicts with ADR-016 decision 13's explicit rejection of a
   customer-facing alert severity taxonomy. **Met.**
5. **Clear lifecycle, ownership, tenant boundary, analytical purpose.**
   ADR-016 specifies the lifecycle precisely (Active/Resolved/Ended with
   fully defined transitions); tenant boundary inherits the universal
   `organization_id NOT NULL` convention (`system-architecture.md`
   §"Organization / Site / ... — `organization_id` is `NOT NULL` and
   carried directly on every tenant-scoped row"); analytical purpose is
   explicit (notify of existing Attention conditions). **Met, strongly.**

**All five criteria are satisfied. The DDS is formally amended from ten
core concepts to eleven — see "DDS amendment" below.** Per this
ratification: **no generic event framework, no generalized Subject
abstraction, and no customer-facing alert severity taxonomy are introduced**
— `Alert` is added as its own narrow, dedicated concept, not as an
instance of a more general mechanism.

### Minimum Alert conceptual data model

Conceptual fields only — **no DDL, table name, schema placement, or
migration number is finalized here**; that is implementation work, out of
scope for this pass. Working shape, for design purposes:

- **Identity/tenant/context**: `alert_id` (surrogate, immutable);
  `organization_id` (`NOT NULL`, universal tenant-scoping convention);
  `site_id` (`NOT NULL` — MVP-7's only existing condition is Site-level;
  see "Remaining unresolved architecture questions" re: Space/Asset);
  `space_id`, `asset_id` (nullable, reserved for if/when a Space/Asset-
  level Attention condition is ever separately decided and built — **not
  populated by anything MVP-7 actually generates today**).
- **Condition identity** (ADR-016 decision 10's recurrence-identity
  requirement): a stable key over {parameter/metric, threshold/reference,
  scope/context} that changes exactly when configuration changes — this is
  what gives a configuration change "a new condition identity" and what
  recurrence-counting groups by.
- **Lifecycle**: `state` (`ACTIVE`/`RESOLVED`/`ENDED`); `triggered_at`,
  `trigger_value`; `resolved_at`, `resolved_value` (null until Resolved);
  `ended_at`, `ended_reason` (null until Ended); `last_evaluated_at`
  (bookkeeping).
- **Recurrence**: deliberately **not** stored as a separate counter —
  "previous occurrences"/"most recent" (ADR-016 decision 10) are derived by
  querying prior rows sharing the same condition identity within the
  90-day retention window at read time, avoiding a second source of truth
  for a value that is fully derivable.
- **Retention**: Resolved/Ended rows retained 90 days from
  `resolved_at`/`ended_at`, Active rows retained indefinitely while true —
  intended to reuse the platform's existing TimescaleDB retention-policy
  mechanism (already operating 23 registered retention policies per this
  session's own staging post-deploy verification), not a new bespoke
  purge mechanism.

**A companion, internal-only tracking structure is needed** to hold
in-progress 5-minute-qualification / 1-minute-resolution windows between
1-minute job runs (so the job can detect a gap and reset a timer). This is
**not** part of the customer-facing Alert concept — ADR-016 explicitly
requires no customer-visible pending state, and conflating candidate-
tracking with the customer-facing history table risks leaking
not-yet-qualified rows into retention/recurrence counting by accident.
Treated as internal job-scratch state (comparable in spirit to existing
plumbing tables like `config.profile_field_mapping`), not a second
DDS-level concept requiring its own five-criteria pass — but its exact
shape is **not finalized here**; see "Remaining unresolved architecture
questions."

### Evaluation/persistence boundary

- **One TimescaleDB job** (1-minute interval, matching the existing job
  cadence and satisfying both the 1-minute resolution and 5-minute
  qualification granularity) owns: calling the canonical evaluator
  function per site/condition; maintaining candidate-tracking state;
  applying ADR-016's qualification/resolution/configuration-change/
  restart-survival rules; writing Alert rows.
- **Persistence-failure retry (ADR-016 decision 6, up to 30 minutes)**:
  the exact interpretation against TimescaleDB's own job-level retry
  semantics (`max_retries`/`retry_period`, which govern whole-job-run
  failures, not per-occurrence persistence within a successful run) is
  **not fully resolved here** — flagged below as a remaining question.
- **Customer-facing reads go through the Analytics API** (`GET
  /api/v1/sites/{id}/alerts` list, detail by ID — exact paths/shapes an
  implementation detail), reusing the existing `_require_portal_user`/
  `organization_id`/scope-mode authorization pattern already governing
  every endpoint in `app/src/routers/analytics_api.py`. **The job's writes
  are backend-internal, not customer-facing**, exactly mirroring the
  existing precedent of `telemetry.run_environment_routing_job` writing
  directly into `telemetry.environment_measurements`, which the Analytics
  API then reads — **no [ADR-007](ADR-007-analytics-api-boundary.md)
  boundary violation**: verified.

### Tenant authorization model — verified

Alert rows carry `organization_id NOT NULL` per the universal tenant-
scoping convention; read authorization reuses the existing
`AuthenticatedPortalUser`/`access_scope_mode` pattern
(`app/src/routers/analytics_api.py:153` `_require_portal_user`) and the
existing three-role scope model
(`postgres/ddl/104_three_role_scope_model.sql`) already governing every
other site-scoped read. **No new role is introduced** — reaffirms ADR-016
decision 14. Verified compliant, subject to the Space/Asset caveat below.

## DDS amendment

`docs/DDS/analytics-platform-future-state-architecture.md` is amended,
under its own documented change-control process (§"Architecture change
control," passed above), from its stated ten core concepts to **eleven**:

- §"Architecture Status" point 3's enumeration is updated to add `Alert`,
  with an explicit amendment marker (date, this ADR) — the original
  ten-concept freeze and its stress-test evidentiary record are preserved
  unchanged, not rewritten.
- A new §B.2a ("Alert (NEW, 2026-09-14)") is added immediately after
  §B.2 Entities, in the same style as the document's own precedent for a
  later-appended correction (§B.6a), describing the conceptual shape above.
- [system-architecture.md](../../04-architecture/system-architecture.md)'s
  "What is frozen" summary is updated to match.

## Consequences

- MVP-7 now has a fully specified architecture (evaluation mechanism,
  domain model, evaluation/persistence boundary, API/authorization
  verification) to design and code against. **No code or schema exists
  yet** — nothing was changed beyond documentation in this pass.
- ADR-010 is **qualified, not superseded**: its single-point-of-definition
  principle is upheld going forward by making the new SQL function
  canonical and tracking the client's migration to consume it, rather than
  abandoning the principle.
- A new architecture gap is tracked:
  `docs/04-architecture/application-architecture.md` gains a `PA-7` entry
  (server-side Attention/alert evaluation mechanism + Alert persistence —
  now architecturally resolved at the decision level, still `MISSING` in
  code).
- `requirements-traceability.md`'s Alert blocker row is updated: the two
  architecture questions are now **decided**, not merely named; the
  capability remains `C — NOT LANDED` in code.

## Remaining unresolved architecture questions

Explicitly not resolved by this ADR — flagged, not guessed at:

1. **Candidate/pending-qualification tracking table's exact design** (fields,
   gap-detection comparison logic, cleanup) is sketched but not finalized —
   an implementation-design task.
2. **Persistence-failure retry semantics** (ADR-016 decision 6's
   30-minute, per-occurrence retry) against TimescaleDB's own job-level
   `max_retries`/`retry_period` (whole-run retry) are conceptually
   different mechanisms — how they compose is not resolved here.
3. **Space/Asset-level Attention is product-specified but not yet built —
   a sequencing dependency, not a contradiction** (reconciled 2026-09-14,
   see the dedicated reconciliation note this ADR links below). The
   original Product Owner Workshop (Q99 — MVP Space Experience, Q100 — MVP
   Asset Experience) explicitly lists Attention as part of both the Space
   and Asset experience, "where supported" by available data — this is
   genuine, established product intent, not something ADR-016 introduced.
   MVP-3's actual build (commit `19c09d7`'s message, and the "MVP-3
   Implementation Decision Pack" it cites) explicitly narrowed that MVP-3
   increment to Site-level Energy only, listing "per-space/per-asset
   Attention" as out of scope **for that increment** — the same
   narrow-first-slice pattern already applied to Demand/PQ (informational
   only, no threshold rule). ADR-016 decision 14 correctly describes the
   product's general authorization/configuration model; it does not mean
   Space/Asset alerts exist today. **MVP-7 alerts can therefore only be
   generated from the one condition that currently exists (Site-level
   Energy, ±15%) until a Space/Asset-level Attention materiality rule is
   separately built — an MVP-3-scope extension, not a new product/
   architecture decision.** See the requirements-traceability update
   below.
4. **Exact schema/migration details** (table/function/job names, migration
   number — next available is 238 as of this writing) are implementation
   decisions, deliberately not made here.
5. **No timeline or owner is set** for the MVP-3 client-migration follow-on
   task (§"A1 — Single-source-of-truth arrangement," item 2) — tracked,
   not scheduled.

## Rationale

Not independently stated beyond the reasoning inline above — this ADR
documents a ratification of options this session's own investigation
brief presented; no additional undocumented rationale exists.

## Alternatives considered

See "A1 — Evaluation mechanism" (Python worker, rejected per explicit
instruction unless A1 proves insufficient) and "B1 — Alert domain concept"
criterion 4 (three alternatives to a new entity, each rejected with
reasoning) above.

## Evidence / references

- This session's architecture investigation brief (2026-09-14) — options
  A1/A2 and B1/B2/B3, now ratified as A1+B1.
- `postgres/jobs/42_normalization_background_job.sql`,
  `48_energy_background_job.sql`, `69_environment_routing_job.sql` (the
  extended mechanism).
- `postgres/migrations/236_analytics_api_energy_typical_reference.sql:151`
  (`analytics.get_portal_site_energy_typical_reference`, reused by the new
  canonical evaluator function).
- [ADR-010](ADR-010-mvp3-attention-materiality-policy.md) (the rule being
  safeguarded against drift, including the `e64c1e3` epsilon fix).
- `docs/DDS/analytics-platform-future-state-architecture.md:79-97`
  (five-criteria test text), `:30-58` (Architecture Status, amended),
  `:333-402` (§B.2 Entities style, followed for §B.2a).
- `docs/DDS/analytics-platform-future-state-architecture-implementation-roadmap.md:620-646`
  (`analytics.insights`, Phase 14 — considered and rejected as a reuse
  target).
- `app/src/routers/analytics_api.py:153` (`_require_portal_user`
  authorization pattern reused); `postgres/ddl/104_three_role_scope_model.sql`
  (three-role scope model reused).
- `docs/04-architecture/README.md:37-45` (change-control restatement);
  `docs/04-architecture/application-architecture.md:111-125` (PA-1..PA-6,
  gaining `PA-7`).

## Implementation references

`postgres/migrations/238_mvp7_alert_evaluation.sql` (schema),
`postgres/migrations/239_mvp7_alert_evaluation_functions.sql` (evaluator,
lifecycle procedure, job wrapper, read functions),
`postgres/jobs/238_alert_evaluation_job.sql` (job registration),
`app/src/analytics_api_service.py` / `app/src/routers/analytics_api.py`
(Analytics API), `web/src/api/types.ts` / `endpoints.ts`,
`web/src/routes/alerts/AlertsArea.tsx`,
`web/src/alerts/useActiveAlertCount.ts`, `web/src/router.tsx`,
`web/src/layout/navigation.ts` / `AppLayout.tsx`.

## Validation references

Backend: `app/tests/test_analytics_api_v1_alerts_routes.py` (9 tests, API
contract), `app/tests/test_alert_evaluation_contract.py` (16 tests, static
SQL contract). Frontend: `web/src/routes/alerts/AlertsArea.test.tsx` (6
tests) + updated `navigation.test.ts`; full frontend suite, `tsc --noEmit`,
`eslint --max-warnings 0`, and `vite build` all pass. **Not performed**:
the executable cross-language parity test between the SQL materiality
function and the TypeScript implementation this ADR names as a required
precondition (§"A1 — Single-source-of-truth arrangement," item 3) — only
static/structural checks exist; see this session's implementation report
and `docs/07-features/alerts/README.md` "Known limitations." No live
TimescaleDB instance was available locally to execute the SQL migrations
themselves — relies on the CI database/migration integration job.
