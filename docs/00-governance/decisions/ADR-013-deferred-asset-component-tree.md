# ADR-013: Deferred asset component-tree functionality

Status: Decided (deferred to Post-MVP / SHOULD priority, not MVP `MUST`)
Date: 2026-09-10 (product requirements v0.1); scope narrowed further by Workshop Q100 (2026-09-11)
Decision owners: Product Owner
Related requirements: EMS-REQ-016, EMS-REQ-017
Related features: [Hierarchy](../../07-features/hierarchy/README.md)

## Context

The frozen DDS architecture defines a full typed, effective-dated
`AssetRelationship` graph (`COMPONENT_OF`, `DRIVEN_BY`, `SUPPLIED_BY`,
`PART_OF`, ...) enabling a navigable component tree such as "AHU-01 → Fan →
Motor" (DDS §B.4, §F "Asset view"). The product requirements catalogue
initially proposed surfacing this to customers as `EMS-REQ-016`.

## Decision

The asset component tree (`EMS-REQ-016`, "navigate `AHU-01 → Fan → Motor`
via `asset_relationships`") is classified **`SHOULD`**, not `MUST`, in the
requirements catalogue — not required for the initial release. The Workshop's
later MVP scoping narrows the Asset experience further: **the Asset
experience is "a narrower, data-driven version of the common analytical
experience"** — showing relevant energy consumption, demand, PF/THD where
available, trend, comparison, status/Attention, data quality, and supporting
evidence, determined by *available data*, not by a full navigable
relationship graph (Workshop Q100). "An Asset does not need to expose every
metric" (Workshop Q100).

## Rationale

The requirements traceability verification (2026-09-11) found Asset has
**zero platform API surface today** — no "assets for a site" endpoint, no
asset-relationship read object — making it the single largest MVP gap
(`ems-requirements-traceability.md` §2, Q100/Q51/Q52 headline finding). Asset
relationship/space-relationship read objects are scheduled for MVP-1 as
additive views/functions, but the *customer-facing component-tree navigation
experience itself* is not required for MVP.

## Alternatives considered

Not established in available source material.

## Consequences

- MVP-1 delivers the underlying "assets for a site" list endpoint and
  asset-relationship read objects as additive API work (roadmap v0.2 MVP-1),
  but the frontend does not need to render a full interactive component-tree
  navigator to satisfy MVP scope.
- A future decision may promote this to MVP scope if a customer requirement
  makes it necessary — it is deferred, not rejected.

## Evidence / references

- `docs/product/ems-customer-requirements.md` EMS-REQ-016 — [../../99-archive/superseded-product/ems-customer-requirements.md](../../99-archive/superseded-product/ems-customer-requirements.md)
- `docs/product/ems-requirements-traceability.md` §2 (Q100/Q51/Q52 headline finding) — [../../99-archive/superseded-product/ems-requirements-traceability.md](../../99-archive/superseded-product/ems-requirements-traceability.md)
- Workshop baseline §133 (Q100) — [../../99-archive/superseded-product/ems-product-owner-workshop-baseline.md](../../99-archive/superseded-product/ems-product-owner-workshop-baseline.md)
- `docs/DDS/analytics-platform-future-state-architecture.md` §B.4, §F

## Implementation references

MVP-1 (Hierarchy & Navigation Foundation) delivers the underlying read
objects; the full navigable component-tree UI is Post-MVP.

## Validation references

Not applicable — no implementation exists (verified 2026-09-11: "no API
surface at all" for Asset).
