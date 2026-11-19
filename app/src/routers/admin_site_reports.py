"""Reports -> Create report: WiseWatts Admin pages of the staff-only
Administration App (ADR-025; A2-A4, A6-A12, A13-A23, A61-A63, A69, A71,
A81-A87, A107, A111).

    /administration/sites/{site_id}/reporting                   enrolment, automation account,
                                                                schedules, reporting asset list,
                                                                fixed data-quality thresholds, change log
    /administration/sites/{site_id}/reporting/assets/{asset_id} per-asset settings + history
    /administration/sites/{site_id}/reports                     report management + recycle bin
    /administration/site-reports/{report_id}                    versions + attempt history

Access: an active ADMIN with GLOBAL scope (a WiseWatts Admin) who can access
the site -- checked HERE for every route regardless of EMS_ADMIN_STAFF_ONLY
(which is still off on staging, ADR-023 stage 4 not started), and again in
every database function. Radisson (tenant) Admins get 403 on every page
(A3, T-ADM-3). State-changing forms also require a same-origin Origin header.
"""

from __future__ import annotations

import json
from datetime import date, datetime, timezone
from typing import Any, Optional
from uuid import UUID
from zoneinfo import ZoneInfo

from fastapi import APIRouter, Form, Request
from fastapi.responses import HTMLResponse, RedirectResponse, Response

from src import site_report_service as svc
from src.auth.customer_session import same_origin
from src.auth.dependencies import require_authenticated_portal_user
from src.auth.models import AuthenticatedPortalUser
from src.report_engine.schedules import DAYS, describe_schedule, normalise_schedule

router = APIRouter(include_in_schema=False)

GROUP_LABELS = {"HVAC_CHILLERS": "HVAC · Chillers", "HVAC_PUMPS": "HVAC · Pumps",
                "HVAC_COOLING_TOWERS": "HVAC · Cooling towers", "HVAC_AHU": "HVAC · Air handling units",
                "KITCHEN": "Kitchen"}
AREA_LABELS = {"LOBBY": "Lobby", "RESTAURANT": "Restaurant", "BANQUET_1": "Banquet 1", "BANQUET_2": "Banquet 2",
               "PRE_FUNCTION": "Pre-function"}
SETTING_LABELS = {"TEMPERATURE_SETPOINT": "Temperature setpoint", "OPERATING_SCHEDULE": "Operating schedule",
                  "OPERATING_THRESHOLDS": "Operating thresholds"}
# Fixed, WiseWatts-controlled report data-quality thresholds (A11), shown read-only.
DATA_QUALITY_THRESHOLDS = [
    ("Short energy gap estimation", "Internal gaps of up to 30 minutes, linear"),
    ("Full day", "At least 90 % of expected readings measured"),
    ("Directly comparable totals", "No partial days and at most 0.5 % of energy readings unmeasured"),
    ("Peak demand", "Only timestamps where every HVAC meter reported; indicative below 95 % coverage"),
    ("Temperature band", "±1 °C of the setpoint in force; below 50 % within band is listed for attention"),
    ("Duty change", "Opposite unit swings of at least 10 % of subsystem energy"),
    ("Kitchen attention", "Weekly: > 10 % and > 25 kWh increase; monthly: > 10 % and > 100 kWh"),
    ("Publication minimum", "HVAC and Kitchen each ≥ 80 % of expected energy readings available, "
                            "and at least one valid peak-demand timestamp (current period)"),
]


class Forbidden(Exception):
    pass


def _templates():
    from src.main import settings, templates

    return templates, settings


def _staff(request: Request) -> AuthenticatedPortalUser:
    user = require_authenticated_portal_user(request)
    if user.role_code != "ADMIN" or user.access_scope_mode != "GLOBAL":
        raise Forbidden()
    return user


def _same_origin_post(request: Request) -> None:
    origin = request.headers.get("origin")
    if origin is not None and not same_origin(origin, request.headers.get("host")):
        raise Forbidden()


def _forbidden(request: Request) -> Response:
    templates, settings = _templates()
    return templates.TemplateResponse(request=request, name="forbidden.html", status_code=403,
                                      context={"environment": settings.app_env})


