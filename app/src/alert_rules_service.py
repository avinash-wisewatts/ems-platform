"""Customer-configurable alert rules (ADR-024) -- request/response contracts
and database access for src.routers.alerts_api.

Every read and write goes through the migration 323 / 324 SECURITY DEFINER
functions, keyed on the authenticated portal_user_id. The database
re-derives site access and permission; nothing here trusts identifiers from
the browser for authorisation. Writes commit (each function call is one
transaction: the change and its admin.audit_events row together); reads roll
back like every other /api/v1 read.

Contract notes:
- Email / WhatsApp are stored preferences only; their status is always
  "COMING_SOON" -- nothing is ever sent (ADR-024 §9).
- reminder_minutes: none, 15 or 30 -- stored only (ADR-024 §10).
- An acknowledgement by WiseWatts staff is returned as "WiseWatts Support";
  the staff identity is never returned.
"""

from __future__ import annotations

import math
import re
from datetime import datetime, time
from decimal import Decimal
from typing import Any, Literal
from uuid import UUID

from pydantic import BaseModel, ConfigDict, Field, field_validator

WEEKDAYS: tuple[str, ...] = ("MON", "TUE", "WED", "THU", "FRI", "SAT", "SUN")
EVERY_DAY_MASK = 127
REMINDER_CHOICES: tuple[int | None, ...] = (None, 15, 30)
COMPARATORS: tuple[str, ...] = ("GT", "LT", "EQ")
ALERT_STATES: tuple[str, ...] = ("ACTIVE", "RESOLVED", "ENDED")
DELIVERY_STATUS = "COMING_SOON"
_TIME_RE = re.compile(r"^([01]\d|2[0-3]):([0-5]\d)$")

# result codes of the migration 323 functions -> HTTP status
RESULT_STATUS: dict[str, int] = {
    "not_found": 404,
    "forbidden": 403,
    "version_conflict": 409,
    "name_taken": 409,
    "rule_limit_reached": 409,
    "alert_not_active": 409,
    "already_acknowledged": 409,
}
RESULT_DETAIL: dict[str, str] = {
    "not_found": "The resource does not exist or is not accessible.",
    "forbidden": "You do not have permission to do this.",
    "version_conflict": "This alert rule was changed by someone else. Reload it and try again.",
    "name_taken": "Another alert rule on this site already has this name.",
    "rule_limit_reached": "This site already has the maximum of 25 active alert rules.",
    "alert_not_active": "Only an active alert can be acknowledged.",
    "already_acknowledged": "This alert has already been acknowledged.",
    "invalid_name": "Enter a name of 1 to 120 characters.",
    "invalid_comparator": "Choose greater than, less than or equal to.",
    "invalid_threshold": "Enter a valid number.",
    "tolerance_required": "Equal to needs a tolerance in the parameter's unit.",
    "invalid_tolerance": "The tolerance must be zero or a positive number.",
    "tolerance_not_allowed": "A tolerance applies to equal to only.",
    "counter_not_allowed": "Alerts cannot be set on a cumulative counter.",
    "parameter_not_available": "This parameter is not available for the selected asset.",
    "asset_not_found": "Choose an active asset of this site.",
    "invalid_schedule": "The schedule start and end times must differ.",
    "invalid_weekdays": "Choose every day or at least one weekday.",
    "invalid_reminder": "Choose no reminder, 15 minutes or 30 minutes.",
    "mean_not_available": "Mean over time comparisons are not available yet.",
    "invalid_comparison_mode": "Choose a fixed value comparison.",
    "invalid_enabled": "Enabled must be true or false.",
}


class AlertRuleError(Exception):
    """A non-ok result from a migration 323 write function."""

    def __init__(self, code: str):
        super().__init__(code)
        self.code = code
        self.status = RESULT_STATUS.get(code, 422)
        self.detail = RESULT_DETAIL.get(code, "The request violates the alert rule contract.")


# ---------------------------------------------------------------------------
# Requests
# ---------------------------------------------------------------------------

class ScheduleIn(BaseModel):
    model_config = ConfigDict(extra="forbid")

    start_time: str = Field(description="Site-local HH:MM (24 h).")
    end_time: str = Field(description="Site-local HH:MM; earlier than start_time = crosses midnight.")
    weekdays: list[Literal["MON", "TUE", "WED", "THU", "FRI", "SAT", "SUN"]] = Field(
        description="Days the window starts on; all seven = every day."
    )

    @field_validator("start_time", "end_time")
    @classmethod
    def _hhmm(cls, value: str) -> str:
        if not _TIME_RE.match(value):
            raise ValueError("must be HH:MM")
        return value


class DeliveryIn(BaseModel):
    model_config = ConfigDict(extra="forbid")

    email: bool = False
    whatsapp: bool = False


