from typing import Any

from psycopg.errors import DatabaseError

from src.database import database_connection
from src.onboarding.result_contract import build_organization_result


async def create_organization(
    *,
    name: str,
    code: str,
    timezone: str,
    lifecycle_status: str,
    requested_by: str,
) -> dict[str, Any]:
    """Create one EMS organization through the controlled database function."""

    async with database_connection() as connection:
        try:
            async with connection.cursor() as cursor:
                await cursor.execute(
                    """
                    SELECT admin.create_organization(
                        %s,
                        %s,
                        %s,
                        %s,
                        %s
                    ) AS organization_result
                    """,
                    (
                        name,
                        code,
                        timezone,
                        lifecycle_status,
                        requested_by,
                    ),
                )

                row = await cursor.fetchone()

            await connection.commit()

        except DatabaseError:
            await connection.rollback()
            raise

    return build_organization_result(
        row["organization_result"]
    )

async def list_organizations_with_grafana_status() -> list[dict[str, Any]]:
    """Return organizations with their current Grafana provisioning state."""

    async with database_connection() as connection:
        async with connection.cursor() as cursor:
            await cursor.execute(
                """
                SELECT
                    organization_id,
                    organization_code,
                    organization_name,
                    timezone,
                    lifecycle_status,
                    provisioning_status,
                    grafana_org_id,
                    attempt_count,
                    last_attempt_at,
                    provisioned_at,
                    last_error
                FROM admin.list_grafana_provisioning_status()
                """,
                (),
            )

            rows = await cursor.fetchall()

        await connection.rollback()

    return rows


async def get_grafana_provisioning(
    organization_id: str,
) -> dict[str, Any] | None:
    """Return Grafana provisioning state for one EMS organization."""

    async with database_connection() as connection:
        async with connection.cursor() as cursor:
            await cursor.execute(
                """
                SELECT admin.get_grafana_provisioning(
                    %s::uuid
                ) AS provisioning_result
                """,
                (organization_id,),
            )

            row = await cursor.fetchone()

        await connection.rollback()

    return row["provisioning_result"]


async def mark_grafana_provisioning_pending(
    organization_id: str,
) -> dict[str, Any]:
    """Record the start of one Grafana provisioning attempt."""

    async with database_connection() as connection:
        try:
            async with connection.cursor() as cursor:
                await cursor.execute(
                    """
                    SELECT admin.mark_grafana_provisioning_pending(
                        %s::uuid
                    ) AS provisioning_result
                    """,
                    (organization_id,),
                )

                row = await cursor.fetchone()

            await connection.commit()

        except DatabaseError:
            await connection.rollback()
            raise

    return row["provisioning_result"]


async def mark_grafana_provisioning_failed(
    organization_id: str,
    error_message: str,
) -> dict[str, Any]:
    """Persist a Grafana provisioning failure without deleting EMS data."""

    async with database_connection() as connection:
        try:
            async with connection.cursor() as cursor:
                await cursor.execute(
                    """
                    SELECT admin.mark_grafana_provisioning_failed(
                        %s::uuid,
                        %s
                    ) AS provisioning_result
                    """,
                    (
                        organization_id,
                        error_message,
                    ),
                )

                row = await cursor.fetchone()

            await connection.commit()

        except DatabaseError:
            await connection.rollback()
            raise

    return row["provisioning_result"]


async def mark_grafana_provisioning_complete(
    organization_id: str,
    grafana_org_id: int,
) -> dict[str, Any]:
    """Persist the successful one-to-one EMS-to-Grafana mapping."""

    async with database_connection() as connection:
        try:
            async with connection.cursor() as cursor:
                await cursor.execute(
                    """
                    SELECT admin.mark_grafana_provisioning_complete(
                        %s::uuid,
                        %s
                    ) AS provisioning_result
                    """,
                    (
                        organization_id,
                        grafana_org_id,
                    ),
                )

                row = await cursor.fetchone()

            await connection.commit()

        except DatabaseError:
            await connection.rollback()
            raise

    return row["provisioning_result"]


async def get_grafana_reconciliation_context(
    *, portal_user_id: int, organization_id: str,
) -> dict[str, Any]:
    """Return the authoritative local Grafana mapping state."""
    async with database_connection() as connection:
        async with connection.cursor() as cursor:
            await cursor.execute(
                "SELECT admin.get_grafana_reconciliation_context(%s,%s::uuid) AS result",
                (portal_user_id, organization_id),
            )
            row = await cursor.fetchone()
        await connection.rollback()
    return row["result"]


async def apply_grafana_reconciliation_mapping(
    *, portal_user_id: int, organization_id: str,
    grafana_org_id: int, repair_reason: str,
) -> dict[str, Any]:
    """Persist one safe Grafana reconciliation mapping and its audit event."""
    async with database_connection() as connection:
        try:
            async with connection.cursor() as cursor:
                await cursor.execute(
                    "SELECT admin.apply_grafana_reconciliation_mapping(%s,%s::uuid,%s,%s) AS result",
                    (portal_user_id, organization_id, grafana_org_id, repair_reason),
                )
                row = await cursor.fetchone()
            await connection.commit()
        except DatabaseError:
            await connection.rollback()
            raise
    return row["result"]
