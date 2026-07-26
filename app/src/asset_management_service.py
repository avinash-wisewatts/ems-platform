"""Controlled independent asset inventory operations."""

from typing import Any

from psycopg.errors import DatabaseError

from src.database import database_connection
from src.onboarding.result_contract import build_entity_result


async def create_asset(
    *,
    portal_user_id: int,
    organization_id: str,
    site_id: str,
    asset_name: str,
    asset_type_id: str | None,
    lifecycle_status: str,
    metering_requirement: str,
    parent_asset_id: str | None,
    building_id: str | None,
    floor_id: str | None,
    space_id: str | None,
) -> dict[str, Any]:
    """Create one independent asset with optional hierarchy links."""

    async with database_connection() as connection:
        try:
            async with connection.cursor() as cursor:
                await cursor.execute(
                    """
                    SELECT admin.create_asset(
                        %s,
                        %s::uuid,
                        %s::uuid,
                        %s,
                        %s::uuid,
                        %s,
                        %s,
                        %s::uuid,
                        %s::uuid,
                        %s::uuid,
                        %s::uuid
                    ) AS asset_result
                    """,
                    (
                        portal_user_id,
                        organization_id,
                        site_id,
                        asset_name,
                        asset_type_id,
                        lifecycle_status,
                        metering_requirement,
                        building_id,
                        floor_id,
                        space_id,
                        parent_asset_id,
                    ),
                )

                row = await cursor.fetchone()

            await connection.commit()

        except DatabaseError:
            await connection.rollback()
            raise

    payload = row["asset_result"]

    return build_entity_result(
        payload,
        entity_type="ASSET",
        entity_id=payload.get("asset_id"),
        lifecycle_status=payload.get("lifecycle_status"),
        commissioning_status=payload.get(
            "commissioning_status"
        ),
        validation_warnings=payload.get(
            "validation_warnings"
        ),
        blocking_conditions=payload.get(
            "blocking_conditions"
        ),
        audit_transaction_id=payload.get(
            "audit_transaction_id"
        ),
    )


async def list_accessible_assets(
    *,
    portal_user_id: int,
) -> list[dict[str, Any]]:
    """Return assets visible within one portal user's access scope."""

    async with database_connection() as connection:
        async with connection.cursor() as cursor:
            await cursor.execute(
                """
                SELECT
                    organization_id,
                    organization_code,
                    organization_name,
                    site_id,
                    site_code,
                    site_name,
                    asset_id,
                    asset_name,
                    asset_type_id,
                    asset_type_name,
                    parent_asset_id,
                    parent_asset_name,
                    building_id,
                    building_name,
                    floor_id,
                    floor_name,
                    space_id,
                    space_name,
                    lifecycle_status,
                    metering_requirement,
                    coverage_status
                FROM admin.list_accessible_assets(%s)
                """,
                (portal_user_id,),
            )

            rows = await cursor.fetchall()

        await connection.rollback()

    return rows


async def update_asset(
    *,
    portal_user_id: int,
    asset_id: str,
    asset_name: str,
    asset_type_id: str,
    lifecycle_status: str,
    metering_requirement: str,
    parent_asset_id: str | None,
    building_id: str | None,
    floor_id: str | None,
    space_id: str | None,
) -> dict[str, Any]:
    """Update one accessible asset through the controlled contract."""

    async with database_connection() as connection:
        try:
            async with connection.cursor() as cursor:
                await cursor.execute(
                    """
                    SELECT admin.update_asset(
                        %s,
                        %s::uuid,
                        %s,
                        %s::uuid,
                        %s,
                        %s,
                        %s::uuid,
                        %s::uuid,
                        %s::uuid,
                        %s::uuid
                    ) AS asset_result
                    """,
                    (
                        portal_user_id,
                        asset_id,
                        asset_name,
                        asset_type_id,
                        lifecycle_status,
                        metering_requirement,
                        building_id,
                        floor_id,
                        space_id,
                        parent_asset_id,
                    ),
                )

                row = await cursor.fetchone()

            await connection.commit()

        except DatabaseError:
            await connection.rollback()
            raise

    payload = row["asset_result"]

    return build_entity_result(
        payload,
        entity_type="ASSET",
        entity_id=payload.get("asset_id"),
        lifecycle_status=payload.get("lifecycle_status"),
        commissioning_status=payload.get(
            "commissioning_status"
        ),
        validation_warnings=payload.get(
            "validation_warnings"
        ),
        blocking_conditions=payload.get(
            "blocking_conditions"
        ),
        audit_transaction_id=payload.get(
            "audit_transaction_id"
        ),
    )
