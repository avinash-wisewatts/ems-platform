# EMS Analytics Platform — Future-State Architecture Red-Team Review

```
Status: REVIEW — red-team of docs/DDS/analytics-platform-future-state-architecture.md
Prepared: 2026-09-07
Verification basis: docs/platform-manual/*, the original proposal document
(unchanged, not modified by this review), and targeted re-verification of
postgres/ddl/* for tables the original proposal did not account for
(config.site_energy_meter_roles, config.energy_register_semantics,
config.interval_quality_rules, metadata.sectors/sub_sectors, config.site_sectors).
No database, migration, application, or Grafana change was made to produce
this document.
```

This document red-teams `docs/DDS/analytics-platform-future-state-architecture.md`
(the "original proposal," left unmodified). It does not repeat the original's
current-state findings except where they need correcting. Where this review
disagrees with or extends the original, it says so explicitly and cites
evidence.

---

## 3. Most important question, answered directly

> Is the proposed architecture capable of becoming a genuinely robust
> energy-efficiency management system, rather than an energy-monitoring system
> with extra sensor columns?

**Yes, but only conditionally — the original proposal reaches "environmental
conditions" on the brief's own chain (`Energy → Asset operation → Asset
condition → System behaviour → Environmental conditions → ...`) and then stops
without naming a seam for what comes after.** Nothing in it *prevents*
continuing the chain, but nothing in it *designs* the continuation either: the
original document's Parameter/Subject/Measurement/Derived-Parameter model is a
correct and necessary foundation for `Energy → Asset operation → Asset
condition → Environmental conditions`, but it never names `Expected
performance`, `Baseline`, `Anomaly`, `Opportunity`, or `Recommendation` as
concepts at all — its roadmap jumps straight from "derived parameters" to
"efficiency analytics" in prose, with no schema seam identified for where a
baseline is stored, what an anomaly references, or how a recommendation cites
its evidence.

This review closes that gap explicitly (§15, §19) by drawing a firm boundary
between three layers — **core data model** (Parameter/Point/Subject/
Measurement/Relationship — what exists, what it means), **analytics model**
(derived parameters, baselines, allocation estimates — computed facts with a
known formula/method and a version), and **intelligence/insight model**
(anomaly/opportunity/recommendation — a narrow evidence-referencing event log,
deliberately *not* a rich modeled domain, because detection logic will change
far faster than the schema should). With that seam named, the answer is yes:
the corrected architecture reaches all the way to `Recommendation` without a
schema rewrite at any later stage. Without it — if teams built directly on the
original document — baselines and anomalies would likely get bolted onto
`config.parameters` or `analytics.derived_parameter_values` ad hoc, the same
way `~20+` near-duplicate `v_energy_*` views accreted (a documented, open
problem per `docs/platform-manual/23-known-issues-and-drift.md` #8). That is
the concrete failure mode this review is defending against.

---

## 4. Subject model — red-teamed

### 4.1 Evidence the original proposal missed

`config.site_energy_meter_roles` (`postgres/ddl/85_site_energy_meter_roles.sql`)
is a **shipped, live, reviewed** table that already solves a "subject beyond
Asset/Space" problem once: a site's energy balance has logical components
(`GRID_IMPORT`, `GRID_EXPORT`, `ONSITE_GENERATION`, `SITE_CONSUMPTION`,
`BATTERY_CHARGE`, `BATTERY_DISCHARGE`, `LOAD_SUBMETER`) that are not assets and
not spaces — they're roles a physical meter plays in an accounting equation.
The platform's actual answer, when it faced this, was **not** a generic
polymorphic "Subject" entity — it was a narrow, purpose-built,
effective-dated role table with an `allocation_factor` and a GiST exclusion
constraint preventing overlapping active roles for the same
`(site, device, role)`. This is real, working precedent, and it should govern
how the future model answers "do we need System/Plant/Zone/Process/Metering-
boundary/Virtual-asset as first-class Subjects."

### 4.2 Verdict: do not add a generalized Subject supertype

A polymorphic `subject_type + subject_id` table (or a new abstract "Subject"
entity that Asset/Space/System/Zone all inherit from) is rejected. It would:
break the trigger-based ownership/compatibility validation pattern every
existing relationship table in this schema relies on (`trg_validate_*`
functions all assume a concrete FK, not a polymorphic reference); make every
future join two steps instead of one; and solve a problem (`System`/`Zone`/
`Process` as distinct entity kinds) that the brief's own examples don't
actually require — every example in the brief is expressible as an Asset, a
Space, or a relationship between them.

Per-concept verdicts:

| Brief's candidate concept | Verdict | Reasoning |
|---|---|---|
| System / Plant (e.g., "Chiller Plant," "HVAC System") | **Not a new entity — model as an Asset** with `asset_type_id` = "System"/"Plant," composed via `AssetRelationship` (§7). A Chiller Plant is a real piece of physical infrastructure a business user cares about — it already fits `metadata.assets`' own definition (`09-asset-model.md`: "the thing a business user actually cares about metering"). Reuses every existing asset mechanism (lifecycle, energy metering via `asset_devices`, `asset_points`) for free. |
| Equipment group / Process | **Later capability, Analytics layer.** A typed grouping table (`metadata.asset_groups`) only if a real onboarding need appears that `AssetRelationship`/`asset_type_id` filtering cannot answer. Do not build preemptively — no concrete requirement surfaced in this investigation. |
| Zone (a set of spaces) | **Later capability.** Trivially representable as a saved *query* over `spaces` (e.g., `floor_id` grouping, or a tag) until there's a real need for a zone to be an addressable, independently-configurable entity (its own targets, its own dashboard). Do not add a table speculatively. |
| Metering boundary | **Core, and it already exists** — `config.site_energy_meter_roles`, at the site level. If an asset-level equivalent is ever needed (e.g., "this motor's meter double-counts against its VFD's own meter"), it should be a new table with the **identical shape** (role + `allocation_factor` + effective-dated + GiST exclusion), not a generalized subject. **Defer** until a real double-counting case appears. |
| Virtual / calculated asset (e.g., "Total HVAC Load," not a physical thing) | **Add, Foundation-safe, low-risk.** A single `metadata.assets.asset_nature` column (`'PHYSICAL' | 'VIRTUAL'`, default `'PHYSICAL'`) lets a virtual asset be a full, first-class subject for `asset_points`, `asset_relationships`, and derived parameters without special-casing a single downstream consumer — it *is* an asset row, just one with no physical meter/device of its own (its energy figure, if any, is itself a derived parameter — see §8). |
| Service area | **Not needed as a distinct concept** — this is what `AssetSpaceRelationship` (§8) already names: "the set of spaces an asset serves." No separate entity required. |

---

## 5. Point vs. Parameter — validated against every listed case

The original split (`Point` = source/channel identity, `Parameter` = semantic
meaning) is confirmed **correct** — it matches how `config.profile_field_mapping`
already works, and how `config.energy_register_semantics` already keys off
`(profile_id, logical_point_id)` rather than a device or asset. But it is
**necessary, not sufficient**, as originally specified. Case-by-case:

| Case | Original proposal's answer | Verdict |
|---|---|---|
| Multi-channel sensor | Point-per-channel via `device_field_mapping` | **Correct, unchanged.** |
| Phase-specific electrical (`CURRENT_L1/L2/L3/TOTAL`) | `parameter_id` + `qualifier` on `logical_points` | **Correct — and confirmed as the right layer.** A phase qualifier is intrinsic to what the point *is*, not to which asset it's bound to or which device emitted it — it belongs on the point/parameter-mapping layer, not on `asset_points` or the observation row. |
| Same "temperature" name, different physical meaning (bearing vs. ambient vs. CHW supply) | Not explicitly addressed | **Different parameters, not qualifier variants — see §6 for the rule that distinguishes these two cases.** |
| Vendor-specific telemetry, different raw field names for the same concept | `profile_field_mapping`/`device_field_mapping` | **Correct, unchanged — already handled today.** |
| Multiple sensors measuring the same parameter (primary + secondary temperature probe) | Multiple `asset_points` rows, `point_role` distinguishing them | **Correct as designed** — `UNIQUE(asset_id, logical_point_id)` still holds because the two probes are two different `logical_point_id`s even though they resolve to the same `parameter_id`. |
| Sensor moves between assets | Not specified | **Gap — `asset_points`/`space_points` must be effective-dated** (with a GiST exclusion constraint against overlap, exactly like `config.site_energy_meter_roles`), not a plain mutable row. The original proposal's revival plan under-specified this; without it, re-pointing a sensor silently rewrites the *meaning* of every historical reading it ever produced. See §13 for the full argument and §19.E for the worked failure scenario. |
| Sensor measuring a named component (bearing on a motor) | `asset_points.component_asset_id`, a new nullable column | **Redundant — remove.** Once `AssetRelationship` exists (§7), "this point is about the bearing" is just "this point's `asset_points.asset_id` is the Bearing's own Asset row, and the Bearing relates to the Motor via `COMPONENT_OF`." Keeping `component_asset_id` alongside `AssetRelationship` creates two different ways to express the same fact — a real "which one is authoritative" ambiguity risk the first time they disagree. Whether a component needs its own Asset row (independently metered/analyzed) or is better left as an unmodeled sub-detail of the parent asset is a per-case onboarding judgment, not a schema fork. |
| Sensor measuring a space | `space_points` | **Correct, unchanged**, same effective-dating requirement as above. |
| Calculated / derived / aggregated parameter | `is_derived` flag, no `logical_points` row | **Correct — and should be a stated invariant**, not just a flag: a `config.parameters` row must have *either* ≥1 `logical_points` rows pointing at it (observed) *or* exactly one active `parameter_calculations` row producing it (derived) — never both, never neither. Worth a `CHECK`-adjacent validation (a trigger, since it spans tables), not just documentation. |
| Categorical / state parameter (`RUN_STATUS`, door open/closed) | `value_kind = 'STATE'`, no further detail | **Gap.** A state parameter's legal values need their own controlled vocabulary. Do not invent a new table for this — the platform already has `config.status_definitions` (`status_domain, code, label, description, sort_order`, seen in `postgres/ddl/03_01_reference_schema.sql`), used elsewhere for exactly this shape of problem. Add rows there under a `status_domain` per state parameter (or a small `config.parameter_state_values` if `status_definitions`' domain semantics don't fit cleanly) rather than a bespoke enum per parameter. |
| Cumulative register (energy import/export) | Stays in `config.energy_register_semantics`, energy-specific, untouched | **Correct — but the*pattern* should generalize beyond energy**, see §6. |
| Instantaneous measurement | Default case | **Correct, unchanged.** |

**Verdict: `logical_points.parameter_id` — MODIFY, not KEEP as originally
sketched.** Add: the qualifier column (confirmed, keep as proposed);
effective-dating + exclusion constraints on `asset_points`/`space_points`/
`device_field_mapping` (new requirement, not in the original); remove
`component_asset_id` (over-engineering, §17); add the parameter-existence
invariant (either-observed-or-derived, never both); reuse
`config.status_definitions` for state-parameter vocabularies instead of a
bespoke design.

---

## 6. Parameter semantics — a concrete rule, and a scoping correction

### 6.1 The qualifier-vs-separate-parameter rule

State it explicitly, since the brief's own "Temperature" example needs a
principled answer, not a case-by-case guess:

> **If the same underlying physical quantity is measured simultaneously, in
> multiple instances, by one logical measurement act (three phases of one
> current transformer, X/Y/Z axes of one vibration sensor) → same Parameter,
> different `qualifier`. If two readings are of genuinely different physical
> quantities that merely share a unit (bearing temperature and ambient
> temperature are both °C, but knowing one tells you nothing about the other)
> → separate Parameters, even if their names both contain the word
> "temperature."**

`BEARING_TEMPERATURE`, `CASING_TEMPERATURE`, `AMBIENT_TEMPERATURE`,
`CHW_SUPPLY_TEMP`, `CHW_RETURN_TEMP` are five separate `config.parameters`
rows under this rule, not one `TEMPERATURE` parameter with five qualifiers —
confirming (with a stated reason, not just an assertion) the original
proposal's D.1–D.3 walkthroughs got this right.

### 6.2 Correction: cumulative/state/rollover semantics do not belong on `config.parameters`

The original proposal put an "instantaneous vs. cumulative" flag directly on
the parameter. **This is wrong, and the existing schema already proves why**:
`config.energy_register_semantics` keys rollover/reset/counter-direction
behavior off `(profile_id, logical_point_id)` — i.e., off the **device profile
that emits the reading**, not off a universal parameter fact. Two different
vendors' "runtime hours" counters (a parameter that already exists, unwired, as
`telemetry.asset_health.runtime_hours_total`) could legitimately roll over
differently, reset differently, or use different moduli — the *parameter*
"Runtime Hours" is the same across vendors, but its *register behavior* is not.

**Recommendation**: generalize `config.energy_register_semantics`' *shape*
(minus its energy-specific `flow_interpretation` column) into a domain-agnostic
`config.cumulative_register_semantics(profile_id, logical_point_id,
counter_direction, rollover_behavior, rollover_value, reset_behavior,
expected_max_interval_delta)`. This is a real, valuable generalization the
original proposal implied ("reuse the pattern") but never named specifically —
and it directly unblocks two columns that already exist and are already
unwired: `asset_health.runtime_hours_total` and `asset_health.starts_count`,
plus any future pulse-count-based water totalizer.

### 6.3 Coverage checklist against the brief's list

| Concern | Recommendation |
|---|---|
| Canonical / source units + conversion | Keep as originally proposed (`parameters.unit_id` = canonical; `device_field_mapping.scale_to_canonical_unit`/`offset` = conversion) — already correct, do not duplicate conversion logic on the parameter itself. |
| Precision / data type | Keep `data_type` on `logical_points` (as today), not duplicated on `config.parameters` — every point mapped to a parameter must agree on data type; enforce with a validation trigger, don't model it twice. |
| Aggregation method | Keep as proposed (parameter-level default, overridable per calculation). |
| **Interpolation** | **Missing from the original — add** `interpolation_policy` (`NONE` / `LAST_VALUE_HOLD` / `LINEAR` / `NEVER`) as parameter metadata. A `STATE` parameter must never interpolate; an instantaneous `NUMERIC` parameter reasonably might for short gaps; a cumulative register never does (delta logic already handles this, per `config.energy_register_semantics`'s `reset_behavior`). |
| State semantics | Reuse `config.status_definitions` (§5), do not invent a parallel vocabulary. |
| Cumulative semantics | **Not on the parameter** — belongs on the generalized profile-scoped register-semantics table (§6.2). |
| Quality semantics | Reuse the existing `quality_code` mechanism (§12) — no new parameter-level concept needed. |
| Direction of good | Keep as proposed (`HIGHER_BETTER`/`LOWER_BETTER`/`NEUTRAL`). |
| Target / range | **Analytics layer, not Foundation** — a lightweight `config.parameter_targets` (parameter_id, scope [asset_type_id or asset_id], target/min/max, effective-dated) belongs with baselines (§15), since a target is a modeling/expectation fact, not raw metadata that should gate ingestion. |
| Applicability to asset types | Extend the pattern already proven by `config.device_profile_categories` (a dedicated compatibility table, not a bare nullable column) — add `config.parameter_asset_type_applicability(parameter_id, asset_type_id)` for *every* parameter (not just derived ones, as the original proposal only specified for `parameter_calculations`), so the onboarding UI can filter which parameters are offerable for a given asset type the same way it already filters device profiles by category. |

---

## 7. Asset relationships — red-teamed against real equipment hierarchies

`AssetRelationship` (`from_asset_id, to_asset_id, relationship_type,
effective_from/to`) correctly handles `Building → HVAC System → AHU → Fan →
Motor` and `Chiller Plant → Chiller → Compressor → Motor` as typed composition
edges, **once corrected as follows**:

1. **Add a GiST exclusion constraint preventing overlapping active
   relationships for the same `(from_asset_id, relationship_type)`** where
   exclusivity is expected (a Fan has exactly one `DRIVEN_BY` motor at a time)
   — mirroring `config.site_energy_meter_roles`' proven
   `ex_site_energy_meter_role_no_overlap` idiom. The original proposal's DDL
   sketch had plain timestamp columns with no database-enforced non-overlap
   guarantee — a real gap given how many of the brief's own test cases
   (equipment replaced, moved, temporarily swapped) depend on it.
2. **`AssetRelationship` is a graph (M:N), not a tree** — parallel chillers,
   redundant pumps, and a shared motor serving two pumps sequentially over its
   life are all just multiple rows, no special modeling. State this
   explicitly; the original proposal didn't, and the existing
   `trg_validate_asset_hierarchy` (which enforces a *single-parent tree* on
   `parent_asset_id`) **cannot be reused unmodified** for `AssetRelationship` —
   a new trigger is required, and cycle-prevention should be **scoped per
   relationship_type** (enforced for hierarchical types like `COMPONENT_OF`;
   not necessarily for a symmetric type like `PAIRED_WITH`, if one is ever
   added).
3. **Primary/backup, lead/lag are not structural relationship types — do not
   fold them into `relationship_type`.** `COMPONENT_OF`/`DRIVEN_BY`/`PART_OF`
   describe stable physical composition; "which chiller is lead this week" is
   an **operational state that changes on its own schedule**, often driven by
   telemetry (a BMS-reported lead/lag state) rather than a metadata edit.
   Model it as either (a) a small effective-dated
   `metadata.asset_operational_roles(asset_id, role_code, effective_from/to)`
   table if it changes on human timescales (days/weeks), or (b) a `STATE`
   parameter (§5/§6) bound via `asset_points` if it changes on operational
   timescales (hourly rotation) — **not** as a value in the same vocabulary as
   physical composition. This is a real omission in the original proposal.
4. **Equipment temporarily swapped or moved between systems** is fully
   supported by (1) + (2) — no new concept, provided the exclusion constraint
   from (1) exists.
5. **Equipment replaced** needs nothing beyond the existing
   `lifecycle_status`/`DECOMMISSIONED` mechanism plus effective-dated
   relationships — confirmed sufficient, no new concept.
6. **Directionality**: keep `from_asset_id`/`to_asset_id` as proposed, but
   require every `config.asset_relationship_types` row to declare its expected
   directionality semantics (`HIERARCHICAL_UP`/`HIERARCHICAL_DOWN`/
   `SYMMETRIC`) so `COMPONENT_OF` is unambiguous about which end is the "part"
   and which is the "whole" — the original proposal didn't specify this and it
   is a genuine source of onboarding error (a fan entered as `COMPONENT_OF`
   the AHU vs. the AHU entered as containing the fan are not automatically
   the same fact without a documented convention).
7. **Tenant isolation / asset-type compatibility**: reuse the exact
   `asset_devices`/`asset_device_relationship_category_compatibility`
   pattern — a seeded `config.asset_relationship_type_compatibility` table
   constraining which `asset_type_id` pairs are valid for which relationship
   type, enforced by a trigger mirroring `trg_validate_asset_device_relationship`.
   Confirmed correct in the original proposal; restated here because it is
   easy to skip in a first cut and this is exactly the kind of DB-level safety
   net `08-device-onboarding.md` warns is otherwise silently bypassable by a
   direct-SQL path.

**Verdict: `AssetRelationship` — MODIFY** (exclusion constraint,
directionality metadata, cycle-prevention scoped by type), **plus ADD** a
separate, explicitly-distinct operational-role concept for lead/lag/primary/
backup that the original proposal omitted entirely.

---

## 8. Asset ↔ Space — and the energy-attribution question

### 8.1 `AssetSpaceRelationship`

Sufficient for existence/topology questions (`AHU-01 SERVES Ballroom A and
Ballroom B`, `AHU-02 SERVES Ballroom B`, `FCU → room`, `Chiller plant →
building`) **once it inherits the same corrections as `AssetRelationship`**:
effective-dating with a GiST exclusion constraint (an AHU's serving map
changes when ductwork is reconfigured, and history must reflect what was true
at the time — see the failure scenario in §19.E), and a seeded
`config.asset_space_relationship_type_compatibility` table (a `Chiller Plant`
`COOLS` a `Building` makes sense; a `Motor` `SERVES` a `Space` generally
doesn't, and should be rejectable the same way `PRIMARY_METER` is
category-constrained today).

### 8.2 Energy attribution — the harder question, answered directly

**The platform already has a directly analogous, shipped precedent one level
up**: `config.site_energy_meter_roles` allocates a *physically distinct,
separately metered* flow (grid import vs. on-site generation — real circuits,
real meters) into a logical accounting bucket, via `allocation_factor` (a
fraction, 0–1) and effective dating. Asset→space energy attribution for a
shared AHU is a **fundamentally different kind of problem**, and the
architecture must not blur the two: you cannot physically un-mix the
conditioned air an AHU sends to two rooms and measure each room's share with a
sensor — any split is an **estimate**, never a directly measured fact, whereas
`site_energy_meter_roles`' allocation *is* metered fact (each role's device
has its own real reading).

**Recommendation**: when asset→space attribution is actually needed (it is not
yet — no current dashboard, view, or stated requirement asks for it), the
right answer is a new table with the *same shape* as
`site_energy_meter_roles` but placed in the **`analytics` schema, not
`metadata`/`config`**, because it is an analytical/modeling decision, not a
structural fact: `analytics.asset_space_energy_allocation(asset_id, space_id,
allocation_factor, allocation_method ['EQUAL_SPLIT'/'AREA_WEIGHTED'/'MANUAL'/
'METERED'], effective_from/to)`. Any figure derived through it must be
**visibly, permanently flagged as an estimate** wherever it's surfaced (its own
`allocation_method` column, always shown, never hidden behind a plain number)
— and must **not** reuse the existing per-reading `is_estimated` flag, which
already means something different and more mechanical (an interpolated/held
telemetry value). Conflating "this reading was interpolated" with "this
number is a modeled apportionment of someone else's meter" would understate
how much less certain an attribution figure is.

**Where it belongs, and when**: `analytics` schema, **Advanced-analytics
roadmap stage** (§20), introduced only once a concrete customer requirement
exists — not added to the core model now. This directly answers the brief's
own instruction not to add it automatically.

---

## 9. Measurement storage — red-teamed against all four options

| Option | Verdict | Why |
|---|---|---|
| **A — one universal narrow table** | **Rejected, with numbers.** `telemetry.energy_measurements` is a 75-column wide table; a single meter's ~50-point payload becomes ~50 EAV rows per timestamp instead of 1. At the platform's own verified production volume (946 rows/device/day at 1-minute resolution for a single Meenaxy device, per `docs/platform-manual/11-aggregation.md`), that's a ~50x row-count multiplier for the platform's highest-volume, most mature domain — directly regressing TimescaleDB compression (which wants homogeneous, `segmentby(device_id)`-friendly wide rows) and continuous-aggregate performance that is *already proven working* in this exact codebase. Rejecting Option A is not a stylistic preference; it would measurably regress an already-shipped, already-tuned system. |
| **B — fully specialized domain tables, no generic layer** | **Rejected — under-serves onboarding speed.** Every new parameter, even a one-off pilot sensor, would require a schema migration before it can be stored at all. Given this platform's actual velocity (`postgres/migrations/205`–`222` in roughly one month, per the change history) this is workable but wasteful for genuinely exploratory/low-volume domains. |
| **C — generic canonical layer + specialized domains, no promotion path** | **Close, but incomplete** — this is Option D minus an explicit lifecycle. Without a defined promotion trigger, the "generic" table silently becomes Option A's EAV table by neglect rather than design, which is exactly the failure mode Option A was rejected for. |
| **D — hybrid generic landing + specialized promoted domains** | **Recommended, with an explicit, enforced promotion rule the original proposal lacked.** |

**Strengthening D**: define a concrete promotion trigger up front — e.g., *"any
parameter exceeding N rows/day or deployed across more than M assets within a
90-day window must be promoted to a dedicated domain table before the next
onboarding wave in that domain."* Without a stated threshold, "promote when it
matures" is unenforceable and `generic_point_measurements` will simply grow
forever — the same view-sprawl failure mode (`23-known-issues-and-drift.md`
#8) recurring at the storage-table layer instead of the view layer.

**Operational addition the original proposal omitted**:
`generic_point_measurements` should compress with `segmentby(parameter_id)`,
not `segmentby(device_id)` — its heterogeneity is much higher along the
parameter axis than the device axis (unlike `energy_measurements`, where every
row for a device carries a consistent, near-identical column set).

---

## 10. Data routing — sharpen the boundary

### 10.1 A nuance the original proposal missed

Re-reading `postgres/ddl/124_parameterized_domain_routing.sql` closely: the
routing procedure actually does **two separable things**, and only one of them
is genuinely hardcoded. (1) The **pivot** from EAV `normalized_points` into
wide domain-table columns — hand-authored `MAX(...) FILTER (WHERE
logical_point = 'ENERGY_IMPORT_L1' ...)` blocks, one per column, per profile.
(2) The **semantic classification** — scale factors, register direction —
which is *already* correctly externalized to `config.energy_register_semantics`
and joined in, not hardcoded. The original proposal's claim that "routing is
100% hardcoded" overstates the problem: the part that actually needs fixing is
narrower — only the column-mapping pivot, not the semantic interpretation,
which the current system already gets right.

### 10.2 Recommendation: codegen, not runtime-dynamic SQL

`config.parameter_routing` (parameter_id/logical_point_id →
destination_table/column, scoped by profile or device category) is the right
shape for the *mapping*. But the original proposal's implied execution model —
have the loader interpret this table dynamically at run time to build its
pivot — is rejected: dynamic SQL generation inside a production ingestion
procedure is fragile, hard to `EXPLAIN`, and defeats the specific,
deliberate, performance-tuned query shape (forced `LATERAL` probes)
`124_parameterized_domain_routing.sql`'s own file header says exists *to
prevent the planner from flattening into a full hash join* — a dynamically
assembled statement risks silently losing that shape.

Instead: **a small, offline, CI-time generator reads `config.parameter_routing`
and emits the actual `CREATE OR REPLACE PROCEDURE`** — the same
hand-review-able `FILTER`-pivot shape used today, just machine-generated
instead of hand-typed — **as a normal, reviewed, versioned migration file**.
This satisfies the brief's stated objective ("a new device profile should be
onboardable without modifying the core ingestion architecture merely because
it introduces new parameters") because no one hand-writes new procedure logic
— they add configuration rows and re-run the generator — while preserving the
platform's actual operating discipline (every pipeline behavior change goes
through the same migration/CI/staging-validation path every other change in
this repository's history, migrations 205–222 included, has gone through).
Energy's register semantics stay completely untouched by this — `parameter_
routing` only ever decides destination table/column, never reimplements
rollover/reset/delta logic.

**Verdict: `config.parameter_routing` — MODIFY** (right data shape, wrong
proposed execution mechanism — codegen-to-migration, not runtime-dynamic SQL).

---

## 11. Derived parameters — is `parameter_calculations` sufficient?

**No, as originally sketched it is underspecified against real needs.**
Corrected shape:

```sql
config.parameter_calculations (
  id, output_parameter_id, calculation_version INT, is_active,
  formula_definition JSONB,      -- {expression, engine: 'SQL_EXPR' | 'WINDOW_FUNCTION'}
  input_parameter_refs JSONB,    -- [{parameter_id, role, required: bool, resolution_tier}]
  applicable_asset_type_id,
  output_unit_id,
  null_handling TEXT,            -- 'NULL_IF_ANY_MISSING' | 'NULL_IF_REQUIRED_MISSING' | 'ESTIMATE_WITH_FLAG'
  required_resolution TEXT,      -- every required input must be read at this tier; mismatches reject, not silently mix
  materialization_strategy,
  effective_from, effective_to   -- a formula revision is itself effective-dated
)

