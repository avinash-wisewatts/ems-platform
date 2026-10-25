"""Reports tab -- site measurement export routes (additive /api/v1 surface).

    GET  /api/v1/sites/{site_id}/report-exports/estimate   size + mode for a request
    GET  /api/v1/sites/{site_id}/report-exports/file       immediate ZIP download
    POST /api/v1/sites/{site_id}/report-exports            queue a background job
    GET  /api/v1/report-exports                             the caller's jobs
    GET  /api/v1/report-exports/{job_id}                    one job's status
    POST /api/v1/report-exports/{job_id}/retry              re-queue a FAILED job
    GET  /api/v1/report-exports/{job_id}/file               download a COMPLETED job

An export covers the selected assets of the site (asset_id query parameters,
or asset_ids in the POST body), at most EMS_REPORT_EXPORT_MAX_ASSETS (10);
without a selection, every asset of the site, which is then subject to the
same maximum. A selected asset that is not an accessible asset of the site
is HTTP 422 (invalid_assets).

The export reads only through the portal-scoped Analytics functions
(report_export_service.py, migration 312 for 1 minute), keyed on the
authenticated portal_user_id; job records are written only through the
migration 309 / 312 functions. An
inaccessible site, or a job that is not the caller's or whose site the caller
can no longer access, is HTTP 404 -- indistinguishable from a missing one.

The two POST routes change only the caller's own export job records. They
accept only application/json and reject cross-site requests (Sec-Fetch-Site),
on top of the SameSite=Lax session cookie, so another site cannot queue a job
in the user's name. Downloads are attachment responses with Cache-Control:
no-store, served only to the job's owner while the file is unexpired.
"""

from __future__ import annotations

from urllib.parse import quote
from uuid import UUID

from fastapi import APIRouter, HTTPException, Query, Request, Response, status
from pydantic import BaseModel, ConfigDict, Field

from src.analytics_api_service import ApiContractError, fetch_accessible_sites, fetch_site_assets
from src.auth.authorization import PortalPermission, has_permission
from src.auth.models import AuthenticatedPortalUser
from src.analytics_trends_service import fetch_analytics_catalog, fetch_analytics_site
from src.config import get_settings
from src.report_export_service import (
    ExportRequest,
    ReportExportEstimateResponse,
    ReportExportJob,
    ReportExportJobListResponse,
    build_export_zip,
    build_job,
    estimate_export,
    export_mode,
    parse_export_request,
    prepare_export,
    select_assets,
)
from src.report_export_worker import (
    ActiveJobLimitError,
    create_job,
    get_job,
    get_job_file,
    list_jobs,
    retry_job,
)
from src.routers.analytics_api import _contract_error, _not_found, _require_portal_user


router = APIRouter(prefix="/api/v1", tags=["report-exports"])

_RESPONSES: dict[int | str, dict] = {
    401: {"description": "Authentication is required."},
    403: {"description": "The user may not export reports (report.export)."},
    404: {"description": "The site or export does not exist or is not accessible (indistinguishable by design)."},
    422: {"description": "The request violates the export contract."},
}

ZIP_MEDIA_TYPE = "application/zip"


class ReportExportCreateRequest(BaseModel):
    model_config = ConfigDict(populate_by_name=True)

    range_from: str = Field(alias="from", description="Inclusive ISO-8601 start (UTC).")
    range_to: str = Field(alias="to", description="Exclusive ISO-8601 end (UTC).")
    resolution: str | None = Field(default=None, description="auto (default), 1m, 15m, 30m, 1h or 1d.")
    asset_ids: list[UUID] | None = Field(
        default=None, description="The selected assets (at most 10); omitted = every asset of the site."
    )


_ASSET_QUERY_DESCRIPTION = "A selected asset (repeat for each, at most 10); omitted = every asset of the site."


def _require_exporter(request: Request) -> AuthenticatedPortalUser:
    """The authenticated portal user, who must hold report.export (HTTP 403
    otherwise; the /api/v1 middleware gate is dashboard.view only)."""

    user = _require_portal_user(request)
    if not has_permission(user, PortalPermission.REPORT_EXPORT):
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail={"error": "forbidden", "detail": "You do not have permission to export reports."},
        )
    return user


def _require_same_site_json(request: Request) -> None:
    content_type = request.headers.get("content-type", "").split(";")[0].strip().lower()
    if content_type != "application/json":
        raise HTTPException(
            status_code=status.HTTP_415_UNSUPPORTED_MEDIA_TYPE,
            detail={"error": "unsupported_media_type", "detail": "Send the request as application/json."},
        )
    if request.headers.get("sec-fetch-site", "").lower() == "cross-site":
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail={"error": "forbidden", "detail": "Cross-site requests are not allowed."},
        )


def _zip_response(file_name: str, content: bytes) -> Response:
    ascii_name = file_name.encode("ascii", "replace").decode("ascii").replace('"', "_")
    return Response(
        content=content,
        media_type=ZIP_MEDIA_TYPE,
        headers={
            "Content-Disposition": f"attachment; filename=\"{ascii_name}\"; filename*=UTF-8''{quote(file_name)}",
            "Cache-Control": "no-store",
            "X-Content-Type-Options": "nosniff",
        },
    )


