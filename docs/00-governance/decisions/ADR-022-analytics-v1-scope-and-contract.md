# ADR-022: Analytics v1 — scope, catalogue and series contract

Status: Decided (Product Owner, 2026-09-27); implementation in progress (B0/B1 first — see [Analytics feature](../../07-features/analytics/README.md#implementation-plan)).
Date: 2026-09-27
Decision owners: Product Owner
Related requirements: EMS-REQ-037 (Trends, refined here), EMS-REQ-129 – EMS-REQ-139 (new, Analytics v1), EMS-REQ-901 / EMS-REQ-903 (unchanged exclusions).
Related features: [Analytics](../../07-features/analytics/README.md)
Related decisions: [ADR-007](ADR-007-analytics-api-boundary.md), [ADR-014](ADR-014-q75-export-scope-and-behavior.md), [ADR-018](ADR-018-asset-point-assignment-and-commissioning.md), [ADR-019](ADR-019-analytical-backbone-time-basis-and-tiers.md)

## Context

The EMS Web App shell has an "Analytics" navigation entry that routes to a
placeholder. The Product Owner supplied an Analytics requirements PDF with
mockups as a design reference. That PDF is a temporary, uncommitted artifact
and is not a repository document; its content is carried into committed
documentation only where the Product Owner has confirmed it (see the
Analytics feature document, which labels every requirement's origin).

A read-only reconciliation (2026-09-27) against `origin/staging` and the
staging database found:

- `metadata.asset_points` on staging holds 108 rows: `ENERGY_IMPORT_TOTAL` and
  `ENERGY_EXPORT_TOTAL` for each of the 54 assets that have a
  `PRIMARY_METER` relationship, on two sites. All were written in one
  statement at 2026-09-25 21:06:21 IST, 40 minutes before migration 263 was
  applied, with `effective_from = '-infinity'` and no `admin.onboarding_audit`
  entry. No committed migration, seed or application path writes them.
  Earlier statements that staging has 0 `asset_points` rows (ADR-018,
  change-history entry for migration 263) are stale.
- The Asset Data Point Assignment workflow (ADR-018 Amendments 5–8) is not
  deployed; no non-Energy point is assigned to any asset.
- ADR-019 D2 (block site timezone edits once a site has telemetry) is decided
  but not implemented: `admin.update_site_workspace` accepts any valid IANA
  zone at any time.
- The canonical Energy read's 1h tier (`analytics.v_energy_reporting_hourly`)
  buckets by site-local hour, while ADR-019 D3 puts 1h on the UTC grid.
- The `/api/v1` surface is GET-only by design
  (`app/src/auth/authorization.py`).

## Decision

1. **Reference material.** The Analytics PDF is not committed. Committed
   Analytics requirements live in the Analytics feature document and the
   requirements catalogue.
2. **Curated semantic explorer.** Analytics is a curated, semantic Trends
   explorer, not a raw-tag browser or free-form query builder (EMS-REQ-901/903
   unchanged). Users select Assets and semantic Data Points only from the
   confirmed `metadata.asset_points` catalogue (ADR-018 decision 1).
3. **Energy-only pilot.** An Energy-only pilot on the currently deployed
   Energy assignments is acceptable. Analytics implementation is not blocked
   on the full Asset Data Point Assignment workflow.
4. **Staging parity-bridge rows.** The 108 staging `asset_points` rows are
   staging-only parity-bridge assignments for development and testing. They
   are **not** completed commissioning. They must not be modified by
   Analytics work. Parity-bridge status is not customer-facing; an internal
   `attribution_basis` may exist in the read model only.
5. **Multi-type trends allowed.** Analytics Trends may combine assets of
   different asset types. The Post-MVP Comparisons fairness rule (EMS-REQ-038
   / EMS-REQ-064: comparisons only within one `asset_type_id`) governs the
   separate Comparisons capability and does not prohibit multi-type trend
   investigation.
6. **ACTIVE assets only.** The customer Analytics catalogue lists only assets
   with `lifecycle_status = 'ACTIVE'`. DRAFT and COMMISSIONING (and every
   other non-ACTIVE status) are excluded.
7. **Limits.** At most 5 distinct data points, 10 selected assets and 25
   rendered series per request.
8. **Energy directions.** Energy Import and Energy Export are separate
   selectable data points.
9. **1h basis.** Analytics 1h follows the UTC-grid contract (ADR-019 D3) for
   every data point, Energy included. Existing Energy screens (Main
   Dashboard, Asset View, Energy) are not changed by this work.
10. **Asset-only v1.** Analytics v1 is Asset-only. Environmental / Space data
    (`metadata.space_points`) is out of scope for v1 and is not forced into
    the Asset contract.
11. **Per-series statistics.** Summary statistics are per
    asset × data point × phase series. No cross-asset aggregate totals in v1.
12. **Grouped Energy bars.** Energy is drawn as grouped bars, not stacked.
13. **1d required in v1.** 1-day resolution is required in Analytics v1, with
    proper site-local calendar-day semantics and DST handling. It is not
    deferred behind ADR-019 M3; the persisted generic 1d tier is part of the
    Analytics v1 plan.
14. **Explicit selections.** The series API takes an explicit list of
    (asset, data point) selections rather than independent asset and data
    point lists, so a request never produces an unintended cross-product.

## Rationale

Product Owner decisions, recorded 2026-09-27. Decisions 5, 9 and 11 resolve
conflicts the reconciliation surfaced between the PDF and committed IA / ADR
text. Decision 4 preserves ADR-018's distinction between confirmed
commissioning and an assignment made for another purpose.

## Alternatives considered

- Deriving the data-point list from device capability (the PDF's fallback):
  rejected by ADR-018 decision 1.
- Deferring 1d until ADR-019 M3: rejected by decision 13.
- Independent `asset_id[]` / `data_point[]` request arrays: rejected by
  decision 14.
- A POST request body for selections: not chosen at the implementation level,
  because `/api/v1` is a GET-only surface with no CSRF handling. Selections
  are carried as repeated query parameters instead.

## Consequences

- Production has no `asset_points` rows (decision 4 scopes the 108 rows to
  staging). Until the Asset Data Point Assignment workflow is deployed and
  real assets are commissioned there, the production Analytics catalogue is
  empty. See open question 6 in the feature document.
- Non-Energy data points, 3-phase selection and Power / Power Quality grouping
  remain blocked on the Asset Data Point Assignment workflow.
- ADR-019 D2 must be implemented before any persisted site-local-day tier
  (B0 in the feature plan).
- Analytics hourly Energy bars for half-hour-offset sites (all current sites
  are `Asia/Kolkata`) start on the half hour and differ from the site-local
  hourly bars on the existing Energy screens; daily totals are unaffected.

## Evidence / references

- Read-only staging verification, 2026-09-27 (image `5eb02ca`, ledger through
  migration 270): `metadata.asset_points` counts, provenance timestamps,
  `admin.schema_migrations`, `pg_get_viewdef('analytics.v_energy_reporting_hourly')`,
  `pg_get_functiondef('admin.update_site_workspace')`,
  `config.telemetry_capture_policies`, TimescaleDB chunk and policy metadata.
- `app/src/auth/authorization.py` (`/api/v1` GET-only surface).

## Implementation references

- B0: `postgres/migrations/275_site_timezone_immutable_with_telemetry.sql` (ADR-019 D2).
- B1: `postgres/migrations/276_analytics_api_catalog.sql`, `app/src/analytics_trends_service.py`, `GET /api/v1/sites/{site_id}/analytics/catalog`.
- B1b: `postgres/migrations/277_analytics_api_energy_availability.sql` (availability bounds per Energy data point, in the catalogue).
- B2: `postgres/migrations/278_analytics_api_energy_series.sql`, `GET /api/v1/sites/{site_id}/analytics/series` (explicit selections; Energy only; UTC-grid 1h; DST-correct site-local 1d).
- Amendment 1: `postgres/migrations/279_asset_energy_tier_read.sql` (deployed to staging, PR #85), `postgres/migrations/280_analytics_energy_persisted_tier_switch.sql` (not deployed).
- Remaining steps: [the Analytics feature document](../../07-features/analytics/README.md#implementation-plan).

## Validation references

Local only (2026-09-27): see the feature document's Validation section. Not deployed.

---

## Amendment 1 (2026-09-27): Option B — Analytics Energy from the persisted tiers

**Decision (Product Owner, 2026-09-27).** Customer Energy reads for Analytics
are keyed on the portal user and the asset's organization, never on
`metadata.grafana_organization_map`. Analytics Energy reads ADR-019's
persisted Energy tiers: `energy_consumption_15min` (15m; 30m derived from it),
`energy_consumption_hourly` (UTC hours), `energy_consumption_daily`
(site-local days) and raw 1-minute data only within raw retention.

**Why.** A read-only investigation found that `analytics.get_canonical_energy_read`
— the source of the first B2 implementation — is keyed on the Grafana
organization mapping, which only Grafana provisioning writes (staging: 2
mappings for 3 organizations), and aggregates every tier at request time from
raw 1-minute/5-minute rows, so it cannot return anything older than raw
retention (180 days). Option A (an organization-keyed core inside the
canonical read) was rejected because it keeps both the retention limit and the
request-time aggregation cost.

**Delivery, parity-gated.**
1. Migration 279 — `analytics.get_portal_asset_energy_series`, additive.
   Deployed to staging 2026-09-27 (PR #85, `5ca62b0`). Read-only staging parity
   gate PT-1–PT-11 against the canonical read: zero mismatches at every
   resolution; the 108 parity-bridge rows unchanged.
2. Migration 280 — Analytics switches to 279 (the canonical-read-era Analytics
   series function from 278 is dropped); availability aligned with the same
   tiers; per-resolution retention floors make out-of-retention requests
   `RESOLUTION_UNAVAILABLE`. HTTP contract unchanged.

**Unchanged.** `analytics.get_canonical_energy_read`, every Grafana path and
the Asset View Energy tile; moving the Asset View off the Grafana-keyed read is
a separate, parity-gated decision.
