# ADR-015: MVP-6 Site Performance Report (Q76)

Status: Decided; implemented (not yet deployed)
Date: 2026-09-14 (Q76 Reporting Product Decision — communicated directly
as an implementation authorization, not via a separate workshop-brief
turn; see Evidence)
Decision owners: Product Owner
Related requirements: EMS-REQ-090, EMS-REQ-093 (existing); EMS-REQ-110
through EMS-REQ-116 (new — see functional-requirements.md)
Related features: Reports (first Reporting capability to receive a
dedicated feature document — see `docs/07-features/README.md`)

## Context

Workshop Q76 (`docs/99-archive/superseded-product/ems-product-owner-workshop-baseline.md`
§108) established Reporting's purpose ("What happened → What matters →
What needs attention"), its non-goals (no scheduling, no report builder,
no complex configuration, no automated narratives), and its distinction
from Export ("Report = communicate the important story; Export = provide
the underlying data" — Export decided separately in
[ADR-014](ADR-014-q75-export-scope-and-behavior.md)). The 2026-09-14 Q76
Product Decision Workshop brief (produced in-session, not separately
committed, same evidentiary pattern as ADR-009/ADR-010/ADR-014) catalogued
13 open product questions. This ADR records the Product decisions that
resolve the specific, narrower set of those questions needed to build one
concrete report type — the Site Performance Report — communicated
directly as an implementation authorization.

**This is the first MVP-6 capability to be implemented**, not merely
decided. Unlike ADR-014 (Export, decided but explicitly not implemented),
this ADR's Consequences section records real code changes.

## Decision

**Report catalogue**: exactly one report type for MVP-6 — the **Site
Performance Report**. No other catalogue entries exist.

**Access**: Reports area only. No contextual generation from other
screens (distinct from Export's dual contextual/dedicated access model,
ADR-014 decision 6 — Reporting does not inherit that pattern).

**Configuration inputs**:
- Hierarchy context: Site, Space, or Asset (see Decision — Hierarchy
  scope, below, for what this does and does not change about report
  content).
- Reporting period: predefined **current-calendar** Weekly / Monthly /
  Quarterly / Yearly windows, or **Custom** (any dates, within applicable
  data availability — see Decision — Custom period bound, below).

**Generation**: in-app, on demand. No history is retained, no email
delivery, no share links.

**Title**: `Performance Report — [context name]`, where `[context name]`
is the selected Site's, Space's, or Asset's name.

**Report structure** (explicitly the implemented baseline, not frozen —
see Consequences):
1. Overall Site Health / Status
2. Attention / Exceptions
3. Energy Performance
4. Maximum Demand
5. Power Quality
6. Investigation paths

This is the same order and composition as `SiteOverview.tsx`'s Q70
information hierarchy (ADR-003, ADR-004) — the report reuses that
existing, already-decided structure rather than inventing a new one.

**Data rules**: only existing EMS metrics, comparisons/baselines, and
deterministic rules already implemented elsewhere (Site Health via
`siteHealth.ts`, Energy Attention via `energyAttention.ts`, Energy/Demand/
Power Quality via their existing Overview screens' data). No new
analytics, thresholds, metrics, or AI/LLM-generated narrative reasoning.
`Data unavailable`/no-data states are preserved per-domain; one domain's
absence does not block the others from reporting.

**No overall report status**: the report carries no summary verdict
beyond the existing Site Health three-state signal (Healthy / Needs
Attention / Insufficient Data) — no new composite score.

**PDF**: optional, generated from the already-rendered in-app report, same
underlying content, PDF-specific layout. See Decision — PDF delivery,
below, for the immediate-vs-background interpretation.

**Controls**: "Change" (return to configuration) / "Generate another
report"; a clear generation-error state with retry; a PDF-generation
failure leaves the in-app report intact (does not discard or invalidate
it).

## Decision — gap resolutions (identified during pre-implementation
review, not silently assumed)

Six points where the approved behavior above depends on repository
capability that does not fully exist, or does not specify an
implementation mechanism. Each is recorded here as an explicit,
narrow interpretation — not invented architecture — per the "identify
gaps, do not silently resolve" instruction this work was performed under.

**1. Hierarchy scope — report content is always Site-level.** No
Space-scoped or Asset-scoped equivalent of Energy consumption, Demand, or
Power Quality exists anywhere in the platform (`getSiteEnergyConsumption`,
`getSiteDemandSeries`, `getSitePowerQuality` — all Site-only, verified by
reading `web/src/api/endpoints.ts`); Site Health (`siteHealth.ts`) and
Energy Attention (`energyAttention.ts`, `attention/types.ts`: *"Site
name -- MVP-3 Attention is site-scoped only"*) are architecturally
Site-only decisions (ADR-010, ADR-011), not per-space/per-asset ones. The
report structure's own wording — "Overall **Site** Health/Status" — is
consistent with this. **Resolution**: selecting a Space or Asset as
hierarchy context changes the report's title and the Investigation
section's emphasis/link target (into that Space's or Asset's own detail
screen), but Health/Attention/Energy/Demand/Power-Quality content is
always the selected Site's own data (the Site containing the chosen
Space/Asset). This uses zero new analytics and fabricates nothing. If
Product intends Space/Asset-scoped analytical content distinct from the
Site's, that requires new API surface — a genuine architecture dependency,
not something this report can create for itself.

