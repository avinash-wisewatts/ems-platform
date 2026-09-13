# ADR-001: EMS product vision and principles

Status: Decided
Date: 2026-09-10 (product definition v0.1); reaffirmed and deepened 2026-09-11 (Product Owner Workshop Session 1–2)
Decision owners: Product Owner (workshop decisions); documented by Product
Related requirements: `ems-customer-requirements.md` (all `EMS-REQ-*`)
Related features: All — this is the top-level product framing every feature inherits.

## Context

Before any customer-facing screen or requirement could be prioritized, the
product needed a stated identity distinct from "a dashboards/analytics
product," and a small set of principles to resolve ambiguous cases
consistently.

## Decision

WiseWatts EMS is **"an Energy Management System that happens to contain
dashboards"** — not a dashboard product, not a Grafana-style analytics tool,
and not a generic charting product. Dashboards, charts, KPIs are mechanisms
inside the EMS, in service of the customer's energy-management work, never
the product itself (Workshop §11).

The product organizes around the **Energy Management Cycle** (the
overarching business framework) and the four-stage digital experience model
**MONITOR → INVESTIGATE → IMPROVE → MEASURE** (Workshop §6, §9; the two
coexist, per Workshop §9 and §37 item 2 — the Cycle is the business
framework, MONITOR/INVESTIGATE/IMPROVE/MEASURE is the product experience
model supporting it).

Design principle: the EMS is designed around **customer energy-management
outcomes and questions**, never around screens, chart types, database
structures, telemetry structures, or Grafana concepts (Workshop §11;
`ems-product-definition.md` §7 principle 1 and 2).

Ten product principles govern requirement/design decisions (`ems-product-definition.md`
§7): business questions first; semantic vocabulary only (no raw telemetry
terms in the customer UI); progressive investigation (every headline number
has a path to "why"); the Analytics API is the only door; performance is a
product requirement; "no data" is a normal state; quality is always visible;
role-appropriate views; don't clone the ZeroWatt reference product; the
frozen architecture wins (no requirement silently forces an architecture
change).

## Rationale

`ems-product-definition.md` §1: "How are we doing?" → "Why is this
happening?" → "What should we do?" is the customer's actual mental model; a
product organized as "a collection of dashboards and charts" does not serve
that progression. The Workshop's "EMS that happens to contain dashboards"
framing (Workshop §11) makes the same point at the level of product identity,
not just screen design.

## Alternatives considered

Not established in available source material — the workshop and product
definition record the decided framing, not alternative framings that were
weighed against it.

## Consequences

- Every requirement in `ems-customer-requirements.md` is expressed as
  *customer question → capability → metric/semantic concept → required
  data → visualisation*, not as a chart-type request.
- The customer UI never surfaces device IDs, logical-point IDs, raw field
  names, or Grafana artifacts (EMS-REQ-003).
- A ZeroWatt-observed capability is reference/inspiration only, never
  automatically adopted (product definition evidence tag `[ZEROWATT-OBSERVED]`).

## Evidence / references

- `docs/product/ems-product-definition.md` §1, §7 (as archived: [../../99-archive/superseded-product/ems-product-definition.md](../../99-archive/superseded-product/ems-product-definition.md))
- Workshop baseline §5–§11, §36–§37 ([../../99-archive/superseded-product/ems-product-owner-workshop-baseline.md](../../99-archive/superseded-product/ems-product-owner-workshop-baseline.md))

## Implementation references

Not applicable — this ADR is a product-framing decision, not an
implementation.

## Validation references

Not applicable — no implementation to validate yet.
