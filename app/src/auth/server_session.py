"""Server-side customer sessions in the database (ADR-023, migration 314).

The customer API's half of admin.portal_sessions: create at sign-in, check
(and slide the idle expiry) on every authenticated request, revoke at
sign-out. Only the SHA-256 of the session token reaches the database
(src.auth.customer_session.session_token_hash). live-telemetry checks the
same sessions read-only (admin.get_portal_session_user, src.live_main).
"""

from __future__ import annotations

from src.auth.customer_session import CUSTOMER_AUDIENCE, session_token_hash
from src.database import database_connection


async def create_server_session(
    portal_user_id: int,
    token: str,
    *,
    idle_seconds: int,
    absolute_seconds: int,
) -> bool:
    """Record a new session; False when the account is not active."""

    async with database_connection() as connection:
        async with connection.cursor() as cursor:
            await cursor.execute(
                "SELECT admin.create_portal_session(%s, %s, %s, %s, %s) AS created",
                (portal_user_id, session_token_hash(token), CUSTOMER_AUDIENCE, idle_seconds, absolute_seconds),
            )
            row = await cursor.fetchone()
    return bool(row and row["created"])


async def touch_server_session(token: str, *, idle_seconds: int) -> int | None:
    """The portal_user_id of a live session (sliding its idle expiry), else None."""

    async with database_connection() as connection:
        async with connection.cursor() as cursor:
            await cursor.execute(
                "SELECT admin.touch_portal_session(%s, %s, %s) AS portal_user_id",
                (session_token_hash(token), CUSTOMER_AUDIENCE, idle_seconds),
            )
            row = await cursor.fetchone()
    return row["portal_user_id"] if row else None


async def revoke_server_session(token: str, *, reason: str = "LOGOUT") -> None:
    """Revoke one session; a no-op when it is already revoked or unknown."""

    async with database_connection() as connection:
        async with connection.cursor() as cursor:
            await cursor.execute(
                "SELECT admin.revoke_portal_session(%s, %s)",
                (session_token_hash(token), reason),
            )
