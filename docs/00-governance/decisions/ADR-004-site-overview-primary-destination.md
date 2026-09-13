# ADR-004: Site Overview as the primary MVP landing destination

Status: Decided
Date: 2026-09-11 (Workshop Q61, Q62, Q88)
Decision owners: Product Owner (Workshop)
Related requirements: EMS-REQ-020, EMS-REQ-012
Related features: [Site Overview](../../07-features/site-overview/README.md)

## Context

Product-definition v0.1 left the landing page and portfolio-vs-site question
explicitly open (`ems-product-definition.md` §13, question 1 and 2). The
workshop needed to resolve this before MVP-1 sequencing could be finalized.

## Decision

The MVP landing experience is a **Site Overview / Energy Health** view
bringing the core signals together into one coherent experience: Overall
Site Status, Energy Consumption, Energy Performance vs. baseline, Maximum
Demand, Power Quality, Issues/Attention, and paths into Space → Asset
investigation (Workshop Q61).

**Site is the primary customer context** (Workshop Q62): a single-site
customer lands directly on Site Overview; a multi-site customer
selects/enters the relevant site from organisation/portfolio context, then
the experience stays anchored to that site.

The first-time experience is deliberately lightweight (Workshop Q88):
**Login → Select Portfolio/Site → Site Overview → Start analysing** — no
setup wizard, because configuration is owned by the Administration Portal
(see ADR-006).

## Rationale

"The customer should not have to choose between separate analytical
dashboards just to understand how the facility is doing" (Workshop Q61) —
this directly answers the customer's first question, "How am I doing, and is
there anything I need to pay attention to?" (Workshop Q5, Q20).

## Alternatives considered

Not established in available source material — product-definition v0.1
recorded the landing-page question as open without proposing competing
options; the workshop recorded only the decided answer.

## Consequences

- Product-roadmap v0.2 sequences **MVP-1 (Hierarchy) before MVP-3 (Site
  Overview)** specifically because Site Overview is a composite screen built
  from MVP-1's navigation and MVP-2's analytics endpoints.
- Portfolio Overview exists in MVP scope but is explicitly the
  **lowest-priority** MVP experience (Workshop Q63/Q64) — see ADR-005 note
  and `01-product/roadmap.md` §2 MVP-8.

## Evidence / references

- Workshop baseline §92 (Q61), §93 (Q62), §121 (Q88) — [../../99-archive/superseded-product/ems-product-owner-workshop-baseline.md](../../99-archive/superseded-product/ems-product-owner-workshop-baseline.md)
- `docs/product/ems-product-definition.md` §13 — [../../99-archive/superseded-product/ems-product-definition.md](../../99-archive/superseded-product/ems-product-definition.md)

## Implementation references

MVP-3 — see [../../01-product/roadmap.md](../../01-product/roadmap.md).
Frontend shell (`ShellHome.tsx`) is landed as a placeholder; real Site
Overview content is not built as of 2026-09-11.

## Validation references

Not yet validated.
