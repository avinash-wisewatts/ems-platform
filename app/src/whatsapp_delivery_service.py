"""Database access for WhatsApp delivery (migration 333, ADR-026 A3-A5).

Thin wrappers over the SECURITY DEFINER functions; the database enforces
eligibility, tenancy, idempotency, the quiet period and the 60-minute window.
"""

from __future__ import annotations

from datetime import datetime, timedelta
from typing import Any
from uuid import UUID

from src.database import database_connection


async def _call(sql: str, params: tuple[Any, ...]) -> list[dict[str, Any]]:
    async with database_connection() as connection:
        try:
            async with connection.cursor() as cursor:
                await cursor.execute(sql, params)
                rows = await cursor.fetchall() if cursor.description else []
            await connection.commit()
        except BaseException:
            await connection.rollback()
            raise
    return rows


async def claim(worker_id: str, limit: int, lease: timedelta) -> list[dict[str, Any]]:
    return await _call(
        "SELECT delivery_id, phone_e164, message, attempts, created_at "
        "FROM analytics.claim_whatsapp_deliveries(%s, %s, %s)",
        (worker_id, limit, lease),
    )


async def begin_send(delivery_id: UUID, worker_id: str, min_remaining: timedelta) -> bool:
    """Mark a leased delivery in flight just before the provider request.
    False: do not send (lease too short or lost, or the kill switch is off)."""
    rows = await _call(
        "SELECT analytics.begin_whatsapp_send(%s, %s, %s) AS ok",
        (str(delivery_id), worker_id, min_remaining),
    )
    return bool(rows and rows[0]["ok"])


async def record_result(delivery_id: UUID, worker_id: str, outcome: str, *, message_id: str | None = None,
                        error_code: str | None = None, retry_at: datetime | None = None) -> str | None:
    rows = await _call(
        "SELECT analytics.record_whatsapp_send_result(%s, %s, %s, %s, %s, %s) AS status",
        (str(delivery_id), worker_id, outcome, message_id, error_code, retry_at),
    )
    return rows[0]["status"] if rows else None


async def record_status(message_id: str, status: str, status_at: datetime, error_code: str | None) -> str:
    rows = await _call(
        "SELECT analytics.record_whatsapp_status_update(%s, %s, %s, %s) AS result",
        (message_id, status, status_at, error_code),
    )
    return rows[0]["result"]


async def purge() -> dict[str, Any]:
    rows = await _call("SELECT * FROM analytics.purge_whatsapp_deliveries()", ())
    return rows[0] if rows else {}


async def overview() -> dict[str, Any]:
    rows = await _call("SELECT * FROM analytics.get_whatsapp_delivery_overview()", ())
    return rows[0] if rows else {}


async def portal_rule_deliveries(portal_user_id: int, rule_id: UUID, limit: int) -> list[dict[str, Any]]:
    return await _call(
        "SELECT * FROM analytics.get_portal_alert_rule_whatsapp_deliveries(%s, %s, %s)",
        (portal_user_id, str(rule_id), limit),
    )
