"""Asset Data Point Assignment (ADR-018 Amendments 5-8) read/write operations.

Mirrors src/relationship_management_service.py's shape (_read_all /
_execute_result-style helpers over admin.* SECURITY DEFINER functions).
"""

import json
from typing import Any

from psycopg.errors import DatabaseError

from src.database import database_connection
from src.onboarding.result_contract import build_entity_result

# ADR-018 Amendment 2 correction / migration 259: the ONE deliberately
# authored admin.save_asset_point_assignments() validation failure that is
# genuinely reachable through normal Admin Portal usage (an admin checking
# points that happen to collide across devices within the same canonical
# measurement group). Every other DatabaseError from that function keeps a
# standard SQLSTATE and must continue through the generic
# user_facing_database_error() path -- see migration 259's header for why
# the mapping is scoped this narrowly.
MEASUREMENT_GROUP_CONFLICT_SQLSTATE = "EM001"

_DEFAULT_CONFLICT_MESSAGE = (
    "This assignment conflicts with another device already confirmed for "
    "the same measurement group on this asset. Each measurement group "
    "(Energy Import, Energy Export, Apparent Energy, Power, Power "
    "Quality, Voltage, Current) must come from a single device."
)


class AssetPointAssignmentConflictError(ValueError):
    """A known, safe-to-display measurement-group source conflict (ERRCODE EM001)."""


def _primary_message(exc: BaseException) -> str | None:
    """Return PostgreSQL's primary message without depending on a concrete driver type."""
    diag: Any = getattr(exc, "diag", None)
    message = getattr(diag, "message_primary", None)
    if isinstance(message, str) and message.strip():
        return message.strip()
    return None


async def _read_all(query: str, params: tuple = ()) -> list[dict[str, Any]]:
    async with database_connection() as connection:
        async with connection.cursor() as cursor:
            await cursor.execute(query, params)
            rows = await cursor.fetchall()
        await connection.rollback()
    return rows


# effective_from / effective_to can be infinite: the staging parity-bridge
# assignments start at '-infinity', which Python's datetime cannot represent
# (psycopg raises DataError while loading the row). An infinite bound means
# "unbounded", so it is returned as NULL; no caller relies on the value.
LIST_CANDIDATES_SQL = """
    SELECT device_id, device_name, relationship_type, relationship_type_name,
           logical_point_id, logical_point_name, point_category_id,
           point_category_name, unit_symbol, is_confirmed, asset_point_id,
           friendly_name,
           CASE WHEN isfinite(effective_from) THEN effective_from END AS effective_from,
           CASE WHEN isfinite(effective_to) THEN effective_to END AS effective_to
    FROM admin.list_asset_point_assignment_candidates(%s, %s::uuid)
"""


async def list_asset_point_assignment_candidates(
    *, portal_user_id: int, asset_id: str
) -> list[dict[str, Any]]:
    return await _read_all(LIST_CANDIDATES_SQL, (portal_user_id, asset_id))


async def get_asset_commissioning_backfill_status(
    *, portal_user_id: int, asset_id: str
) -> dict[str, Any] | None:
    rows = await _read_all(
        "SELECT * FROM admin.get_asset_commissioning_backfill_status(%s, %s::uuid)",
        (portal_user_id, asset_id),
    )
    return rows[0] if rows else None


async def save_asset_point_assignments(
    *,
    portal_user_id: int,
    asset_id: str,
    device_id: str,
    confirmed_points: list[dict[str, Any]],
) -> dict[str, Any]:
    async with database_connection() as connection:
        try:
            async with connection.cursor() as cursor:
                await cursor.execute(
                    "SELECT admin.save_asset_point_assignments(%s, %s::uuid, %s::uuid, %s::jsonb) "
                    "AS save_result",
                    (portal_user_id, asset_id, device_id, json.dumps(confirmed_points)),
                )
                row = await cursor.fetchone()
            await connection.commit()
        except DatabaseError as exc:
            await connection.rollback()
            if getattr(exc, "sqlstate", None) == MEASUREMENT_GROUP_CONFLICT_SQLSTATE:
                raise AssetPointAssignmentConflictError(
                    _primary_message(exc) or _DEFAULT_CONFLICT_MESSAGE
                ) from exc
            raise

    payload = row["save_result"]
    return build_entity_result(
        payload,
        entity_type="ASSET_POINT_ASSIGNMENT",
        entity_id=payload.get("asset_id"),
        audit_transaction_id=payload.get("audit_transaction_id"),
    )