analytics.derived_parameter_values (
  ..., calculation_id, calculation_version, input_quality_summary JSONB, quality_code, ...
)
```

What the original proposal was missing, item by item against the brief's
checklist:

- **Minimum required inputs / missing-input policy** — not addressed at all;
  add `null_handling` and per-input `required` flags. Without this, "flow is
  missing, should COP be NULL or a lower-confidence estimate" has no defined
  answer.
- **Time alignment / resolution** — not addressed; add `required_resolution`
  so a calculation can't silently mix 1-minute power with 15-minute flow.
- **Calculation provenance** — "versioned" was asserted but not designed;
  stamp `calculation_id` + `calculation_version` onto every stored derived
  value, so a later formula correction doesn't silently rewrite the meaning
  of historical numbers without a visible trail (directly answers §13's
  concern for calculations specifically).
- **Quality propagation** — not addressed in the original at all; see §12 for
  the exact rule (worst-wins over *required* inputs only).
- **Backfill / reconciliation** — the original said "reuse the existing job
  pattern," correctly, but didn't specify *which* variant. Migration 213
  proved two different fingerprint strategies (sample-count comparison for
  native tiers; recompute-recency `calculated_at` comparison for
  15min/hourly/daily). Derived parameters have heterogeneous, arbitrary
  inputs, so they must use the **recency-based variant**, not sample-count —
  worth stating explicitly rather than leaving "reuse the pattern" ambiguous.

**Do not build a general-purpose formula/expression DSL** — the brief warns
against this directly, and it's correct to heed it: a handful of calculations
(COP, ΔT, cooling load, runtime-from-status) fit comfortably as plain reviewed
SQL expressions or window-function procedures, registered like any other
calculation. A parsed custom language is unjustified complexity for the actual
scope of "formula" this platform needs.

**Verdict: `parameter_calculations` — MODIFY**, not KEEP as originally
sketched; the additions above are not optional polish, they're the difference
between "a table that exists" and "a table that actually answers the brief's
own list of requirements."

---

## 12. Data quality propagation — answered concretely

### 12.1 The brief's own example, answered directly

> `CHW return temperature = GOOD`, `CHW supply temperature = GAP`, `flow =
> GOOD`, `power = GOOD` — what quality does `Cooling Load` and `COP` receive?

**Rule**: a derived value's `quality_code` is the **worst quality among its
*required* inputs only** (optional/diagnostic inputs cannot poison an
otherwise-valid result), using a fixed, deterministic lattice — worst wins:
`INVALID` > `GAP` > `ESTIMATED` > `GOOD`. If `CHW supply` is a *required*
input to `Cooling Load` (it is — you cannot compute a ΔT without both
temperatures), `Cooling Load` inherits `GAP`. `COP`, which consumes `Cooling
Load` as one of its own required inputs, inherits `GAP` transitively. Neither
is silently reported `GOOD`. This rule is a direct, necessary consequence of
the `required: bool` flag added to `input_parameter_refs` in §11 — without
that flag, there is no way to distinguish "this missing input should degrade
the result" from "this missing input is merely informational."

### 12.2 The rest of the list

**Reuse, don't reinvent.** `quality_code` (with values like `GOOD` and
`INVALID_NUMERIC`, confirmed live in the routing procedure text) already
covers estimated/stale/invalid/gap at the measurement level — but today those
values are **bare string literals scattered across procedure bodies**, not a
registered vocabulary. Recommend registering them under
`config.status_definitions` (`status_domain = 'TELEMETRY_QUALITY'`), reusing
the exact table the platform already has for this shape of problem (§5) —
a low-risk cleanup, not a new quality model. Sensor-failure/communication-gap
detection is already served by the existing `device_telemetry_state`/
`device_status` freshness tracking (`06-data-model.md`) — no change needed.
**Outlier detection has no current mechanism and should not get one at the
ingestion layer** — an outlier is a judgment relative to an expected range,
which is an *analytical* fact (compares a reading to a baseline, §15), not a
mechanical ingestion-time fact like GOOD/GAP/INVALID. Keep these as separate
layers; conflating them would mean re-classifying historical raw data every
time a baseline model improves, which is exactly the kind of retroactive
meaning-change §13 argues against.

---

## 13. Time and historical correctness

Consolidated list of what requires effective-dating, several of which the
original proposal did not flag:

| Needs effective-dating | In original proposal? | Note |
|---|---|---|
| `asset_points` / `space_points` | **No — gap** | Required for "sensor moved between assets" (§5, §19.E). |
| `metadata.device_field_mapping` | **No — gap** | A firmware update reassigning a channel's meaning is the same class of problem as a sensor moving; missed in the original. |
| `asset_relationships` / `asset_space_relationships` | Partial (columns proposed, no overlap enforcement) | Needs the GiST exclusion constraint (§7, §8). |
| `parameter_calculations` | Implied ("versioned") but undesigned | Now concrete via `calculation_version` + `effective_from/to` (§11). |
| `config.energy_register_semantics` / the new `cumulative_register_semantics` | **Not effective-dated today, in the live system** | Flagged as an **existing** latent gap, not just a future-model concern: if a profile's rollover value were ever corrected, historical `energy_consumption_*` rows computed under the old assumption are not distinguishable from rows computed after the fix, because classification is baked in at calculation time. In practice this is survivable — migration 213's reconciliation path is the actual remedy (recompute, don't silently reinterpret) — but the same `calculation_version` idea proposed for derived parameters would close this properly. **Classify as Later capability**, not urgent, given the existing reconciliation path already provides a working (if less elegant) remedy. |
| `config.parameters.unit_id` | Not addressed | **New rule**: once live, a parameter's canonical unit must be treated as immutable — a genuine unit change is a new parameter version (or a reviewed, explicit, one-time backfill migration, exactly like migration 187's asset-type remap precedent), never an in-place edit, or every historical numeric value silently means something different after the edit. |
| Calibration changes | Not modeled, not proposed | **Later capability** — an informational `metadata.device_calibration_events` log feeding quality context, never retroactively rewriting stored raw values. |

---

## 14. Energy integration — reaffirmed, with the connective tissue tightened

The original proposal's core call — energy's `energy_measurements`/
`energy_register_semantics`/five-tier consumption ladder stay untouched and
domain-specific — is **correct and reaffirmed**. The two corrections from
this review sharpen *how* the rest of the model connects to it without
touching it:

- §6.2's generalization of register semantics means non-energy cumulative
  counters (`runtime_hours_total`, `starts_count`, a water totalizer) get the
  same rollover-safety energy already has, via a **new, separate** table
  (`config.cumulative_register_semantics`) — energy's own table and its
  `flow_interpretation` column, which is genuinely energy-specific, are never
  touched.
- §10's routing correction means energy's ingestion procedure eventually gets
  regenerated from the same `config.parameter_routing` mechanism every other
  domain uses, closing the "add a profile without a code change" gap for
  energy too — without changing `energy_measurements`' storage shape, its
  CAGGs, or any downstream `analytics.energy_consumption_*`/`v_grafana_*`
  consumer.

Motor/Chiller/Refrigeration/AHU examples' energy-plus-condition joins (§D of
the original) remain valid under this review's corrections — the join key
(`asset_id`, time bucket) is unchanged; only the underlying subject-binding and
routing mechanisms are tightened.

---

## 15. Efficiency analytics — three layers, explicitly separated

Per the brief's explicit instruction not to put everything in the core schema:

**Core data model (Foundation)**: `Parameter`, `Point`, `Subject`,
`Measurement`, `Relationship` metadata — what exists and what it means. No
baseline, no anomaly, no recommendation logic lives here, ever.

**Analytics model (Capabilities → Advanced)**: `derived_parameter_values`
(§11), allocation estimates (§8). **Baseline / expected performance is not a
new concept** — model it as a *specialization* of the same derived-parameter
framework: a calculation whose `formula_definition.engine` is `'FIT'` (a
trained/regressed reference curve) rather than `'SQL_EXPR'`, stored through the
identical `analytics.derived_parameter_values` mechanism, with the same
`calculation_version` provenance. This reuses everything §11 already built
instead of inventing a parallel "Baseline" table family. `Operating envelope`
and `degradation` follow the same reuse: both are just derived parameters
(a distance-from-baseline calculation) or `parameter_targets` (§6.3)
comparisons.

**Intelligence/insight model (Advanced, deliberately last)**: `Anomaly`,
`Opportunity`, `Recommendation`, `Equipment/system comparison`,
`Benchmarking`. **These should not become a rich modeled domain in the core
schema.** Recommend a narrow, mostly-append event log —
`analytics.insights(id, subject_ref, insight_type, severity, evidence_refs
JSONB, generated_at, generated_by ['RULE'/'ML_MODEL'/'MANUAL'], status
['OPEN'/'ACKNOWLEDGED'/'DISMISSED'/'RESOLVED'])` — whose only job is to give a
finding a stable place to attach evidence (pointers into
`derived_parameter_values`/measurements) and be surfaced to an API/frontend.
The actual detection logic (thresholds, statistical models, ML) stays
explicitly **outside** the schema and evolves independently — this is the
direct, concrete answer to the brief's "do not put everything into the core
database schema" instruction.

---

## 16. Frontend implications — red-teamed

The original F section's shape (Site/Asset/Space/Device views, API objects not
mirroring tables) is broadly correct. Sharpened:

- **Do not build a redundant REST/GraphQL layer that just re-wraps the view
  layer.** The `v_grafana_*` boundary already *is* a clean API contract
  (tenant-filtered, domain-shaped, never raw-table-shaped) — extend it with
  new view families for the new relationship types (`v_grafana_asset_
  components`, `v_grafana_space_summary`, `v_grafana_asset_efficiency_*`,
  following the exact naming/`security_barrier`/grant conventions already
  established) and let both Grafana and any future purpose-built frontend
  consume the same layer, rather than maintaining two API surfaces that can
  drift apart.
- A dedicated application-level API becomes justified specifically for
  **writes/interactivity a SQL view cannot express** — editing an
  asset-relationship graph, authoring a `parameter_calculations` formula,
  managing `asset_space_relationships` — and should extend the platform's
  existing `admin.*` function-plus-audit-log pattern (already the established
  write path for onboarding), not a new paradigm.
- Confirmed correct in the original: never expose `asset_points`,
  `parameter_routing`, or any raw metadata/config table directly to any
  frontend surface.

---

## 17. Over-engineering — flagged aggressively

1. **`asset_points.component_asset_id`** — redundant with `AssetRelationship`
   once it exists; two ways to say the same thing is a correctness risk, not a
   convenience. **Remove** from the original proposal.
2. **An implied generalized "Subject" supertype** — rejected in §4. Keep
   exactly two physical subject tables (Asset, Space); everything else is a
   relationship or a flag on one of those two.
3. **Runtime-dynamic SQL generation for routing** — rejected in §10 in favor
   of codegen-to-migration; too clever/fragile for a platform whose entire
   2026-08 operational history (migrations 205–222) has been about making
   pipeline behavior reviewable and predictable, not dynamically assembled.
4. **A general-purpose formula/expression DSL for derived parameters** —
   explicitly rejected by the brief itself and reaffirmed in §11; plain
   reviewed SQL/window-function procedures are sufficient for the platform's
   actual calculation count.
5. **Unbounded dimensions on `generic_point_measurements`** — resist adding
   more than `parameter_id`, `point_id`, `asset_id`, `space_id`,
   `quality_code`, `is_estimated` until a real query pattern demands more; a
   speculative star-schema here recreates Option A's problem one table later.
6. **Building `EnergyAllocation`/attribution into the core model now** —
   explicitly deferred in §8; pulling it into Foundation would be premature
   given zero current requirement for it.
7. **Modeling Baseline/Anomaly/Insight as new core-schema table families now**
   — deferred in §15; reuse the derived-parameter framework instead of a
   parallel design.
8. **Reflexive effective-dating everywhere** — apply it only where §13
   identifies real need (relationships, calculations, bindings). Do **not**
   effective-date `config.parameters` itself — the underlying vocabulary
   (mirroring `metadata.logical_points` today) has never needed versioning in
   the live system, and adding it preemptively is complexity with no
   evidenced payoff.

---

## 18. Missing concepts — classified

| Concept | Classification | Note |
|---|---|---|
| Metering boundaries | **1 — Core, already exists** (`config.site_energy_meter_roles`); an asset-level equivalent is **2 — Later capability**, only if a real double-counting case appears (§4). |
| Systems / Plants | **1 — Core**, via existing Asset + `AssetRelationship`, no new table (§4). |
| Allocation | **3 — Analytics layer**, Advanced stage (§8). |
| Operating modes / setpoints / control state (telemetered) | **1 — Core**, already covered by the parameter framework — a setpoint reported by a BMS is just another `NUMERIC`/`STATE` parameter with an `asset_points` binding, no new entity. |
| Targets (human-entered, not telemetered) | **3 — Analytics layer** (`config.parameter_targets`, §6.3). |
| Schedules | **4 — Application layer** (a BMS schedule is operational configuration the EMS observes via telemetry, not a concept the analytics schema needs to model directly, absent a stated requirement to *set* schedules from this platform). |
| Alarms / events | **1 — Core, largely already exists** (`analytics.v_grafana_active_alarms` per the platform manual) — **flagged as a verification gap**, not confidently assessed: this review did not re-audit the alarms subsystem in depth and recommends a dedicated pass before assuming full coverage. |
| Maintenance state / calibration | **2 — Later capability** (an informational event log, §13). |
| Sensor health | **1 — Core, already exists** (`telemetry.device_telemetry_state`/`device_status`/`device_live_point_state`, per `06-data-model.md`) — no new concept, just a point-level lens onto existing tables. |
| Data provenance | **1 — Core, already exists** at the measurement level (`normalized_points.mapping_source`); **extended, Core** for derived parameters via `calculation_id`/`calculation_version` (§11). |
| Measurement uncertainty | **3 — Analytics layer**, and only for derived values (a numeric confidence/uncertainty alongside `quality_code`) — not for raw telemetry, where the categorical `quality_code` model is sufficient. |
| Asset lifecycle / replacement / commissioning | **1 — Core, already exists** (`lifecycle_status`, `16-commissioning.md`'s workflow) — no new concept. |
| Virtual / calculated measurements | **1 — Core**, via `is_derived` on parameters (already in the original proposal). |
| Virtual / calculated **assets** | **1 — Core, ADD** — `assets.asset_nature` flag (§4.2), a genuine gap in the original. |
| Unit conversion | **1 — Core, already exists and preserved** (`device_field_mapping`, `engineering_units`) — no change needed. |
| Time zones / DST | **1 — Core, already correctly solved** — `metadata.sites.timezone`-based, DST-aware local-day boundaries are already live (`environment_daily`, per `07-telemetry-pipeline.md`). Explicitly note: no new work needed here. |
| Weather / external conditions | **4 — Application/Analytics layer, genuinely missing.** Distinct from every other gap here: it requires ingesting from an *external* API against `(site_id, time)`, not from a device in this platform's own tenant hierarchy — recommend a small, separate `telemetry.external_conditions(site_id, source, time, ...)` table, explicitly **not** modeled as a device (there is no physical on-prem device to onboard), when this becomes a real requirement. |
| Baseline context | **3 — Analytics layer** (§15, folded into the derived-parameter/baseline reuse). |

---

## 19. Revised target architecture

### A. Verdict on the original proposal, by component

| Component | Verdict |
|---|---|
| Point↔Parameter↔Subject chain (overall shape) | **KEEP** |
| `logical_points.parameter_id` + `qualifier` | **KEEP** |
| Reviving `metadata.asset_points`/adding `space_points` | **MODIFY** — add effective-dating + GiST exclusion; remove `component_asset_id` |
| `AssetRelationship` | **MODIFY** — add exclusion constraint, directionality metadata, per-type cycle scoping, compatibility table |
| `AssetSpaceRelationship` | **MODIFY** — same corrections as above |
| Hybrid generic + specialized storage (Option D) | **KEEP, with an explicit promotion-threshold rule ADDED** |
| `telemetry.generic_point_measurements` | **KEEP, scope trimmed** (§17.5) |
| Wiring `asset_health`/`water_measurements` loaders | **KEEP, unchanged priority** |
| `config.parameter_routing` (data shape) | **KEEP** |
| `config.parameter_routing` (execution mechanism: runtime-dynamic SQL) | **REMOVE — replace with codegen-to-migration** |
| `config.parameter_calculations` | **MODIFY** — add version, null-handling, required-resolution, provenance |
| Reusing the watermark/reconciliation job pattern for new tiers | **KEEP** |
| Cumulative-register-semantics generalization | **ADD** (new, not in the original) |
| A generalized Subject supertype | **Never explicit in the original, but implied — REJECT explicitly** |
| System / Plant / Zone / Process / Metering-boundary as new entities | **REJECT as new entities — ADD only `asset_nature` flag; DEFER an asset-level metering-boundary table** |
| Energy attribution (`EnergyAllocation`) | **DEFER to Advanced stage, analytics schema** (§8) |
| Baseline / Anomaly / Insight | **ADD, but only as a thin reuse of the derived-parameter framework plus a narrow event log — not a new rich domain — and explicitly DEFERRED to Advanced stage** (§15) |
| Formula/expression DSL | **REJECT — was never proposed, reaffirmed as out of scope** |
| Frontend: extend `v_grafana_*`, avoid a redundant API layer | **KEEP, sharpened** (§16) |

### B. Revised conceptual model

```
Organization ──< Site ──< Building ──< Floor ──< Space
                    │
                    ├──< Gateway ──< Device
                    │
                    └──< Asset  (asset_nature: PHYSICAL | VIRTUAL)
                           ├──< AssetRelationship >── Asset          [M:N, typed, effective-dated, exclusion-constrained]
                           ├──< AssetSpaceRelationship >── Space     [M:N, typed, effective-dated, exclusion-constrained]
                           ├──< AssetDevice (existing, unchanged)
                           └──< AssetPoint >── Point                 [effective-dated, exclusion-constrained, NO component_asset_id]