class AlertRuleIn(BaseModel):
    """Full rule definition (create and update)."""

    model_config = ConfigDict(extra="forbid")

    name: str
    asset_id: UUID
    parameter_code: str
    qualifier: str | None = None
    comparator: Literal["GT", "LT", "EQ"]
    threshold: float
    tolerance: float | None = None
    schedule: ScheduleIn
    reminder_minutes: int | None = None
    delivery: DeliveryIn = Field(default_factory=DeliveryIn)

    @field_validator("threshold", "tolerance")
    @classmethod
    def _finite(cls, value: float | None) -> float | None:
        if value is not None and not math.isfinite(value):
            raise ValueError("must be a finite number")
        return value


class AlertRuleCreate(AlertRuleIn):
    enabled: bool = True


class AlertRuleUpdate(AlertRuleIn):
    version: int = Field(ge=1, description="The version being edited (409 version_conflict if stale).")


# ---------------------------------------------------------------------------
# Responses
# ---------------------------------------------------------------------------

class AssetRef(BaseModel):
    asset_id: UUID
    name: str


class ParameterRef(BaseModel):
    code: str
    name: str
    qualifier: str | None = None
    unit: str | None = None


class ConditionOut(BaseModel):
    comparator: str
    threshold: float
    tolerance: float | None = None
    comparison_mode: str = "FIXED"


class ScheduleOut(BaseModel):
    start_time: str
    end_time: str
    weekdays: list[str]
    every_day: bool
    timezone: str | None = None


class DeliveryChannelOut(BaseModel):
    requested: bool
    status: Literal["COMING_SOON"] = DELIVERY_STATUS


class DeliveryOut(BaseModel):
    email: DeliveryChannelOut
    whatsapp: DeliveryChannelOut


class AlertRule(BaseModel):
    rule_id: UUID
    site_id: UUID
    name: str
    asset: AssetRef
    parameter: ParameterRef
    condition: ConditionOut
    schedule: ScheduleOut
    reminder_minutes: int | None = None
    delivery: DeliveryOut
    enabled: bool
    version: int
    active_alert_id: UUID | None = None
    created_at: datetime
    updated_at: datetime


class AlertRulesResponse(BaseModel):
    site_id: UUID
    max_active_rules: int = 25
    rules: list[AlertRule]


class AlertRuleParameter(BaseModel):
    asset: AssetRef
    parameter: ParameterRef


class AlertRuleParametersResponse(BaseModel):
    site_id: UUID
    parameters: list[AlertRuleParameter]


class Acknowledgement(BaseModel):
    acknowledged_at: datetime
    acknowledged_by: str = Field(description='Display name, or "WiseWatts Support" for WiseWatts staff.')


class Alert(BaseModel):
    alert_id: UUID
    site_id: UUID
    rule_id: UUID
    rule_name: str
    rule_deleted: bool
    asset: AssetRef
    parameter: ParameterRef
    condition: ConditionOut
    state: Literal["ACTIVE", "RESOLVED", "ENDED"]
    triggered_at: datetime
    trigger_value: float
    latest_value: float | None = None
    latest_value_at: datetime | None = None
    data_unavailable: bool
    resolved_at: datetime | None = None
    resolved_value: float | None = None
    ended_at: datetime | None = None
    ended_reason_code: str | None = None
    acknowledgement: Acknowledgement | None = None
    previous_occurrence_count: int
    most_recent_previous_occurrence_at: datetime | None = None


class AlertListResponse(BaseModel):
    site_id: UUID
    alerts: list[Alert]
    next_before: datetime | None = Field(
        default=None, description="Cursor for the next page (pass as before), or null at the end."
    )


class WriteResult(BaseModel):
    rule_id: UUID | None = None
    alert_id: UUID | None = None
    version: int | None = None


# ---------------------------------------------------------------------------
# Conversions
# ---------------------------------------------------------------------------

def weekday_mask(days: list[str]) -> int:
    mask = 0
    for day in days:
        mask |= 1 << WEEKDAYS.index(day)
    return mask


def weekday_list(mask: int) -> list[str]:
    return [day for i, day in enumerate(WEEKDAYS) if mask & (1 << i)]


def parse_hhmm(value: str) -> time:
    hour, minute = value.split(":")
    return time(int(hour), int(minute))


def format_hhmm(value: time) -> str:
    return value.strftime("%H:%M")


def _num(value: float | None) -> Decimal | None:
    return None if value is None else Decimal(repr(float(value)))


def _float(value: Any) -> float | None:
    return None if value is None else float(value)


def check_rule(body: AlertRuleIn) -> None:
    """API-side checks that give a precise error before any database call
    (the database re-validates everything)."""

    if body.reminder_minutes not in REMINDER_CHOICES:
        raise AlertRuleError("invalid_reminder")
    if not body.schedule.weekdays:
        raise AlertRuleError("invalid_weekdays")
    if body.schedule.start_time == body.schedule.end_time:
        raise AlertRuleError("invalid_schedule")


