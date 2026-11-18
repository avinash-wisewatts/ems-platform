"""Alerts (ADR-024) -- customer-configurable alert rules, Active Alerts,
Resolved/Ended history and acknowledgement, under /api/v1.

    GET    /api/v1/sites/{site_id}/alerts?state=ACTIVE|RESOLVED|ENDED (repeatable)
    GET    /api/v1/alerts/{alert_id}
    POST   /api/v1/alerts/{alert_id}/acknowledge                 alert.acknowledge
    GET    /api/v1/sites/{site_id}/alert-rules
    GET    /api/v1/sites/{site_id}/alert-rules/parameters[?asset_id=]
    POST   /api/v1/sites/{site_id}/alert-rules                   alert.configure
    GET    /api/v1/alert-rules/{rule_id}
    PATCH  /api/v1/alert-rules/{rule_id}                         alert.configure
    POST   /api/v1/alert-rules/{rule_id}/enable | /disable        alert.configure
    DELETE /api/v1/alert-rules/{rule_id}                         alert.configure

Mounted in both the customer API (src.customer_main) and the Administration
App process (src.main), like the Analytics router. Reads need the session's
dashboard.view (middleware) and site access (database). Writes additionally
need the dedicated permission at the route -- the blanket /api/v1 middleware
rule is dashboard.view only -- and again inside the SECURITY DEFINER function
(migration 323), which also re-checks site access and writes the audit row in
the same transaction. Writes must be same-origin: a cross-site
Sec-Fetch-Site or a foreign Origin is 403, and a body that is not
application/json is 415, on top of the SameSite=Lax session cookie.

Inaccessible / unknown site, rule or alert: 404, indistinguishable from
missing. Permission missing on an accessible resource: 403. Contract
violations: 422 / 409 with the flat {"error", "detail"} envelope. Nothing is
ever sent by email or WhatsApp; staff acknowledgements are shown as
"WiseWatts Support".

Replaces the MVP-7 GET /sites/{site_id}/alerts and GET /alerts/{alert_id}
contract (ADR-024 §19; ADR-007 Amendment 1).
"""

from __future__ import annotations

from datetime import datetime, timezone
from uuid import UUID

from fastapi import APIRouter, Depends, HTTPException, Query, Request, Response, status

from src.alert_rules_service import (
    ALERT_STATES,
    Alert,
    AlertListResponse,
    AlertRule,
    AlertRuleCreate,
    AlertRuleError,
    AlertRuleParameter,
    AlertRuleParametersResponse,
    AlertRulesResponse,
    AlertRuleUpdate,
    AssetRef,
    ParameterRef,
    acknowledge_alert,
    build_alert,
    build_rule,
    check_rule,
    create_rule,
    delete_rule,
    fetch_alert,
    fetch_parameters,
    fetch_rule,
    fetch_rules,
    fetch_site_alerts,
    set_rule_enabled,
    update_rule,
)
from src.analytics_trends_service import fetch_analytics_site
from src.auth.authorization import PortalPermission, has_permission
from src.auth.customer_session import same_origin
from src.auth.models import AuthenticatedPortalUser
from src.routers.analytics_api import _not_found, _require_portal_user

router = APIRouter(prefix="/api/v1", tags=["alerts"])

_READ_RESPONSES: dict[int | str, dict] = {
    401: {"description": "Authentication is required."},
    404: {"description": "The site, rule or alert does not exist or is not accessible (indistinguishable)."},
    422: {"description": "The request violates the contract."},
}
_WRITE_RESPONSES: dict[int | str, dict] = {
    **_READ_RESPONSES,
    403: {"description": "Missing permission, or a cross-site request."},
    409: {"description": "Conflict: name taken, 25-rule limit, stale version, or alert not active / already acknowledged."},
    415: {"description": "The body is not application/json."},
}


def _error(status_code: int, code: str, detail: str) -> HTTPException:
    return HTTPException(status_code=status_code, detail={"error": code, "detail": detail})


def _require(request: Request, permission: PortalPermission) -> AuthenticatedPortalUser:
    user = _require_portal_user(request)
    if not has_permission(user, permission):
        raise _error(status.HTTP_403_FORBIDDEN, "forbidden", "You do not have permission to do this.")
    return user


def _require_same_origin(request: Request, *, json_body: bool) -> None:
    """CSRF defence for writes, on both processes (the customer middleware also
    refuses foreign origins; the Administration App's guard covers only HTML
    form paths)."""

    headers = request.headers
    if headers.get("sec-fetch-site", "").lower() == "cross-site":
        raise _error(status.HTTP_403_FORBIDDEN, "forbidden", "Cross-site requests are not allowed.")
    origin = headers.get("origin")
    if origin is not None and not same_origin(origin, headers.get("host")):
        raise _error(status.HTTP_403_FORBIDDEN, "forbidden", "Cross-origin requests are not allowed.")
    if json_body:
        content_type = headers.get("content-type", "").split(";")[0].strip().lower()
        if content_type != "application/json":
            raise _error(
                status.HTTP_415_UNSUPPORTED_MEDIA_TYPE, "unsupported_media_type", "Send the request as application/json."
            )


