"""Reports -> Create report: customer-facing, READ-ONLY report API (ADR-025, A5, A107).

    GET /api/v1/sites/{site_id}/site-reports                     history + schedule state
    GET /api/v1/site-reports/{report_id}/versions                version details (coverage, settings)
    GET /api/v1/site-report-versions/{version_id}/download       the PDF

Every profile with access to the site (ADMIN, OPERATOR, VIEWER) may view and
download (report.view). There is deliberately NO write route here: generating,
regenerating, retrying, deleting, restoring and permanently deleting reports,
and all reporting configuration, are WiseWatts Admin actions in the staff-only
Administration App (A2-A4, A6, A107, ADR-023 unchanged). The database
functions behind these routes are the only ones the customer API's database
role may execute for reports (migration 329 postconditions); site access is
re-checked in the database on every call, including at download time.

Mounted by the customer API and the Administration App only where Reports is
enabled (EMS_REPORTS_ENABLED, staging-only).
"""

from __future__ import annotations

from typing import Any, Literal, Optional
from urllib.parse import quote
from uuid import UUID

from fastapi import APIRouter, HTTPException, Query, Request, Response, status
from pydantic import BaseModel

from src import site_report_service as svc
from src.auth.authorization import PortalPermission, has_permission
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


class SiteReportListResponse(BaseModel):
    enrolled: bool
    weekly_enabled: bool
    monthly_enabled: bool
    timezone: str
    reports: list[SiteReportItem]


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
    )


@router.get("/sites/{site_id}/site-reports", response_model=SiteReportListResponse,
            summary="Weekly and monthly report history of a site (read-only)", operation_id="listSiteReports")
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
                                  reports=[_item(r) for r in reports])


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
