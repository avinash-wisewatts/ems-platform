# ADR-002: Organisation → Site → Space → Asset customer hierarchy

Status: Decided
Date: 2026-09-10 (product architecture v0.1); reaffirmed Workshop Q4 (2026-09-11), Q51/Q69 (2026-09-11)
Decision owners: Product Owner (Workshop); Architecture (frozen DDS)
Related requirements: EMS-REQ-010 through EMS-REQ-017
Related features: [Hierarchy](../../07-features/hierarchy/README.md)

## Context

The customer needs a consistent way to navigate and scope every screen. The
platform's underlying data model and the customer-facing vocabulary needed
to be reconciled without inventing a new schema concept.

## Decision

The customer-facing navigation and investigation hierarchy is:

**Organisation / Portfolio → Site → Space → Asset**

(Workshop Q4: "the customer hierarchy is Organisation/Portfolio → Site →
Space → Asset"; Workshop Q51: MVP hierarchy/drill-down is Site → Space →
Asset; Workshop Q69: information architecture "Where?" dimension is
Portfolio → Site → Space → Asset.)

Context is not merely navigation — it changes the meaning of performance
metrics at each level (Workshop Q4): Organisation/Portfolio asks "which sites
need attention," Site asks "how is this facility performing," Space asks
"where is the problem occurring," Asset asks "what equipment may be
contributing."

## Rationale

This is the customer's own mental model of their facility (product
definition §6: "the customer should be able to reason about their facility
in their own terms — sites, spaces, systems, equipment — and never in the
platform's terms"). Single-site customers must not be forced through
unnecessary portfolio ceremony (Workshop Q4, Q62).

## Alternatives considered

Not established in available source material.

## Consequences

- Every screen's breadcrumb shows this chain, clickable, never showing
  internal IDs (EMS-REQ-013).
- Space is a **drill-down target**, not primary top-level navigation
  (Workshop Q51, Q99 — this closes product-definition v0.1's open question
  #11).
- Asset is the narrowest, most data-driven level, with what it shows
  determined by available measurements, not a fixed template (Workshop
  Q100).

## Known tension with the frozen architecture — recorded, not resolved

The frozen DDS architecture (`docs/DDS/analytics-platform-future-state-architecture.md`
§A.1, §B.2) models the *physical* hierarchy as **Organization → Site →
Building → Floor → Space**, with **Asset as a separate, non-nested
hierarchy** related to Space only via the newer `AssetSpaceRelationship`
(`SERVES`, `LOCATED_IN`, etc.) — not as a child of Space. The customer-facing
four-level chain above is very likely an intentional simplification of this
richer model for the customer vocabulary layer (Building/Floor folded into
"Space" context; Asset's relationship to Space expressed as "serves" rather
than strict containment) — but no source document explicitly states that
reconciliation. This is recorded per
[../source-of-truth.md](../source-of-truth.md)'s contradiction-handling rule,
not silently resolved.

## Evidence / references

- Workshop baseline §24 (Q4), §81 (Q51), §100 (Q69) — [../../99-archive/superseded-product/ems-product-owner-workshop-baseline.md](../../99-archive/superseded-product/ems-product-owner-workshop-baseline.md)
- `docs/product/ems-product-definition.md` §6, §16 item 11 — [../../99-archive/superseded-product/ems-product-definition.md](../../99-archive/superseded-product/ems-product-definition.md)
- `docs/DDS/analytics-platform-future-state-architecture.md` §A.1, §B.2, §B.5

## Implementation references

- MVP-1 (Hierarchy & Navigation Foundation) — see [../../01-product/roadmap.md](../../01-product/roadmap.md)
- Schema: `metadata.sites`, `metadata.buildings/floors/spaces`, `metadata.assets`, `metadata.asset_space_relationships` (frozen-architecture proposal, not yet implemented as of this writing)

## Validation references

Not yet validated — MVP-1's "assets/spaces for a site" API surface is not
built (see [../../02-requirements/requirements-traceability.md](../../02-requirements/requirements-traceability.md) Q51).
