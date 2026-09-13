# MVP-4 Implementation/Product Decision Pack — Data Quality & Freshness

Status: DRAFT — device-level scope approved; semantic model decided (§5); aggregation model decided (§5a); minor content/API-shape questions remain (see §15)
Date: 2026-09-13 · Owner: Product + Engineering
Related roadmap: [../../01-product/roadmap.md](../../01-product/roadmap.md) (MVP-4)
Related ADRs: [ADR-007](../decisions/ADR-007-analytics-api-boundary.md), [ADR-008](../decisions/ADR-008-grafana-ops-role.md), [ADR-011](../decisions/ADR-011-insufficient-data-not-healthy.md)
Related features: [Demand](../../07-features/demand/README.md), [Power Quality](../../07-features/power-quality/README.md), [Attention](../../07-features/attention/README.md)

> This pack exists to close the evidence gap already flagged twice in this
> repository — [ADR-009](../decisions/ADR-009-slice-c-historical-reference-methodology.md)
> and [ADR-010](../decisions/ADR-010-mvp3-attention-materiality-policy.md) both
> cite a "decision pack" as their approval source, and neither pack exists as
> a file. This one does. It is a genuine architecture/product input, not a
> record of a decision already fully made — several implementation-relevant
> questions surfaced during its writing remain open (§13) and are not
> resolved here.

## Product decision (closed, not reopened here)

Approved 2026-09-13: MVP-4 proceeds on the **device-level freshness scope**.
`telemetry.device_telemetry_state` is the source of truth for device/
telemetry freshness. Row-level `quality_code`/`quality_status` semantics on
energy/demand aggregate tables are explicitly **not** introduced as part of
MVP-4. This scope choice is closed and is not reopened by anything found
below — the findings in this pack narrow *how* the device-level scope should
be implemented, they do not challenge *that* it is the right scope.

---

## 1. Objective

Answer the customer question "can I trust this number, and if not, why?" —
on the screens the customer already has (Site Overview, Energy, Demand,
Power Quality) — using freshness/connectivity state that already exists in
the platform, without inventing a new quality mechanism or touching the
telemetry pipeline (Phase 6).

## 2. Current state

**Documented fact.** MVP-1 (hierarchy), MVP-2 (Energy/Demand/PQ analytics),
and MVP-3 (Site Overview + Energy Attention) are DONE as of commit `ddbe5a4`
on `origin/staging` (roadmap.md; [staging-validation.md](../../08-verification/staging-validation.md)).
MVP-3's own staging validation record found the **Insufficient Data** state
triggering more often than Healthy/Needs Attention on real staging data,
because Slice C's typical-reference comparison needs historical depth
staging does not yet have. Customers hitting that state today have no way
to distinguish "too early to compare" from "a device is actually offline"
from "the number is otherwise degraded" — this is the specific gap MVP-4
closes.

**Implementation fact — the trust-signal picture per domain is uneven, not uniform:**

| Domain | What exists today | Evidence |
|---|---|---|
| Space measurements | `quality_code` column exists and flows through the API (`fetch_space_measurement_series` returns `quality_code`) | `app/src/analytics_api_service.py:552` |
| Energy | A distinct "evidence" mechanism (Slice C coverage: how many historical periods were eligible) — explicitly **not** the same thing as a per-reading quality lattice | `EnergyOverview.tsx` (comment, line ~35): "not forced through QualityIndicator's unrelated five-value lattice" |
| Demand | Already has `quality_status` (`VALID`/`PROVISIONAL`/`INCOMPLETE`/`NO_DATA`/`INVALID_SOURCE`/`INSUFFICIENT_SOURCE_RESOLUTION`) and `coverage_percent`, already returned by the API and already rendered — **as plain text**, explicitly not run through the `QualityIndicator` component | `postgres/ddl/132_demand_calculation_processor.sql:97,604`; `app/src/analytics_api_service.py` (`fetch_site_current_demand`, `build_current_demand_response`); `DemandOverview.tsx` line 16: "quality_status, shown as plain text. NOT a [lattice mapping]" |
| Power Quality | **Nothing.** The underlying telemetry table carries no quality/freshness column at all; the screen says so explicitly | `PowerQualityOverview.tsx` lines 17–18, 164: "telemetry.ca_energy_* carries no quality/freshness column; nothing is fabricated"; "Data quality / freshness indicators are not yet available for power quality." |
| Device connectivity/freshness | Exists (`telemetry.device_telemetry_state`), but is consumed **only** by a Grafana-org-scoped, asset-dashboard function today — never by the customer-facing Analytics API or EMS Web | `postgres/ddl/138_asset_dashboard_consolidated_read_path_fix.sql` (`analytics.get_grafana_asset_telemetry_context`) |
| `QualityIndicator` (frontend) | Built, renders exactly the five-value lattice (`GOOD`/`GAP`/`ESTIMATED`/`INVALID`/`PARTIAL`) — but its own code comment states the numeric→label mapping (`QUALITY_CODE_LABELS`) is **currently empty**; no code value has real meaning yet even for space measurements | `web/src/components/QualityIndicator.tsx` (full file, on `origin/staging`) |

