"""Phase 7 -- the /api/v1 semantic read API (first slice).

Read-only endpoints consumed by the EMS web application:

    GET /api/v1/me                                      (Phase 8: session echo)
    GET /api/v1/sites
    GET /api/v1/sites/{site_id}/energy/consumption
    GET /api/v1/spaces/{space_id}/measurements
    GET /api/v1/sites/{site_id}/spaces                  (Slice 0: hierarchy)
    GET /api/v1/sites/{site_id}/assets                  (Slice 0: hierarchy)
    GET /api/v1/sites/{site_id}/demand                  (Slice B: demand)
    GET /api/v1/sites/{site_id}/demand/current           (Slice B: demand)
    GET /api/v1/sites/{site_id}/power-quality            (Slice B: PQ)
    GET /api/v1/sites/{site_id}/energy/consumption/evidence (Slice C: C2)
    GET /api/v1/sites/{site_id}/energy/consumption/typical-reference (Slice C)

Every endpoint requires the existing authenticated portal session. Tenant /
site / space access is enforced server-side inside the database boundary
functions (migration 231), keyed on the authenticated portal_user_id --
identifiers supplied by the browser are never trusted. An inaccessible or
unknown site/space is indistinguishable from a missing one (both HTTP 404).

GET /api/v1/me (added in Phase 8) is an additive session echo -- it reflects
only the already-safe fields of the authenticated session so a browser SPA
can bootstrap identity/role/scope without a second auth system. It changes
none of the three frozen Phase 7 data contracts.

GET /api/v1/sites/{site_id}/spaces and .../assets (Slice 0, migration 232)
are additive, site-scoped hierarchy listings -- identity and placement only.
Neither reads metadata.asset_relationships; asset component-tree / "spaces
served by an asset" are explicitly out of scope for this increment.

GET /api/v1/sites/{site_id}/demand and .../demand/current (Slice B,
migration 233) read analytics.demand_intervals / analytics.demand_state
only -- both already meter-role-resolved upstream; neither this router nor
migration 233 re-derives that resolution or reads the older
v_energy_demand_15min / v_energy_site_demand_kpis view family.

GET /api/v1/sites/{site_id}/power-quality (Slice B, migration 234) resolves
the site's SITE_CONSUMPTION-role meter directly against
config.site_energy_meter_roles (independent of the demand-specific
config.site_demand_policies) and reads telemetry.ca_energy_15min/hourly/
daily. No PF/THD threshold is exposed -- none exists in the schema.

GET /api/v1/sites/{site_id}/energy/consumption/evidence (Slice C, migration
235) is an additive parallel read of the SAME two historians
GET /energy/consumption reads -- it does not call, modify, or change the
contract of that endpoint. Exposes coverage/gap/reset/rollover counters
already present on those historian rows; invents no new quality
classification.

GET /api/v1/sites/{site_id}/energy/consumption/typical-reference (Slice C,
migration 236) is the comparable-period historical reference (median of up
to 8 coverage-eligible comparable periods; see the approved Slice C
Historical Comparison decision pack). Additive alongside -- never a
replacement for -- GET /energy/consumption; reads ONLY
analytics.energy_consumption_daily (not the hourly table, which lacks a
trustworthy site-local calendar date) and has NO dependency on migration
235. One bounded request returns the complete reference; the frontend never
issues N follow-up calls for this feature.
"""

from __future__ import annotations

from uuid import UUID

from fastapi import APIRouter, HTTPException, Query, Request, status