def rule_args(body: AlertRuleIn) -> dict[str, Any]:
    """The definition in the migration 323 argument order (after the id args)."""

    check_rule(body)
    return {
        "name": body.name,
        "asset_id": str(body.asset_id),
        "parameter_code": body.parameter_code,
        "qualifier": body.qualifier,
        "comparator": body.comparator,
        "threshold": _num(body.threshold),
        "tolerance": _num(body.tolerance),
        "start": parse_hhmm(body.schedule.start_time),
        "end": parse_hhmm(body.schedule.end_time),
        "weekdays": weekday_mask(list(body.schedule.weekdays)),
        "reminder": body.reminder_minutes,
        "email": body.delivery.email,
        "whatsapp": body.delivery.whatsapp,
    }


def build_rule(row: dict[str, Any], timezone_name: str | None = None) -> AlertRule:
    mask = int(row["weekdays"])
    return AlertRule(
        rule_id=row["rule_id"],
        site_id=row["site_id"],
        name=row["name"],
        asset=AssetRef(asset_id=row["asset_id"], name=row["asset_name"]),
        parameter=ParameterRef(
            code=row["parameter_code"], name=row["parameter_name"], qualifier=row["qualifier"], unit=row["unit_symbol"]
        ),
        condition=ConditionOut(
            comparator=row["comparator"],
            threshold=float(row["threshold"]),
            tolerance=_float(row["tolerance"]),
            comparison_mode=row["comparison_mode"],
        ),
        schedule=ScheduleOut(
            start_time=format_hhmm(row["schedule_start"]),
            end_time=format_hhmm(row["schedule_end"]),
            weekdays=weekday_list(mask),
            every_day=mask == EVERY_DAY_MASK,
            timezone=timezone_name,
        ),
        reminder_minutes=row["reminder_minutes"],
        delivery=DeliveryOut(
            email=DeliveryChannelOut(requested=bool(row["email_requested"])),
            whatsapp=DeliveryChannelOut(requested=bool(row["whatsapp_requested"])),
        ),
        enabled=bool(row["enabled"]),
        version=int(row["version"]),
        active_alert_id=row["active_alert_id"],
        created_at=row["created_at"],
        updated_at=row["updated_at"],
    )


def build_alert(row: dict[str, Any]) -> Alert:
    ack = None
    if row["acknowledged_at"] is not None:
        ack = Acknowledgement(acknowledged_at=row["acknowledged_at"], acknowledged_by=row["acknowledged_by_name"])
    return Alert(
        alert_id=row["alert_id"],
        site_id=row["site_id"],
        rule_id=row["rule_id"],
        rule_name=row["rule_name"],
        rule_deleted=bool(row["rule_deleted"]),
        asset=AssetRef(asset_id=row["asset_id"], name=row["asset_name"]),
        parameter=ParameterRef(
            code=row["parameter_code"], name=row["parameter_name"], qualifier=row["qualifier"], unit=row["unit_symbol"]
        ),
        condition=ConditionOut(
            comparator=row["comparator"], threshold=float(row["threshold"]), tolerance=_float(row["tolerance"])
        ),
        state=row["state"],
        triggered_at=row["triggered_at"],
        trigger_value=float(row["trigger_value"]),
        latest_value=_float(row["last_value"]),
        latest_value_at=row["last_value_at"],
        data_unavailable=bool(row["data_unavailable"]),
        resolved_at=row["resolved_at"],
        resolved_value=_float(row["resolved_value"]),
        ended_at=row["ended_at"],
        ended_reason_code=row["ended_reason_code"],
        acknowledgement=ack,
        previous_occurrence_count=int(row["previous_occurrence_count"] or 0),
        most_recent_previous_occurrence_at=row["most_recent_previous_triggered_at"],
    )


# ---------------------------------------------------------------------------
# Data access
# ---------------------------------------------------------------------------

async def _execute(sql: str, params: tuple[Any, ...], *, commit: bool) -> list[dict[str, Any]]:
    from src.database import database_connection

    async with database_connection() as connection:
        try:
            async with connection.cursor() as cursor:
                await cursor.execute(sql, params)
                rows = await cursor.fetchall() if cursor.description else []
            if commit:
                await connection.commit()
            else:
                await connection.rollback()
        except BaseException:
            await connection.rollback()
            raise
    return rows


def _checked(rows: list[dict[str, Any]]) -> dict[str, Any]:
    row = rows[0] if rows else {"result": "not_found"}
    if row["result"] != "ok":
        raise AlertRuleError(row["result"])
    return row


