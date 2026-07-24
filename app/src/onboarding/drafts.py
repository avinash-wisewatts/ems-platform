from typing import Any
from uuid import UUID

from psycopg.types.json import Jsonb

from src.database import database_connection
from src.onboarding.result_contract import build_onboarding_result


async def get_onboarding_draft(
    draft_token: UUID,
    *,
    portal_user_id: int,
    role_code: str,
) -> dict[str, Any] | None:
    """
    Return one active, unexpired draft visible to the authenticated user.

    PostgreSQL remains authoritative for ownership and SUPER_ADMIN access.
    """

    async with database_connection() as connection:
        async with connection.cursor() as cursor:
            await cursor.execute(
                """
                SELECT
                    draft_token,
                    current_step,
                    status,
                    payload,
                    requested_by,
                    owner_portal_user_id,
                    created_at,
                    updated_at,
                    expires_at
                FROM admin.get_onboarding_draft(
                    %s::uuid,
                    %s::bigint,
                    %s
                )
                """,
                (
                    str(draft_token),
                    portal_user_id,
                    role_code,
                ),
            )

            return await cursor.fetchone()


async def save_onboarding_draft_step(
    *,
    draft_token: UUID | None,
    step: str,
    step_payload: dict[str, Any],
    next_step: str,
    portal_user_id: int,
    role_code: str,
    requested_by: str,
) -> UUID:
    """
    Create or update one validated onboarding draft step.

    PostgreSQL verifies the active portal account, current role, actor identity,
    and draft ownership before modifying any draft data.
    """

    async with database_connection() as connection:
        try:
            async with connection.cursor() as cursor:
                await cursor.execute(
                    """
                    SELECT admin.save_onboarding_draft_step(
                        %s::uuid,
                        %s,
                        %s::jsonb,
                        %s,
                        %s::bigint,
                        %s,
                        %s
                    ) AS draft_token
                    """,
                    (
                        str(draft_token) if draft_token else None,
                        step,
                        Jsonb(step_payload),
                        next_step,
                        portal_user_id,
                        role_code,
                        requested_by,
                    ),
                )

                row = await cursor.fetchone()

            await connection.commit()

        except Exception:
            await connection.rollback()
            raise

    return UUID(str(row["draft_token"]))


async def submit_onboarding_draft(
    *,
    draft_token: UUID,
    portal_user_id: int,
    role_code: str,
    requested_by: str,
) -> dict[str, Any]:
    """
    Atomically execute a completed onboarding draft.

    PostgreSQL verifies the active portal account, current role, actor identity,
    and draft ownership before locking and submitting the draft.
    """

    async with database_connection() as connection:
        try:
            async with connection.cursor() as cursor:
                await cursor.execute(
                    """
                    SELECT admin.submit_onboarding_draft(
                        %s::uuid,
                        %s::bigint,
                        %s,
                        %s
                    ) AS onboarding_result
                    """,
                    (
                        str(draft_token),
                        portal_user_id,
                        role_code,
                        requested_by,
                    ),
                )

                row = await cursor.fetchone()

            await connection.commit()

        except Exception:
            await connection.rollback()
            raise

    return build_onboarding_result(
        row["onboarding_result"],
        audit_transaction_id=draft_token,
    )


async def get_submitted_onboarding_result(
    draft_token: UUID,
    *,
    portal_user_id: int,
    role_code: str,
) -> dict[str, Any] | None:
    """
    Return one submitted result visible to the authenticated portal user.

    PostgreSQL enforces ownership, current account state, and SUPER_ADMIN
    override. The application role has no direct table access.
    """

    async with database_connection() as connection:
        async with connection.cursor() as cursor:
            await cursor.execute(
                """
                SELECT
                    draft_token,
                    status,
                    requested_by,
                    owner_portal_user_id,
                    created_at,
                    submitted_at,
                    payload,
                    result
                FROM admin.get_submitted_onboarding_result(
                    %s::uuid,
                    %s::bigint,
                    %s
                )
                """,
                (
                    str(draft_token),
                    portal_user_id,
                    role_code,
                ),
            )

            record = await cursor.fetchone()

    if record is None:
        return None

    normalized_record = dict(record)
    normalized_record["result"] = build_onboarding_result(
        normalized_record["result"],
        audit_transaction_id=draft_token,
    )
    return normalized_record


async def log_onboarding_submission_failure(
    *,
    draft_token: UUID,
    requested_by: str,
    error_message: str,
    error_type: str,
) -> UUID:
    """
    Record a failed final submission in a separate database transaction.

    This function must be called only after the failed onboarding transaction
    has rolled back. Keeping this write separate ensures the failure event is
    not rolled back with the production operation.
    """

    context = {
        "error_message": error_message[:2000],
        "error_type": error_type[:200],
    }

    async with database_connection() as connection:
        try:
            async with connection.cursor() as cursor:
                await cursor.execute(
                    """
                    SELECT admin.log_onboarding_event(
                        %s::uuid,
                        'SUBMISSION_FAILED',
                        'review',
                        %s,
                        %s::jsonb
                    ) AS event_id
                    """,
                    (
                        str(draft_token),
                        requested_by,
                        Jsonb(context),
                    ),
                )

                row = await cursor.fetchone()

            await connection.commit()

        except Exception:
            await connection.rollback()
            raise

    return UUID(str(row["event_id"]))
