"""Controlled independent device operations."""

from typing import Any

from psycopg.errors import DatabaseError

from src.database import database_connection
from src.onboarding.result_contract import build_entity_result


async def create_device(
    *, portal_user_id: int, gateway_id: str, device_name: str,
    external_id: str, device_category_id: str, device_model_id: str,
    profile_id: str, protocol: str, lifecycle_status: str,
    firmware_version: str | None, serial_number: str | None,
    identifier_type: str, identifier_value: str, operational_policy: str,
    use_gateway_location: bool, building_id: str | None,
    floor_id: str | None, space_id: str | None,
) -> dict[str, Any]:
    """Create a device and its telemetry identifier atomically."""
    async with database_connection() as connection:
        try:
            async with connection.cursor() as cursor:
                await cursor.execute(
                    """
                    SELECT admin.create_device(
                        %s, %s::uuid, %s, %s, %s::uuid, %s::uuid,
                        %s::uuid, %s, %s, %s, %s, %s,
                        %s::uuid, %s::uuid, %s::uuid, %s, %s, %s
                    ) AS device_result
                    """,
                    (
                        portal_user_id, gateway_id, device_name, external_id,
                        device_category_id, device_model_id, profile_id,
                        protocol, lifecycle_status, firmware_version,
                        serial_number, use_gateway_location, building_id,
                        floor_id, space_id, identifier_type,
                        identifier_value, operational_policy,
                    ),
                )
                row = await cursor.fetchone()
            await connection.commit()
        except DatabaseError:
            await connection.rollback()
            raise
    payload = row["device_result"]
    return build_entity_result(
        payload,
        entity_type="DEVICE",
        entity_id=payload.get("device_id"),
        lifecycle_status=payload.get("lifecycle_status"),
        commissioning_status=payload.get("commissioning_status"),
        validation_warnings=payload.get("validation_warnings"),
        blocking_conditions=payload.get("blocking_conditions"),
        audit_transaction_id=payload.get("audit_transaction_id"),
    )


async def list_accessible_devices(
    *, portal_user_id: int
) -> list[dict[str, Any]]:
    """Return all devices available within one actor's controlled site scope."""
    async with database_connection() as connection:
        async with connection.cursor() as cursor:
            await cursor.execute(
                "SELECT * FROM admin.list_accessible_devices(%s)",
                (portal_user_id,),
            )
            rows = await cursor.fetchall()
        await connection.rollback()
    return rows


async def get_device_workspace(
    *, portal_user_id: int, device_id: str
) -> dict[str, Any] | None:
    """Return one device only when it is accessible to the actor."""
    async with database_connection() as connection:
        async with connection.cursor() as cursor:
            await cursor.execute(
                "SELECT admin.get_device_workspace(%s, %s::uuid) AS result",
                (portal_user_id, device_id),
            )
            row = await cursor.fetchone()
        await connection.rollback()
    return row["result"] if row else None


async def update_device_workspace(
    *, portal_user_id: int, device_id: str, device_name: str,
    device_category_id: str, device_model_id: str, profile_id: str,
    protocol: str, lifecycle_status: str, firmware_version: str | None,
    serial_number: str | None, identifier_type: str,
    identifier_value: str, operational_policy: str, use_gateway_location: bool,
    building_id: str | None, floor_id: str | None,
    space_id: str | None, change_reason: str,
) -> dict[str, Any]:
    """Update one device without changing its organization, gateway or external ID."""
    async with database_connection() as connection:
        try:
            async with connection.cursor() as cursor:
                await cursor.execute(
                    """
                    SELECT admin.update_device_workspace(
                        %s, %s::uuid, %s, %s::uuid, %s::uuid,
                        %s::uuid, %s, %s, %s, %s, %s,
                        %s::uuid, %s::uuid, %s::uuid, %s, %s, %s, %s
                    ) AS result
                    """,
                    (
                        portal_user_id, device_id, device_name,
                        device_category_id, device_model_id, profile_id,
                        protocol, lifecycle_status, firmware_version,
                        serial_number, use_gateway_location, building_id,
                        floor_id, space_id, identifier_type,
                        identifier_value, operational_policy, change_reason,
                    ),
                )
                row = await cursor.fetchone()
            await connection.commit()
        except DatabaseError:
            await connection.rollback()
            raise
    return row["result"]