def _redirect(url: str, *, notice: str | None = None, error: str | None = None) -> RedirectResponse:
    from urllib.parse import quote

    params = []
    if notice:
        params.append(f"notice={quote(notice)}")
    if error:
        params.append(f"error={quote(error)}")
    return RedirectResponse(url=url + ("?" + "&".join(params) if params else ""), status_code=303)


async def _site(user: AuthenticatedPortalUser, site_id: UUID) -> Optional[dict]:
    from src.location_management_service import get_site_workspace

    return await get_site_workspace(portal_user_id=user.portal_user_id, site_id=str(site_id))


def _render(request: Request, name: str, context: dict, status_code: int = 200) -> HTMLResponse:
    templates, settings = _templates()
    return templates.TemplateResponse(request=request, name=name, status_code=status_code, context={
        "environment": settings.app_env, "active_navigation_key": "sites",
        "notice": request.query_params.get("notice"), "error": request.query_params.get("error"),
        "group_labels": GROUP_LABELS, "area_labels": AREA_LABELS, "setting_labels": SETTING_LABELS,
        "status_labels": svc.STATUS_LABELS, **context})


def _local(value: Optional[datetime], zone: ZoneInfo) -> str:
    return value.astimezone(zone).strftime("%d-%b-%Y %H:%M") if value else "—"


# ---------------------------------------------------------------------------
# Site reporting configuration
# ---------------------------------------------------------------------------

@router.get("/administration/sites/{site_id}/reporting", response_class=HTMLResponse)
async def site_reporting(request: Request, site_id: UUID) -> Response:
    try:
        user = _staff(request)
    except Forbidden:
        return _forbidden(request)
    site = await _site(user, site_id)
    if site is None:
        return _forbidden(request)
    try:
        profile = await svc.admin_profile(user.portal_user_id, site_id)
        assets = await svc.admin_assets(user.portal_user_id, site_id)
        settings_rows = await svc.admin_settings(user.portal_user_id, site_id) if profile and profile["enrolled"] else []
    except svc.SiteReportError as exc:
        return _render(request, "site_reporting.html", {"site": site, "profile": None, "assets": [], "error": exc.message,
                                                        "candidates": [], "changes": [], "zone_name": "UTC"}, exc.status)
    zone = ZoneInfo(profile["site_timezone"])
    candidates = []
    if profile["enrolled"]:
        from src.user_management_service import list_manageable_users

        users = await list_manageable_users(actor_portal_user_id=user.portal_user_id)
        candidates = [u for u in users if u["role_code"] == "ADMIN" and u["access_scope_mode"] == "SELECTED_SITES"
                      and str(u["organization_id"]) == str(profile["organization_id"])
                      and [str(s) for s in (u["site_ids"] or [])] == [str(site_id)]]
    names = {str(a["asset_id"]): a["asset_name"] for a in assets}
    changes = [{**r, "asset_name": names.get(str(r["asset_id"]), str(r["asset_id"])),
                "effective_local": _local(r["effective_from"], zone), "created_local": _local(r["created_at"], zone)}
               for r in settings_rows][:50]
    return _render(request, "site_reporting.html", {
        "site": site, "profile": profile, "assets": assets, "candidates": candidates, "changes": changes,
        "thresholds": DATA_QUALITY_THRESHOLDS, "zone_name": profile["site_timezone"],
        "resumed": {"WEEKLY": _local(profile["weekly_resumed_at"], zone), "MONTHLY": _local(profile["monthly_resumed_at"], zone)},
    })


@router.post("/administration/sites/{site_id}/reporting/enrol")
async def site_reporting_enrol(request: Request, site_id: UUID) -> Response:
    try:
        user = _staff(request)
        _same_origin_post(request)
        await svc.enrol(user.portal_user_id, site_id)
    except Forbidden:
        return _forbidden(request)
    except svc.SiteReportError as exc:
        return _redirect(f"/administration/sites/{site_id}/reporting", error=exc.message)
    return _redirect(f"/administration/sites/{site_id}/reporting", notice="Site enrolled for weekly and monthly reports.")