def _parse(range_from: str, range_to: str, resolution: str | None, asset_ids: list[UUID] | None) -> ExportRequest:
    try:
        return parse_export_request(
            range_from=range_from,
            range_to=range_to,
            resolution=resolution,
            asset_ids=asset_ids,
            max_assets=get_settings().report_export_max_assets,
        )
    except ApiContractError as exc:
        raise _contract_error(exc)


def _check_asset_count(count: int) -> None:
    """Every export, selected or whole-site, covers at most max_assets."""

    max_assets = get_settings().report_export_max_assets
    if count > max_assets:
        raise _contract_error(
            ApiContractError("too_many_assets", f"Select at most {max_assets} assets to export.")
        )


async def _selected_assets_and_catalog(
    portal_user_id: int, site_id: UUID, export_request: ExportRequest
) -> tuple[list[dict], list[dict]]:
    """The selected site assets (422 for one that is not accessible) and
    their catalogue rows."""

    try:
        assets = select_assets(await fetch_site_assets(portal_user_id, site_id), export_request.asset_ids)
    except ApiContractError as exc:
        raise _contract_error(exc)
    _check_asset_count(len(assets))
    selected = {str(a["asset_id"]) for a in assets}
    catalog_rows = [r for r in await fetch_analytics_catalog(portal_user_id, site_id) if str(r["asset_id"]) in selected]
    return assets, catalog_rows


async def _site_names(portal_user_id: int) -> dict[str, str]:
    return {str(s["site_id"]): s["site_name"] for s in await fetch_accessible_sites(portal_user_id)}


@router.get(
    "/sites/{site_id}/report-exports/estimate",
    response_model=ReportExportEstimateResponse,
    summary="Size of a site measurement export and whether it downloads immediately or runs in the background",
    operation_id="estimateSiteReportExport",
    responses=_RESPONSES,
)
async def estimate_site_report_export(
    request: Request,
    site_id: UUID,
    range_from: str = Query(..., alias="from", description="Inclusive ISO-8601 start (UTC)."),
    range_to: str = Query(..., alias="to", description="Exclusive ISO-8601 end (UTC)."),
    resolution: str | None = Query(None, description="auto (default), 1m, 15m, 30m, 1h or 1d."),
    asset_ids: list[UUID] | None = Query(None, alias="asset_id", description=_ASSET_QUERY_DESCRIPTION),
) -> ReportExportEstimateResponse:
    user = _require_exporter(request)
    export_request = _parse(range_from, range_to, resolution, asset_ids)
    if await fetch_analytics_site(user.portal_user_id, site_id) is None:
        raise _not_found("Site")
    site_assets, catalog_rows = await _selected_assets_and_catalog(user.portal_user_id, site_id, export_request)
    estimate = estimate_export(export_request, site_assets, catalog_rows)
    settings = get_settings()
    return ReportExportEstimateResponse(
        site_id=site_id,
        range_from=export_request.dt_from,
        range_to=export_request.dt_to,
        requested_resolution=export_request.requested_resolution,
        resolution=export_request.resolution,
        asset_count=estimate.asset_count,
        column_count=estimate.column_count,
        bucket_count=estimate.bucket_count,
        estimated_cells=estimate.cells,
        mode=export_mode(
            estimate.cells,
            immediate_max_cells=settings.report_export_immediate_max_cells,
            max_cells=settings.report_export_max_cells,
        ),
    )


@router.get(
    "/sites/{site_id}/report-exports/file",
    summary="Download a small site measurement export immediately (ZIP, one CSV per asset)",
    operation_id="downloadSiteReportExport",
    response_class=Response,
    responses={**_RESPONSES, 200: {"content": {ZIP_MEDIA_TYPE: {}}, "description": "The ZIP file."}},
)
async def download_site_report_export(
    request: Request,
    site_id: UUID,
    range_from: str = Query(..., alias="from", description="Inclusive ISO-8601 start (UTC)."),
    range_to: str = Query(..., alias="to", description="Exclusive ISO-8601 end (UTC)."),
    resolution: str | None = Query(None, description="auto (default), 1m, 15m, 30m, 1h or 1d."),
    asset_ids: list[UUID] | None = Query(None, alias="asset_id", description=_ASSET_QUERY_DESCRIPTION),
) -> Response:
    user = _require_exporter(request)
    export_request = _parse(range_from, range_to, resolution, asset_ids)
    try:
        ctx = await prepare_export(user.portal_user_id, site_id, export_request)
    except ApiContractError as exc:
        raise _contract_error(exc)
    if ctx is None:
        raise _not_found("Site")
    _check_asset_count(len(ctx.site_assets))
    estimate = estimate_export(ctx.request, ctx.site_assets, ctx.catalog_rows)
    if estimate.cells > get_settings().report_export_immediate_max_cells:
        raise _contract_error(
            ApiContractError(
                "export_requires_background",
                "This export is too large to download immediately; create a background export instead.",
            )
        )
    result = await build_export_zip(user.portal_user_id, site_id, ctx)
    return _zip_response(result.file_name, result.content)


