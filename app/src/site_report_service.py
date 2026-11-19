"""Reports -> Create report: database access (migrations 328 / 329, ADR-025).

Every call goes through a SECURITY DEFINER function that re-derives site
access (and, for configuration and management, an active ADMIN with GLOBAL
scope -- a WiseWatts Admin) from the portal user id in the database, so the
rules hold whichever process calls (A2, A3, A6, A107). Reads roll back; writes
commit. No heavy imports: the web processes use this module.
"""

from __future__ import annotations

from datetime import date, datetime, timedelta
from typing import Any
from uuid import UUID

import psycopg.errors
from psycopg.types.json import Jsonb

REPORT_TYPES = ("WEEKLY", "MONTHLY")
SETTING_KEYS = ("TEMPERATURE_SETPOINT", "OPERATING_SCHEDULE", "OPERATING_THRESHOLDS")
REPORT_GROUPS = ("HVAC_CHILLERS", "HVAC_PUMPS", "HVAC_COOLING_TOWERS", "HVAC_AHU", "KITCHEN")
AHU_AREAS = ("LOBBY", "RESTAURANT", "BANQUET_1", "BANQUET_2", "PRE_FUNCTION")
RETENTION = timedelta(days=60)          # A78
RECYCLE_BIN = timedelta(days=7)         # A84

STATUS_LABELS = {"PENDING": "Pending", "PROCESSING": "Processing", "GENERATED": "Generated", "FAILED": "Failed"}

# Database error messages (RAISE EXCEPTION '<code>...') -> user-facing text.
ERROR_TEXT = {
    "site_report_forbidden": "Only WiseWatts Admins with access to this site can do this.",
    "site_report_already_enrolled": "This site is already enrolled for reports.",
    "site_report_not_enrolled": "This site is not enrolled for reports.",
    "site_report_automation_account_invalid": "That account cannot be the automation account",
    "site_report_asset_not_in_site": "The asset does not belong to this site.",
    "site_report_asset_not_in_roster": "The asset is not in this site's reporting asset list.",
    "report_setting_past_effective_date": "Settings can take effect today or on a future date only.",
    "report_setting_effective_date_required": "Choose when the setting takes effect.",
    "report_setting_invalid": "The setting is not valid",
    "report_setting_not_found": "The setting version was not found.",
    "report_setting_already_effective": "Only a future-dated setting that has not taken effect can be withdrawn.",
    "site_report_exists": "A report already exists for this period. Use Regenerate to create a new version.",
    "site_report_in_recycle_bin": "This period's report is in the recycle bin. Restore it, or permanently delete it first.",
    "site_report_period_not_ended": "The reporting period has not ended yet.",
    "site_report_invalid_period": "The period is not a valid reporting period",
    "site_report_invalid_type": "Choose Weekly or Monthly.",
    "site_report_not_found": "The report was not found.",
    "site_report_not_active": "The report is not active.",
    "site_report_attempt_active": "The report is already pending or processing.",
    "site_report_not_failed": "Only a failed report can be retried.",
    "site_report_processing": "The report is being generated; try again when it finishes.",
    "site_report_not_restorable": "The report can no longer be restored (the 7-day recycle-bin period has ended).",
    "site_report_not_in_recycle_bin": "Only a report in the recycle bin can be permanently deleted.",
    "site_report_confirmation_required": "Confirm permanent deletion to continue.",
}


class SiteReportError(Exception):
    """A database rule refused the request; .message is user-facing."""

    def __init__(self, code: str, message: str, status: int = 400) -> None:
        super().__init__(message)
        self.code = code
        self.message = message
        self.status = status


def _translate(exc: Exception) -> SiteReportError:
    text = str(getattr(exc, "diag", None) and exc.diag.message_primary or exc).strip()
    code, _, detail = text.partition(":")
    code = code.strip()
    message = ERROR_TEXT.get(code, "The request could not be completed.")
    if detail and code in ("site_report_automation_account_invalid", "report_setting_invalid", "site_report_invalid_period"):
        message = f"{message}: {detail.strip()}."
    status = 403 if isinstance(exc, psycopg.errors.InsufficientPrivilege) else 409 if isinstance(
        exc, (psycopg.errors.UniqueViolation, psycopg.errors.ObjectNotInPrerequisiteState)) else 404 if isinstance(
        exc, psycopg.errors.NoDataFound) else 400
    return SiteReportError(code or "error", message, status)


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
        except (psycopg.errors.RaiseException, psycopg.errors.InsufficientPrivilege, psycopg.errors.UniqueViolation,
                psycopg.errors.InvalidParameterValue, psycopg.errors.NoDataFound,
                psycopg.errors.ObjectNotInPrerequisiteState) as exc:
            await connection.rollback()
            raise _translate(exc) from exc
        except BaseException:
            await connection.rollback()
            raise
    return rows