@router.post("/administration/sites/{site_id}/reporting/automation-account")
async def site_reporting_automation(request: Request, site_id: UUID, automation_portal_user_id: str = Form("")) -> Response:
    try:
        user = _staff(request)
        _same_origin_post(request)
        account = int(automation_portal_user_id) if automation_portal_user_id.strip() else None
        await svc.set_automation_account(user.portal_user_id, site_id, account)
    except Forbidden:
        return _forbidden(request)
    except ValueError:
        return _redirect(f"/administration/sites/{site_id}/reporting", error="Choose an account.")
    except svc.SiteReportError as exc:
        return _redirect(f"/administration/sites/{site_id}/reporting", error=exc.message)
    return _redirect(f"/administration/sites/{site_id}/reporting", notice="Automation account updated.")


@router.post("/administration/sites/{site_id}/reporting/schedule")
async def site_reporting_schedule(request: Request, site_id: UUID, report_type: str = Form(...),
                                  enabled: str = Form(...)) -> Response:
    try:
        user = _staff(request)
        _same_origin_post(request)
        await svc.set_schedule(user.portal_user_id, site_id, report_type, enabled == "true")
    except Forbidden:
        return _forbidden(request)
    except svc.SiteReportError as exc:
        return _redirect(f"/administration/sites/{site_id}/reporting", error=exc.message)
    label = "Weekly" if report_type == "WEEKLY" else "Monthly"
    return _redirect(f"/administration/sites/{site_id}/reporting",
                     notice=f"{label} automatic generation {'resumed' if enabled == 'true' else 'paused'}.")


@router.post("/administration/sites/{site_id}/reporting/assets/{asset_id}/roster")
async def site_reporting_roster(request: Request, site_id: UUID, asset_id: UUID, action: str = Form(...),
                                report_group: str = Form(""), area: str = Form(""), display_order: str = Form("0")) -> Response:
    try:
        user = _staff(request)
        _same_origin_post(request)
        if action == "remove":
            await svc.remove_roster_asset(user.portal_user_id, site_id, asset_id)
            notice = "Asset removed from the reporting asset list."
        else:
            if report_group not in svc.REPORT_GROUPS:
                raise svc.SiteReportError("invalid", "Choose a reporting group.")
            if report_group == "HVAC_AHU" and area not in svc.AHU_AREAS:
                raise svc.SiteReportError("invalid", "Choose the area this AHU serves.")
            await svc.set_roster_asset(user.portal_user_id, site_id, asset_id, report_group,
                                       area if report_group == "HVAC_AHU" else None, int(display_order or 0))
            notice = "Reporting asset list updated."
    except Forbidden:
        return _forbidden(request)
    except ValueError:
        return _redirect(f"/administration/sites/{site_id}/reporting", error="Display order must be a whole number.")
    except svc.SiteReportError as exc:
        return _redirect(f"/administration/sites/{site_id}/reporting", error=exc.message)
    return _redirect(f"/administration/sites/{site_id}/reporting", notice=notice)


# ---------------------------------------------------------------------------
# Per-asset settings
# ---------------------------------------------------------------------------

def _current(rows: list[dict], key: str) -> Optional[dict]:
    return next((r for r in rows if r["setting_key"] == key and r["in_force"]), None)


