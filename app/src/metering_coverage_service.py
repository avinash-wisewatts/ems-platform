"""Tenant-scoped metering policy and configuration coverage reads."""

from typing import Any

async def list_accessible_metering_coverage(
    *, portal_user_id: int,
) -> list[dict[str, Any]]:
    """Return metering coverage rows visible to one portal user."""

    from src.database import database_connection

    async with database_connection() as connection:
        async with connection.cursor() as cursor:
            await cursor.execute(
                "SELECT * FROM admin.list_accessible_asset_meter_coverage(%s)",
                (portal_user_id,),
            )
            rows = await cursor.fetchall()
        await connection.rollback()
    return rows


def summarize_metering_coverage(rows: list[dict[str, Any]]) -> dict[str, int]:
    """Build KPI counts without placing excluded assets in the denominator."""

    in_scope = [row for row in rows if row.get("is_coverage_in_scope")]
    configured = [row for row in in_scope if row.get("coverage_status") == "CONFIGURED"]
    action_required = [
        row
        for row in in_scope
        if row.get("coverage_status")
        in {
            "MISSING_DIRECT_METER",
            "PARTIALLY_CONFIGURED",
            "MISSING_DESCENDANT_COVERAGE",
            "NO_REQUIRED_DESCENDANTS",
            "UNKNOWN_POLICY",
        }
    ]
    return {
        "visible_assets": len(rows),
        "in_scope_assets": len(in_scope),
        "configured_assets": len(configured),
        "action_required_assets": len(action_required),
        "excluded_assets": sum(
            1 for row in rows if row.get("coverage_status") == "EXCLUDED"
        ),
    }
