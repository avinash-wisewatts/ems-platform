# ADR-011: Insufficient Data must never be represented as Healthy

Status: Decided
Date: 2026-09-11 (Workshop Q79, Q80)
Decision owners: Product Owner (Workshop)
Related requirements: EMS-REQ-070, EMS-REQ-071, EMS-REQ-105
Related features: [Site Overview](../../07-features/site-overview/README.md)

## Context

The Site Overview needed a small set of site-level states, and the workshop
needed to make explicit how a lack of data is distinguished from a genuinely
healthy state — a normal occurrence for a newly commissioned site or device.

## Decision

MVP defines three basic site states (Workshop Q79):

- **Healthy** — no significant analytical conditions requiring attention.
- **Needs Attention** — one or more significant conditions detected.
- **Insufficient Data** — available data is insufficient for a reliable
  assessment.

**Insufficient data must not be interpreted as Healthy** (Workshop Q80,
stated as its own explicit sentence). MVP must explicitly handle no data,
partial data, stale data, and insufficient comparison history, and explain
what is missing, why it matters, and what analysis remains available.

## Rationale

A silent fallback that reports "Healthy" merely because no adverse condition
was *detected* — rather than because the system actually confirmed health
from sufficient data — would misrepresent a data gap as good news, directly
undermining the workshop's own "trust through evidence" principle (Q14) and
the product principle that "no data" must be a normal, visible state, never
disguised as a positive result (`ems-product-definition.md` §7 principle 6).

## Alternatives considered

Not established in available source material.

## Consequences

- The Site Overview's health computation must have a distinct branch for
  "not enough data to assess" that is never collapsed into the "no problems
  found" branch.
- Example wording from the workshop: "Insufficient data for comparison — we
  have 12 days of energy data, but not enough historical data to establish
  the selected comparison" (Q80).
- This state applies wherever a health/status judgement is rendered, not
  only on the Site Overview — e.g. Space and Asset experiences reuse the
  same analytical grammar (Q99, Q100).

## Evidence / references

- Workshop baseline §111 (Q79), §112 (Q80) — [../../99-archive/superseded-product/ems-product-owner-workshop-baseline.md](../../99-archive/superseded-product/ems-product-owner-workshop-baseline.md)
- `docs/product/ems-product-definition.md` §7 principle 6 — [../../99-archive/superseded-product/ems-product-definition.md](../../99-archive/superseded-product/ems-product-definition.md)

## Implementation references

MVP-3 (Site Overview & Attention) and MVP-4 (Data Quality & Freshness) — see
[../../01-product/roadmap.md](../../01-product/roadmap.md). Not yet built.

## Validation references

Not yet validated.