def _same_origin_json(request: Request) -> None:
    """Route dependency: resolved before the body is parsed, so a cross-site
    or non-JSON write is refused (403 / 415) whatever its body contains."""

    _require_same_origin(request, json_body=True)


def _same_origin_no_body(request: Request) -> None:
    _require_same_origin(request, json_body=False)


_JSON_WRITE = [Depends(_same_origin_json)]
_BODYLESS_WRITE = [Depends(_same_origin_no_body)]


def _check(body) -> None:
    try:
        check_rule(body)
    except AlertRuleError as exc:
        raise _error(exc.status, exc.code, exc.detail)


def _raise_for(exc: AlertRuleError, kind: str) -> HTTPException:
    if exc.code == "not_found":
        return _not_found(kind)
    return _error(exc.status, exc.code, exc.detail)


def _parse_instant(value: str | None, name: str) -> datetime | None:
    if value is None:
        return None
    try:
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        raise _error(422, "invalid_parameter", f"{name} must be an ISO-8601 timestamp.")
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=timezone.utc)
    return parsed


# ---------------------------------------------------------------------------
# Alerts: Active and Resolved/Ended history
# ---------------------------------------------------------------------------

@router.get(
    "/sites/{site_id}/alerts",
    response_model=AlertListResponse,
    summary="Site alerts -- Active, or Resolved/Ended history (ADR-024)",
    operation_id="getSiteAlerts",
    responses=_READ_RESPONSES,
)
async def get_site_alerts(
    request: Request,
    site_id: UUID,
    state: list[str] | None = Query(None, description="ACTIVE | RESOLVED | ENDED; repeat for several. Omit for all."),
    range_from: str | None = Query(None, alias="from"),
    range_to: str | None = Query(None, alias="to"),
    limit: int = Query(50, ge=1, le=200),
    before: str | None = Query(None, description="Cursor: next_before of the previous page."),
) -> AlertListResponse:
    user = _require_portal_user(request)
    states = sorted(set(state)) if state else None
    if states and any(s not in ALERT_STATES for s in states):
        raise _error(422, "invalid_state", "state must be ACTIVE, RESOLVED or ENDED.")
    if await fetch_analytics_site(user.portal_user_id, site_id) is None:
        raise _not_found("Site")
    rows = await fetch_site_alerts(
        user.portal_user_id, site_id, states, _parse_instant(range_from, "from"), _parse_instant(range_to, "to"),
        limit, _parse_instant(before, "before"),
    )
    alerts = [build_alert(r) for r in rows]
    next_before = rows[-1]["event_at"] if len(rows) == limit else None
    return AlertListResponse(site_id=site_id, alerts=alerts, next_before=next_before)


@router.get(
    "/alerts/{alert_id}",
    response_model=Alert,
    summary="Alert detail (ADR-024)",
    operation_id="getAlertDetail",
    responses=_READ_RESPONSES,
)
async def get_alert(request: Request, alert_id: UUID) -> Alert:
    user = _require_portal_user(request)
    row = await fetch_alert(user.portal_user_id, alert_id)
    if row is None:
        raise _not_found("Alert")
    return build_alert(row)


@router.post(
    "/alerts/{alert_id}/acknowledge",
    response_model=Alert,
    summary="Acknowledge an Active alert -- never resolves it (ADR-024 §7)",
    operation_id="acknowledgeAlert",
    responses=_WRITE_RESPONSES,
    dependencies=_BODYLESS_WRITE,
)
async def post_acknowledge(request: Request, alert_id: UUID) -> Alert:
    user = _require(request, PortalPermission.ALERT_ACKNOWLEDGE)
    _require_same_origin(request, json_body=False)
    try:
        await acknowledge_alert(user.portal_user_id, alert_id)
    except AlertRuleError as exc:
        raise _raise_for(exc, "Alert")
    row = await fetch_alert(user.portal_user_id, alert_id)
    if row is None:
        raise _not_found("Alert")
    return build_alert(row)


# ---------------------------------------------------------------------------
# Rules
# ---------------------------------------------------------------------------

@router.get(
    "/sites/{site_id}/alert-rules",
    response_model=AlertRulesResponse,
    summary="A site's alert rules (ADR-024)",
    operation_id="getSiteAlertRules",
    responses=_READ_RESPONSES,
)
async def get_site_rules(request: Request, site_id: UUID) -> AlertRulesResponse:
    user = _require_portal_user(request)
    site = await fetch_analytics_site(user.portal_user_id, site_id)
    if site is None:
        raise _not_found("Site")
    rows = await fetch_rules(user.portal_user_id, site_id)
    return AlertRulesResponse(site_id=site_id, rules=[build_rule(r, site.get("timezone")) for r in rows])


