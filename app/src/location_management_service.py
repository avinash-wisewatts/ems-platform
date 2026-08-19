"""Controlled site and physical-location administration operations."""

from typing import Any

from psycopg.errors import DatabaseError

from src.database import database_connection
from src.onboarding.result_contract import build_entity_result


async def _execute_creation(
    *,
    statement: str,
    parameters: tuple[Any, ...],
    result_column: str,
    entity_type: str,
    entity_id_field: str,
) -> dict[str, Any]:
    """Execute one controlled hierarchy creation function."""

    async with database_connection() as connection:
        try:
            async with connection.cursor() as cursor:
                await cursor.execute(statement, parameters)
                row = await cursor.fetchone()

            await connection.commit()

        except DatabaseError:
            await connection.rollback()
            raise

    payload = row[result_column]

    return build_entity_result(
        payload,
        entity_type=entity_type,
        entity_id=payload.get(entity_id_field),
        lifecycle_status=payload.get("lifecycle_status"),
        audit_transaction_id=payload.get("audit_transaction_id"),
    )


async def create_site(
    *,
    portal_user_id: int,
    organization_id: str,
    name: str,
    code: str,
    timezone: str,
    lifecycle_status: str,
) -> dict[str, Any]:
    """Create one independently managed site."""

    return await _execute_creation(
        statement="""
            SELECT admin.create_site(
                %s,
                %s::uuid,
                %s,
                %s,
                %s,
                %s
            ) AS site_result
        """,
        parameters=(
            portal_user_id,
            organization_id,
            name,
            code,
            timezone,
            lifecycle_status,
        ),
        result_column="site_result",
        entity_type="SITE",
        entity_id_field="site_id",
    )


async def list_manageable_sites(
    *,
    portal_user_id: int,
) -> list[dict[str, Any]]:
    """Return every site visible to the actor, including inactive sites."""

    async with database_connection() as connection:
        async with connection.cursor() as cursor:
            await cursor.execute(
                """
                SELECT
                    site_id, organization_id, organization_code,
                    organization_name, site_code, site_name, timezone,
                    address, lifecycle_status, is_active, created_at, updated_at
                FROM admin.list_manageable_sites(%s)
                """,
                (portal_user_id,),
            )
            rows = await cursor.fetchall()
        await connection.rollback()
    return rows


async def _set_site_capture_interval(
    *,
    cursor,
    portal_user_id: int,
    site_id: str,
    capture_interval_seconds: int,
    change_reason: str,
) -> None:
    await cursor.execute(
        """
        SELECT admin.set_site_telemetry_capture_interval(
            %s, %s::uuid, %s, %s
        )
        """,
        (portal_user_id, site_id, capture_interval_seconds, change_reason),
    )


async def _set_site_demand_policy(
    *,
    cursor,
    portal_user_id: int,
    site_id: str,
    is_enabled: bool,
    demand_interval_seconds: int,
    demand_basis: str,
    site_demand_source_role: str,
    minimum_coverage_percent: float,
    late_arrival_tolerance_seconds: int,
    change_reason: str,
) -> None:
    """Persist the effective site demand-monitoring policy."""

    await cursor.execute(
        """
        SELECT admin.set_site_demand_policy(
            %s::bigint,
            %s::uuid,
            %s::boolean,
            %s::integer,
            %s::text,
            %s::text,
            %s::numeric,
            %s::integer,
            %s::text
        )
        """,
        (
            portal_user_id,
            site_id,
            is_enabled,
            demand_interval_seconds,
            demand_basis,
            site_demand_source_role,
            minimum_coverage_percent,
            late_arrival_tolerance_seconds,
            change_reason,
        ),
    )