@router.get("/administration/sites/{site_id}/reporting/assets/{asset_id}", response_class=HTMLResponse)
async def asset_reporting(request: Request, site_id: UUID, asset_id: UUID) -> Response:
    try:
        user = _staff(request)
    except Forbidden:
        return _forbidden(request)
    site = await _site(user, site_id)
    if site is None:
        return _forbidden(request)
    try:
        profile = await svc.admin_profile(user.portal_user_id, site_id)
        assets = await svc.admin_assets(user.portal_user_id, site_id)
        rows = await svc.admin_settings(user.portal_user_id, site_id, asset_id)
    except svc.SiteReportError as exc:
        return _redirect(f"/administration/sites/{site_id}/reporting", error=exc.message)
    asset = next((a for a in assets if str(a["asset_id"]) == str(asset_id) and a["in_roster"]), None)
    if asset is None:
        return _redirect(f"/administration/sites/{site_id}/reporting", error=svc.ERROR_TEXT["site_report_asset_not_in_roster"])
    from src.analytics_trends_service import fetch_analytics_catalog

    catalog = await fetch_analytics_catalog(user.portal_user_id, site_id)
    monitored = any(str(r["asset_id"]) == str(asset_id) and r.get("data_point") == "TEMPERATURE" for r in catalog)
    zone = ZoneInfo(profile["site_timezone"])
    now = datetime.now(timezone.utc)
    history = []
    for r in rows:
        value = r["value"] or {}
        text = _setting_text(r["setting_key"], value)
        history.append({**r, "text": text, "effective_local": _local(r["effective_from"], zone),
                        "created_local": _local(r["created_at"], zone), "withdrawn_local": _local(r["withdrawn_at"], zone),
                        "future": r["state"] == "ACTIVE" and r["effective_from"] > now})
    current = {key: _current(rows, key) for key in svc.SETTING_KEYS}
    schedule_value = (current["OPERATING_SCHEDULE"] or {}).get("value") or {}
    today = now.astimezone(zone).date()
    return _render(request, "asset_reporting.html", {
        "site": site, "asset": asset, "monitored": monitored, "history": history, "current": current,
        "current_text": {k: (_setting_text(k, v["value"]) if v else "Not configured") for k, v in current.items()},
        "days": DAYS, "schedule": (schedule_value.get("schedule") or {}), "schedule_value": schedule_value,
        "thresholds": (current["OPERATING_THRESHOLDS"] or {}).get("value") or {},
        "setpoint": ((current["TEMPERATURE_SETPOINT"] or {}).get("value") or {}).get("value_c"),
        "today": today.isoformat(), "zone_name": profile["site_timezone"],
    })


def _setting_text(key: str, value: dict) -> str:
    if key == "TEMPERATURE_SETPOINT":
        return f"{float(value.get('value_c')):.1f} °C"
    if key == "OPERATING_SCHEDULE":
        schedule, _ = normalise_schedule(value.get("schedule"))
        text = describe_schedule(schedule)
        if not value.get("calculate_out_of_hours", True):
            text += " · out-of-hours not calculated"
        return text + (" · confirmed by hotel" if value.get("confirmed_by_hotel") else " · provisional")
    if key == "OPERATING_THRESHOLDS":
        standby = value.get("standby_kw")
        text = f"OFF ≤ {value.get('off_kw')} kW · STANDBY ≤ {standby if standby is not None else '—'} kW · ON ≥ {value.get('on_kw')} kW"
        return text + ("" if value.get("runtime_enabled", True) else " · runtime not reported")
    return json.dumps(value)


def _parse_effective(text: str) -> date:
    try:
        return date.fromisoformat(text)
    except ValueError as exc:
        raise svc.SiteReportError("invalid", "Choose the date the setting takes effect.") from exc