**Conclusion carried into §5/§13**: there is no single existing "quality
system" MVP-4 slots into. There are at least three independent,
non-unified vocabularies already live in the codebase (the five-value
customer lattice, Demand's six-value calculation-provenance status, and the
unexposed six-value device-connectivity state), plus one domain (Power
Quality) with nothing at all. This is a documented-vs-implementation
distinction worth stating plainly: the roadmap's MVP-4 description reads as
if a single "freshness state" concept just needs wiring to more screens;
the implementation shows three different concepts under adjacent names.

## 3. Customer outcome

After MVP-4, on Site Overview, Energy, Demand, and Power Quality, a customer
can see — next to the number they're looking at — whether the underlying
device is currently communicating normally, and if not, a plain-language
reason (never offline vs. gone quiet vs. reporting stale/invalid values vs.
no device assigned). This does not replace or reinterpret Demand's existing
`quality_status`/`coverage_percent` display — it adds a second, distinct
signal (is the *device* healthy) alongside it, and is the first quality
signal Power Quality has ever had.

## 4. Scope

**In scope:**
- Expose `telemetry.device_telemetry_state`-derived connectivity state
  through a new, narrow, read-only Analytics API extension.
- Surface it via the existing `QualityIndicator` component (or a sibling
  component using the same visual system) on Site Overview, Energy, Demand,
  and Power Quality.
- Site-level rollup: resolve "which device feeds this figure" per-domain,
  per the metric-specific dependency model in §5a — `SITE_CONSUMPTION`-role
  lookup for Power Quality and Energy, `site_demand_source_role` lookup for
  `SITE`-scope Demand — using only existing config tables
  (`config.site_energy_meter_roles`, `config.site_demand_policies`). No new
  attribution mechanism. Where a domain's device set is not resolvable
  today (Energy without a `SITE_CONSUMPTION` meter; `ASSET`-scope Demand),
  freshness reports `UNKNOWN`, per §5a — not a fabricated aggregation.
- No single blended "Site is fresh" verdict — Energy, Demand, and PQ each
  carry their own freshness signal on Site Overview, per §5a.

**Not in scope (per the approved decision, restated for precision):**
- No `quality_code`/`quality_status`-style column added to
  `telemetry.energy_measurements`, `analytics.demand_intervals`, or any
  other aggregate table.
- No change to Demand's existing `quality_status`/`coverage_percent`
  mechanism — it stays exactly as built.
- No new quality vocabulary invented for Power Quality's missing column —
  Power Quality gets the *device*-level signal only, not a fabricated
  reading-level one.

## 5. Quality semantics — RESOLVED 2026-09-13

**Decision: Measurement quality and Data freshness are two distinct,
coexisting customer-facing signals. Device connectivity/freshness state is
NOT mapped into, or expressed through, the existing five-value
`GOOD`/`GAP`/`ESTIMATED`/`INVALID`/`PARTIAL` lattice.**

This closes the semantic-model question left open at first writing (below,
retained as the analysis record). The full option analysis and product-
question walkthrough live in a follow-up product/design review dated
2026-09-13 (session record; not a separate committed file) — summarized
here as the evidence this decision rests on.