async def _write(sql: str, params: tuple[Any, ...]) -> list[dict[str, Any]]:
    return await _execute(sql, params, commit=True)


async def _read(sql: str, params: tuple[Any, ...]) -> list[dict[str, Any]]:
    return await _execute(sql, params, commit=False)


# ---------------------------------------------------------------------------
# Customer-facing reads (customer portal; all profiles; read-only, A5, A107).
# ---------------------------------------------------------------------------

async def portal_schedule(portal_user_id: int, site_id: UUID) -> dict[str, Any] | None:
    rows = await _read("SELECT * FROM analytics.get_portal_site_report_schedule(%s, %s)", (portal_user_id, str(site_id)))
    return rows[0] if rows else None


async def portal_reports(portal_user_id: int, site_id: UUID, report_type: str | None, limit: int = 200) -> list[dict[str, Any]]:
    return await _read("SELECT * FROM analytics.list_portal_site_reports(%s, %s, %s, %s)",
                       (portal_user_id, str(site_id), report_type, limit))


async def portal_versions(portal_user_id: int, report_id: UUID) -> list[dict[str, Any]]:
    return await _read("SELECT * FROM analytics.list_portal_site_report_versions(%s, %s)", (portal_user_id, str(report_id)))


async def portal_file(portal_user_id: int, version_id: UUID) -> dict[str, Any] | None:
    rows = await _read("SELECT * FROM analytics.get_portal_site_report_file(%s, %s)", (portal_user_id, str(version_id)))
    return rows[0] if rows else None


# ---------------------------------------------------------------------------
# Administration App (WiseWatts Admins only; enforced in the database).
# ---------------------------------------------------------------------------

async def admin_profile(portal_user_id: int, site_id: UUID) -> dict[str, Any] | None:
    rows = await _read("SELECT * FROM analytics.get_site_report_profile_admin(%s, %s)", (portal_user_id, str(site_id)))
    return rows[0] if rows else None


async def admin_assets(portal_user_id: int, site_id: UUID) -> list[dict[str, Any]]:
    return await _read("SELECT * FROM analytics.list_site_report_assets_admin(%s, %s)", (portal_user_id, str(site_id)))


async def admin_settings(portal_user_id: int, site_id: UUID, asset_id: UUID | None = None) -> list[dict[str, Any]]:
    return await _read("SELECT * FROM analytics.list_asset_report_settings_admin(%s, %s, %s)",
                       (portal_user_id, str(site_id), str(asset_id) if asset_id else None))


async def enrol(portal_user_id: int, site_id: UUID) -> None:
    await _write("SELECT * FROM analytics.enrol_site_report_profile(%s, %s)", (portal_user_id, str(site_id)))


async def set_automation_account(portal_user_id: int, site_id: UUID, account_id: int | None) -> None:
    await _write("SELECT * FROM analytics.set_site_report_automation_account(%s, %s, %s)",
                 (portal_user_id, str(site_id), account_id))


async def set_schedule(portal_user_id: int, site_id: UUID, report_type: str, enabled: bool) -> None:
    await _write("SELECT * FROM analytics.set_site_report_schedule(%s, %s, %s, %s)",
                 (portal_user_id, str(site_id), report_type, enabled))


async def set_roster_asset(portal_user_id: int, site_id: UUID, asset_id: UUID, group: str, area: str | None,
                           order: int) -> None:
    await _write("SELECT * FROM analytics.set_site_report_asset(%s, %s, %s, %s, %s, %s)",
                 (portal_user_id, str(site_id), str(asset_id), group, area, order))


async def remove_roster_asset(portal_user_id: int, site_id: UUID, asset_id: UUID) -> None:
    await _write("SELECT analytics.remove_site_report_asset(%s, %s, %s)", (portal_user_id, str(site_id), str(asset_id)))


async def add_setting(portal_user_id: int, asset_id: UUID, setting_key: str, value: dict, effective_date: date) -> dict:
    rows = await _write("SELECT * FROM analytics.add_asset_report_setting(%s, %s, %s, %s, %s)",
                        (portal_user_id, str(asset_id), setting_key, Jsonb(value), effective_date))
    return rows[0]


async def withdraw_setting(portal_user_id: int, version_id: int) -> None:
    await _write("SELECT * FROM analytics.withdraw_asset_report_setting(%s, %s)", (portal_user_id, version_id))


async def admin_reports(portal_user_id: int, site_id: UUID, state: str = "ACTIVE") -> list[dict[str, Any]]:
    return await _read("SELECT * FROM analytics.list_site_reports_admin(%s, %s, %s)", (portal_user_id, str(site_id), state))


