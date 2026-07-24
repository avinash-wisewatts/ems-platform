from typing import Any

from src.database import database_connection


async def list_manageable_users(
    *,
    actor_portal_user_id: int,
) -> list[dict[str, Any]]:
    async with database_connection() as connection:
        try:
            async with connection.cursor() as cursor:
                await cursor.execute(
                    """
                    SELECT *
                    FROM admin.list_manageable_portal_users(%s)
                    """,
                    (actor_portal_user_id,),
                )
                rows = await cursor.fetchall()

            await connection.rollback()
            return list(rows)
        except Exception:
            await connection.rollback()
            raise


async def create_managed_user(
    *,
    actor_portal_user_id: int,
    username: str,
    display_name: str,
    email: str,
    password_hash: str,
    role_code: str,
    organization_id: str | None,
) -> int:
    async with database_connection() as connection:
        try:
            async with connection.cursor() as cursor:
                await cursor.execute(
                    """
                    SELECT admin.create_managed_portal_user(
                        %s,
                        %s,
                        %s,
                        %s,
                        %s,
                        %s,
                        %s
                    ) AS portal_user_id
                    """,
                    (
                        actor_portal_user_id,
                        username,
                        display_name,
                        email,
                        password_hash,
                        role_code,
                        organization_id,
                    ),
                )
                row = await cursor.fetchone()

            if row is None:
                raise RuntimeError(
                    "Portal user creation returned no identifier."
                )

            await connection.commit()
            return int(row["portal_user_id"])
        except Exception:
            await connection.rollback()
            raise


async def change_managed_user_role(
    *,
    actor_portal_user_id: int,
    target_portal_user_id: int,
    role_code: str,
    organization_id: str | None,
) -> None:
    async with database_connection() as connection:
        try:
            async with connection.cursor() as cursor:
                await cursor.execute(
                    """
                    SELECT admin.change_managed_portal_user_role(
                        %s,
                        %s,
                        %s,
                        %s
                    )
                    """,
                    (
                        actor_portal_user_id,
                        target_portal_user_id,
                        role_code,
                        organization_id,
                    ),
                )

            await connection.commit()
        except Exception:
            await connection.rollback()
            raise


async def set_managed_user_active(
    *,
    actor_portal_user_id: int,
    target_portal_user_id: int,
    is_active: bool,
) -> None:
    async with database_connection() as connection:
        try:
            async with connection.cursor() as cursor:
                await cursor.execute(
                    """
                    SELECT admin.set_managed_portal_user_active(
                        %s,
                        %s,
                        %s
                    )
                    """,
                    (
                        actor_portal_user_id,
                        target_portal_user_id,
                        is_active,
                    ),
                )

            await connection.commit()
        except Exception:
            await connection.rollback()
            raise


async def set_managed_user_access_scope(
    *,
    actor_portal_user_id: int,
    target_portal_user_id: int,
    access_scope_mode: str,
    site_ids: tuple[str, ...],
) -> None:
    async with database_connection() as connection:
        try:
            async with connection.cursor() as cursor:
                await cursor.execute(
                    """
                    SELECT admin.set_managed_portal_user_access_scope(
                        %s,
                        %s,
                        %s,
                        %s
                    )
                    """,
                    (
                        actor_portal_user_id,
                        target_portal_user_id,
                        access_scope_mode,
                        list(site_ids),
                    ),
                )

            await connection.commit()
        except Exception:
            await connection.rollback()
            raise