**Why not map into the existing lattice (rejected — Option A):**

`telemetry.device_telemetry_state` (via `analytics.get_grafana_asset_telemetry_context`,
`postgres/ddl/138_asset_dashboard_consolidated_read_path_fix.sql`, the
`v_state := CASE …` block) produces a six-value vocabulary —
`NEVER_SEEN`/`SILENT`/`RECEIVING`/`STALE`/`VALIDATED`/`NO_ASSIGNED_DEVICE` —
that does not map cleanly onto the five-value lattice:

- Only `VALIDATED` (→`GOOD`) and `NO_ASSIGNED_DEVICE`/`NEVER_SEEN`
  (→ the existing "unknown/not reported" state) have a defensible
  correspondence.
- `STALE` and `SILENT` have no honest lattice home. `GAP` is a
  **per-interval, historical** concept (this bucket has no value); `STALE`/
  `SILENT` are **current-moment connectivity** concepts (the meter hasn't
  been heard from recently, right now). Collapsing them together loses a
  distinction a customer would act on differently.
- Mapping `SILENT` (no data received at all) to `INVALID` would overload a
  label that means "a value was received and failed validation" everywhere
  else the lattice is used or will be used (space measurements today;
  energy/PQ readings once populated) — a genuine semantic conflict, not a
  stylistic one.
- Power Quality has no reading-level quality concept to map *from* in the
  first place — "mapping device state into PQ's lattice" would mean
  fabricating a reading-quality claim PQ has never made, which the
  existing `PowerQualityOverview.tsx` code explicitly refuses to do
  ("nothing is fabricated").
- Demand already has its own calculation-provenance vocabulary
  (`quality_status` — see §2); routing device state through the customer
  lattice as well would put three overlapping "quality" signals on one
  screen, one of which (the lattice mapping) is a lossy proxy for
  information `quality_status` already partially expresses.
- Future risk: the roadmap plans to populate real `quality_code` values for
  energy/space readings later. Reusing `INVALID`/`GAP`/`PARTIAL` to also
  mean "device offline" now creates semantic debt that future work would
  have to unwind.

**Why a separate signal works (adopted — Option B / hybrid):**

- The codebase already keeps purpose-specific "trust" signals separate
  rather than forcing them through one shared vocabulary — Demand's
  `quality_status`, Energy's own per-item `dataQuality` evidence object
  (`coveragePercent`/`gapIntervalCount`/`resetIntervalCount`/
  `rolloverIntervalCount`/`invalidIntervalCount` — `web/src/attention/types.ts`)
  are already independent of `QualityIndicator`'s lattice. A separate
  freshness signal is consistent with, not a departure from, that pattern.
- It works uniformly across Energy, Demand, and Power Quality because it
  describes the *meter*, not the *metric* — unlike Option A, it needs no
  domain-specific justification for what a "lattice value" derived from
  device state would even mean in a domain (PQ) with no reading-level
  quality concept at all.
- It gives Power Quality its first-ever trust signal without fabricating a
  reading-level quality value it doesn't have.
- `QualityIndicator.tsx` is unchanged — it keeps rendering exactly the
  lattice its own header comment documents; freshness is carried by a
  separate, honestly-named component or a documented variant, never a
  repurposed lattice value.

