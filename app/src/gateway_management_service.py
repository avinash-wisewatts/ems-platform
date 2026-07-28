"""Controlled independent gateway operations."""

from typing import Any

from psycopg.errors import DatabaseError

from src.database import database_connection
from src.onboarding.result_contract import build_entity_result


async def create_gateway(
    *,
    portal_user_id: int,
    organization_id: str,
    site_id: str,
    gateway_name: str,
    external_id: str,
    gateway_model_id: str,
    lifecycle_status: str,
    building_id: str | None,
    floor_id: str | None,
    space_id: str | None,
) -> dict[str, Any]:
    """Create a gateway without requiring devices or assets."""
    async with database_connection() as connection:
        try:
            async with connection.cursor() as cursor:
                await cursor.execute(
                    """
                    SELECT admin.create_gateway(
                        %s, %s::uuid, %s::uuid, %s, %s,
                        %s::uuid, %s, %s::uuid, %s::uuid, %s::uuid
                    ) AS gateway_result
                    """,
                    (
                        portal_user_id,
                        organization_id,
                        site_id,
                        gateway_name,
                        external_id,
                        gateway_model_id,
                        lifecycle_status,
                        building_id,
                        floor_id,
                        space_id,
                    ),
                )
                row = await cursor.fetchone()
            await connection.commit()
        except DatabaseError:
            await connection.rollback()
            raise

    payload = row["gateway_result"]
    return build_entity_result(
        payload,
        entity_type="GATEWAY",
        entity_id=payload.get("gateway_id"),
        lifecycle_status=payload.get("lifecycle_status"),
        commissioning_status=payload.get("commissioning_status"),
        validation_warnings=payload.get("validation_warnings"),
        blocking_conditions=payload.get("blocking_conditions"),
        audit_transaction_id=payload.get("audit_transaction_id"),
    )


async def list_accessible_gateways(
    *, portal_user_id: int
) -> list[dict[str, Any]]:
    """Return gateways visible within one portal user's site scope."""
    async with database_connection() as connection:
        async with connection.cursor() as cursor:
            await cursor.execute(
                """
                SELECT * FROM admin.list_accessible_gateways(%s)
                """,
                (portal_user_id,),
            )
            rows = await cursor.fetchall()
        await connection.rollback()
    return rows


async def update_gateway_lifecycle(
    *,
    portal_user_id: int,
    gateway_id: str,
    lifecycle_status: str,
    change_reason: str | None,
) -> dict[str, Any]:
    """Apply one explicit, audited gateway lifecycle transition."""
    async with database_connection() as connection:
        try:
            async with connection.cursor() as cursor:
                await cursor.execute(
                    """
                    SELECT admin.update_gateway_lifecycle(
                        %s, %s::uuid, %s, %s
                    ) AS gateway_result
                    """,
                    (
                        portal_user_id, gateway_id, lifecycle_status,
                        change_reason,
                    ),
                )
                row = await cursor.fetchone()
            await connection.commit()
        except DatabaseError:
            await connection.rollback()
            raise

    payload = row["gateway_result"]
    return build_entity_result(
        payload,
        entity_type="GATEWAY",
        entity_id=payload.get("gateway_id"),
        lifecycle_status=payload.get("lifecycle_status"),
        audit_transaction_id=payload.get("audit_transaction_id"),
    )


async def commission_gateway(
    *, portal_user_id: int, gateway_id: str
) -> dict[str, Any]:
    """Commission one gateway after declarative identity/connectivity checks."""
    async with database_connection() as connection:
        try:
            async with connection.cursor() as cursor:
                await cursor.execute(
                    "SELECT admin.commission_gateway(%s,%s::uuid) AS gateway_result",
                    (portal_user_id, gateway_id),
                )
                row = await cursor.fetchone()
            await connection.commit()
        except DatabaseError:
            await connection.rollback()
            raise

    payload = row["gateway_result"]
    return build_entity_result(
        payload,
        entity_type="GATEWAY",
        entity_id=payload.get("gateway_id"),
        lifecycle_status=payload.get("lifecycle_status"),
        commissioning_status=payload.get("commissioning_status"),
        validation_warnings=payload.get("validation_warnings"),
        blocking_conditions=payload.get("blocking_conditions"),
        audit_transaction_id=payload.get("audit_transaction_id"),
    )
