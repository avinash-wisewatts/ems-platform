"""Tenant-safe operational reconciliation queue reads and summaries."""

from typing import Any

from src.database import database_connection

ISSUE_TYPES = (
    "UNASSIGNED_DEVICE",
    "UNMAPPED_TELEMETRY",
    "MISSING_PRIMARY_METER",
    "INVALID_PROFILE",
    "INCOMPLETE_LOCATION",
    "FAILED_GRAFANA_PROVISIONING",
)


async def list_accessible_reconciliation_queue(
    *, portal_user_id: int, organization_id: str | None = None,
    site_id: str | None = None, issue_type: str | None = None,
) -> list[dict[str, Any]]:
    async with database_connection() as connection:
        async with connection.cursor() as cursor:
            await cursor.execute(
                "SELECT * FROM admin.list_accessible_reconciliation_queue(%s,%s::uuid,%s::uuid,%s)",
                (portal_user_id, organization_id, site_id, issue_type),
            )
            rows = await cursor.fetchall()
        await connection.rollback()
    return rows


def summarize_reconciliation_queue(rows: list[dict[str, Any]]) -> dict[str, int]:
    return {
        "total": len(rows),
        "high": sum(1 for row in rows if row.get("severity") == "HIGH"),
        "medium": sum(1 for row in rows if row.get("severity") == "MEDIUM"),
        "low": sum(1 for row in rows if row.get("severity") == "LOW"),
    }