from src.auth.authorization import ROLE_PERMISSIONS, portal_role
from src.auth.dependencies import get_authenticated_portal_user
from src.auth.models import AuthenticatedPortalUser
from src.analytics_api_service import (
    DEMAND_MAX_WINDOW,
    ENERGY_RESOLUTION_MAX_WINDOW,
    MEASUREMENT_RESOLUTION_MAX_WINDOW,
    POWER_QUALITY_RESOLUTION_MAX_WINDOW,
    ApiContractError,
    AssetsResponse,
    CurrentDemandResponse,
    CurrentUserResponse,
    DemandSeriesResponse,
    EnergyConsumptionEvidenceResponse,
    EnergyConsumptionResponse,
    EnergyTypicalReferenceResponse,
    MeasurementSeriesResponse,
    PowerQualityResponse,
    SitesResponse,
    SpacesResponse,
    build_assets_response,
    build_current_demand_response,
    build_demand_series_response,
    build_energy_consumption_evidence_response,
    build_energy_consumption_response,
    build_energy_typical_reference_response,
    build_measurement_series_response,
    build_power_quality_response,
    build_sites_response,
    build_spaces_response,
    fetch_accessible_sites,
    fetch_site_assets,
    fetch_site_current_demand,
    fetch_site_demand_series,
    fetch_site_energy_consumption,
    fetch_site_energy_consumption_evidence,
    fetch_site_energy_typical_reference,
    fetch_site_power_quality_series,
    fetch_site_spaces,
    fetch_space_measurement_series,
    parse_time_range,
    parse_typical_reference_range,
    portal_user_can_access_space,
    portal_user_can_access_site,
    validate_measurement_parameter,
    validate_resolution,
)


router = APIRouter(prefix="/api/v1", tags=["analytics-api-v1"])


_AUTH_RESPONSES: dict[int | str, dict] = {
    401: {"description": "Authentication is required."},
}

_RESOURCE_RESPONSES: dict[int | str, dict] = {
    401: {"description": "Authentication is required."},
    404: {
        "description": "The site or space does not exist or is not "
        "accessible (indistinguishable by design)."
    },
    422: {"description": "The request violates the fixed API contract."},
}


def _require_portal_user(request: Request) -> AuthenticatedPortalUser:
    """Return the authenticated portal identity or raise HTTP 401.

    PortalAuthenticationMiddleware already rejects unauthenticated /api/v1
    requests with a JSON 401; this is a fail-closed second gate for the
    route itself.
    """

    user = get_authenticated_portal_user(request)
    if user is None:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail={
                "error": "unauthenticated",
                "detail": "Authentication is required.",
            },
        )
    return user


def _contract_error(exc: ApiContractError) -> HTTPException:
    return HTTPException(
        status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
        detail={"error": exc.code, "detail": exc.detail},
    )


def _not_found(kind: str) -> HTTPException:
    return HTTPException(
        status_code=status.HTTP_404_NOT_FOUND,
        detail={
            "error": "not_found",
            "detail": f"{kind} not found or not accessible.",
        },
    )


@router.get(
    "/me",
    response_model=CurrentUserResponse,
    summary="Echo the authenticated portal session (frontend bootstrap)",
    operation_id="getCurrentUser",
    tags=["session"],
    responses=_AUTH_RESPONSES,
)
async def get_current_user(request: Request) -> CurrentUserResponse:
    """Return the current session identity + derived permission codes.

    Additive session echo (Phase 8). No database access, no secrets: it
    serialises the same safe fields the signed session already holds so the
    SPA can render tenant context and permission-gated navigation. Frontend
    permission checks are UX only -- server-side enforcement is unchanged.
    """

    user = _require_portal_user(request)

    role = portal_role(user)
    permissions = sorted(
        p.value for p in (ROLE_PERMISSIONS.get(role, frozenset()) if role else frozenset())
    )

    return CurrentUserResponse(
        portal_user_id=user.portal_user_id,
        username=user.username,
        display_name=user.display_name,
        role_code=user.role_code,
        access_scope_mode=user.access_scope_mode or "",
        organization_id=user.organization_id,
        site_ids=list(user.site_ids),
        permissions=permissions,
    )


@router.get(
    "/sites",
    response_model=SitesResponse,
    summary="List the authenticated user's accessible sites",
    operation_id="listAccessibleSites",
    responses=_AUTH_RESPONSES,
)
async def list_sites(request: Request) -> SitesResponse:
    user = _require_portal_user(request)
    rows = await fetch_accessible_sites(user.portal_user_id)
    return build_sites_response(rows)