async def update_device_lifecycle(
    *, portal_user_id: int, device_id: str, lifecycle_status: str,
    change_reason: str | None,
) -> dict[str, Any]:
    """Apply one explicit, audited device lifecycle transition."""
    async with database_connection() as connection:
        try:
            async with connection.cursor() as cursor:
                await cursor.execute(
                    """
                    SELECT admin.update_device_lifecycle(
                        %s, %s::uuid, %s, %s
                    ) AS device_result
                    """,
                    (portal_user_id, device_id, lifecycle_status, change_reason),
                )
                row = await cursor.fetchone()
            await connection.commit()
        except DatabaseError:
            await connection.rollback()
            raise
    payload = row["device_result"]
    return build_entity_result(
        payload,
        entity_type="DEVICE",
        entity_id=payload.get("device_id"),
        lifecycle_status=payload.get("lifecycle_status"),
        audit_transaction_id=payload.get("audit_transaction_id"),
    )


async def set_device_operational_policy(
    *, portal_user_id: int, device_id: str, operational_policy: str,
) -> dict[str, Any]:
    async with database_connection() as connection:
        try:
            async with connection.cursor() as cursor:
                await cursor.execute(
                    "SELECT admin.set_device_operational_policy(%s,%s::uuid,%s) AS device_result",
                    (portal_user_id, device_id, operational_policy),
                )
                row = await cursor.fetchone()
            await connection.commit()
        except DatabaseError:
            await connection.rollback()
            raise
    return row["device_result"]


async def commission_device(
    *, portal_user_id: int, device_id: str,
) -> dict[str, Any]:
    async with database_connection() as connection:
        try:
            async with connection.cursor() as cursor:
                await cursor.execute(
                    "SELECT admin.commission_device(%s,%s::uuid) AS device_result",
                    (portal_user_id, device_id),
                )
                row = await cursor.fetchone()
            await connection.commit()
        except DatabaseError:
            await connection.rollback()
            raise
    payload = row["device_result"]
    return build_entity_result(
        payload,
        entity_type="DEVICE",
        entity_id=payload.get("device_id"),
        lifecycle_status=payload.get("lifecycle_status"),
        commissioning_status=payload.get("commissioning_status"),
        validation_warnings=payload.get("validation_warnings"),
        blocking_conditions=payload.get("blocking_conditions"),
        audit_transaction_id=payload.get("audit_transaction_id"),
    )

async def list_device_point_configuration(
    *, portal_user_id: int, device_id: str
) -> list[dict[str, Any]]:
    """Return the explicit point enablement contract for one device."""
    async with database_connection() as connection:
        async with connection.cursor() as cursor:
            await cursor.execute(
                """
                SELECT *
                FROM admin.list_device_point_configuration(%s, %s::uuid)
                """,
                (portal_user_id, device_id),
            )
            rows = await cursor.fetchall()
        await connection.rollback()
    return rows


async def update_device_point_configuration(
    *, portal_user_id: int, device_id: str,
    enabled_logical_point_ids: list[str], change_reason: str,
) -> dict[str, Any]:
    """Replace the enabled point set for one device atomically."""
    async with database_connection() as connection:
        try:
            async with connection.cursor() as cursor:
                await cursor.execute(
                    """
                    SELECT admin.update_device_point_configuration(
                        %s, %s::uuid, %s::uuid[], %s
                    ) AS result
                    """,
                    (
                        portal_user_id,
                        device_id,
                        enabled_logical_point_ids,
                        change_reason,
                    ),
                )
                row = await cursor.fetchone()
            await connection.commit()
        except DatabaseError:
            await connection.rollback()
            raise
    return row["result"]


async def reset_device_point_configuration(
    *, portal_user_id: int, device_id: str, change_reason: str,
) -> dict[str, Any]:
    """Reset one device to all points supplied by its current mappings."""
    async with database_connection() as connection:
        try:
            async with connection.cursor() as cursor:
                await cursor.execute(
                    """
                    SELECT admin.reset_device_point_configuration(
                        %s, %s::uuid, %s
                    ) AS result
                    """,
                    (portal_user_id, device_id, change_reason),
                )
                row = await cursor.fetchone()
            await connection.commit()
        except DatabaseError:
            await connection.rollback()
            raise
    return row["result"]
