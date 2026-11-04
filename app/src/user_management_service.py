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


async def list_managed_user_audit(
    *,
    actor_portal_user_id: int,
    target_portal_user_id: int,
    limit: int = 50,
) -> list[dict[str, Any]]:
    """One user's audit history, newest first (migration 319).

    The database function applies the actor's scope: no rows for a target
    outside it, organization-only rows (without organization / site ids) for
    a non-GLOBAL actor, redacted payloads.
    """

    async with database_connection() as connection:
        try:
            async with connection.cursor() as cursor:
                await cursor.execute(
                    """
                    SELECT *
                    FROM admin.list_manageable_portal_user_audit(%s, %s, %s)
                    """,
                    (actor_portal_user_id, target_portal_user_id, limit),
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
    access_scope_mode: str,
    organization_id: str | None,
    site_ids: tuple[str, ...],
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
                        access_scope_mode,
                        organization_id,
                        list(site_ids),
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
) -> None:
    async with database_connection() as connection:
        try:
            async with connection.cursor() as cursor:
                await cursor.execute(
                    """
                    SELECT admin.change_managed_portal_user_role(
                        %s,
                        %s,
                        %s
                    )
                    """,
                    (
                        actor_portal_user_id,
                        target_portal_user_id,
                        role_code,
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
    organization_id: str | None,
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
                        %s,
                        %s
                    )
                    """,
                    (
                        actor_portal_user_id,
                        target_portal_user_id,
                        access_scope_mode,
                        organization_id,
                        list(site_ids),
                    ),
                )

            await connection.commit()
        except Exception:
            await connection.rollback()
            raise


# ---------------------------------------------------------------------------
# EMS Web App Admin -> Users (migration 315). Same controlled database
# functions as the Administration App's Users pages; a multi-field edit or a
# create-as-inactive runs in ONE transaction so it is all-or-nothing.
# ---------------------------------------------------------------------------


async def create_managed_user_with_status(
    *,
    actor_portal_user_id: int,
    username: str,
    display_name: str,
    email: str,
    password_hash: str,
    role_code: str,
    access_scope_mode: str,
    organization_id: str | None,
    site_ids: tuple[str, ...],
    is_active: bool,
) -> int:
    """Create a user (and, if requested, leave it inactive) atomically."""

    async with database_connection() as connection:
        try:
            async with connection.cursor() as cursor:
                await cursor.execute(
                    """
                    SELECT admin.create_managed_portal_user(
                        %s, %s, %s, %s, %s, %s, %s, %s, %s
                    ) AS portal_user_id
                    """,
                    (
                        actor_portal_user_id,
                        username,
                        display_name,
                        email,
                        password_hash,
                        role_code,
                        access_scope_mode,
                        organization_id,
                        list(site_ids),
                    ),
                )
                row = await cursor.fetchone()
                if row is None:
                    raise RuntimeError(
                        "Portal user creation returned no identifier."
                    )
                portal_user_id = int(row["portal_user_id"])

                if not is_active:
                    await cursor.execute(
                        "SELECT admin.set_managed_portal_user_active(%s, %s, %s)",
                        (actor_portal_user_id, portal_user_id, False),
                    )

            await connection.commit()
            return portal_user_id
        except Exception:
            await connection.rollback()
            raise


async def apply_managed_user_changes(
    *,
    actor_portal_user_id: int,
    target_portal_user_id: int,
    details: tuple[str, str] | None = None,
    role_code: str | None = None,
    access_scope: tuple[str, str | None, tuple[str, ...]] | None = None,
    is_active: bool | None = None,
) -> None:
    """Apply any combination of edits to one managed user in one transaction.

    details      -- (display_name, email)
    access_scope -- (access_scope_mode, organization_id, site_ids)
    Each part calls its own audited database function; any refusal rolls
    back every part.
    """

    async with database_connection() as connection:
        try:
            async with connection.cursor() as cursor:
                if details is not None:
                    await cursor.execute(
                        "SELECT admin.update_managed_portal_user_details(%s, %s, %s, %s)",
                        (actor_portal_user_id, target_portal_user_id, details[0], details[1]),
                    )
                if access_scope is not None:
                    await cursor.execute(
                        "SELECT admin.set_managed_portal_user_access_scope(%s, %s, %s, %s, %s)",
                        (
                            actor_portal_user_id,
                            target_portal_user_id,
                            access_scope[0],
                            access_scope[1],
                            list(access_scope[2]),
                        ),
                    )
                if role_code is not None:
                    await cursor.execute(
                        "SELECT admin.change_managed_portal_user_role(%s, %s, %s)",
                        (actor_portal_user_id, target_portal_user_id, role_code),
                    )
                if is_active is not None:
                    await cursor.execute(
                        "SELECT admin.set_managed_portal_user_active(%s, %s, %s)",
                        (actor_portal_user_id, target_portal_user_id, is_active),
                    )

            await connection.commit()
        except Exception:
            await connection.rollback()
            raise


async def reset_managed_user_password(
    *,
    actor_portal_user_id: int,
    target_portal_user_id: int,
    password_hash: str,
) -> None:
    """Set a new (temporary) password hash for another managed user."""

    async with database_connection() as connection:
        try:
            async with connection.cursor() as cursor:
                await cursor.execute(
                    "SELECT admin.reset_managed_portal_user_password(%s, %s, %s)",
                    (actor_portal_user_id, target_portal_user_id, password_hash),
                )
            await connection.commit()
        except Exception:
            await connection.rollback()
            raise


async def change_own_password(
    *,
    portal_user_id: int,
    password_hash: str,
) -> None:
    """Replace the signed-in user's own password hash (current one verified by the caller)."""

    async with database_connection() as connection:
        try:
            async with connection.cursor() as cursor:
                await cursor.execute(
                    "SELECT admin.change_own_portal_user_password(%s, %s)",
                    (portal_user_id, password_hash),
                )
            await connection.commit()
        except Exception:
            await connection.rollback()
            raise