@router.post("/administration/sites/{site_id}/reporting/assets/{asset_id}/settings")
async def asset_reporting_save(request: Request, site_id: UUID, asset_id: UUID) -> Response:
    back = f"/administration/sites/{site_id}/reporting/assets/{asset_id}"
    try:
        user = _staff(request)
        _same_origin_post(request)
        form = await request.form()
        key = str(form.get("setting_key", ""))
        effective = _parse_effective(str(form.get("effective_date", "")))
        if key == "TEMPERATURE_SETPOINT":
            value = {"value_c": float(str(form.get("value_c", "")))}
        elif key == "OPERATING_SCHEDULE":
            raw: dict[str, list[list[str]]] = {}
            if form.get("no_schedule") != "on":
                for day in DAYS:
                    for slot in range(3):
                        start = str(form.get(f"{day}_{slot}_start", "")).strip()
                        end = str(form.get(f"{day}_{slot}_end", "")).strip()
                        if start or end:
                            raw.setdefault(day, []).append([start, end])
                    raw.setdefault(day, [])
            schedule, problems = normalise_schedule(raw if form.get("no_schedule") != "on" else None)
            if problems:
                raise svc.SiteReportError("invalid", "Schedule problems: " + "; ".join(problems[:4]))
            value = {"schedule": None if schedule is None else {d: [list(i) for i in schedule[d]] for d in DAYS},
                     "calculate_out_of_hours": form.get("calculate_out_of_hours") == "on",
                     "confirmed_by_hotel": form.get("confirmed_by_hotel") == "on"}
        elif key == "OPERATING_THRESHOLDS":
            standby = str(form.get("standby_kw", "")).strip()
            value = {"off_kw": float(str(form.get("off_kw", ""))), "on_kw": float(str(form.get("on_kw", ""))),
                     "standby_kw": float(standby) if standby else None,
                     "runtime_enabled": form.get("runtime_enabled") == "on",
                     "confidence": str(form.get("confidence", "")).strip()[:120]}
        else:
            raise svc.SiteReportError("invalid", "Unknown setting.")
        row = await svc.add_setting(user.portal_user_id, asset_id, key, value, effective)
    except Forbidden:
        return _forbidden(request)
    except ValueError:
        return _redirect(back, error="Enter numbers for the values.")
    except svc.SiteReportError as exc:
        return _redirect(back, error=exc.message)
    when = "now" if row["effective_from"] <= datetime.now(timezone.utc) else f"from {row['effective_date']:%d-%b-%Y} 00:00 site time"
    return _redirect(back, notice=f"{SETTING_LABELS[key]} saved; it takes effect {when}.")


@router.post("/administration/sites/{site_id}/reporting/assets/{asset_id}/settings/{version_id}/withdraw")
async def asset_reporting_withdraw(request: Request, site_id: UUID, asset_id: UUID, version_id: int) -> Response:
    back = f"/administration/sites/{site_id}/reporting/assets/{asset_id}"
    try:
        user = _staff(request)
        _same_origin_post(request)
        await svc.withdraw_setting(user.portal_user_id, version_id)
    except Forbidden:
        return _forbidden(request)
    except svc.SiteReportError as exc:
        return _redirect(back, error=exc.message)
    return _redirect(back, notice="Future setting withdrawn.")


# ---------------------------------------------------------------------------
# Report management
# ---------------------------------------------------------------------------

@router.get("/administration/sites/{site_id}/reports", response_class=HTMLResponse)
async def site_reports_admin(request: Request, site_id: UUID) -> Response:
    try:
        user = _staff(request)
    except Forbidden:
        return _forbidden(request)
    site = await _site(user, site_id)
    if site is None:
        return _forbidden(request)
    try:
        profile = await svc.admin_profile(user.portal_user_id, site_id)
        type_filter = request.query_params.get("type") or ""
        status_filter = request.query_params.get("status") or ""
        active = await svc.admin_reports(user.portal_user_id, site_id, "ACTIVE") if profile["enrolled"] else []
        deleted = await svc.admin_reports(user.portal_user_id, site_id, "DELETED") if profile["enrolled"] else []
    except svc.SiteReportError as exc:
        return _redirect(f"/administration/sites/{site_id}/reporting", error=exc.message)
    zone = ZoneInfo(profile["site_timezone"])
    rows = [r for r in active if (not type_filter or r["report_type"] == type_filter)
            and (not status_filter or r["status"] == status_filter)]
    for r in rows + deleted:
        r["generated_local"] = _local(r["generated_at"], zone)
        r["expires_local"] = _local(r["expires_at"], zone)
        r["deleted_local"] = _local(r.get("deleted_at"), zone)
        r["restore_until_local"] = _local(r.get("restore_until"), zone)
        r["next_purge_local"] = _local(r.get("next_purge_at"), zone)
    today = datetime.now(timezone.utc).astimezone(zone).date()
    return _render(request, "site_reports_admin.html", {
        "site": site, "profile": profile, "reports": rows, "deleted": deleted, "type_filter": type_filter,
        "status_filter": status_filter, "zone_name": profile["site_timezone"], "today": today.isoformat(),
    })


