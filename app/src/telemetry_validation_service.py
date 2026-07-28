"""Tenant-scoped telemetry availability reads."""

from typing import Any

from src.database import database_connection

TELEMETRY_STATES = (
    "NEVER_SEEN", "RECEIVING", "STALE", "SILENT",
    "INVALID_PROFILE", "UNMAPPED", "VALIDATED",
)

async def list_accessible_device_telemetry_availability(
    *, portal_user_id: int, organization_id: str | None = None,
    site_id: str | None = None, telemetry_state: str | None = None,
) -> list[dict[str, Any]]:
    """Return device configuration and telemetry health in the actor scope."""
    async with database_connection() as connection:
        async with connection.cursor() as cursor:
            await cursor.execute(
                "SELECT * FROM admin.list_accessible_device_telemetry_availability(%s,%s::uuid,%s::uuid,%s)",
                (portal_user_id, organization_id, site_id, telemetry_state),
            )
            rows = await cursor.fetchall()
        await connection.rollback()
    return rows