@router.get(
    "/sites/{site_id}/energy/consumption",
    response_model=EnergyConsumptionResponse,
    summary="Site energy consumption series (mature persisted historian)",
    operation_id="getSiteEnergyConsumption",
    responses=_RESOURCE_RESPONSES,
)
async def get_site_energy_consumption(
    request: Request,
    site_id: UUID,
    resolution: str = Query(
        ...,
        description="Time resolution. One of: 1h, 1d.",
    ),
    range_from: str = Query(
        ...,
        alias="from",
        description="Inclusive ISO-8601 start of the window (UTC).",
    ),
    range_to: str = Query(
        ...,
        alias="to",
        description="Exclusive ISO-8601 end of the window (UTC).",
    ),
) -> EnergyConsumptionResponse:
    user = _require_portal_user(request)

    try:
        resolved = validate_resolution(
            resolution, tuple(ENERGY_RESOLUTION_MAX_WINDOW.keys())
        )
        dt_from, dt_to = parse_time_range(
            range_from,
            range_to,
            resolution=resolved,
            max_window_by_resolution=ENERGY_RESOLUTION_MAX_WINDOW,
        )
    except ApiContractError as exc:
        raise _contract_error(exc)

    if not await portal_user_can_access_site(user.portal_user_id, site_id):
        raise _not_found("Site")

    rows = await fetch_site_energy_consumption(
        portal_user_id=user.portal_user_id,
        site_id=site_id,
        dt_from=dt_from,
        dt_to=dt_to,
        resolution=resolved,
    )
    return build_energy_consumption_response(
        site_id=site_id,
        resolution=resolved,
        dt_from=dt_from,
        dt_to=dt_to,
        rows=rows,
    )


@router.get(
    "/sites/{site_id}/energy/consumption/evidence",
    response_model=EnergyConsumptionEvidenceResponse,
    summary="Site energy consumption evidence/coverage counters (Slice C, C2)",
    operation_id="getSiteEnergyConsumptionEvidence",
    responses=_RESOURCE_RESPONSES,
)
async def get_site_energy_consumption_evidence(
    request: Request,
    site_id: UUID,
    resolution: str = Query(
        ...,
        description="Time resolution. One of: 1h, 1d.",
    ),
    range_from: str = Query(
        ...,
        alias="from",
        description="Inclusive ISO-8601 start of the window (UTC).",
    ),
    range_to: str = Query(
        ...,
        alias="to",
        description="Exclusive ISO-8601 end of the window (UTC).",
    ),
) -> EnergyConsumptionEvidenceResponse:
    """Slice C (C2). Additive parallel read of the SAME two historians
    GET /energy/consumption reads (migration 235) -- does not call, modify,
    or change the contract of get_site_energy_consumption above. Exposes
    coverage/gap/reset/rollover counters that already exist on those
    historian rows. No new quality classification is invented."""

    user = _require_portal_user(request)

    try:
        resolved = validate_resolution(
            resolution, tuple(ENERGY_RESOLUTION_MAX_WINDOW.keys())
        )
        dt_from, dt_to = parse_time_range(
            range_from,
            range_to,
            resolution=resolved,
            max_window_by_resolution=ENERGY_RESOLUTION_MAX_WINDOW,
        )
    except ApiContractError as exc:
        raise _contract_error(exc)

    if not await portal_user_can_access_site(user.portal_user_id, site_id):
        raise _not_found("Site")

    rows = await fetch_site_energy_consumption_evidence(
        portal_user_id=user.portal_user_id,
        site_id=site_id,
        dt_from=dt_from,
        dt_to=dt_to,
        resolution=resolved,
    )
    return build_energy_consumption_evidence_response(
        site_id=site_id,
        resolution=resolved,
        dt_from=dt_from,
        dt_to=dt_to,
        rows=rows,
    )


@router.get(
    "/sites/{site_id}/energy/consumption/typical-reference",
    response_model=EnergyTypicalReferenceResponse,
    summary="Site typical historical consumption -- comparable-period reference (Slice C)",
    operation_id="getSiteEnergyTypicalReference",
    responses=_RESOURCE_RESPONSES,
)
async def get_site_energy_typical_reference(
    request: Request,
    site_id: UUID,
    range_from: str = Query(
        ...,
        alias="from",
        description="Inclusive ISO-8601 start of the CURRENT window (UTC).",
    ),
    range_to: str = Query(
        ...,
        alias="to",
        description=(
            "Exclusive ISO-8601 end of the current window (UTC). "
            "(to - from) must be exactly 1, 7, 30, 90, or 365 whole days."
        ),
    ),
) -> EnergyTypicalReferenceResponse:
    """Slice C. Comparable-period historical reference (migration 236) --
    always 8 requested comparable periods, median of the coverage-eligible
    ones (minimum 5). One bounded request; no frontend N+1. Additive
    alongside GET /energy/consumption -- does not call, modify, or change
    its contract, and has no dependency on migration 235."""

    user = _require_portal_user(request)

    try:
        dt_from, dt_to, period_length_days = parse_typical_reference_range(
            range_from, range_to
        )
    except ApiContractError as exc:
        raise _contract_error(exc)

    if not await portal_user_can_access_site(user.portal_user_id, site_id):
        raise _not_found("Site")

    rows = await fetch_site_energy_typical_reference(
        portal_user_id=user.portal_user_id,
        site_id=site_id,
        dt_from=dt_from,
        dt_to=dt_to,
    )
    return build_energy_typical_reference_response(
        site_id=site_id,
        period_length_days=period_length_days,
        dt_from=dt_from,
        dt_to=dt_to,
        rows=rows,
    )


