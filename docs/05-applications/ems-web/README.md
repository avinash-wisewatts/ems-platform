# EMS Web Application

Status: CURRENT · Last reviewed: 2026-09-13 · Owner: Engineering
Related decisions: [ADR-006](../../00-governance/decisions/ADR-006-ems-web-app-vs-admin-portal.md)

## Purpose

The new customer-facing application: understand facility/site performance,
investigate energy and environmental behaviour, navigate sites/spaces/
assets, analyse consumption and demand, understand equipment performance,
identify problems — and, eventually, recommendations, reporting, and
sustainability capabilities. See
[../../01-product/product-definition.md](../../01-product/product-definition.md)
§3.2.

## Technology and delivery

React / TypeScript SPA. Currently delivered as an independently versioned
`ghcr.io/<repo>-web:<sha>` artifact, mounted read-only into the
admin-portal container and served same-origin under `/app` by the existing
FastAPI hook. This is a delivery mechanism chosen because no reverse proxy
exists yet — see
[../../04-architecture/deployment-architecture.md](../../04-architecture/deployment-architecture.md) —
not the application's architectural boundary.

## Data access

Read-only, via the Analytics API only ([../analytics-api/README.md](../analytics-api/README.md)).
No direct DB/TimescaleDB/Grafana access, no query builder, no dynamic SQL.

## Authentication

Reuses the existing signed session cookie (`ems_admin_session`), shared
with the Administration App — same-origin delivery so the cookie flows to
`/api/v1` automatically. No parallel auth system.

## Implementation status (verified against `origin/staging`, commit `ddbe5a4`, 2026-09-13)

**Phase 8 (Frontend Foundation) — DONE.** Landed: `e5fd026`…`7c4349a` (10
commits) + PR #44 — the shared shell (`SessionProvider`/`TenantProvider`/
`RequirePermission`, `TimeRangePicker`, `ChartFrame`, `QualityIndicator`,
`EmptyState`/`ErrorState`/`NoDataYet`/`Loading`, `AppLayout`/`router.tsx`).

**MVP-1 (Hierarchy & Navigation) — DONE.** PR #46 (Slice 0), closed out by
PR #50. Real `SpacesList`/`SpaceDetail` and `AssetsList`/`AssetDetail`
screens replace the placeholder; primary nav renders in two IA-labelled
sections ("Site" and "Spaces & Assets"); `HierarchyCrumb` gains a
`multiSite` segment for portfolio-level visibility (Q69/Q101/Q62).

**MVP-2 (Core Energy Analytics) — DONE.** `EnergyOverview` (PR #46),
`DemandOverview`/`PowerQualityOverview` (Slice B, PR #48), and the Slice C
historical-comparison ("typical reference") capability (PR #49) are all
live — see [ADR-009](../../00-governance/decisions/ADR-009-slice-c-historical-reference-methodology.md).

**MVP-3 (Site Overview & Attention) — DONE.** `SiteOverview.tsx` (PR #50,
commit `ddbe5a4`) replaces the `ShellHome` placeholder at `/home` with a
real composite screen in the Q70 order: Site Health → Attention → Energy →
Demand → Power Quality → investigation paths. Energy Attention (the only
approved MVP-3 Attention rule) and the three-state Site Health computation
are both implemented — see
[ADR-010](../../00-governance/decisions/ADR-010-mvp3-attention-materiality-policy.md)
and [ADR-011](../../00-governance/decisions/ADR-011-insufficient-data-not-healthy.md).
See [../../08-verification/staging-validation.md](../../08-verification/staging-validation.md)
for the MVP-3 staging validation record.

**Confirmed NOT built (still `PlaceholderArea.tsx`)**: Portfolio, Alerts,
Export, Reports, Analytics/Trends/Comparisons/Correlations screens (MVP-6
through MVP-8, and the deferred/Post-MVP areas).

See [../../01-product/roadmap.md](../../01-product/roadmap.md) for MVP-4
through MVP-8, and [../../07-features/](../../07-features/) for
per-feature detail.