@router.post(
    "/sites/{site_id}/report-exports",
    response_model=ReportExportJob,
    status_code=status.HTTP_202_ACCEPTED,
    summary="Queue a background site measurement export",
    operation_id="createSiteReportExport",
    responses={**_RESPONSES, 429: {"description": "Too many exports are already queued or processing."}},
)
async def create_site_report_export(
    request: Request, site_id: UUID, body: ReportExportCreateRequest
) -> ReportExportJob:
    user = _require_exporter(request)
    _require_same_site_json(request)
    export_request = _parse(body.range_from, body.range_to, body.resolution, body.asset_ids)
    settings = get_settings()
    if await fetch_analytics_site(user.portal_user_id, site_id) is None:
        raise _not_found("Site")
    site_assets, catalog_rows = await _selected_assets_and_catalog(user.portal_user_id, site_id, export_request)
    if not site_assets:
        raise _contract_error(ApiContractError("no_assets_selected", "This site has no assets to export."))
    estimate = estimate_export(export_request, site_assets, catalog_rows)
    if estimate.cells > settings.report_export_max_cells:
        raise _contract_error(
            ApiContractError(
                "export_too_large",
                "This export is too large. Choose a shorter time range or a coarser resolution.",
            )
        )
    try:
        # The job keeps the selection as it is now (a whole-site request
        # becomes the site's current assets).
        row = await create_job(
            user.portal_user_id,
            site_id,
            export_request,
            settings.report_export_max_active_jobs,
            [UUID(str(a["asset_id"])) for a in site_assets],
        )
    except ActiveJobLimitError:
        raise HTTPException(
            status_code=status.HTTP_429_TOO_MANY_REQUESTS,
            detail={
                "error": "too_many_active_exports",
                "detail": f"You already have {settings.report_export_max_active_jobs} exports queued or "
                "processing. Wait for one to finish.",
            },
        )
    if row is None:
        raise _not_found("Site")
    return build_job(row, await _site_names(user.portal_user_id))


@router.get(
    "/report-exports",
    response_model=ReportExportJobListResponse,
    summary="The caller's site measurement export jobs, newest first",
    operation_id="listReportExports",
    responses={401: _RESPONSES[401]},
)
async def list_report_exports(
    request: Request, limit: int = Query(50, ge=1, le=200)
) -> ReportExportJobListResponse:
    user = _require_exporter(request)
    rows = await list_jobs(user.portal_user_id, limit)
    names = await _site_names(user.portal_user_id) if rows else {}
    return ReportExportJobListResponse(jobs=[build_job(row, names) for row in rows])


@router.get(
    "/report-exports/{job_id}",
    response_model=ReportExportJob,
    summary="One export job's status",
    operation_id="getReportExport",
    responses=_RESPONSES,
)
async def get_report_export(request: Request, job_id: UUID) -> ReportExportJob:
    user = _require_exporter(request)
    row = await get_job(user.portal_user_id, job_id)
    if row is None:
        raise _not_found("Export")
    return build_job(row, await _site_names(user.portal_user_id))


@router.post(
    "/report-exports/{job_id}/retry",
    response_model=ReportExportJob,
    status_code=status.HTTP_202_ACCEPTED,
    summary="Re-queue a failed export job",
    operation_id="retryReportExport",
    responses={**_RESPONSES, 409: {"description": "Only a failed export can be retried."}},
)
async def retry_report_export(request: Request, job_id: UUID) -> ReportExportJob:
    user = _require_exporter(request)
    _require_same_site_json(request)
    row = await retry_job(user.portal_user_id, job_id)
    if row is None:
        if await get_job(user.portal_user_id, job_id) is None:
            raise _not_found("Export")
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail={"error": "export_not_failed", "detail": "Only a failed export can be retried."},
        )
    return build_job(row, await _site_names(user.portal_user_id))


@router.get(
    "/report-exports/{job_id}/file",
    summary="Download a completed export (ZIP, one CSV per asset)",
    operation_id="downloadReportExport",
    response_class=Response,
    responses={
        **_RESPONSES,
        200: {"content": {ZIP_MEDIA_TYPE: {}}, "description": "The ZIP file."},
        410: {"description": "The export expired or is not complete."},
    },
)
async def download_report_export(request: Request, job_id: UUID) -> Response:
    user = _require_exporter(request)
    file_row = await get_job_file(user.portal_user_id, job_id)
    if file_row is None:
        if await get_job(user.portal_user_id, job_id) is None:
            raise _not_found("Export")
        raise HTTPException(
            status_code=status.HTTP_410_GONE,
            detail={"error": "export_not_available", "detail": "This export has expired or is not complete."},
        )
    return _zip_response(file_row["file_name"], bytes(file_row["content"]))
