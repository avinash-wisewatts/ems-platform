# ADR-012: Deferred AI / anomaly / recommendation functionality

Status: Decided
Date: 2026-09-10 (product definition v0.1); reaffirmed extensively through Workshop Q7–Q26 (2026-09-11)
Decision owners: Product Owner (Workshop)
Related requirements: EMS-REQ-120 through EMS-REQ-128, EMS-REQ-906
Related features: Not applicable — explicitly deferred, no MVP feature

## Context

The long-term product vision (ADR-001) includes an eventual "Energy
Intelligence Platform with AI" (Workshop §10). Without an explicit boundary,
this risked either being built prematurely or being used to justify
under-scoping the near-term visibility product.

## Decision

**No AI, recommendation engine, anomaly scoring, or "continuous AI insights"
functionality ships before its designated later phase** (product definition
§10 non-goals; Workshop §10: "a strategic direction, not a request to
implement AI now"). MVP's Attention/Issues surface is explicitly
**analytical, not intelligent** — predefined thresholds and measurable
deviations only; it does not intelligently rank opportunities, explain root
causes, recommend actions, predict future problems, or learn site-specific
behaviour (Workshop Q57).

The broader recommendation/automation maturity ladder — **INFORM (MVP) →
MANAGE → VERIFY → AUTOMATE** (Workshop Q8) — has exactly one rung in MVP
scope: WiseWatts identifies an issue and informs the customer, who acts
outside WiseWatts. Manage, Verify, and Automate are explicitly **not MVP**.
Before productised insight/recommendation capabilities exist, the WiseWatts
team may manually analyse customer data and provide insights — an
intentional human-in-the-loop step, not something to hide (Workshop Q12).

## Rationale

Workshop Q26: "WiseWatts should earn its authority through evidence and
verified outcomes" — recommendation/AI functionality is deliberately gated
behind first proving the visibility and evidence foundation, not built ahead
of it. Product-definition non-goal: "Not an AI product in the near term."

## Alternatives considered

Not established in available source material.

## Consequences

- `analytics.insights` (Phase 14 of the DDS implementation roadmap) is a
  narrow, evidence-referencing event log; detection logic lives in
  application/analytics code, never as database objects, and each detector
  ships behind its own explicit approval (roadmap Phase 14).
- The requirements catalogue classifies every insights/recommendation/
  anomaly/AI-assistant requirement (EMS-REQ-120 through EMS-REQ-128) as
  `LATER`, not `MUST`/`SHOULD`.
- Reviewers reject any requirement or screen that "introduces AI/
  recommendation/anomaly-scoring ahead of its phase" as an explicit
  anti-pattern (`ems-requirements-traceability.md` §5).

## Evidence / references

- `docs/product/ems-product-definition.md` §10 — [../../99-archive/superseded-product/ems-product-definition.md](../../99-archive/superseded-product/ems-product-definition.md)
- `docs/product/ems-customer-requirements.md` §13, §14 — [../../99-archive/superseded-product/ems-customer-requirements.md](../../99-archive/superseded-product/ems-customer-requirements.md)
- Workshop baseline §27 (Q7), §28 (Q8), §32 (Q12), §50 (Q26) — [../../99-archive/superseded-product/ems-product-owner-workshop-baseline.md](../../99-archive/superseded-product/ems-product-owner-workshop-baseline.md)
- `docs/DDS/analytics-platform-future-state-architecture-implementation-roadmap.md` Phase 14

## Implementation references

Not started — Phase 14 depends on Phase 13 (Advanced Efficiency Analytics),
itself depending on Phases 1–6 and 11.

## Validation references

Not applicable — no implementation exists.
