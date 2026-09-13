# ADR-003: Overview → Energy → Demand → Power Quality → Performance → Attention information model

Status: Decided
Date: 2026-09-11 (Workshop Q69)
Decision owners: Product Owner (Workshop)
Related requirements: EMS-REQ-020 through EMS-REQ-024, EMS-REQ-100
Related features: [Site Overview](../../07-features/site-overview/README.md), [Energy](../../07-features/energy/README.md), [Demand](../../07-features/demand/README.md), [Power Quality](../../07-features/power-quality/README.md), [Attention](../../07-features/attention/README.md)

## Context

MVP-2 and MVP-3 needed a fixed, consistent "what" dimension to complement the
hierarchy's "where" dimension (ADR-002), so every screen family presents
analytics the same way.

## Decision

The MVP information architecture has two dimensions (Workshop Q69):

- **Where?** Portfolio → Site → Space → Asset (ADR-002)
- **What?** Overview → Energy → Demand → Power Quality → Performance →
  Attention

Site Overview / Energy Health is the primary MVP destination (Workshop Q69,
reaffirmed Q61, Q70). The hierarchy provides context and progressive
drill-down rather than forcing the customer through every level. Customer
navigation reflects facility concepts, never technical ones (gateways,
devices, meters, telemetry, raw parameters, Grafana) — the underlying
analytical journey is **See → Compare → Investigate → Understand** (Workshop
Q69).

The Site Overview's own information hierarchy, within this model, is
(Workshop Q70): Overall Site Health/Status → Attention/Exceptions → Energy
Performance → Maximum Demand → Power Quality → investigation paths into
Space/Asset. Principle: "tell the customer the story first; provide
analytical depth afterwards."

## Rationale

This closes product-definition v0.1's open questions #3 (the five headline
things on Site Overview) and #13 (product owner's five key questions,
questions 1 and 3) with a decided answer rather than leaving every screen
family to invent its own layout.

## Alternatives considered

Not established in available source material.

## Consequences

- A common analytical grammar applies across metrics where appropriate:
  **Current value → Comparison → Trend → Status → Evidence/Data Quality**
  (Workshop Q83, Q87) — a consistency principle, not a permanent constraint.
- Every metric shows **Value + Context + Status**, never a bare number
  (Workshop Q87).
- MVP analytical scope is exactly these areas plus Space/Asset drill-down
  (Workshop Q52) — no additional analytical domain is MVP scope without a
  separate decision.

## Evidence / references

- Workshop baseline §100–§103 (Q69–Q72), §82 (Q52), §115/§119 (Q83/Q87) — [../../99-archive/superseded-product/ems-product-owner-workshop-baseline.md](../../99-archive/superseded-product/ems-product-owner-workshop-baseline.md)
- `docs/product/ems-information-architecture.md` §4.3 — [../../99-archive/superseded-product/ems-information-architecture.md](../../99-archive/superseded-product/ems-information-architecture.md)

## Implementation references

MVP-3 (Site Overview & Attention) — see [../../01-product/roadmap.md](../../01-product/roadmap.md). Not yet built as of 2026-09-11 (traceability Q70/Q71/Q72 all classified `C — NOT LANDED`).

## Validation references

Not yet validated — no composite Site Overview screen/endpoint exists yet.
