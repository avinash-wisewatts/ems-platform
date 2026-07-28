from typing import Any

from psycopg.types.json import Jsonb

from src.database import database_connection


async def get_organization_workspace(*, actor_portal_user_id: int, organization_id: str) -> dict[str, Any] | None:
    async with database_connection() as connection:
        async with connection.cursor() as cursor:
            await cursor.execute(
                "SELECT admin.get_organization_workspace(%s,%s::uuid) AS result",
                (actor_portal_user_id, organization_id),
            )
            row = await cursor.fetchone()
        await connection.rollback()
    return row["result"] if row else None


async def create_organization_workspace(*, actor_portal_user_id: int, requested_by: str, name: str, code: str, legal_name: str, timezone: str, locale: str, lifecycle_status: str, primary_contact: dict[str, str], address: dict[str, str], notes: str) -> dict[str, Any]:
    async with database_connection() as connection:
        try:
            async with connection.cursor() as cursor:
                await cursor.execute(
                    "SELECT admin.create_organization_workspace(%s,%s,%s,%s,%s,%s,%s,%s,%s::jsonb,%s::jsonb,%s) AS result",
                    (actor_portal_user_id, requested_by, name, code, legal_name, timezone, locale, lifecycle_status, Jsonb(primary_contact), Jsonb(address), notes),
                )
                row = await cursor.fetchone()
            await connection.commit()
        except Exception:
            await connection.rollback()
            raise
    return row["result"]


async def update_organization_workspace(*, actor_portal_user_id: int, organization_id: str, name: str, legal_name: str, timezone: str, locale: str, lifecycle_status: str, primary_contact: dict[str, str], address: dict[str, str], notes: str) -> dict[str, Any]:
    async with database_connection() as connection:
        try:
            async with connection.cursor() as cursor:
                await cursor.execute(
                    "SELECT admin.update_organization_workspace(%s,%s::uuid,%s,%s,%s,%s,%s,%s::jsonb,%s::jsonb,%s) AS result",
                    (actor_portal_user_id, organization_id, name, legal_name, timezone, locale, lifecycle_status, Jsonb(primary_contact), Jsonb(address), notes),
                )
                row = await cursor.fetchone()
            await connection.commit()
        except Exception:
            await connection.rollback()
            raise
    return row["result"]