**2. Custom period — no data-availability bound exists to enforce.** No
endpoint or client utility anywhere exposes a site's actual minimum/
maximum data-available date range (the same gap already flagged, and left
unresolved, for Export's identical rule — ADR-014 decision 9,
requirements-traceability.md §6). **Resolution**: the Custom date picker
does not enforce a fabricated bound; it accepts any range. Genuinely
unavailable data within a chosen range surfaces honestly through each
domain's existing `no_data`/empty-state handling — consistent with the
EMS's established "no data is normal, never invented" principle
(ADR-011, `interaction-patterns.md`) — rather than through a client-side
guess at data availability.

**3. Predefined periods are a new concept, not a `TimeRangePicker` reuse.**
`web/src/time/ranges.ts`'s existing presets (`TODAY`/`7D`/`30D`/`3M`/`1Y`)
are rolling windows ending "now," not calendar-aligned periods. Weekly/
Monthly/Quarterly/Yearly, as specified, are current-calendar windows (this
week/month/quarter/year to date). **Resolution**: implemented as a new,
report-specific period concept (pure client-side date arithmetic — no new
analytics), leaving `TimeRangePicker` and every existing screen that uses
it completely unmodified.

**4. PDF generation is client-side; "background for larger reports" is
approximated, not built as a server job.** No background-job, queue, or
report-generation backend exists anywhere in this repository, and none is
authorized to be invented by this work. The Site Performance Report is
also a small, fixed-structure document (six sections, not an open-ended
data dump), unlike Export's genuinely variable-size CSV concern.
**Resolution**: PDF is generated entirely in the browser via a new,
additive frontend dependency (see Consequences). "Immediate where
practical, background-generated for larger reports" is approximated by
generating synchronously for the normal case and never blocking the
already-rendered in-app report if PDF generation is slow or fails — there
is no separate, literal "background job" state, because nothing in the
repository establishes the infrastructure such a state would need. This
is a real simplification, flagged here rather than silently presented as
a full implementation of the size-tiered delivery model ADR-014 decision 5
established for Export.