**Customer framing (label wording deferred, not decided here — see
§13 Q2/MVP-5 note)**: the signal must be expressed as a customer concept —
answering "is this current / can we hear from your meter right now" — never
as literal device/gateway/point terminology (per ADR-001's "no raw
telemetry terminology" principle). The six raw states collapse to a smaller
customer-legible set; exact wording is a content decision, not a semantic-
model one.

**Relationship to Site Health and Energy Attention**: freshness is
**informational only** in MVP-4. It does not feed `deriveSiteHealth`'s
boolean gate (`web/src/attention/siteHealth.ts`) and is not a materiality
input to Energy Attention (`energyAttention.ts`). `siteHealth.ts`'s own
header comment states that combining multiple signals into one Health
verdict is "itself an undecided product question" that the function
"deliberately does not invent an aggregation rule for" — extending that
aggregation now, as part of introducing freshness, would be exactly the
kind of silent invention the existing code avoids. Site Health's
`INSUFFICIENT_DATA` state already indirectly reflects a dead meter (no
telemetry → no coverage → insufficient data); freshness explains that
state's cause without changing what triggers it.

## 5a. Device aggregation model — RESOLVED 2026-09-13

**Decision: metric-specific dependency.** Each of Energy, Demand, and Power
Quality resolves its own contributing device(s) through its own existing
(or partially existing) mechanism. There is no single generic
multi-device aggregation rule applied uniformly, and no blended
"Site is fresh" verdict on Site Overview — each section carries its own
freshness signal.

**Implementation fact — the three domains do not share one device-resolution
path today:**

| Domain | Read-path source | Device attribution at read time |
|---|---|---|
| Power Quality | `analytics.get_portal_site_power_quality_series` (`postgres/migrations/234_analytics_api_power_quality.sql`) | **Resolved at read time** via `config.site_energy_meter_roles WHERE meter_role = 'SITE_CONSUMPTION' AND is_active` — exactly one device, deterministically (`SITE_CONSUMPTION` is `is_exclusive_per_site = TRUE`, migration 100). No device configured → zero rows today, not an error. |
| Energy consumption | `analytics.get_portal_site_energy_consumption` (`postgres/migrations/231_analytics_api_query_boundary.sql`) | Reads pre-aggregated `analytics.energy_consumption_hourly/daily`. No `device_id`, no meter-role join anywhere in this function — device attribution happened further upstream and **is not visible from the portal read path**. |
| Demand | `analytics.get_portal_site_demand_series`/`get_portal_site_current_demand` (`postgres/migrations/233_analytics_api_demand.sql`) | Reads pre-aggregated `analytics.demand_intervals`/`demand_state` (`scope_type = 'SITE'`). The migration's own comment: "this migration does not repeat [meter-role resolution] — that resolution already ran upstream." For `SITE`-scope demand policies, a single device *is* derivable via `config.site_demand_policies.site_demand_source_role → config.site_energy_roles.role_code → config.site_energy_meter_roles` (`postgres/ddl/130_site_demand_policy_contract.sql`) — an existing, joinable relationship, just not one any current function performs. For `ASSET`-scope policies (the system-default fallback backfilled per-site — see `postgres/ddl/138_asset_dashboard_consolidated_read_path_fix.sql`'s migration-019 backfill), the site figure may aggregate multiple per-asset devices, and **no existing read path exposes that decomposition.** |

**Per-domain resolution for MVP-4:**
- **Power Quality**: exact — read `device_telemetry_state` for the
  `SITE_CONSUMPTION`-role device. No aggregation needed; this is the one
  domain the read layer already resolves to a single device.
- **Energy**: approximate via the same `SITE_CONSUMPTION`-role lookup PQ
  already performs (reasonable, since `SITE_CONSUMPTION` is documented as
  "the authoritative directly measured total site consumption," and
  migration 234 already proved the join is cheap and correct). Where no
  `SITE_CONSUMPTION` device is configured for a site (an equation-based,
  multi-meter site), Energy freshness returns **`UNKNOWN`/`can_assess:
  false`** — an honest gap, not a guess.
- **Demand**: exact for `SITE`-scope demand policies (resolve via
  `site_demand_policies.site_demand_source_role`, as above). **`UNKNOWN`/
  `can_assess: false` for `ASSET`-scope policies** — the decomposition to
  per-asset devices is not implemented anywhere today, and inventing one
  here would fabricate a relationship the repository doesn't establish.
- **Site Overview**: **no single blended freshness verdict.** Each of
  Energy/Demand/PQ's own freshness (or `UNKNOWN`) is shown in its own
  section, exactly because they resolve through genuinely different (or
  differently incomplete) device paths — blending them would either hide a
  perfectly good PQ signal behind Energy's read-layer gap, or fabricate
  confidence a blended number doesn't have.

