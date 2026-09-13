# Feature: Attention

Status: CURRENT · Last reviewed: 2026-09-13 · Owner: Product + Engineering
MVP stage: MVP-3 · Related decisions: [ADR-011](../../00-governance/decisions/ADR-011-insufficient-data-not-healthy.md), [ADR-012](../../00-governance/decisions/ADR-012-deferred-ai-recommendation-functionality.md)

## Purpose

Surface areas requiring investigation — "things worth looking at, not
everything that changed" (Workshop Q72).

## Requirements

[EMS-REQ-080](../../02-requirements/functional-requirements.md) and
related alert requirements (which share the same predefined-condition
logic, delivered as a notification rather than a screen state — MVP-7).

## User experience

[../../03-ux-and-design/information-architecture.md](../../03-ux-and-design/information-architecture.md)
§"Alerts"; consolidates conditions from Energy, Maximum Demand, Power
Quality, and Energy Performance (Workshop Q98). Each item communicates:
**What → Where → When → Metric → Trigger → Evidence → Data Quality →
Investigate.**

## Business rules

**Analytical, not intelligent** (Workshop Q57, Q72) — clear analytical
conditions, measurable deviations, configured thresholds/limits only. Does
**not** intelligently rank opportunities, explain root causes, recommend
actions, predict future problems, or learn site-specific behaviour — see
[ADR-012](../../00-governance/decisions/ADR-012-deferred-ai-recommendation-functionality.md).
Core principle: "MVP identifies and helps investigate. It does not
prescribe." The **only approved MVP-3 Attention rule** is Energy Attention
at a ±15% deviation from the Slice C typical reference — see
[ADR-010](../../00-governance/decisions/ADR-010-mvp3-attention-materiality-policy.md)
for the exact methodology, its single-point-of-definition design, and the
floating-point boundary fix.

## Data / API dependencies

**No dedicated Attention API endpoint exists, by design** — Energy
Attention (`web/src/attention/energyAttention.ts`) is a pure client-side
function evaluating the same `TypicalReferenceResult`/
`EnergyEvidenceSummary` the [energy](../energy/README.md) screen already
fetches from the Slice C endpoints. No second historical-baseline
mechanism, no new backend contract. Demand and Power Quality summaries on
the Site Overview are informational only — no materiality rule exists for
either, consistent with no contracted-demand or PF/THD threshold existing
anywhere in the schema.

## Architecture

Threshold-based, not a database concept of its own per the frozen
architecture's change-control discipline — see
[../../04-architecture/system-architecture.md](../../04-architecture/system-architecture.md).
The later `analytics.insights` event log (DDS Phase 14) is a distinct,
Post-MVP mechanism for a different purpose (evidence-referencing detector
output) — Attention and Insights are not the same thing.

## Validation

Landed with 152/152 frontend tests passing (PR #50 + follow-up fix
`e64c1e3`), including regression fixtures proving the ±15% boundary
triggers correctly on real (non-round) inputs after the floating-point
epsilon fix. See
[../../08-verification/staging-validation.md](../../08-verification/staging-validation.md).

## Release status

**DONE** for Energy (2026-09-13, PR #50, commit `ddbe5a4`). Demand and
Power Quality remain informational only, by explicit decision, not as a
gap.

## Known limitations

Only Energy has a materiality rule. Contract-demand proximity and PF/THD
limits have no threshold anywhere in the schema, so no equivalent Attention
rule exists for Demand or Power Quality yet. The "MVP-3 Implementation
Decision Pack" that approved the 15% figure is cited by the implementation
but is not itself a file in this repository — see
[ADR-010](../../00-governance/decisions/ADR-010-mvp3-attention-materiality-policy.md)
§"Evidence gap."

## Future scope

Intelligent prioritisation and root-cause explanation are explicitly
Post-MVP — see
[ADR-012](../../00-governance/decisions/ADR-012-deferred-ai-recommendation-functionality.md).