@router.post("/administration/sites/{site_id}/reports/generate")
async def site_reports_generate(request: Request, site_id: UUID, report_type: str = Form(...),
                                period_start: str = Form(...)) -> Response:
    back = f"/administration/sites/{site_id}/reports"
    try:
        user = _staff(request)
        _same_origin_post(request)
        if report_type == "MONTHLY" and len(period_start) == 7:
            period_start = period_start + "-01"
        start = date.fromisoformat(period_start)
        if report_type == "WEEKLY":
            from src.report_engine.periods import week_start

            start = week_start(start)
        await svc.request_generation(user.portal_user_id, site_id, report_type, start)
    except Forbidden:
        return _forbidden(request)
    except ValueError:
        return _redirect(back, error="Choose a valid week or month.")
    except svc.SiteReportError as exc:
        return _redirect(back, error=exc.message)
    return _redirect(back, notice="Report queued. It shows Pending, then Processing, and Generated when published.")


@router.post("/administration/site-reports/{report_id}/{action}")
async def site_report_action(request: Request, report_id: UUID, action: str, site_id: str = Form(...),
                             confirm: str = Form("")) -> Response:
    try:
        back = f"/administration/sites/{UUID(site_id)}/reports"
    except ValueError:
        back = "/administration/sites"
    try:
        user = _staff(request)
        _same_origin_post(request)
        if action == "regenerate":
            await svc.request_regeneration(user.portal_user_id, report_id)
            notice = "Regeneration queued. The current version stays downloadable until the new one is published."
        elif action == "retry":
            await svc.retry(user.portal_user_id, report_id)
            notice = "Retry queued."
        elif action == "delete":
            if confirm != "yes":
                raise svc.SiteReportError("confirm", "Confirm deletion to continue.")
            until = await svc.delete(user.portal_user_id, report_id)
            notice = f"Report moved to the recycle bin; it can be restored until {until:%d-%b-%Y %H:%M} UTC."
        elif action == "restore":
            await svc.restore(user.portal_user_id, report_id)
            notice = "Report restored. Its versions keep their original expiry dates."
        elif action == "purge":
            await svc.permanently_delete(user.portal_user_id, report_id, confirm == "PERMANENTLY DELETE")
            notice = "Report permanently deleted."
        else:
            return _redirect(back, error="Unknown action.")
    except Forbidden:
        return _forbidden(request)
    except svc.SiteReportError as exc:
        return _redirect(back, error=exc.message)
    return _redirect(back, notice=notice)


@router.get("/administration/site-reports/{report_id}", response_class=HTMLResponse)
async def site_report_detail(request: Request, report_id: UUID) -> Response:
    try:
        user = _staff(request)
    except Forbidden:
        return _forbidden(request)
    try:
        versions = await svc.admin_versions(user.portal_user_id, report_id)
        attempts = await svc.admin_attempts(user.portal_user_id, report_id)
    except svc.SiteReportError as exc:
        return _render(request, "site_report_detail.html", {"versions": [], "attempts": [], "error": exc.message,
                                                             "report_id": report_id, "zone_name": "UTC"}, exc.status)
    zone = ZoneInfo("Asia/Kolkata")
    site_id: Optional[str] = None
    try:
        site_uuid = UUID(request.query_params.get("site_id", ""))
        profile = await svc.admin_profile(user.portal_user_id, site_uuid)
        zone = ZoneInfo(profile["site_timezone"])
        site_id = str(site_uuid)
    except (svc.SiteReportError, ValueError, TypeError):
        site_id = None
    for v in versions:
        v["generated_local"] = _local(v["generated_at"], zone)
        v["expires_local"] = _local(v["expires_at"], zone)
        v["purge_local"] = _local(v["purge_at"], zone)
        v["coverage_json"] = json.dumps(v["coverage"], indent=2, default=str)
        v["settings_json"] = json.dumps(v["settings_snapshot"], indent=2, default=str)
    for a in attempts:
        for key in ("created_at", "not_before", "started_at", "finished_at"):
            a[f"{key}_local"] = _local(a[key], zone)
    return _render(request, "site_report_detail.html", {"versions": versions, "attempts": attempts,
                                                        "report_id": report_id, "site_id": site_id,
                                                        "zone_name": str(zone)})
