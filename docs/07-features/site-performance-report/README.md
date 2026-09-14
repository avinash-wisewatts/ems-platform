# Feature: Site Performance Report

Status: CURRENT · Last reviewed: 2026-09-14 · Owner: Product + Engineering
MVP stage: MVP-6 · Related decisions: [ADR-015](../../00-governance/decisions/ADR-015-q76-site-performance-report.md)

## Purpose

Answer "how did my site perform over this period, and is there anything I
need to pay attention to?" as a generated, in-app document — the first
implemented Reporting (Q76) capability. Purpose per the workshop:
"communicate the important story" (Workshop Q76), distinct from Export
(Q75, ADR-014), which provides the underlying data instead.

## Requirements

[EMS-REQ-110](../../02-requirements/functional-requirements.md#site-performance-report)
through
[EMS-REQ-116](../../02-requirements/functional-requirements.md#site-performance-report).

## User experience

[../../03-ux-and-design/information-architecture.md](../../03-ux-and-design/information-architecture.md)
§"Site Performance Report". Two steps: configure (hierarchy context +
reporting period), then a generated in-app report with the same six-part
structure as Site Overview (Overall Site Health/Status → Attention/
Exceptions → Energy Performance → Maximum Demand → Power Quality →
Investigation paths), plus an optional client-side PDF export. Reports
area only — not reachable contextually from other screens.

## Business rules

Exactly one report type for MVP-6. Only existing EMS metrics, comparisons/
baselines, and deterministic rules — no new analytics, thresholds,
metrics, or AI/LLM narrative reasoning. No overall report status beyond
the existing three-state Site Health signal. No report history, email
delivery, share links, or scheduling.

**Two genuine, named platform-capability limitations** (not implementation
shortcuts — see ADR-015 "Decision — gap resolutions" for full detail):

1. Report content (Health/Attention/Energy/Demand/Power-Quality) is always
   the selected Site's own data — selecting a Space or Asset as hierarchy
   context changes only the report title and the Investigation section's
   link target, because no Space/Asset-scoped equivalent of these
   analytics exists anywhere in the platform (ADR-015 gap resolution 1).
2. Site Health and Attention require the Slice C typical-reference
   endpoint's exact whole-day window (1/7/30/90/365 days). Current-
   calendar to-date periods (e.g. "12 days into this month") essentially
   never satisfy this, so those two sections legitimately read
   "unavailable" for most report periods — Energy's own current value and
   a Previous-Period comparison remain available regardless, since that
   basis has no such restriction (ADR-015 gap resolution 6).

## Data / API dependencies

No new endpoint. Composed entirely from already-live endpoints: `GET
/sites/{id}/energy/consumption` (+ `.../evidence`, `.../typical-
reference`), `GET /sites/{id}/demand`, `GET /sites/{id}/power-quality`,
`GET /sites/{id}/spaces`, `GET /sites/{id}/assets` — the same calls
`SiteOverview.tsx`, `DemandOverview.tsx`, and `PowerQualityOverview.tsx`
already make, satisfying `EMS-REQ-093`'s on-screen parity requirement by
construction (no second computation path).

Two client-side-only additions, not API dependencies:
- `web/src/reports/sitePerformanceReportRanges.ts` — current-calendar
  Weekly/Monthly/Quarterly/Yearly period math and arbitrary-range request
  planning, reusing (not duplicating) the exact window caps
  `web/src/time/ranges.ts` already enforces for every existing screen.
- `web/src/reports/pdf.ts` — the PDF-generation foundation (jsPDF 4.2.1,
  pinned above 2.5.2's published critical CVEs). No server-side
  report-generation job exists or is introduced (ADR-015 gap resolutions
  4-5) — PDF is generated synchronously in the browser.

## Architecture

Two new frontend-only screens under `web/src/routes/reports/` plus the
two modules above. No API, database, or migration change.

## Validation

Frontend unit/component tests: `sitePerformanceReportRanges.test.ts`,
`pdf.test.ts`, `SitePerformanceReportConfig.test.tsx`,
`SitePerformanceReportView.test.tsx`, `SitePerformanceReport.test.tsx` —
28 new tests, landed alongside the implementation (2026-09-14). Full
frontend suite (209 tests), `tsc --noEmit`, `eslint --max-warnings 0`, and
`vite build` all verified passing in the same session. Not yet validated
against a live staging environment.

## Release status

**Implemented, not yet deployed.** Built on `feature/mvp6-q76-site-
performance-report`, branched fresh from `origin/staging` per this
repository's branching rule. Not merged, not pushed to staging at the
time of this record.

## Known limitations

Beyond the two platform-capability gaps above: Custom period selection
does not enforce a data-availability bound, because no endpoint exposes a
site's actual minimum/maximum data-available date range anywhere in the
platform (ADR-015 gap resolution 2 — the same gap already recorded
against Export, ADR-014 decision 9). jsPDF's bundled `html()` plugin pulls
in `html2canvas`/`dompurify` as additional build chunks (~230KB) even
though this feature only uses jsPDF's plain text-layout API — a bundle-
size tradeoff noted but not resolved in this increment.

## Future scope

Additional report types (the catalogue is currently exactly one); Excel
report format (`EMS-REQ-091` remains `BLOCKED`); a real data-availability
bound for Custom periods; genuinely Space/Asset-scoped report content, if
and when the underlying analytics API gains that capability; background/
server-side PDF generation, if a real size threshold and job
infrastructure are ever decided.