@router.get(
    "/spaces/{space_id}/measurements",
    response_model=MeasurementSeriesResponse,
    summary="Environmental measurement series for one space",
    operation_id="getSpaceMeasurements",
    responses=_RESOURCE_RESPONSES,
)
async def get_space_measurements(
    request: Request,
    space_id: UUID,
    parameter: str = Query(
        ...,
        description="One of: TEMPERATURE, HUMIDITY, DEW_POINT.",
    ),
    resolution: str = Query(
        ...,
        description="Time resolution. One of: raw, 1h.",
    ),
    range_from: str = Query(
        ...,
        alias="from",
        description="Inclusive ISO-8601 start of the window (UTC).",
    ),
    range_to: str = Query(
        ...,
        alias="to",
        description="Exclusive ISO-8601 end of the window (UTC).",
    ),
) -> MeasurementSeriesResponse:
    user = _require_portal_user(request)

    try:
        resolved_parameter = validate_measurement_parameter(parameter)
        resolved_resolution = validate_resolution(
            resolution, tuple(MEASUREMENT_RESOLUTION_MAX_WINDOW.keys())
        )
        dt_from, dt_to = parse_time_range(
            range_from,
            range_to,
            resolution=resolved_resolution,
            max_window_by_resolution=MEASUREMENT_RESOLUTION_MAX_WINDOW,
        )
    except ApiContractError as exc:
        raise _contract_error(exc)

    if not await portal_user_can_access_space(user.portal_user_id, space_id):
        raise _not_found("Space")

    rows = await fetch_space_measurement_series(
        portal_user_id=user.portal_user_id,
        space_id=space_id,
        parameter=resolved_parameter,
        dt_from=dt_from,
        dt_to=dt_to,
        resolution=resolved_resolution,
    )
    return build_measurement_series_response(
        space_id=space_id,
        parameter=resolved_parameter,
        resolution=resolved_resolution,
        dt_from=dt_from,
        dt_to=dt_to,
        rows=rows,
    )


@router.get(
    "/sites/{site_id}/spaces",
    response_model=SpacesResponse,
    summary="List a site's spaces (Slice 0: Hierarchy Foundation)",
    operation_id="listSiteSpaces",
    responses=_RESOURCE_RESPONSES,
)
async def list_site_spaces(request: Request, site_id: UUID) -> SpacesResponse:
    """Identity + placement only. No environmental snapshot, no comfort
    targets -- both out of scope for this increment; see
    GET /spaces/{space_id}/measurements for a space's live readings."""

    user = _require_portal_user(request)

    if not await portal_user_can_access_site(user.portal_user_id, site_id):
        raise _not_found("Site")

    rows = await fetch_site_spaces(user.portal_user_id, site_id)
    return build_spaces_response(site_id=site_id, rows=rows)


@router.get(
    "/sites/{site_id}/assets",
    response_model=AssetsResponse,
    summary="List a site's assets (Slice 0: Hierarchy Foundation)",
    operation_id="listSiteAssets",
    responses=_RESOURCE_RESPONSES,
)
async def list_site_assets(request: Request, site_id: UUID) -> AssetsResponse:
    """Identity + placement only. NO component-tree / relationship data --
    explicitly deferred (see migration 232's header)."""

    user = _require_portal_user(request)

    if not await portal_user_can_access_site(user.portal_user_id, site_id):
        raise _not_found("Site")

    rows = await fetch_site_assets(user.portal_user_id, site_id)
    return build_assets_response(site_id=site_id, rows=rows)


