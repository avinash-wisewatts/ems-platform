# ADR-010: MVP-3 Energy Attention materiality policy (±15%)

Status: Decided; implemented and merged to `origin/staging`
Date: 2026-09-13 (PR #50, commits `19c09d7`, `e64c1e3`)
Decision owners: Product Owner (via the "MVP-3 Implementation Decision Pack" — cited by the implementing source comment, not itself present as a file in this repository) / Engineering (implementation)
Related requirements: Workshop Q57, Q72 (Attention); [ADR-009](ADR-009-slice-c-historical-reference-methodology.md) (the underlying comparison this threshold is measured against)
Related features: [Attention](../../07-features/attention/README.md)

## Context

An earlier revision of this ADR, written during the initial documentation
reorganization pass, stated no specific numeric materiality threshold was
established anywhere in the repository. That was a research error — the
search covered `docs/` and `Audit/` text files, not source code. This
revision corrects the record with the actual implementation, found in
`web/src/attention/materiality-policy.ts` on `origin/staging`.

## Decision

**Energy Attention materiality threshold = 15% deviation from the Slice C
historical typical reference** (verbatim, from the module's own header
comment, attributed to the "MVP-3 Implementation Decision Pack"). The
threshold is:

- **Inclusive both directions** — triggers when `|deviation%| >= 15`.
- **The only approved MVP-3 Attention rule** — Demand and Power Quality
  summaries on the Site Overview are explicitly **informational only**, with
  no materiality rule and no status coloring, "consistent with no
  contracted-demand or PF/THD threshold existing anywhere in the schema"
  (commit `19c09d7`).
- **Defined in exactly one place** (`MVP3_MATERIALITY_POLICY` in
  `web/src/attention/materiality-policy.ts`), deliberately never a literal
  scattered through components, so it can evolve to metric-specific,
  site-specific, or variability-based policies later without redesigning
  the Attention/Site-Health architecture.
  > **Qualified, not superseded (2026-09-14,
  > [ADR-017](ADR-017-mvp7-alert-architecture.md)):** MVP-7 Basic Alerts
  > requires a second, server-side implementation of this exact rule (no
  > server-side evaluation mechanism existed before ADR-017). This
  > principle is upheld, not abandoned — the new SQL function becomes the
  > canonical implementation going forward, with a tracked follow-on to
  > migrate this client-side code to consume the server-computed result,
  > gated by a mandatory parity test in the interim. See ADR-017
  > §"A1 — Single-source-of-truth arrangement."
- **No configuration UI** — for MVP-3 the policy is a plain, centrally-
  defined constant, per the decision pack's own instruction: "Do NOT build
  configuration UI now."

A follow-up fix (commit `e64c1e3`) corrected a floating-point boundary
defect: `evaluateEnergyAttention()` originally compared the deviation
percentage to ±15% with a raw floating-point `>=`/`<=`, which could fail to
trigger on a real (non-round) input mathematically exactly at 15% (e.g.
computing `14.999999999999988`) while the UI's `.toFixed(1)` display still
showed "+15.0%". Fixed with a `THRESHOLD_EPSILON` (`1e-9`) tolerance — ten
orders of magnitude larger than observed floating-point noise and ten
orders of magnitude smaller than any perceptible percentage difference.
The 15% rule itself, its inclusive boundaries, and the evaluator's
signature were otherwise unchanged.

## Rationale

Not independently stated beyond the decision pack citation — no separate
rationale for choosing 15% specifically (as opposed to, say, 10% or 20%) is
recorded in available source material.

## Alternatives considered

Not established in available source material.

## Consequences

- Energy Attention now exists on `origin/staging`, evaluating the **same**
  `TypicalReferenceResult`/`EnergyEvidenceSummary` `EnergyOverview` already
  computes from the Slice C endpoints — no second historical-baseline
  mechanism (see [ADR-009](ADR-009-slice-c-historical-reference-methodology.md)).
- Site Health (`web/src/attention/siteHealth.ts`) checks assessability
  first, unconditionally, so insufficient/unknown data can never read as
  Healthy — the direct implementation of
  [ADR-011](ADR-011-insufficient-data-not-healthy.md).
- Explicitly out of scope per the same decision pack (commit `19c09d7`):
  AI/ML/anomaly scoring, predictive/adaptive baselines, recommendations,
  contracted-demand threshold logic, PF/THD threshold configuration,
  functional categories, portfolio-level health rollups, an ops/
  connectivity dashboard, per-space/per-asset Attention, Admin Portal
  configuration, asset component trees/relationships.

## Evidence gap — flagged, not resolved

The "MVP-3 Implementation Decision Pack" is cited by name in the source
comment as the approval source for the 15% figure, but **no file by that
name exists anywhere in this repository** (searched: `docs/`, `Audit/`,
full commit history). Same gap as [ADR-009](ADR-009-slice-c-historical-reference-methodology.md)'s
"Slice C Historical Comparison decision pack" — quite possibly the same
document, or a closely related one. If it exists outside this repository,
it should be added so this ADR's evidence trail is self-contained.

## Evidence / references

- `web/src/attention/materiality-policy.ts` (full header comment quoted
  above in Decision) — live on `origin/staging`.
- Commit `19c09d7` ("feat(web): add site overview and energy attention").
- Commit `e64c1e3` ("fix(web): make energy attention threshold boundary
  deterministic").
- Workshop baseline §87 (Q57), §103 (Q72), §26 (Q6) — [../../99-archive/superseded-product/ems-product-owner-workshop-baseline.md](../../99-archive/superseded-product/ems-product-owner-workshop-baseline.md)

## Implementation references

`web/src/attention/materiality-policy.ts`, `web/src/attention/energyAttention.ts`,
`web/src/attention/siteHealth.ts`, `web/src/components/AttentionList.tsx`,
`web/src/components/SiteHealthBanner.tsx`, `web/src/routes/SiteOverview.tsx`.

## Validation references

Commit `19c09d7`: 146/146 frontend tests passing (+30 new), 74/74 relevant
backend regression tests. Commit `e64c1e3`: 152/152 frontend tests passing
(+6 new, including two real non-round fixtures verified via direct
computation to reproduce the exact floating-point failure the fix
addresses). See
[../../08-verification/staging-validation.md](../../08-verification/staging-validation.md).