Space ──< SpacePoint >── Point                                       [effective-dated]

Device ──< Point (metadata.logical_points occurrence,
                   via profile_field_mapping / device_field_mapping [now effective-dated])
              │
              ├── parameter_id, qualifier → Parameter (config.parameters)
              └── (never directly bound to a Subject — only via AssetPoint/SpacePoint)

Parameter (config.parameters)
   ── unit_id → EngineeringUnit          [immutable once live — §13]
   ── parameter_category, value_kind, aggregation_method, direction_of_good, interpolation_policy
   ── is_derived
   ── invariant: EITHER ≥1 Points reference it (observed) OR exactly one active ParameterCalculation produces it (derived) — never both

CumulativeRegisterSemantics (config, NEW — generalizes energy_register_semantics)
   ── (profile_id, logical_point_id) → counter_direction, rollover_behavior, reset_behavior, expected_max_interval_delta
   ── energy keeps its OWN table (flow_interpretation is energy-specific); this is a separate, parallel table for non-energy cumulative counters

ParameterCalculation (config.parameter_calculations)
   ── output_parameter_id, calculation_version, effective_from/to
   ── input_parameter_refs[] (parameter_id, role, required, resolution_tier)
   ── null_handling, required_resolution, applicable_asset_type_id
   ── materialization → analytics.derived_parameter_values (calculation_id, calculation_version, quality_code = worst-of-required-inputs)
   ── Baseline/expected-performance = same mechanism, engine='FIT'

