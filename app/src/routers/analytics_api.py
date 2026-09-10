"""Phase 7 -- the /api/v1 semantic read API (first slice).

Three read-only endpoints consumed by the future EMS web application:

    GET /api/v1/sites
    GET /api/v1/sites/{site_id}/energy/consumption
    GET /api/v1/spaces/{space_id}/measurements

Every endpoint requires the existing authenticated portal session. Tenant /
site / space access is enforced server-side inside the database boundary
functions (migration 231), keyed on the authenticated portal_user_id --
identifiers supplied by the browser are never trusted. An inaccessible or
unknown site/space is indistinguishable from a missing one (both HTTP 404).
"""

from __future__ import annotations

from uuid import UUID

from fastapi import APIRouter, HTTPException, Query, Request, status

from src.auth.dependencies import get_authenticated_portal_user
from src.auth.models import AuthenticatedPortalUser
from src.analytics_api_service import (
    ENERGY_RESOLUTION_MAX_WINDOW,
    MEASUREMENT_RESOLUTION_MAX_WINDOW,
    ApiContractError,
    EnergyConsumptionResponse,
    MeasurementSeriesResponse,
    SitesResponse,
    build_energy_consumption_response,
    build_measurement_series_response,
    build_sites_response,
    fetch_accessible_sites,
    fetch_site_energy_consumption,
    fetch_space_measurement_series,
    parse_time_range,
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