async def get_site_workspace(
    *,
    portal_user_id: int,
    site_id: str,
) -> dict[str, Any] | None:
    """Return one site only when it is inside the actor's access scope."""

    async with database_connection() as connection:
        async with connection.cursor() as cursor:
            await cursor.execute(
                "SELECT admin.get_site_workspace(%s, %s::uuid) AS result",
                (portal_user_id, site_id),
            )
            row = await cursor.fetchone()
        await connection.rollback()
    result = row["result"] if row else None
    if result is None:
        return None

    async with database_connection() as connection:
        async with connection.cursor() as cursor:
            await cursor.execute(
                "SELECT admin.get_site_telemetry_capture_interval(%s, %s::uuid) AS interval_seconds",
                (portal_user_id, site_id),
            )
            interval_row = await cursor.fetchone()

            await cursor.execute(
                """
                SELECT *
                FROM admin.get_site_demand_policy(%s, %s::uuid)
                """,
                (portal_user_id, site_id),
            )
            demand_policy_row = await cursor.fetchone()

            await cursor.execute(
                """
                SELECT *
                FROM admin.get_site_demand_readiness(%s, %s::uuid)
                """,
                (portal_user_id, site_id),
            )
            demand_readiness_row = await cursor.fetchone()

        await connection.rollback()

    result["telemetry_capture_interval_seconds"] = (
        interval_row["interval_seconds"] if interval_row else 60
    )
    result["demand_policy"] = (
        dict(demand_policy_row) if demand_policy_row else None
    )
    result["demand_readiness"] = (
        dict(demand_readiness_row) if demand_readiness_row else None
    )
    return result


async def set_site_sub_sector(
    *,
    cursor,
    portal_user_id: int,
    site_id: str,
    sub_sector_id: str,
) -> None:
    await cursor.execute(
        """
        SELECT admin.set_site_sub_sector(
            %s, %s::uuid, %s::uuid
        )
        """,
        (portal_user_id, site_id, sub_sector_id),
    )


async def create_site_workspace(
    *,
    portal_user_id: int,
    organization_id: str,
    name: str,
    code: str,
    timezone: str,
    lifecycle_status: str,
    address: dict[str, str],
    telemetry_capture_interval_seconds: int,
    sub_sector_id: str | None = None,
) -> dict[str, Any]:
    """Create one site through the scope-aware site workspace contract."""

    async with database_connection() as connection:
        try:
            async with connection.cursor() as cursor:
                await cursor.execute(
                    """
                    SELECT admin.create_site_workspace(
                        %s, %s::uuid, %s, %s, %s, %s, %s::jsonb
                    ) AS result
                    """,
                    (portal_user_id, organization_id, name, code, timezone,
                     lifecycle_status, __import__('json').dumps(address)),
                )
                row = await cursor.fetchone()
                if sub_sector_id:
                    await set_site_sub_sector(
                        cursor=cursor,
                        portal_user_id=portal_user_id,
                        site_id=str(row["result"]["site_id"]),
                        sub_sector_id=sub_sector_id,
                    )
                await _set_site_capture_interval(
                    cursor=cursor,
                    portal_user_id=portal_user_id,
                    site_id=str(row["result"]["site_id"]),
                    capture_interval_seconds=telemetry_capture_interval_seconds,
                    change_reason="Site creation telemetry storage interval",
                )
            await connection.commit()
        except DatabaseError:
            await connection.rollback()
            raise
    return row["result"]


async def update_site_workspace(
    *,
    portal_user_id: int,
    site_id: str,
    name: str,
    timezone: str,
    lifecycle_status: str,
    address: dict[str, str],
    change_reason: str,
    telemetry_capture_interval_seconds: int,
    demand_monitoring_enabled: bool,
    demand_interval_seconds: int,
    demand_basis: str,
    site_demand_source_role: str,
    demand_minimum_coverage_percent: float,
    demand_late_arrival_tolerance_seconds: int,
    sub_sector_id: str | None = None,
) -> dict[str, Any]:
    """Update one site without allowing organization or code reassignment."""

    async with database_connection() as connection:
        try:
            async with connection.cursor() as cursor:
                await cursor.execute(
                    """
                    SELECT admin.update_site_workspace(
                        %s, %s::uuid, %s, %s, %s, %s::jsonb, %s
                    ) AS result
                    """,
                    (portal_user_id, site_id, name, timezone, lifecycle_status,
                     __import__('json').dumps(address), change_reason),
                )
                row = await cursor.fetchone()
                if sub_sector_id:
                    await set_site_sub_sector(
                        cursor=cursor,
                        portal_user_id=portal_user_id,
                        site_id=site_id,
                        sub_sector_id=sub_sector_id,
                    )
                await _set_site_capture_interval(
                    cursor=cursor,
                    portal_user_id=portal_user_id,
                    site_id=site_id,
                    capture_interval_seconds=telemetry_capture_interval_seconds,
                    change_reason=change_reason,
                )
                await _set_site_demand_policy(
                    cursor=cursor,
                    portal_user_id=portal_user_id,
                    site_id=site_id,
                    is_enabled=demand_monitoring_enabled,
                    demand_interval_seconds=demand_interval_seconds,
                    demand_basis=demand_basis,
                    site_demand_source_role=site_demand_source_role,
                    minimum_coverage_percent=demand_minimum_coverage_percent,
                    late_arrival_tolerance_seconds=(
                        demand_late_arrival_tolerance_seconds
                    ),
                    change_reason=change_reason,
                )
            await connection.commit()
        except DatabaseError:
            await connection.rollback()
            raise
    return row["result"]