@router.get(
    "/sites/{site_id}/alert-rules/parameters",
    response_model=AlertRuleParametersResponse,
    summary="Parameters an alert rule may use (cumulative counters excluded)",
    operation_id="getSiteAlertRuleParameters",
    responses=_READ_RESPONSES,
)
async def get_rule_parameters(request: Request, site_id: UUID, asset_id: UUID | None = Query(None)) -> AlertRuleParametersResponse:
    user = _require_portal_user(request)
    if await fetch_analytics_site(user.portal_user_id, site_id) is None:
        raise _not_found("Site")
    rows = await fetch_parameters(user.portal_user_id, site_id, asset_id)
    return AlertRuleParametersResponse(
        site_id=site_id,
        parameters=[
            AlertRuleParameter(
                asset=AssetRef(asset_id=r["asset_id"], name=r["asset_name"]),
                parameter=ParameterRef(
                    code=r["parameter_code"], name=r["parameter_name"], qualifier=r["qualifier"], unit=r["unit_symbol"]
                ),
            )
            for r in rows
        ],
    )


async def _rule_response(user: AuthenticatedPortalUser, rule_id: UUID) -> AlertRule:
    row = await fetch_rule(user.portal_user_id, rule_id)
    if row is None:
        raise _not_found("Alert rule")
    site = await fetch_analytics_site(user.portal_user_id, row["site_id"])
    return build_rule(row, site.get("timezone") if site else None)


@router.get(
    "/alert-rules/{rule_id}",
    response_model=AlertRule,
    summary="One alert rule (ADR-024)",
    operation_id="getAlertRule",
    responses=_READ_RESPONSES,
)
async def get_rule(request: Request, rule_id: UUID) -> AlertRule:
    user = _require_portal_user(request)
    return await _rule_response(user, rule_id)


@router.post(
    "/sites/{site_id}/alert-rules",
    response_model=AlertRule,
    status_code=status.HTTP_201_CREATED,
    summary="Create an alert rule (site administrators, WiseWatts admin staff)",
    operation_id="createAlertRule",
    responses=_WRITE_RESPONSES,
    dependencies=_JSON_WRITE,
)
async def post_rule(request: Request, site_id: UUID, body: AlertRuleCreate) -> AlertRule:
    user = _require(request, PortalPermission.ALERT_CONFIGURE)
    _check(body)
    try:
        row = await create_rule(user.portal_user_id, site_id, body)
    except AlertRuleError as exc:
        raise _raise_for(exc, "Site")
    return await _rule_response(user, row["rule_id"])


@router.patch(
    "/alert-rules/{rule_id}",
    response_model=AlertRule,
    summary="Edit an alert rule -- ends its Active alert (CONFIGURATION_CHANGED)",
    operation_id="updateAlertRule",
    responses=_WRITE_RESPONSES,
    dependencies=_JSON_WRITE,
)
async def patch_rule(request: Request, rule_id: UUID, body: AlertRuleUpdate) -> AlertRule:
    user = _require(request, PortalPermission.ALERT_CONFIGURE)
    _check(body)
    try:
        await update_rule(user.portal_user_id, rule_id, body)
    except AlertRuleError as exc:
        raise _raise_for(exc, "Alert rule")
    return await _rule_response(user, rule_id)


async def _toggle(request: Request, rule_id: UUID, enabled: bool) -> AlertRule:
    user = _require(request, PortalPermission.ALERT_CONFIGURE)
    _require_same_origin(request, json_body=False)
    try:
        await set_rule_enabled(user.portal_user_id, rule_id, enabled)
    except AlertRuleError as exc:
        raise _raise_for(exc, "Alert rule")
    return await _rule_response(user, rule_id)


@router.post(
    "/alert-rules/{rule_id}/enable",
    response_model=AlertRule,
    summary="Enable an alert rule",
    operation_id="enableAlertRule",
    responses=_WRITE_RESPONSES,
    dependencies=_BODYLESS_WRITE,
)
async def post_enable(request: Request, rule_id: UUID) -> AlertRule:
    return await _toggle(request, rule_id, True)


@router.post(
    "/alert-rules/{rule_id}/disable",
    response_model=AlertRule,
    summary="Disable an alert rule -- ends its Active alert",
    operation_id="disableAlertRule",
    responses=_WRITE_RESPONSES,
    dependencies=_BODYLESS_WRITE,
)
async def post_disable(request: Request, rule_id: UUID) -> AlertRule:
    return await _toggle(request, rule_id, False)


@router.delete(
    "/alert-rules/{rule_id}",
    status_code=status.HTTP_204_NO_CONTENT,
    summary="Delete an alert rule (soft) -- its alert history is kept",
    operation_id="deleteAlertRule",
    responses=_WRITE_RESPONSES,
    dependencies=_BODYLESS_WRITE,
)
async def delete_rule_route(request: Request, rule_id: UUID) -> Response:
    user = _require(request, PortalPermission.ALERT_CONFIGURE)
    _require_same_origin(request, json_body=False)
    try:
        await delete_rule(user.portal_user_id, rule_id)
    except AlertRuleError as exc:
        raise _raise_for(exc, "Alert rule")
    return Response(status_code=status.HTTP_204_NO_CONTENT)
