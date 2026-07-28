"""Controlled asset-device relationship operations."""

from typing import Any
from psycopg.errors import DatabaseError
from src.database import database_connection
from src.onboarding.result_contract import build_entity_result

async def _read_all(query: str, params: tuple = ()) -> list[dict[str, Any]]:
    async with database_connection() as connection:
        async with connection.cursor() as cursor:
            await cursor.execute(query, params)
            rows = await cursor.fetchall()
        await connection.rollback()
    return rows

async def _execute_result(query: str, params: tuple) -> dict[str, Any]:
    async with database_connection() as connection:
        try:
            async with connection.cursor() as cursor:
                await cursor.execute(query, params)
                row = await cursor.fetchone()
            await connection.commit()
        except DatabaseError:
            await connection.rollback()
            raise
    payload = row["relationship_result"]
    return build_entity_result(payload, entity_type="ASSET_DEVICE_RELATIONSHIP", entity_id=payload.get("relationship_id"), audit_transaction_id=payload.get("audit_transaction_id"))

async def list_relationship_types() -> list[dict[str, Any]]:
    return await _read_all("SELECT code,name,description,exclusivity_policy FROM config.asset_device_relationship_types WHERE is_active=TRUE ORDER BY display_order,code")

async def list_accessible_relationships(*, portal_user_id: int) -> list[dict[str, Any]]:
    return await _read_all("SELECT * FROM admin.list_accessible_asset_device_relationships(%s)", (portal_user_id,))

async def assign_device_to_asset(*, portal_user_id: int, asset_id: str, device_id: str, relationship_type: str) -> dict[str, Any]:
    return await _execute_result("SELECT admin.assign_device_to_asset(%s,%s::uuid,%s::uuid,%s) AS relationship_result", (portal_user_id,asset_id,device_id,relationship_type))

async def update_relationship_metadata(*, portal_user_id: int, relationship_id: str, panel_name: str|None, feeder_name: str|None, breaker_identifier: str|None, channel_identifier: str|None, ct_ratio: str|None, phase_designation: str|None, mounting_point: str|None, engineering_notes: str|None) -> dict[str, Any]:
    return await _execute_result("SELECT admin.update_asset_device_relationship_metadata(%s,%s::uuid,%s,%s,%s,%s,%s::numeric,%s,%s,%s) AS relationship_result", (portal_user_id,relationship_id,panel_name,feeder_name,breaker_identifier,channel_identifier,ct_ratio,phase_designation,mounting_point,engineering_notes))

async def remove_relationship(*, portal_user_id: int, relationship_id: str, removal_reason: str) -> dict[str, Any]:
    return await _execute_result("SELECT admin.remove_asset_device_relationship(%s,%s::uuid,%s) AS relationship_result", (portal_user_id,relationship_id,removal_reason))

async def replace_primary_meter(*, portal_user_id: int, relationship_id: str, replacement_device_id: str, replacement_reason: str) -> dict[str, Any]:
    return await _execute_result("SELECT admin.replace_asset_primary_meter(%s,%s::uuid,%s::uuid,%s) AS relationship_result", (portal_user_id,relationship_id,replacement_device_id,replacement_reason))