_ALERT_COLUMNS = """
    alert_id, site_id, rule_id, rule_name, rule_deleted, asset_id, asset_name, parameter_code, qualifier,
    parameter_name, unit_symbol, comparator, threshold, tolerance, state, event_at, triggered_at, trigger_value,
    last_value, last_value_at, data_unavailable, resolved_at, resolved_value, ended_at, ended_reason_code,
    acknowledged_at, acknowledged_by_name, previous_occurrence_count, most_recent_previous_triggered_at
"""


async def fetch_site_alerts(
    portal_user_id: int,
    site_id: UUID,
    states: list[str] | None,
    dt_from: datetime | None,
    dt_to: datetime | None,
    limit: int,
    before: datetime | None,
) -> list[dict[str, Any]]:
    return await _execute(
        f"SELECT {_ALERT_COLUMNS} FROM analytics.get_portal_site_alerts(%s, %s, %s::text[], %s, %s, %s, %s)",
        (portal_user_id, str(site_id), states, dt_from, dt_to, limit, before),
        commit=False,
    )


async def fetch_alert(portal_user_id: int, alert_id: UUID) -> dict[str, Any] | None:
    rows = await _execute(
        f"SELECT {_ALERT_COLUMNS} FROM analytics.get_portal_alert_detail(%s, %s)",
        (portal_user_id, str(alert_id)),
        commit=False,
    )
    return rows[0] if rows else None


async def fetch_rules(portal_user_id: int, site_id: UUID) -> list[dict[str, Any]]:
    return await _execute(
        "SELECT * FROM analytics.list_portal_alert_rules(%s, %s)", (portal_user_id, str(site_id)), commit=False
    )


async def fetch_rule(portal_user_id: int, rule_id: UUID) -> dict[str, Any] | None:
    rows = await _execute(
        "SELECT * FROM analytics.get_portal_alert_rule(%s, %s)", (portal_user_id, str(rule_id)), commit=False
    )
    return rows[0] if rows else None


async def fetch_parameters(portal_user_id: int, site_id: UUID, asset_id: UUID | None) -> list[dict[str, Any]]:
    return await _execute(
        "SELECT * FROM analytics.list_portal_alert_rule_parameters(%s, %s, %s)",
        (portal_user_id, str(site_id), str(asset_id) if asset_id else None),
        commit=False,
    )


async def create_rule(portal_user_id: int, site_id: UUID, body: AlertRuleCreate) -> dict[str, Any]:
    a = rule_args(body)
    return _checked(await _execute(
        "SELECT result, rule_id, version FROM analytics.create_portal_alert_rule("
        "%s, %s, %s, %s, %s, %s, %s, %s::numeric, %s::numeric, %s, %s, %s::smallint, %s::smallint, %s, %s, %s)",
        (portal_user_id, str(site_id), a["name"], a["asset_id"], a["parameter_code"], a["qualifier"], a["comparator"],
         a["threshold"], a["tolerance"], a["start"], a["end"], a["weekdays"], a["reminder"], a["email"], a["whatsapp"],
         body.enabled),
        commit=True,
    ))


async def update_rule(portal_user_id: int, rule_id: UUID, body: AlertRuleUpdate) -> dict[str, Any]:
    a = rule_args(body)
    return _checked(await _execute(
        "SELECT result, rule_id, version FROM analytics.update_portal_alert_rule("
        "%s, %s, %s, %s, %s, %s, %s, %s, %s::numeric, %s::numeric, %s, %s, %s::smallint, %s::smallint, %s, %s)",
        (portal_user_id, str(rule_id), body.version, a["name"], a["asset_id"], a["parameter_code"], a["qualifier"],
         a["comparator"], a["threshold"], a["tolerance"], a["start"], a["end"], a["weekdays"], a["reminder"],
         a["email"], a["whatsapp"]),
        commit=True,
    ))


async def set_rule_enabled(portal_user_id: int, rule_id: UUID, enabled: bool) -> dict[str, Any]:
    return _checked(await _execute(
        "SELECT result, rule_id, version FROM analytics.set_portal_alert_rule_enabled(%s, %s, %s)",
        (portal_user_id, str(rule_id), enabled),
        commit=True,
    ))


async def delete_rule(portal_user_id: int, rule_id: UUID) -> dict[str, Any]:
    return _checked(await _execute(
        "SELECT result, rule_id, version FROM analytics.delete_portal_alert_rule(%s, %s)",
        (portal_user_id, str(rule_id)),
        commit=True,
    ))


async def acknowledge_alert(portal_user_id: int, alert_id: UUID) -> dict[str, Any]:
    return _checked(await _execute(
        "SELECT result, alert_id, version FROM analytics.acknowledge_portal_alert(%s, %s)",
        (portal_user_id, str(alert_id)),
        commit=True,
    ))
