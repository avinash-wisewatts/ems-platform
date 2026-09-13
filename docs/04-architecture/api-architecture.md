# API Architecture

Status: CURRENT · Last reviewed: 2026-09-13 · Owner: Architecture
Source of truth: `ems-product-architecture.md` §3 (archived); verified against `origin/staging` 2026-09-11.
Related decisions: [ADR-007](../00-governance/decisions/ADR-007-analytics-api-boundary.md)

## Shape

Semantic, read-only `GET /api/v1/*`. Flat top-level error envelope:
`{"error": "<code>", "detail": "<message>"}` — `401 unauthenticated`, `403`,
`404 not_found`, `422 invalid_parameter`/`invalid_resolution`/`invalid_request`.

## Auth

The existing signed session cookie (`ems_admin_session`), shared with the
Administration App. Served same-origin so the cookie flows automatically —
no second auth system, no CORS, no CSRF token for GET-only reads.

## Authorisation

Enforced **server-side** — SECURITY DEFINER functions
(`admin.portal_user_can_access_site`, `analytics.portal_user_can_access_space`,
migration 231) plus session middleware. Frontend permission checks are
UX-only.

## Live endpoints (verified against `origin/staging`, commit `ddbe5a4`, 2026-09-13)

| Endpoint | Purpose | Notes |
|---|---|---|
| `GET /api/v1/me` | Session echo — identity + derived permission codes | Additive; no DB, no secrets. |
| `GET /api/v1/sites` | Scope-filtered site list | `site_id`, `site_code`, `site_name`, `organization_id`, `timezone`. |
| `GET /api/v1/sites/{site_id}/spaces` | "Spaces for a site" list | MVP-1 — landed PR #46. |
| `GET /api/v1/sites/{site_id}/assets` | "Assets for a site" list | MVP-1 — landed PR #46. |
| `GET /api/v1/sites/{site_id}/energy/consumption` | Energy consumption series | `from`, `to`, `resolution`; `no_data` is a normal 200. |
| `GET /api/v1/sites/{site_id}/energy/consumption/evidence` | Energy-consumption data-quality/evidence detail | MVP-2/Slice C — landed PR #49. |
| `GET /api/v1/sites/{site_id}/energy/consumption/typical-reference` | Historical comparison ("typical reference") | Slice C — see [ADR-009](../00-governance/decisions/ADR-009-slice-c-historical-reference-methodology.md). |
| `GET /api/v1/sites/{site_id}/demand` | Demand series | MVP-2/Slice B — landed PR #48. |
| `GET /api/v1/sites/{site_id}/demand/current` | Current demand | MVP-2/Slice B. |
| `GET /api/v1/sites/{site_id}/power-quality` | Power Quality (PF/THD) series | MVP-2/Slice B — landed PR #48. |
| `GET /api/v1/spaces/{space_id}/measurements` | Environmental series | `parameter` ∈ {TEMPERATURE, HUMIDITY, DEW_POINT}, `resolution` ∈ {raw, 1h}; `no_data` normal 200; inaccessible/unknown → 404 with no existence leak. DEW_POINT is consumed from the persisted tier — never recalculated in the browser. |

## Extension model

Additive `v_grafana_*`-pattern views/functions + a thin FastAPI layer only
for what a view cannot express. **No change to the existing contract without
an explicit architecture decision.** If a screen needs data the API doesn't
expose, that is a dependency to schedule — see
[../02-requirements/requirements-traceability.md](../02-requirements/requirements-traceability.md)
— never a reason to bypass the boundary.

## Not yet built

Asset-relationship/component-tree read objects (deferred, see
[ADR-013](../00-governance/decisions/ADR-013-deferred-asset-component-tree.md)),
site-wide environmental roll-up, comfort targets, device/point telemetry
state (freshness — MVP-4), Attention/Issues surface (MVP-3, distinct from
the frontend-only Energy Attention rule already shipped — see
[ADR-010](../00-governance/decisions/ADR-010-mvp3-attention-materiality-policy.md)),
cost, alert, export, portfolio, and reporting endpoints. See
[../01-product/roadmap.md](../01-product/roadmap.md).
