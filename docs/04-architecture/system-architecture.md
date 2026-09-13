# System Architecture

Status: CURRENT · Last reviewed: 2026-09-13 · Owner: Architecture
Full authoritative text: `docs/DDS/analytics-platform-future-state-architecture.md` (CONCEPTUALLY FROZEN)

This page summarizes the frozen conceptual data architecture. **Read the DDS
document directly for anything beyond this summary — this page is a map,
not a replacement.**

## What is frozen

Ten concepts form the complete future-state conceptual model. No additional
core entity is authorized without meeting the five-criteria change-control
test (see [README.md](README.md)):

- **Organization / Site / Building / Floor / Space** — the physical
  hierarchy, unchanged from today's schema. `organization_id` is `NOT NULL`
  and carried directly on every tenant-scoped row — there is no separate
  "tenant" abstraction.
- **Asset** (`asset_nature: PHYSICAL | VIRTUAL`) — a separate, non-nested
  hierarchy from Space. A composite ("Chiller Plant," an HVAC system) or a
  purely calculated concept ("Total HVAC Load") is *still* just an Asset —
  never a new "System"/"Plant"/"Zone" entity type.
- **Device** — unchanged; the physical telemetry source.
- **Point** — a telemetry channel: `(device_id, logical_point_id,
  raw_field_name)` flowing through `normalized_points`. Already modeled
  correctly today.
- **Parameter** (new: `config.parameters`) — canonical measurement
  *meaning* ("Vibration RMS," "Active Power"), distinct from a point's
  phase/axis *qualifier* (`L1`/`L2`/`L3`/`TOTAL`). `CURRENT_L1`,
  `CURRENT_L2`, `CURRENT_L3`, `CURRENT_TOTAL` all point at one `CURRENT`
  parameter row, differing only in `qualifier`.
- **AssetPoint / SpacePoint** (new, effective-dated, exclusion-constrained)
  — the subject-binding layer. Asset and Space are the **only two**
  optional subject types; a generalized polymorphic "Subject" is explicitly
  rejected, and Site is never a bindable subject (it's structural context,
  carried via `site_id` on every row).
- **AssetRelationship / AssetSpaceRelationship** (new, typed, effective-
  dated, M:N graphs, exclusion-constrained) — component composition
  (`COMPONENT_OF`, `DRIVEN_BY`, `SUPPLIED_BY`, `PART_OF`) and asset-to-space
  service topology (`SERVES`, `LOCATED_IN`, `COOLS`, `HEATS`, `VENTILATES`,
  `SUPPLIES`, `EXHAUSTS`, `MONITORS`).
- **Domain-specific measurement storage** (`energy_measurements`,
  `environment_measurements`, `asset_health`, `water_measurements`, plus one
  narrow, promotion-governed generic landing table,
  `generic_point_measurements`) — a hybrid model, not a single universal
  table or per-domain-only tables.
- **ParameterCalculation** (new) — derived parameters, three input-
  resolution modes only (`SELF`, `RELATED(relationship_type, direction)`,
  `AGGREGATE_CHILDREN(relationship_type)`), no general-purpose formula DSL.

**Energy accounting stays deliberately independent of physical asset
topology** — `config.site_energy_meter_roles` (grid import/export, on-site
generation, battery charge/discharge) classifies a device's contribution to
a site's energy balance, entirely separate from whatever
`AssetRelationship`/`AssetSpaceRelationship` graph exists among the physical
equipment. This separation is validated (DDS stress test), not accidental.

## What stays untouched, deliberately

`telemetry.energy_measurements`'s 75-column wide shape, its continuous
aggregates, and `config.energy_register_semantics`' rollover/reset/gap
classification logic are the platform's most mature, most validated
subsystem — not rebuilt onto a generic parameter model for conceptual
purity. See [data-architecture.md](data-architecture.md) and
[../06-platform/telemetry/README.md](../06-platform/telemetry/README.md).

## Explicit non-goals (per the DDS)

A generalized polymorphic Subject model; a Site-level subject-binding table;
`System`/`Plant`/`Zone`/`Process` as new entity types; a dynamic tag/
asset-type virtual-grouping mechanism; `component_asset_id` on
`asset_points`; a single cumulative-register-semantics table spanning energy
and non-energy counters; runtime dynamic SQL for telemetry routing; a
general-purpose formula/expression DSL; domain-specific entities per
equipment type; premature AI/ML infrastructure.

## Implementation status

The DDS architecture is **frozen** (design-approved); its implementation
follows the 17-phase roadmap in
`docs/DDS/analytics-platform-future-state-architecture-implementation-roadmap.md`.
As of this writing: Phase 0's inventory and Phase 1 (Semantic Foundation —
`config.parameters`, `logical_points.parameter_id`/`qualifier`) exist as an
implemented-but-not-yet-merged migration (223); Phases 2–6 (subject/
relationship foundation, domain measurement wiring, routing architecture,
derived calculations) are not started. Phases 7 (Analytics API) and 8
(Frontend Foundation) — which sit on top of, but do not require, this
frozen model's newer concepts — are independently **DONE**, verified on
`origin/staging`. See
[../01-product/roadmap.md](../01-product/roadmap.md) for the customer-
facing sequencing of this work.
