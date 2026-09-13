# MVP-3 Staging Validation Record

Status: CURRENT · Last reviewed: 2026-09-13 · Owner: Engineering
Related feature: [Site Overview](../07-features/site-overview/README.md), [Attention](../07-features/attention/README.md)
Related decisions: [ADR-009](../00-governance/decisions/ADR-009-slice-c-historical-reference-methodology.md), [ADR-010](../00-governance/decisions/ADR-010-mvp3-attention-materiality-policy.md), [ADR-011](../00-governance/decisions/ADR-011-insufficient-data-not-healthy.md)

## What was validated

**Deployed SHA:** `ddbe5a4afb17221c22d128b88b313a51518ae8bc`
("MVP-1 closeout + MVP-3: Site Overview & Energy Attention," PR #50,
merged to `origin/staging` 2026-09-13) — the commit that replaces the
Phase-8 `ShellHome` placeholder with the real `SiteOverview.tsx` composite
screen and adds the Energy Attention / Site Health computation.

**Result: PASS WITH OBSERVATIONS.**

## What this record covers

This is a validation of the MVP-3 staging deployment specifically — it is
distinct from, and should not be conflated with, the pre-merge automated
test suites the implementing commits themselves report (146/146 →
152/152 frontend, 74/74 relevant backend regression — see commit messages
cited in [ADR-010](../00-governance/decisions/ADR-010-mvp3-attention-materiality-policy.md)).
Those are pre-merge CI evidence; this record is the post-deploy staging
check.

## Validation categories

- **API validation.** The Analytics API endpoints `SiteOverview.tsx` and
  its dependents (`EnergyOverview`, `DemandOverview`, `PowerQualityOverview`)
  consume — `GET /api/v1/sites/{site_id}/energy/consumption`, `/evidence`,
  `/typical-reference`, `/demand`, `/demand/current`, `/power-quality` —
  were confirmed reachable and returning data through the deployed staging
  build.
- **Deployed bundle validation.** The staging deployment was confirmed to
  be serving the `-web:<sha>` artifact built from commit `ddbe5a4`, not a
  stale prior build — consistent with the platform's independently
  versioned frontend delivery mechanism (see
  [../05-applications/ems-web/README.md](../05-applications/ems-web/README.md)).
- **Tenancy/security validation.** Site Overview and its Attention/Site
  Health computation were confirmed to operate within the existing
  server-side tenant/site authorization boundary — no new API surface, no
  new write path, no bypass of the Analytics API boundary (see
  [ADR-007](../00-governance/decisions/ADR-007-analytics-api-boundary.md)).
- **Real-data limitations.** Validation was performed against real staging
  tenant data, not synthetic fixtures — but staging's telemetry history is
  young relative to what a mature production tenant would have accumulated.
- **Absence of mature historical data for live Healthy/Attention
  observation.** Because the Slice C typical-reference comparison needs
  multiple eligible historical windows (≥70% coverage each, up to 8
  candidates — see [ADR-009](../00-governance/decisions/ADR-009-slice-c-historical-reference-methodology.md)),
  and staging's telemetry history is not yet deep enough to exercise every
  eligibility path, the **Insufficient Data** state (see
  [ADR-011](../00-governance/decisions/ADR-011-insufficient-data-not-healthy.md))
  was observed more often, and the full range of **Needs Attention**
  triggering conditions was not exhaustively exercised live, in this pass.
- **Demand/PQ data limitations.** Demand and Power Quality summaries on
  Site Overview are informational only in MVP-3 (no materiality rule — see
  [../07-features/attention/README.md](../07-features/attention/README.md)),
  so their validation scope was limited to "does the data load and render
  correctly," not a threshold/status check, consistent with what was
  actually built.
- **Browser validation limitation.** This validation pass did not include
  a full interactive-browser walkthrough (visual regression, responsive
  behavior across breakpoints, cross-browser rendering) — it confirmed data
  correctness and API/tenancy behavior, not the complete rendered UI
  experience. **Unobserved browser behavior is not represented as
  validated** — this is an explicit scope limitation, not an implicit
  assumption of pass.
- **Production confirmation.** This validation was performed against
  **staging only**. Production was not touched, queried for write purposes,
  or deployed to as part of this validation pass.

## What this record does not establish

- Long-term stability of the Healthy/Needs-Attention/Insufficient-Data
  classification over weeks of real customer usage.
- Whether the ±15% Energy Attention threshold is the right number for real
  customer sites — that judgment requires production usage data this
  validation pass did not have access to.
- Full cross-browser/responsive UI correctness (see "Browser validation
  limitation" above).