@router.get(
    "/sites/{site_id}/demand",
    response_model=DemandSeriesResponse,
    summary="Site maximum-demand interval series (Slice B)",
    operation_id="getSiteDemandSeries",
    responses=_RESOURCE_RESPONSES,
)
async def get_site_demand_series(
    request: Request,
    site_id: UUID,
    range_from: str = Query(
        ...,
        alias="from",
        description="Inclusive ISO-8601 start of the window (UTC).",
    ),
    range_to: str = Query(
        ...,
        alias="to",
        description="Exclusive ISO-8601 end of the window (UTC).",
    ),
) -> DemandSeriesResponse:
    """Reads analytics.demand_intervals only -- native interval grain
    (900s/1800s per the site's own config.site_demand_policies), so there
    is no resolution query parameter to select. No re-derivation of
    meter-role resolution here; that already happened upstream."""

    user = _require_portal_user(request)

    try:
        dt_from, dt_to = parse_time_range(
            range_from,
            range_to,
            resolution="native",
            max_window_by_resolution={"native": DEMAND_MAX_WINDOW},
        )
    except ApiContractError as exc:
        raise _contract_error(exc)

    if not await portal_user_can_access_site(user.portal_user_id, site_id):
        raise _not_found("Site")

    rows = await fetch_site_demand_series(
        portal_user_id=user.portal_user_id,
        site_id=site_id,
        dt_from=dt_from,
        dt_to=dt_to,
    )
    return build_demand_series_response(
        site_id=site_id, dt_from=dt_from, dt_to=dt_to, rows=rows
    )


@router.get(
    "/sites/{site_id}/demand/current",
    response_model=CurrentDemandResponse,
    summary="Site's most recent live demand reading (Slice B)",
    operation_id="getSiteCurrentDemand",
    responses=_RESOURCE_RESPONSES,
)
async def get_site_current_demand(
    request: Request, site_id: UUID
) -> CurrentDemandResponse:
    """Reads analytics.demand_state only -- the live/current-interval
    table, distinct from the finalized historical series above."""

    user = _require_portal_user(request)

    if not await portal_user_can_access_site(user.portal_user_id, site_id):
        raise _not_found("Site")

    row = await fetch_site_current_demand(user.portal_user_id, site_id)
    return build_current_demand_response(site_id=site_id, row=row)


@router.get(
    "/sites/{site_id}/power-quality",
    response_model=PowerQualityResponse,
    summary="Site power factor / current THD series (Slice B)",
    operation_id="getSitePowerQuality",
    responses=_RESOURCE_RESPONSES,
)
async def get_site_power_quality(
    request: Request,
    site_id: UUID,
    resolution: str = Query(
        ...,
        description="Time resolution. One of: 15min, 1h, 1d.",
    ),
    range_from: str = Query(
        ...,
        alias="from",
        description="Inclusive ISO-8601 start of the window (UTC).",
    ),
    range_to: str = Query(
        ...,
        alias="to",
        description="Exclusive ISO-8601 end of the window (UTC).",
    ),
) -> PowerQualityResponse:
    """Resolves the site's SITE_CONSUMPTION-role meter directly against
    config.site_energy_meter_roles (independent of the demand-specific
    config.site_demand_policies) and reads
    telemetry.ca_energy_15min/hourly/daily for that device. No threshold
    or deviation classification -- none exists in the schema."""

    user = _require_portal_user(request)

    try:
        resolved_resolution = validate_resolution(
            resolution, tuple(POWER_QUALITY_RESOLUTION_MAX_WINDOW.keys())
        )
        dt_from, dt_to = parse_time_range(
            range_from,
            range_to,
            resolution=resolved_resolution,
            max_window_by_resolution=POWER_QUALITY_RESOLUTION_MAX_WINDOW,
        )
    except ApiContractError as exc:
        raise _contract_error(exc)

    if not await portal_user_can_access_site(user.portal_user_id, site_id):
        raise _not_found("Site")

    rows = await fetch_site_power_quality_series(
        portal_user_id=user.portal_user_id,
        site_id=site_id,
        resolution=resolved_resolution,
        dt_from=dt_from,
        dt_to=dt_to,
    )
    return build_power_quality_response(
        site_id=site_id,
        resolution=resolved_resolution,
        dt_from=dt_from,
        dt_to=dt_to,
        rows=rows,
    )