Measurement storage (unchanged shape, promotion-governed):
  telemetry.energy_measurements        (energy-specific, untouched)
  telemetry.environment_measurements   (+ space_id)
  telemetry.water_measurements         (wired to a real loader)
  telemetry.asset_health               (wired to a real loader)
  telemetry.generic_point_measurements (narrow, segmentby(parameter_id), explicit promotion threshold)

Analytics-layer additions (NOT core schema, Advanced stage):
  analytics.asset_space_energy_allocation   (estimate, always flagged, allocation_method explicit)
  analytics.insights                         (narrow evidence-referencing event log; detection logic stays out-of-schema)
```

### C. Revised data flow

```
Physical devices
   │  MQTT
   ▼
Telegraf → raw_messages → normalized_points                         [unchanged]
   │
   │  semantic interpretation: logical_point → parameter_id (+qualifier)
   │  subject resolution: AssetPoint / SpacePoint (effective-dated — resolved AS OF event_time, not "current")
   ▼
config.parameter_routing (codegen'd, reviewed procedure — NOT dynamic SQL)
   │
   ├─→ domain measurement tables (energy / environment / asset_health / water) — CAGG-backed, quality-classified
   └─→ generic_point_measurements — landing zone, promotion-governed
   │
   ▼
Aggregation tiers (existing watermark + bounded-catchup + reconciliation pattern, reused verbatim per domain)
   │
   ▼
Derived measurements (analytics.derived_parameter_values)
   — quality = worst-of-required-inputs; calculation_id/version stamped; recency-based reconciliation
   │
   ▼
Baselines (same mechanism, engine='FIT') → Efficiency metrics (ΔBaseline, envelope) → Anomalies (analytics.insights, evidence_refs)
   │
   ▼
Insights (status-tracked event log; detection logic external to schema)
   │
   ▼
v_grafana_*-style API boundary (extended families; no redundant REST layer unless writes/interactivity require one)
   │
   ▼
Frontend: Grafana (near-term) + any future purpose-built app (only once interactivity outgrows dashboards)
```

### D. Five scenarios, re-run against the revision (deltas from the original walkthrough only)

- **Motor**: unchanged join shape (`asset_id` + time bucket across
  `energy_consumption_15min` and an `asset_health` rollup); vibration/bearing
  points now bind via `asset_points` with no `component_asset_id` — if a
  bearing ever needs independent tracking, it becomes its own Asset related to
  the Motor via `AssetRelationship`, not a special column.
- **Chiller**: COP's `parameter_calculations` row now explicitly declares
  `required_resolution`, `null_handling`, and stamps `calculation_version` on
  every stored value — a formula correction later is fully traceable, not a
  silent reinterpretation of history.
- **Refrigeration**: door-open duration remains a derived (state-duration)
  parameter; its `quality_code` now formally inherits `GAP`/`INVALID` from the
  underlying `DOOR_STATUS` point per the worst-wins rule (§12), rather than
  being implicitly assumed reliable.
- **AHU/Spaces**: `AssetSpaceRelationship` is now effective-dated with an
  exclusion constraint, so a re-ducted AHU's historical "served Room A"
  window is preserved even after it's re-pointed at Room B (§19.E). Any
  per-space energy figure is explicitly sourced from
  `analytics.asset_space_energy_allocation` and carries `allocation_method` —
  never presented with the same confidence as AHU-01's directly metered total.
- **Sensor 22 (one device, many points)**: unchanged from the original — this
  scenario was already correctly modeled; the review found no gap here beyond
  the general effective-dating requirement on `asset_points` that now applies
  uniformly.

### E. Failure scenarios

| Scenario | Outcome under the revised model |
|---|---|
| **Sensor moved to a different asset** | `asset_points`' old binding's `effective_to` closes; a new row opens. A time-aware join (`JOIN asset_points ON point_id AND reading_time <@ effective_range`) attributes old readings to the old asset and new readings to the new one automatically — this only works *because* effective-dating was added in this review; the original proposal's plain mutable row would have silently reattributed history. |
| **Asset replaced** | New Asset row (new UUID); old asset's `lifecycle_status → DECOMMISSIONED` (existing mechanism); relationships/points opened fresh for the new asset at replacement time. No new concept needed. |
| **Point remapped** (firmware reassigns a channel) | Requires `device_field_mapping` to also be effective-dated (§13's addition) — the old mapping's range closes, a new one opens; normalized_points already carry `event_time`, so historical rows resolve against the mapping that was actually in effect. |
| **Data goes missing** | Existing `GAP` quality-code + watermark/reconciliation self-heals when data returns — unchanged, already proven robust across migrations 205–214. |
| **Sensor reports invalid values** | Existing `INVALID_NUMERIC`-class quality path, formalized under `config.status_definitions` (§12) — mechanism unchanged. |
| **Parameter changes unit** | Treated as a new parameter version, or a reviewed one-time backfill migration (reusing migration 187's asset-type-remap precedent) — never an in-place edit of `unit_id` on a live parameter (§13). |
| **Calculation changes version** | `calculation_version` stamped on every `derived_parameter_values` row; old rows keep their original meaning, dashboards can pin to "latest" or a specific version; recompute-from-scratch is a deliberate, reviewed backfill job. |
| **AHU changes which spaces it serves** | `asset_space_relationships`' effective-dating closes the old `SERVES` row and opens the new one; any energy-attribution estimate computed afterward reflects the new relationships, while historical attribution stays computed against what was actually true at the time — the direct payoff of §8/§13's corrections. |

---

## 20. Implementation roadmap (revised)

Same three-stage framing as the original proposal (Foundation → Capabilities →
Advanced), reflecting every verdict in §19.A. Each stage: backend and
frontend together, with dependencies/migration/compat/testing/rollout notes.

### Foundation

**Backend**: `config.parameters` (+`qualifier` on `logical_points`);
effective-dated + exclusion-constrained `asset_points`/`space_points`/
`device_field_mapping` (no `component_asset_id`); `config.asset_relationship_
types` + `metadata.asset_relationships` (+exclusion constraint,
directionality metadata, compatibility table); `config.asset_space_
relationship_types` + `metadata.asset_space_relationships` (same
corrections); `environment_measurements.space_id`; `assets.asset_nature`;
`config.cumulative_register_semantics`; `config.status_definitions` rows for
`TELEMETRY_QUALITY`; wire real loaders for `asset_health`/`water_measurements`
(hand-written, matching today's style — do not build the routing-codegen
mechanism yet); backfill `asset_points` for the existing Meenaxy Pharma fleet
as the acceptance proof.
*All additive — no existing column/table/view renamed or dropped, matching
this repository's actual migration history (001–222).* Every new table gets
the same trigger-based validation `asset_devices` already has, and
`scripts/test/assert_*` coverage per the existing convention.
**Frontend**: none beyond read-only exposure of the new relationships via new
`v_grafana_*` views, so Foundation work is independently verifiable in
Grafana before any application code depends on it.
**Dependencies**: none beyond the existing schema. **Staging validation**:
row-count/EXPLAIN evidence per new join pattern, matching the migration-221
standard already established in this repository.

### Capabilities

**Backend**: `config.parameter_asset_type_applicability`;
`config.parameter_calculations` (full corrected shape, §11) for simple
view-based derived parameters (state-duration/runtime, deltas) — no persisted
tier yet; the `config.parameter_routing` codegen mechanism, proven on **one**
new domain end-to-end (e.g., motor condition monitoring onboarded through
configuration only, as this whole roadmap's acceptance test) before migrating
energy's own routing onto it.
**Frontend**: Space view, Asset component-tree view, Device/Point
mapped-parameter+subject view (§16); minimal admin-portal UI (new `admin.*`
functions + audit log, matching the existing onboarding pattern) for editing
`asset_points`/`asset_relationships`/`asset_space_relationships` — today these
would require direct SQL, which CLAUDE.md's production-safety rules argue
against for routine operations.
**Dependencies**: Foundation complete and staging-verified. **Backward
compatibility**: energy's routing migration must be proven bit-for-bit
equivalent (an `EXPLAIN`+output-diff gate, matching the discipline the
migration-221 N1 fix already used) before cutting over — regression here is
unacceptable given energy's maturity.

### Advanced efficiency analytics

**Backend**: `analytics.derived_parameter_values` persisted tier +
watermark/reconciliation (recency-based fingerprint, §11) for
calculations proven valuable in Capabilities; baseline modeling as a
`parameter_calculations` specialization (§15); `analytics.asset_space_energy_
allocation` (§8), introduced only once a real requirement exists;
`analytics.insights` (§15) plus whatever external detection logic
(rules/ML) is chosen — explicitly outside this document's schema-design scope.
**Frontend**: cross-domain efficiency dashboards/insight surfaces
(Site/Asset/Space efficiency summaries); a purpose-built frontend becomes
justified only if Grafana's dashboard model proves insufficient for
interactive needs (relationship-graph editing, baseline what-if comparison) —
not assumed necessary up front.
**Dependencies**: Capabilities complete, at least one derived-parameter
calculation live and trusted in production. **Rollout**: each new
`analytics.insights`-producing detector ships behind its own explicit
approval, since it is the layer most likely to surface false positives to end
users and most likely to need iteration before being trusted.

**Testing/rollout constant across every stage**: `scripts/test/assert_*`
contract coverage per new table; staging-first with before/after evidence;
no existing object renamed or dropped at any stage; explicit approval required
per stage before any staging/production migration, per CLAUDE.md §§3–4/§11 —
this document remains planning input to that approval, not a substitute for
it.

---

## 21. Final recommendation

> "If you were responsible for building this EMS for the next 5–10 years, what
> architecture would you freeze today?"

**1. Preserve, unconditionally**: the tenant-isolation discipline
(`organization_id` everywhere, trigger + app-layer double enforcement); the
device model/category/profile/asset-type identity separation; energy's
`energy_measurements`/`energy_register_semantics`/five-tier consumption ladder
exactly as they are; the watermark + bounded-catchup + reconciliation job
pattern as the platform's standard mechanism for every new analytical tier;
the `v_grafana_*` tenant-scoped presentation boundary; and the
`asset_devices`-style typed-relationship-plus-compatibility-table idiom as the
literal template for every new relationship table this review adds.

**2. Change**: revive `asset_points`/add `space_points` correctly (effective-
dated, exclusion-constrained, no `component_asset_id`); add `config.parameters`
as a real semantic registry with the point/qualifier split; replace hardcoded
routing with codegen-from-configuration, not runtime-dynamic SQL; add
`AssetRelationship`/`AssetSpaceRelationship` on the `asset_devices` template,
corrected for overlap-safety and directionality; generalize cumulative-
register semantics beyond energy.

**3. Deliberately defer**: `EnergyAllocation`/attribution modeling; Baseline/
Anomaly/Insight as anything beyond a thin reuse of the derived-parameter
framework plus a narrow event log; System/Zone/Process as new entities;
calibration/maintenance logs; weather/external-conditions integration;
operational-role (lead/lag) modeling beyond a minimal table; measurement-
uncertainty fields on raw telemetry.

**4. First implementation phase**: Foundation, as revised in §20 — schema
additions only, entirely additive, with **one real domain (motor condition
monitoring via the already-half-built `asset_health` table) taken end-to-end
through the corrected identity chain as the acceptance test**, using
hand-written routing in today's style rather than the codegen mechanism.
Prove the point→parameter→subject chain actually works, on real data, before
automating anything that depends on it.

**5. Must NOT be built yet**: the `parameter_routing` codegen automation
itself (Foundation should still hand-write the first new domain's loader, to
validate the *model* before building tooling around it); the
`derived_parameter_values` persisted tier; any allocation/baseline/insight
table; any new frontend surface beyond Grafana view additions; a generalized
Subject supertype; an expression-language DSL. Every item on this list was
either explicitly warned against by the brief, or shown in this review to
solve a problem the platform doesn't yet have concrete evidence it needs.

---

🤖 Generated with [Claude Code](https://claude.com/claude-code)