async def get_location_workspace(
    *,
    portal_user_id: int,
    location_type: str,
    location_id: str,
) -> dict[str, Any] | None:
    """Return one accessible building, floor, or space workspace."""

    async with database_connection() as connection:
        async with connection.cursor() as cursor:
            await cursor.execute(
                "SELECT admin.get_location_workspace(%s, %s, %s::uuid) AS result",
                (portal_user_id, location_type, location_id),
            )
            row = await cursor.fetchone()
        await connection.rollback()
    return row["result"] if row else None


async def update_location_workspace(
    *,
    portal_user_id: int,
    location_type: str,
    location_id: str,
    name: str,
    change_reason: str,
) -> dict[str, Any]:
    """Update one location without changing its type, code, or parent."""

    async with database_connection() as connection:
        try:
            async with connection.cursor() as cursor:
                await cursor.execute(
                    "SELECT admin.update_location_workspace(%s, %s, %s::uuid, %s, %s) AS result",
                    (portal_user_id, location_type, location_id, name, change_reason),
                )
                row = await cursor.fetchone()
            await connection.commit()
        except DatabaseError:
            await connection.rollback()
            raise
    return row["result"]


async def create_building(
    *,
    portal_user_id: int,
    site_id: str,
    name: str,
    code: str,
) -> dict[str, Any]:
    """Create one building under an accessible site."""

    return await _execute_creation(
        statement="""
            SELECT admin.create_building(
                %s,
                %s::uuid,
                %s,
                %s
            ) AS building_result
        """,
        parameters=(
            portal_user_id,
            site_id,
            name,
            code,
        ),
        result_column="building_result",
        entity_type="BUILDING",
        entity_id_field="building_id",
    )


async def create_floor(
    *,
    portal_user_id: int,
    building_id: str,
    name: str,
    code: str,
) -> dict[str, Any]:
    """Create one floor under an accessible building."""

    return await _execute_creation(
        statement="""
            SELECT admin.create_floor(
                %s,
                %s::uuid,
                %s,
                %s
            ) AS floor_result
        """,
        parameters=(
            portal_user_id,
            building_id,
            name,
            code,
        ),
        result_column="floor_result",
        entity_type="FLOOR",
        entity_id_field="floor_id",
    )


async def create_space(
    *,
    portal_user_id: int,
    floor_id: str,
    name: str,
    code: str,
) -> dict[str, Any]:
    """Create one space under an accessible floor."""

    return await _execute_creation(
        statement="""
            SELECT admin.create_space(
                %s,
                %s::uuid,
                %s,
                %s
            ) AS space_result
        """,
        parameters=(
            portal_user_id,
            floor_id,
            name,
            code,
        ),
        result_column="space_result",
        entity_type="SPACE",
        entity_id_field="space_id",
    )


async def list_accessible_physical_locations(
    *,
    portal_user_id: int,
) -> list[dict[str, Any]]:
    """Return the hierarchy visible to one portal user."""

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
                    building_id,
                    building_code,
                    building_name,
                    floor_id,
                    floor_code,
                    floor_name,
                    space_id,
                    space_code,
                    space_name
                FROM admin.list_accessible_physical_locations(%s)
                """,
                (portal_user_id,),
            )

            rows = await cursor.fetchall()

        await connection.rollback()

    return rows
