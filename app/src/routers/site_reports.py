"""Reports -> Create report: customer-facing report API (ADR-025, A5, A107;
Amendment 1, A113).

    GET  /api/v1/sites/{site_id}/site-reports                    history + schedule state + can_generate
    POST /api/v1/sites/{site_id}/site-reports                    on-demand generation (report.generate)
    GET  /api/v1/site-reports/{report_id}/versions               version details (coverage, settings)
    GET  /api/v1/site-report-versions/{version_id}/download      the PDF

Every profile with access to the site (ADMIN, OPERATOR, VIEWER) may view and
download (report.view). On-demand generation -- a new report for an ended
period, or a NEW version of an existing one (earlier versions stay) -- is for
Site Admins and WiseWatts Admins only (report.generate = ADMIN role), checked
here, in the middleware, and again in the database (active ADMIN with site
access, never the automation account; migration 330). Operators and Viewers
remain view/download only. A historical period is generated only when a user
explicitly requests it here (A115). Retry, delete, restore, permanent deletion
and all reporting configuration stay WiseWatts Admin actions in the staff-only
Administration App (A2-A4, A6, ADR-023 unchanged). Site access is re-checked
in the database on every call, including at download time.

Mounted by the customer API and the Administration App only where Reports is
enabled (EMS_REPORTS_ENABLED, staging-only).
"""

from __future__ import annotations

from datetime import date
from typing import Any, Literal, Optional
from urllib.parse import quote
from uuid import UUID

from fastapi import APIRouter, Depends, HTTPException, Query, Request, Response, status
from pydantic import BaseModel

from src import site_report_service as svc
from src.auth.authorization import PortalPermission, has_permission
from src.auth.customer_session import same_origin
from src.auth.models import AuthenticatedPortalUser
from src.routers.analytics_api import _not_found, _require_portal_user

router = APIRouter(prefix="/api/v1", tags=["site-reports"])
PDF_MEDIA_TYPE = "application/pdf"


def _require_viewer(request: Request) -> AuthenticatedPortalUser:
    user = _require_portal_user(request)
    if not has_permission(user, PortalPermission.REPORT_VIEW):
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN,
                            detail={"error": "forbidden", "detail": "You do not have permission to view reports."})
    return user


def _error(status_code: int, code: str, detail: str) -> HTTPException:
    return HTTPException(status_code=status_code, detail={"error": code, "detail": detail})


def _same_origin_json(request: Request) -> None:
    """CSRF defence for the write (as the alert routes): a cross-site
    Sec-Fetch-Site or a foreign Origin is 403, a non-JSON body 415; resolved
    before the body is parsed."""

    headers = request.headers
    if headers.get("sec-fetch-site", "").lower() == "cross-site":
        raise _error(status.HTTP_403_FORBIDDEN, "forbidden", "Cross-site requests are not allowed.")
    origin = headers.get("origin")
    if origin is not None and not same_origin(origin, headers.get("host")):
        raise _error(status.HTTP_403_FORBIDDEN, "forbidden", "Cross-origin requests are not allowed.")
    content_type = headers.get("content-type", "").split(";")[0].strip().lower()
    if content_type != "application/json":
        raise _error(status.HTTP_415_UNSUPPORTED_MEDIA_TYPE, "unsupported_media_type",
                     "Send the request as application/json.")


class SiteReportItem(BaseModel):
    report_id: UUID
    report_type: str
    period_start: str
    period_end: str
    comparison_start: str
    comparison_end: str
    status: Literal["PENDING", "PROCESSING", "GENERATED", "FAILED"]
    status_label: str
    status_reason: Optional[str] = None
    incomplete_data: bool = False
    comparison_incomplete: bool = False
    latest_version_no: Optional[int] = None
    version_count: int = 0
    generated_at: Optional[str] = None
    expires_at: Optional[str] = None
    download_version_id: Optional[UUID] = None
    coverage_summary: Optional[dict[str, Any]] = None
    # The latest version used AHU settings back-dated under a PO-approved
    # retrospective reporting baseline (migration 330, A116).
    retrospective_baseline: bool = False


class SiteReportListResponse(BaseModel):
    enrolled: bool
    weekly_enabled: bool
    monthly_enabled: bool
    timezone: str
    # Whether this user may generate on demand (Site Admins and WiseWatts
    # Admins; the database decides again on the request).
    can_generate: bool = False
    reports: list[SiteReportItem]


class SiteReportGenerateRequest(BaseModel):
    report_type: Literal["WEEKLY", "MONTHLY"]
    period_start: date


class SiteReportGenerateResponse(BaseModel):
    report_id: UUID
    attempt_id: UUID
    action: Literal["GENERATE", "REGENERATE"]
    trigger: str


class SiteReportVersion(BaseModel):
    version_id: UUID
    version_no: int
    generated_at: str
    trigger: str
    expires_at: str
    available: bool
    incomplete_data: bool
    comparison_incomplete: bool
    coverage: dict[str, Any]
    settings_snapshot: dict[str, Any]
    file_name: str
    file_size_bytes: int
    page_count: int


class SiteReportVersionsResponse(BaseModel):
    report_id: UUID
    versions: list[SiteReportVersion]


def _iso(value) -> Optional[str]:
    return value.isoformat() if value is not None else None