async def admin_attempts(portal_user_id: int, report_id: UUID) -> list[dict[str, Any]]:
    return await _read("SELECT * FROM analytics.list_site_report_attempts_admin(%s, %s)", (portal_user_id, str(report_id)))


async def admin_versions(portal_user_id: int, report_id: UUID) -> list[dict[str, Any]]:
    return await _read("SELECT * FROM analytics.list_site_report_versions_admin(%s, %s)", (portal_user_id, str(report_id)))


async def request_generation(portal_user_id: int, site_id: UUID, report_type: str, period_start: date) -> dict:
    rows = await _write("SELECT * FROM analytics.request_site_report_generation(%s, %s, %s, %s)",
                        (portal_user_id, str(site_id), report_type, period_start))
    return rows[0]


async def request_regeneration(portal_user_id: int, report_id: UUID) -> None:
    await _write("SELECT analytics.request_site_report_regeneration(%s, %s)", (portal_user_id, str(report_id)))


async def retry(portal_user_id: int, report_id: UUID) -> None:
    await _write("SELECT analytics.retry_site_report(%s, %s)", (portal_user_id, str(report_id)))


async def delete(portal_user_id: int, report_id: UUID) -> datetime:
    rows = await _write("SELECT analytics.delete_site_report(%s, %s) AS restore_until", (portal_user_id, str(report_id)))
    return rows[0]["restore_until"]


async def restore(portal_user_id: int, report_id: UUID) -> None:
    await _write("SELECT analytics.restore_site_report(%s, %s)", (portal_user_id, str(report_id)))


async def permanently_delete(portal_user_id: int, report_id: UUID, confirmed: bool) -> None:
    await _write("SELECT analytics.permanently_delete_site_report(%s, %s, %s)", (portal_user_id, str(report_id), confirmed))


# ---------------------------------------------------------------------------
# Report worker.
# ---------------------------------------------------------------------------

async def schedule_due(now: datetime) -> int:
    rows = await _write("SELECT analytics.schedule_due_site_reports(%s) AS created", (now,))
    return int(rows[0]["created"]) if rows else 0


async def claim(worker_id: str, lease: timedelta) -> dict[str, Any] | None:
    rows = await _write("SELECT * FROM analytics.claim_site_report_attempt(%s, %s)", (worker_id, lease))
    return rows[0] if rows else None


async def extend_lease(attempt_id: UUID, worker_id: str, lease: timedelta) -> bool:
    rows = await _write("SELECT analytics.extend_site_report_lease(%s, %s, %s) AS ok", (str(attempt_id), worker_id, lease))
    return bool(rows and rows[0]["ok"])


async def defer(attempt_id: UUID, worker_id: str, not_before: datetime, message: str) -> bool:
    rows = await _write("SELECT analytics.defer_site_report_attempt(%s, %s, %s, %s) AS ok",
                        (str(attempt_id), worker_id, not_before, message))
    return bool(rows and rows[0]["ok"])


async def complete(attempt_id: UUID, worker_id: str, *, file_name: str, content: bytes, sha256: str, page_count: int,
                   incomplete_data: bool, comparison_incomplete: bool, coverage: dict, settings_snapshot: dict,
                   engine_version: str) -> UUID | None:
    rows = await _write(
        "SELECT analytics.complete_site_report_attempt(%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s) AS version_id",
        (str(attempt_id), worker_id, file_name, content, sha256, page_count, incomplete_data, comparison_incomplete,
         Jsonb(coverage), Jsonb(settings_snapshot), engine_version, RETENTION),
    )
    value = rows[0]["version_id"] if rows else None
    return UUID(str(value)) if value else None


async def fail(attempt_id: UUID, worker_id: str, code: str, message: str, retryable: bool) -> bool:
    rows = await _write("SELECT analytics.fail_site_report_attempt(%s, %s, %s, %s, %s) AS ok",
                        (str(attempt_id), worker_id, code, message, retryable))
    return bool(rows and rows[0]["ok"])


async def purge(now: datetime) -> dict[str, Any]:
    rows = await _write("SELECT * FROM analytics.purge_site_reports(%s)", (now,))
    return rows[0] if rows else {}


async def read_identity_problem(attempt_id: UUID) -> str | None:
    rows = await _read("SELECT analytics.site_report_read_identity_problem(%s) AS problem", (str(attempt_id),))
    return rows[0]["problem"] if rows else "attempt_not_found"


async def worker_settings(site_id: UUID) -> list[dict[str, Any]]:
    return await _read("SELECT * FROM analytics.get_site_report_worker_settings(%s)", (str(site_id),))
