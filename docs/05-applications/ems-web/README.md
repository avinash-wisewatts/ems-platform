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

React / TypeScript SPA. Built once in CI as an independently versioned,
SHA-labelled `ghcr.io/<repo>-web:<sha>` nginx image (`web/Dockerfile`).

- **Deployed today (staging only):** the image's bundle is extracted and
  mounted read-only into the admin-portal container and served same-origin
  under `/app` by the existing FastAPI hook. Production serves no frontend
  (API-only, release plan D6).
- **Staging since 2026-10-26 (PR #156):** the image runs as the dedicated `ems-web` container;
  admin-portal proxies `/app/*` to it after authentication when the host
  sets `EMS_WEB_UPSTREAM`. Deployed and rolled back on its own
  (`deploy-web.yml` / `scripts/release/deploy_web.sh`, recreating only
  `ems-web`); the bind-mount hook remains the fallback.

**Target (ADR-023, stages 1–2 implemented, not deployed):** a dedicated
customer hostname served by an edge proxy: `/app` → `ems-web`, `/api/v1` and
`/auth` → `customer-api`, so customer requests no longer pass through the
Administration App. Stage 3 (pending) replaces the redirect to the
Administration App's `/login` with the app's own sign-in page calling
`POST /auth/login`.

Either way `/app` is a delivery detail, not the application's architectural
boundary — see
[../../04-architecture/deployment-architecture.md](../../04-architecture/deployment-architecture.md).

**Reports tab visibility.** The SPA shows Reports (and polls its job list)
only when `GET /api/v1/me` lists `report.export`. On the same branch, `/me`
advertises it only where `EMS_REPORTS_ENABLED` is on (staging), since the
Reports routes are not mounted elsewhere; the role grant and server-side
authorization are unchanged.

## Data access

Read-only, via the Analytics API only ([../analytics-api/README.md](../analytics-api/README.md)).
The one exception (2026-10-24): the Reports tab creates and retries the
user's own export jobs through the Analytics API
([../../07-features/export/README.md](../../07-features/export/README.md)) —
no EMS data is written.
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