**5. "Following the existing CSV pattern" — no such pattern exists in
code.** Export (Q75) is decided (ADR-014) but has zero implementation
anywhere in the codebase (confirmed by the 2026-09-14 MVP-6 discovery
pass and by ADR-014's own Implementation references section: "None yet").
**Resolution**: PDF delivery instead follows ADR-014 decision 5's
*decided product shape* (immediate for the normal case, no invented size
threshold) as the closest available authoritative analog, per gap
resolution 4 above — not a literal code pattern, because none exists to
follow.

**6. Attention/Site Health are often unavailable for calendar-to-date
periods — an existing API constraint, not a new limitation invented here.**
`GET .../energy/consumption/typical-reference` (the Slice C endpoint
`siteHealth`/Energy Attention depend on, via `buildTypicalReferenceResult`/
`evaluateEnergyAttention` in `SiteOverview.tsx`) requires its window to be
an *exact* whole number of days from a closed set — 1, 7, 30, 90, or 365
(`web/src/time/ranges.ts`, `planEnergyTypicalReferenceRequest`'s own
comment: *"The typical-reference endpoint requires (to - from) to be an
EXACT whole number of days (1/7/30/90/365)"*). A current-calendar
week/month/quarter/year-*to-date* window essentially never lands on one of
those exact spans (e.g. "12 days into this month" is a 12-day window).
**Resolution**: the report attempts the identical typical-reference/
Attention/Site-Health computation `SiteOverview.tsx` already performs, for
the resolved period. When the period doesn't satisfy the endpoint's
whole-day constraint, `planEnergyTypicalReferenceRequestForRange` reports
`supported: false`, and the report shows `SiteOverview.tsx`'s own existing
"Site health isn't available for this range" / insufficient-data
treatment — not a new state invented for this report, and not a new
comparison basis substituted in to force a result. Energy Performance's
own current-value and Previous-Period comparison (Slice A, no whole-day
constraint) remain available regardless, since that basis has no such
restriction. This means Attention and Site Health will legitimately be
absent from most calendar-to-date reports today — a real, named
limitation of the underlying API, not a defect in this report.

## Rationale

Reusing `SiteOverview.tsx`'s exact structure and existing data-fetching
functions (rather than inventing a parallel "report data model") keeps
this feature consistent with the "only existing EMS metrics... no new
analytics" instruction and with `EMS-REQ-093`'s parity requirement ("Report
figures traceable to on-screen numbers") — figures in the report are
computed by the identical logic already shown on screen, not a second,
divergent computation path.

## Alternatives considered

Not established in available source material for most of the approved
behavior above (it was specified directly, not deliberated in a recorded
alternatives discussion). For the six gap resolutions, the alternative in
each case would have been to invent the missing capability (a Space/Asset
analytics API, a data-availability endpoint, a server-side report job) —
rejected as out of this work's authorization ("do not invent architecture
or behavior where the repository does not establish it").

## Consequences

- New frontend route/screen(s) for report configuration and the
  generated report itself, under the Reports area.
- A new frontend PDF-generation dependency is added (first use of any
  export/document-generation library in this codebase) — see the
  implementation for the exact library and its own "single foundation"
  documentation, matching how `recharts` was adopted once as "the one
  charting foundation" and no other charting library may be added.
- No API, database, or migration change — the report is composed entirely
  from already-live endpoints.
- `docs/02-requirements/functional-requirements.md` gains new
  `EMS-REQ-110`–`EMS-REQ-116` rows.
- `docs/02-requirements/requirements-traceability.md` gains a `§7` status
  update, following the `§6` (Q75) precedent.
- `docs/01-product/roadmap.md`'s MVP-6 entry, and
  `docs/03-ux-and-design/information-architecture.md`'s "Reports" section
  and `docs/03-ux-and-design/navigation.md`, are updated to reflect Q76's
  Site Performance Report as decided and implemented (not yet deployed).
- The report structure (Decision, "Report structure" above) is the
  **implemented baseline, not frozen** — a later UX/design refinement may
  change section presentation without requiring a new product decision,
  provided the underlying six-section composition and "existing metrics
  only" rule are preserved. This ADR does not gate future presentational
  iteration on itself.
- The six gap resolutions above remain open architecture dependencies if
  Product later wants genuinely Space/Asset-scoped report content, a real
  data-availability bound, or true background PDF generation — none of
  those are foreclosed by this ADR, only deferred. A post-implementation
  investigation (2026-09-14) confirmed all three functional gaps
  (hierarchy scope, Custom-period bound, Attention/Site-Health
  availability) are genuine platform/API limitations, verified at the
  backend source of truth, not implementation defects — see gap
  resolutions 1, 2, and 6 above, each independently re-confirmed.

## Evidence / references

- Workshop baseline §108 (Q76) — [../../99-archive/superseded-product/ems-product-owner-workshop-baseline.md](../../99-archive/superseded-product/ems-product-owner-workshop-baseline.md)
- Q76 Reporting Product Decision Workshop brief (2026-09-14, in-session,
  not separately committed) — the 13-question open-decision catalogue this
  ADR resolves a subset of.
- [ADR-014](ADR-014-q75-export-scope-and-behavior.md) (Export, the sibling
  MVP-6 decision, kept fully separate).
- [ADR-003](ADR-003-mvp-information-model.md), [ADR-004](ADR-004-site-overview-primary-destination.md)
  (the Q70 Site Overview structure this report reuses).
- `web/src/routes/SiteOverview.tsx`, `web/src/attention/siteHealth.ts`,
  `web/src/attention/energyAttention.ts`, `web/src/api/endpoints.ts`
  (verified this session — the exact existing capability this report is
  built from).

## Implementation references

Implemented 2026-09-14 on `feature/mvp6-q76-site-performance-report`
(branched fresh from `origin/staging`, per this repository's branching
rule):
- `web/src/routes/reports/SitePerformanceReport.tsx` — orchestrator (config ⇄ generated report).
- `web/src/routes/reports/SitePerformanceReportConfig.tsx` — configuration (EMS-REQ-111).
- `web/src/routes/reports/SitePerformanceReportView.tsx` — the generated report (EMS-REQ-112/113/114/115/116).
- `web/src/reports/sitePerformanceReport.ts` — shared `ReportConfig` type + title formatting.
- `web/src/reports/sitePerformanceReportRanges.ts` — calendar-period math + arbitrary-range request planning.
- `web/src/reports/pdf.ts` — the PDF-generation foundation (jsPDF 4.2.1).
- `web/src/router.tsx`, `web/src/layout/navigation.ts` — route (`/features/reports`) and nav entry wiring.
- `web/src/time/ranges.ts` — three constants and one function exported (unchanged behavior) for reuse; no existing caller affected.
- `web/package.json` — `jspdf@^4.2.1` added (pinned above 2.5.2's published critical CVEs; verified via `npm audit`).

## Validation references

28 new frontend unit/component tests (`sitePerformanceReportRanges.test.ts`,
`pdf.test.ts`, `SitePerformanceReportConfig.test.tsx`,
`SitePerformanceReportView.test.tsx`, `SitePerformanceReport.test.tsx`),
plus 2 pre-existing `navigation.test.ts` assertions updated for the new
nav entry. Full frontend suite (209 tests, 31 files), `tsc --noEmit`,
`eslint --max-warnings 0`, and `vite build` all verified passing in the
same session. Not yet validated against a live staging environment — no
deployment has occurred.