**Multi-device case (worst-state-wins) — deferred, not needed today.** None
of the three domains currently exposes a *visible, multi-valued* device set
at the read layer to aggregate over — PQ is single-device by construction;
Energy's and ASSET-scope Demand's multi-device cases are exactly the cases
where the read layer currently has *no visibility at all* (→ `UNKNOWN`), not
a mixed fresh/stale set to combine. **If a future change makes such a set
visible** (e.g. new engineering resolves the ASSET-scope Demand
decomposition, or Energy's equation-based fallback is made read-visible),
the rule to apply then is worst-state-wins (if any contributing device is
stale, the aggregate is stale) — chosen in advance here so that future work
doesn't have to re-litigate the customer-trust question: the customer must
never see `FRESH` while an authoritative source is actually stale, and
worst-state is the only one of the models considered (worst-state,
best-state, majority, coverage-based, metric-specific) that structurally
guarantees this.

**Threshold reconfirmation**: `config.telemetry_availability_policy`
(`receiving=300s/stale=900s/silent=3600s`, single `DEFAULT` policy row,
`postgres/ddl/98_telemetry_availability_validation.sql`) — reconfirmed with
no new contrary evidence. Reuse as-is for MVP-4, per §6 below.

## 6. Source of truth — `telemetry.device_telemetry_state`, verified

**Implementation fact**, read directly from `postgres/ddl/122_telemetry_pipeline_performance_state.sql`
(identical definition duplicated at `postgres/migrations/003_telemetry_pipeline_performance_state.sql`):

```sql
CREATE TABLE IF NOT EXISTS telemetry.device_telemetry_state
(
    device_id UUID PRIMARY KEY,
    latest_source_timestamp TIMESTAMPTZ,
    latest_received_timestamp TIMESTAMPTZ,
    latest_valid_source_timestamp TIMESTAMPTZ,
    latest_valid_received_timestamp TIMESTAMPTZ,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
```

One row per device (not per point, not per site). Table comment: "Compact
persistent latest telemetry state per device. Used by admin inventory,
device workspace and gateway connectivity without history scans." Grants:
`SELECT` to `ems_readonly, grafana_reader`; `SELECT/INSERT/UPDATE` to
`ems_admin` — **no grant to any Analytics-API-facing role exists today**;
a new grant or a `SECURITY DEFINER` function (the existing pattern) is
required before the Analytics API can read it.

The only place today that turns these raw timestamps into a customer-facing
state label is `analytics.get_grafana_asset_telemetry_context()`
(`postgres/ddl/138_asset_dashboard_consolidated_read_path_fix.sql`), which:
- takes `p_grafana_org_id BIGINT` (a **Grafana** organization identifier,
  not the Analytics API's tenant model — see §7),
- is asset-scoped (`p_asset_id`), not site- or device-scoped directly,
- computes state via configurable thresholds from
  `config.telemetry_availability_policy` (receiving/stale/silent seconds),
  not fixed constants.

**Documented-vs-implementation note**: no canonical doc under `docs/`
describes this table on `origin/staging` today (the `docs/06-platform/`
path cited by this repository's own cross-references does not exist on
`origin/staging` — it exists only in this local documentation-reorganization
branch, which has not yet merged). The description above is sourced
directly from the DDL, not from a doc, per this pack's source-discipline
requirement.

## 7. API boundary

Per [ADR-007](../decisions/ADR-007-analytics-api-boundary.md), any new
capability must be **additive** to the existing Phase 7 `GET /api/v1/*`
boundary, server-side-authorized, and follow the existing pattern rather
than invent a parallel mechanism.

**Implementation fact — the existing pattern to follow**: every current
Analytics API read (`fetch_site_energy_consumption`,
`fetch_site_demand_series`, `fetch_site_power_quality_series`, etc., in
`app/src/analytics_api_service.py`) is scoped by `portal_user_id` +
`site_id`, backed by a `SECURITY DEFINER` `analytics.get_portal_site_*`
function that itself calls `portal_user_can_access_site`/
`portal_user_can_access_space` for tenant enforcement. This is a
**different tenant model** from `get_grafana_asset_telemetry_context`'s
`p_grafana_org_id` parameter.

**Conclusion**: MVP-4 cannot simply expose the existing Grafana-facing
function through the API. It needs a **new, additive**
`analytics.get_portal_site_telemetry_freshness(portal_user_id, site_id, …)`
-style function (naming illustrative, not prescriptive), following the same
tenant-check pattern as every other Phase 7 read, joining
`config.site_energy_meter_roles` (site → device) to
`telemetry.device_telemetry_state` (device → freshness). This is additive —
no existing function or endpoint changes — consistent with ADR-007's "no
change to the existing Phase 7 contract" rule. No new API is required in
the sense of a new boundary; one new endpoint under the existing boundary
is required.

## 8. UX impact (description only — no redesign)

- **Site Overview**: a freshness indicator near the site-level summary,
  reflecting the worst state among the site's attributed meter device(s).
  Must not contradict [ADR-011](../decisions/ADR-011-insufficient-data-not-healthy.md) —
  a stale/unassigned device must never be capable of reading as, or
  alongside, a "Healthy" claim.
- **Energy**: freshness indicator alongside the existing Slice C evidence
  section — additive, not a replacement for the evidence/coverage display
  that already exists there.
- **Demand**: freshness indicator placed **next to**, not instead of, the
  existing `quality_status`/`coverage_percent` plain-text display — the two
  signals answer different questions (is the *calculation* valid vs. is the
  *device* communicating) and both should remain visible.
- **Power Quality**: freshness indicator becomes the **first** trust signal
  this screen has ever had — currently it has an explicit "not yet
  available" message that would need to change to reflect the new device
  status while still being honest that no per-reading PQ quality exists.

## 9. Data-flow / architecture impact

**Existing data path** (all already live, no proposed change):

```
device telemetry ingestion (Phase 6, MQTT/Telegraf → normalized_points)
        │
        ▼
telemetry.device_point_state / telemetry.device_telemetry_state
        │ (compact latest-state upsert, written by the ingestion/normalization
        │  pipeline itself — see postgres/ddl/122_telemetry_pipeline_performance_state.sql,
        │  postgres/ddl/126/127/128/129_*.sql)
        ▼
analytics.get_grafana_asset_telemetry_context()   ← today's only consumer, Grafana-scoped
```

**Proposed addition** (net-new, additive, no existing node changed):

```
config.site_energy_meter_roles (site_id → device_id, already live)
        │
        ▼
[NEW] analytics.get_portal_site_telemetry_freshness(portal_user_id, site_id, …)
        │  SECURITY DEFINER, portal_user_can_access_site-gated — mirrors
        │  the existing Phase 7 function pattern, not the Grafana pattern
        ▼
[NEW] GET /api/v1/sites/{site_id}/telemetry-freshness  (or embedded in existing
        site/energy/demand/power-quality responses — an API-design choice,
        not resolved here)
        ▼
EMS Web: QualityIndicator (or a new sibling component) on Site Overview /
        Energy / Demand / Power Quality
```

**Confirms**: the narrow scope genuinely avoids Phase 6 changes. Every
table and write path involved (`device_telemetry_state`,
`site_energy_meter_roles`) already exists and is already populated by the
existing pipeline; MVP-4 only reads them. No migration is required to
create tables — the only possible schema-adjacent step is a `GRANT` (or a
`SECURITY DEFINER` function, which does not require a grant to the calling
role) to let the Analytics API's role reach `device_telemetry_state`, which
is a permissions change, not a structural one.

## 10. Acceptance criteria

A staging scenario, mirroring the exit criterion already written into
[DDS Phase 12](../../DDS/analytics-platform-future-state-architecture-implementation-roadmap.md)
("an operator can diagnose a stale/failed device from the new frontend
alone"):

- **Healthy/fresh state**: a device with recent valid telemetry shows the
  "communicating normally" state on every screen that surfaces it for that
  site.
- **Stale/degraded state**: a device deliberately held past
  `config.telemetry_availability_policy`'s stale/silent thresholds shows
  the corresponding degraded state, and the change is visible within one
  refresh cycle of the underlying state table updating.
- **Missing/unknown state**: a site with no device assigned to the relevant
  meter role (`NO_ASSIGNED_DEVICE`) renders a distinct "not configured"
  presentation, never silently blank and never merged into "Healthy."
- **Tenancy isolation**: a portal user for tenant A cannot retrieve
  freshness state for a device belonging to tenant B's site, verified the
  same way existing Phase 7 tenancy tests verify `portal_user_can_access_site`
  denial.
- **API authorization**: an unauthenticated or session-invalid request to
  the new endpoint returns the same flat error envelope Phase 7 already
  uses, not a stack trace or raw DB error.
- **Partial availability/failure behavior**: if the freshness lookup fails
  or times out, the host screen (Energy/Demand/PQ/Site Overview) still
  renders its primary data — freshness is additive UI, not a hard
  dependency of the page.
- **No misleading Healthy claim**: consistent with ADR-011, a site whose
  attributed device cannot be assessed (unknown/no device) must never
  present as equivalent to a confirmed-fresh state anywhere it appears,
  including Site Overview's health summary.

## 11. Explicit non-goals

Restated from the approved scope, unchanged by this pack's findings:
- No dedicated connectivity/operations diagnostic screen.
- No Phase 6 telemetry/pipeline change.
- No schema change to energy/demand aggregate tables to add row-level
  quality.
- No new quality *lattice* value and no reuse of `GOOD`/`GAP`/`ESTIMATED`/
  `INVALID`/`PARTIAL` to mean device connectivity — resolved in §5. The
  freshness signal is its own small, separate vocabulary, not a sixth or
  seventh lattice value.
- No change to `deriveSiteHealth`'s aggregation logic and no new Energy/
  Demand/PQ Attention materiality rule — freshness is informational only
  in MVP-4 (§5).
- No AI/ML/anomaly scoring, no recommendations, no predictive/adaptive
  baselines.
- No change to Demand's existing `quality_status`/`coverage_percent`
  behavior.

## 12. Dependencies and risks

**Real dependencies:**
- A new `SECURITY DEFINER` function and a new (or extended) Phase 7
  endpoint — engineering work, not yet built.
- Product sign-off on the semantics question in §13 (Open Question 1)
  before that endpoint's response shape can be finalized.
- `config.telemetry_availability_policy`'s existing thresholds
  (receiving/stale/silent seconds) become customer-visible for the first
  time via this feature — worth confirming they were tuned with an ops
  audience in mind, not a customer one, before they drive customer-facing
  language.

**Risks:**
- Scope drift back toward row-level quality if the six-state device signal
  is perceived as "not good enough" once seen next to Demand's already
  richer `quality_status` — the approved scope should be reaffirmed if this
  pressure appears during implementation, not resolved by silently
  expanding scope.
- Two visibly different "quality" idioms on the same Demand screen
  (existing plain-text `quality_status` and a new styled device-freshness
  indicator) could read as inconsistent to a customer if not given brief,
  deliberate copy differentiating "is this calculation valid" from "is the
  device communicating" — a design/content question, not an engineering one.

## 13. Open questions

Only questions that genuinely block implementation. The device-level vs.
row-level scope decision is **closed** and is not listed here.
**Semantics mapping (formerly Open Question 1) is now CLOSED — see §5:**
freshness is a separate signal, never mapped into the five-value lattice.
**Device aggregation model (formerly Open Question — see §5a) is now
CLOSED:** metric-specific dependency, per-domain resolution, `UNKNOWN`
where not resolvable, no blended Site Overview verdict. **Threshold
reuse (formerly Condition 2) is now CLOSED — see §5a/§6:** reuse
`config.telemetry_availability_policy`'s existing `DEFAULT` values as-is.

Remaining, non-blocking-to-close-but-worth-resolving-before-build:

1. **Customer label set**: the six raw connectivity states collapse to a
   smaller customer-legible set (illustratively: fresh/receiving, stale, no
   recent data, unavailable) — the exact collapsing and wording is a
   content decision (naturally MVP-5 — Content & Metric Grammar — territory),
   not a semantic-model question. Needs an owner, not urgently a blocker.
2. **Response shape**: does freshness ship as a new standalone endpoint
   (`GET /api/v1/sites/{id}/telemetry-freshness`) or as an added field on
   the existing Energy/Demand/Power-Quality/Site-Overview-composing
   endpoints? Either is consistent with ADR-007; this is an API-design
   choice for whoever writes the endpoint, not a product question — flagged
   so it isn't decided implicitly by whichever engineer starts first.
3. **`site_demand_policies` scope-column verification**: §5a traced the
   `SITE`-vs-`ASSET`-scope distinction through the migration-019 backfill
   and `130_site_demand_policy_contract.sql`, but did not exhaustively
   audit every migration touching that table. Whoever implements the
   Demand-freshness resolution should verify the exact current
   scope-column/value at that time — an implementation-time verification
   step, not a product ambiguity.
4. **Future aggregation (explicitly deferred, not decided now)**: whether a
   later milestone should let freshness feed `deriveSiteHealth` or a
   Demand/PQ Attention rule. §5 deliberately leaves this undecided,
   mirroring `siteHealth.ts`'s own stated position — noted here only so it
   isn't quietly assumed either way later.

## 14. Traceability

- **Roadmap**: [../../01-product/roadmap.md](../../01-product/roadmap.md), MVP-4.
- **Requirements**: EMS-REQ-073 (customer-facing connectivity/freshness
  view), Q59/Q60 (evidence and trust), Q81 (freshness visible), Q93
  (customer-friendly errors) — [functional-requirements.md](../../02-requirements/functional-requirements.md),
  [requirements-traceability.md](../../02-requirements/requirements-traceability.md) (Q81: "`quality_code` exists for space measurements only").
- **ADRs**: [ADR-007](../decisions/ADR-007-analytics-api-boundary.md) (API
  boundary/pattern this must follow), [ADR-008](../decisions/ADR-008-grafana-ops-role.md)
  (why the existing consumer of this data is Grafana-scoped, and why that
  doesn't transfer directly), [ADR-011](../decisions/ADR-011-insufficient-data-not-healthy.md)
  (a stale/unknown device must never present as Healthy).
- **DDS**: [Phase 12 — Real-Time and Data Quality](../../DDS/analytics-platform-future-state-architecture-implementation-roadmap.md)
  ("no new health-tracking mechanism invented," "Migration strategy: N/A").
- **Existing implementation referenced**: `web/src/components/QualityIndicator.tsx`;
  `postgres/ddl/122_telemetry_pipeline_performance_state.sql` (table);
  `postgres/ddl/138_asset_dashboard_consolidated_read_path_fix.sql`
  (`analytics.get_grafana_asset_telemetry_context`); `postgres/ddl/100_site_energy_role_administration.sql`
  (`config.site_energy_meter_roles`); `postgres/ddl/132_demand_calculation_processor.sql`
  (Demand's `quality_status`); `app/src/analytics_api_service.py` (Phase 7
  tenant pattern); `web/src/routes/demand/DemandOverview.tsx`,
  `web/src/routes/power-quality/PowerQualityOverview.tsx`,
  `web/src/routes/energy/EnergyOverview.tsx`, `web/src/routes/SiteOverview.tsx`
  (all on `origin/staging`, commit `ddbe5a4`).
- **Validation**: staging scenario in §10, mirroring
  [staging-validation.md](../../08-verification/staging-validation.md)'s
  existing pattern.

## 15. Implementation readiness

**IMPLEMENTATION READY.** Both semantic questions that could have changed
the frontend/API shape mid-implementation are now resolved with evidence,
not assumption: the quality-vs-freshness semantic model (§5) and the
device aggregation model (§5a, including the threshold-reuse
confirmation). The approved device-level scope is architecturally sound
and confirmed low-risk (§9: no Phase 6 change, no new tables, no
migration). What remains open (§13: customer label wording, response-shape
choice, the `site_demand_policies` scope-column verification) are
implementation-detail and content decisions for whoever builds each piece,
not product-semantics decisions requiring a further stop. Engineering
tickets may be opened; assign §13 Q1 (label wording) to whoever owns
MVP-5-style content work, in parallel with the API/frontend build (§13 Q2)
and the scope-column check (§13 Q3).