def _item(row: dict[str, Any]) -> SiteReportItem:
    status_code = row["status"]
    return SiteReportItem(
        report_id=row["report_id"], report_type=row["report_type"],
        period_start=row["period_start_date"].isoformat(), period_end=row["period_end_date"].isoformat(),
        comparison_start=row["comparison_start_date"].isoformat(), comparison_end=row["comparison_end_date"].isoformat(),
        status=status_code, status_label=svc.STATUS_LABELS[status_code],
        status_reason=row.get("status_reason") if status_code in ("PENDING", "FAILED") else None,
        incomplete_data=bool(row.get("incomplete_data")),
        comparison_incomplete=bool(row.get("comparison_incomplete")),
        latest_version_no=row.get("latest_version_no"), version_count=int(row.get("version_count") or 0),
        generated_at=_iso(row.get("generated_at")), expires_at=_iso(row.get("expires_at")),
        download_version_id=row.get("download_version_id"), coverage_summary=row.get("coverage_summary"),
        retrospective_baseline=bool(row.get("retrospective_baseline")),
    )


@router.get("/sites/{site_id}/site-reports", response_model=SiteReportListResponse,
            summary="Weekly and monthly report history of a site", operation_id="listSiteReports")
async def list_site_reports(request: Request, site_id: UUID,
                            report_type: Optional[Literal["WEEKLY", "MONTHLY"]] = Query(default=None, alias="type")
                            ) -> SiteReportListResponse:
    user = _require_viewer(request)
    schedule = await svc.portal_schedule(user.portal_user_id, site_id)
    if schedule is None:
        raise _not_found("Site")
    reports = await svc.portal_reports(user.portal_user_id, site_id, report_type) if schedule["enrolled"] else []
    return SiteReportListResponse(enrolled=bool(schedule["enrolled"]), weekly_enabled=bool(schedule["weekly_enabled"]),
                                  monthly_enabled=bool(schedule["monthly_enabled"]), timezone=schedule["site_timezone"],
                                  can_generate=bool(schedule["enrolled"]) and has_permission(user, PortalPermission.REPORT_GENERATE),
                                  reports=[_item(r) for r in reports])


@router.post("/sites/{site_id}/site-reports", response_model=SiteReportGenerateResponse,
             status_code=status.HTTP_202_ACCEPTED, dependencies=[Depends(_same_origin_json)],
             summary="Generate a report on demand (Site Admins and WiseWatts Admins)",
             operation_id="generateSiteReport")
async def generate_site_report(request: Request, site_id: UUID, body: SiteReportGenerateRequest
                               ) -> SiteReportGenerateResponse:
    user = _require_portal_user(request)
    if not has_permission(user, PortalPermission.REPORT_GENERATE):
        raise _error(status.HTTP_403_FORBIDDEN, "forbidden", "Only Site Admins and WiseWatts Admins can generate reports.")
    schedule = await svc.portal_schedule(user.portal_user_id, site_id)
    if schedule is None:
        raise _not_found("Site")
    try:
        row = await svc.portal_generate(user.portal_user_id, site_id, body.report_type, body.period_start)
    except svc.SiteReportError as exc:
        raise _error(exc.status, exc.code, exc.message)
    return SiteReportGenerateResponse(report_id=row["report_id"], attempt_id=row["attempt_id"], action=row["action"],
                                      trigger=row["trigger"])


@router.get("/site-reports/{report_id}/versions", response_model=SiteReportVersionsResponse,
            summary="Versions of a report, with data coverage and settings used (read-only)",
            operation_id="listSiteReportVersions")
async def list_site_report_versions(request: Request, report_id: UUID) -> SiteReportVersionsResponse:
    user = _require_viewer(request)
    rows = await svc.portal_versions(user.portal_user_id, report_id)
    if not rows:
        raise _not_found("Report")
    return SiteReportVersionsResponse(report_id=report_id, versions=[
        SiteReportVersion(version_id=r["version_id"], version_no=r["version_no"], generated_at=_iso(r["generated_at"]),
                          trigger=r["trigger"], expires_at=_iso(r["expires_at"]), available=r["state"] == "AVAILABLE",
                          incomplete_data=r["incomplete_data"], comparison_incomplete=r["comparison_incomplete"],
                          coverage=r["coverage"] or {}, settings_snapshot=r["settings_snapshot"] or {},
                          file_name=r["file_name"], file_size_bytes=r["file_size_bytes"], page_count=r["page_count"])
        for r in rows])


def pdf_response(file_name: str, content: bytes) -> Response:
    ascii_name = file_name.encode("ascii", "replace").decode("ascii").replace('"', "_")
    return Response(content=content, media_type=PDF_MEDIA_TYPE, headers={
        "Content-Disposition": f"attachment; filename=\"{ascii_name}\"; filename*=UTF-8''{quote(file_name)}",
        "Cache-Control": "private, no-store",
        "X-Content-Type-Options": "nosniff",
    })


@router.get("/site-report-versions/{version_id}/download", response_class=Response,
            summary="Download a report PDF", operation_id="downloadSiteReport",
            responses={200: {"content": {PDF_MEDIA_TYPE: {}}}, 404: {"description": "Not found, expired or not accessible."}})
async def download_site_report(request: Request, version_id: UUID) -> Response:
    user = _require_viewer(request)
    row = await svc.portal_file(user.portal_user_id, version_id)
    if row is None:
        raise _not_found("Report version")
    return pdf_response(row["file_name"], bytes(row["content"]))
