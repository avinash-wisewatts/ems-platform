# ADR-005: Energy / Demand / Power Quality as contextual, not unrelated permanent top-level, navigation

Status: Decided (with a noted tension in early UX drafting — see below)
Date: 2026-09-11 (Workshop Q69, Q52); UX hypothesis dated 2026-09-10
Decision owners: Product Owner (Workshop)
Related requirements: EMS-REQ-020 through EMS-REQ-043
Related features: [Energy](../../07-features/energy/README.md), [Demand](../../07-features/demand/README.md), [Power Quality](../../07-features/power-quality/README.md)

## Context

Product-definition v0.1's information-architecture draft (2026-09-10) treated
Energy, Environment, and Assets as independent top-level navigation sections,
reachable "both in site context and as cross-cutting areas"
(`ems-information-architecture.md` §2). The workshop's later MVP-scoping work
(2026-09-11) reframed these areas as part of the Site Overview's own
information hierarchy rather than as freestanding destinations.

## Decision

Energy, Maximum Demand, and Power Quality are **analytical areas reached
through Site (and Space/Asset) context**, not independent, permanently
top-level navigation sections unrelated to where the customer currently is.
Workshop Q69 states the "What?" dimension (Overview → Energy → Demand →
Power Quality → Performance → Attention) explicitly alongside the "Where?"
dimension (Portfolio → Site → Space → Asset) — the two combine, so Energy/
Demand/PQ are always viewed *within* a site/space/asset scope, and the Site
Overview (ADR-004) is the coherent single destination that surfaces all of
them together rather than requiring the customer to "choose between separate
analytical dashboards" (Workshop Q61).

## Rationale

Workshop Q69's explicit two-dimensional framing ("Where? / What?") is the
clearest statement that these are facets of one context-scoped experience,
not sibling menu items with independent identity. This is consistent with
Q50's core analytical job ("how much energy," "how are we performing,"
"where are the issues," "where should I investigate") being answered as one
integrated flow, not per-navigation-section.

## Alternatives considered

The 2026-09-10 information-architecture draft's navigation hypothesis
(`ems-information-architecture.md` §2) is the closest thing to a considered
alternative on record: it proposed Energy/Environment/Assets as persistent
top-level sections in addition to site context. That draft explicitly
labeled itself `[WISEWATTS-DECISION]` (draft) and a "working hypothesis,"
not a final decision, and was written before the workshop's Q49–Q101 MVP
scoping. No document states that this navigation hypothesis was formally
superseded — see the tension noted below.

## Consequences

- The MVP frontend's screen catalogue should be read as "areas within the
  Site Overview / Energy Health experience," per Workshop Q69/Q98, rather
  than as independent top-level routes — see [03-ux-and-design/navigation.md](../../03-ux-and-design/navigation.md).
- This does not prohibit Energy/Demand/PQ from also being independently
  deep-linkable or reachable as a focused drill-down (EMS-REQ-019) — the
  decision is about their role in the primary navigation model, not about
  removing direct access.

## Noted tension — not resolved by this reorganization

`ems-information-architecture.md` §2's navigation hypothesis and Workshop
Q69's two-dimensional framing were never explicitly reconciled in any source
document. Per [../source-of-truth.md](../source-of-truth.md), this is
recorded rather than silently resolved. The workshop's later, more specific
MVP decision (Q69, dated 2026-09-11, after Q49–Q101's explicit MVP-scoping
mandate) is treated here as taking precedence over the earlier, explicitly
provisional IA draft (dated 2026-09-10) — but this precedence has not been
confirmed by the product owner in writing.

## Evidence / references

- Workshop baseline §82 (Q52), §100 (Q69) — [../../99-archive/superseded-product/ems-product-owner-workshop-baseline.md](../../99-archive/superseded-product/ems-product-owner-workshop-baseline.md)
- `docs/product/ems-information-architecture.md` §2 — [../../99-archive/superseded-product/ems-information-architecture.md](../../99-archive/superseded-product/ems-information-architecture.md)

## Implementation references

MVP-2 (Core Energy Analytics), MVP-3 (Site Overview) — see [../../01-product/roadmap.md](../../01-product/roadmap.md).

## Validation references

Not yet validated.
