from typing import Any

from src.auth.models import PortalUserAuthenticationRecord
from src.database import database_connection


async def get_portal_user_for_authentication(
    username: str,
) -> PortalUserAuthenticationRecord | None:
    """
    Retrieve one normalized portal identity through the controlled database
    authentication function.

    Direct SELECT access to admin.portal_users remains denied to ems_app.
    """

    async with database_connection() as connection:
        async with connection.cursor() as cursor:
            await cursor.execute(
                """
                SELECT
                    portal_user_id,
                    username,
                    display_name,
                    password_hash,
                    role_code,
                    organization_id,
                    access_scope_mode,
                    site_ids,
                    is_active,
                    failed_login_count,
                    locked_until
                FROM admin.get_portal_user_for_authentication(%s)
                """,
                (username,),
            )

            row: dict[str, Any] | None = await cursor.fetchone()

    if row is None:
        return None

    return PortalUserAuthenticationRecord(
        portal_user_id=row["portal_user_id"],
        username=row["username"],
        display_name=row["display_name"],
        password_hash=row["password_hash"],
        role_code=row["role_code"],
        is_active=row["is_active"],
        organization_id=(
            str(row["organization_id"])
            if row["organization_id"] is not None
            else None
        ),
        access_scope_mode=row["access_scope_mode"],
        site_ids=tuple(
            str(site_id)
            for site_id in (row["site_ids"] or [])
        ),
        failed_login_count=row["failed_login_count"],
        locked_until=row["locked_until"],
    )


async def record_portal_login_success(
    portal_user_id: int,
) -> None:
    """Reset failure state and record the latest successful login."""

    async with database_connection() as connection:
        async with connection.cursor() as cursor:
            await cursor.execute(
                """
                SELECT admin.record_portal_login_success(%s)
                """,
                (portal_user_id,),
            )


async def record_portal_login_failure(
    portal_user_id: int,
) -> None:
    """Increment the controlled failed-login counter."""

    async with database_connection() as connection:
        async with connection.cursor() as cursor:
            await cursor.execute(
                """
                SELECT admin.record_portal_login_failure(%s)
                """,
                (portal_user_id,),
            )
