"""Reports tab -- background export jobs (migration 309).

Job records and generated ZIP files live in analytics.report_export_jobs /
analytics.report_export_files, reached only through the migration 309
SECURITY DEFINER functions. There is no separate queue or object store: the
admin portal process runs one ReportExportWorker task that claims a job
(FOR UPDATE SKIP LOCKED, with a lease, so a restarted worker -- or a second
process -- never runs a job twice concurrently and an interrupted job is
picked up again), builds the ZIP with the job OWNER's portal-scoped
Analytics reads, and stores it until it expires. The same loop purges
expired files.
"""

from __future__ import annotations

import asyncio
import logging
import os
import socket
from datetime import timedelta
from typing import Any
from uuid import UUID, uuid4

from src.analytics_api_service import ApiContractError
from src.report_export_service import ExportRequest, build_export_zip, estimate_export, prepare_export


logger = logging.getLogger(__name__)

LEASE = timedelta(minutes=10)
MAX_ATTEMPTS = 3
# Job rows (and so their history in the Reports tab) are kept this long.
HISTORY = timedelta(days=30)
PURGE_EVERY_SECONDS = 600.0


# ---------------------------------------------------------------------------
# Data access (writes commit; reads roll back like every /api/v1 read).
# ---------------------------------------------------------------------------

async def _execute(sql: str, params: tuple[Any, ...], *, commit: bool) -> list[dict[str, Any]]:
    from src.database import database_connection

    async with database_connection() as connection:
        try:
            async with connection.cursor() as cursor:
                await cursor.execute(sql, params)
                rows = await cursor.fetchall() if cursor.description else []
            if commit:
                await connection.commit()
            else:
                await connection.rollback()
        except BaseException:
            await connection.rollback()
            raise
    return rows


class ActiveJobLimitError(Exception):
    """The portal user already has the maximum number of active jobs."""


async def create_job(
    portal_user_id: int, site_id: UUID, request: ExportRequest, max_active: int, asset_ids: list[UUID]
) -> dict[str, Any] | None:
    """None when the site, or a selected asset, is not accessible
    (migration 312)."""

    import psycopg.errors

    try:
        rows = await _execute(
            "SELECT * FROM analytics.create_portal_report_export_job(%s, %s, %s, %s, %s, %s, %s, %s::uuid[])",
            (
                portal_user_id,
                str(site_id),
                request.dt_from,
                request.dt_to,
                request.requested_resolution,
                request.resolution,
                max_active,
                [str(a) for a in asset_ids],
            ),
            commit=True,
        )
    except psycopg.errors.ProgramLimitExceeded as exc:
        raise ActiveJobLimitError() from exc
    return rows[0] if rows else None


async def list_jobs(portal_user_id: int, limit: int = 50) -> list[dict[str, Any]]:
    return await _execute(
        "SELECT * FROM analytics.list_portal_report_export_jobs(%s, %s)", (portal_user_id, limit), commit=False
    )


async def get_job(portal_user_id: int, job_id: UUID) -> dict[str, Any] | None:
    rows = await _execute(
        "SELECT * FROM analytics.get_portal_report_export_job(%s, %s)", (portal_user_id, str(job_id)), commit=False
    )
    return rows[0] if rows else None


async def retry_job(portal_user_id: int, job_id: UUID) -> dict[str, Any] | None:
    rows = await _execute(
        "SELECT * FROM analytics.retry_portal_report_export_job(%s, %s)", (portal_user_id, str(job_id)), commit=True
    )
    return rows[0] if rows else None


async def get_job_file(portal_user_id: int, job_id: UUID) -> dict[str, Any] | None:
    rows = await _execute(
        "SELECT file_name, content FROM analytics.get_portal_report_export_file(%s, %s)",
        (portal_user_id, str(job_id)),
        commit=False,
    )
    return rows[0] if rows else None


async def claim_job(worker_id: str) -> dict[str, Any] | None:
    rows = await _execute(
        "SELECT * FROM analytics.claim_report_export_job(%s, %s, %s)", (worker_id, LEASE, MAX_ATTEMPTS), commit=True
    )
    return rows[0] if rows else None


async def extend_lease(job_id: UUID, worker_id: str) -> bool:
    rows = await _execute(
        "SELECT analytics.extend_report_export_lease(%s, %s, %s) AS ok", (str(job_id), worker_id, LEASE), commit=True
    )
    return bool(rows and rows[0]["ok"])


async def complete_job(
    job_id: UUID, worker_id: str, file_name: str, content: bytes, asset_count: int, row_count: int,
    retention: timedelta,
) -> bool:
    rows = await _execute(
        "SELECT analytics.complete_report_export_job(%s, %s, %s, %s, %s, %s, %s) AS ok",
        (str(job_id), worker_id, file_name, content, asset_count, row_count, retention),
        commit=True,
    )
    return bool(rows and rows[0]["ok"])


async def fail_job(job_id: UUID, worker_id: str, code: str, message: str) -> bool:
    rows = await _execute(
        "SELECT analytics.fail_report_export_job(%s, %s, %s, %s) AS ok",
        (str(job_id), worker_id, code, message),
        commit=True,
    )
    return bool(rows and rows[0]["ok"])


async def purge_expired() -> dict[str, Any] | None:
    rows = await _execute("SELECT * FROM analytics.purge_report_exports(%s)", (HISTORY,), commit=True)
    return rows[0] if rows else None


# ---------------------------------------------------------------------------
# Job execution.
# ---------------------------------------------------------------------------

class ExportFailure(Exception):
    def __init__(self, code: str, message: str) -> None:
        super().__init__(message)
        self.code = code
        self.message = message


async def run_job(job: dict[str, Any], worker_id: str, *, max_cells: int, retention: timedelta) -> None:
    """Build and store one claimed job, or record why it failed. Every read
    is keyed on the job owner's portal_user_id, so the owner's current site
    access is enforced again at execution time."""

    job_id = UUID(str(job["id"]))
    portal_user_id = int(job["portal_user_id"])
    site_id = UUID(str(job["site_id"]))
    asset_ids = job.get("asset_ids")
    request = ExportRequest(
        dt_from=job["range_from"],
        dt_to=job["range_to"],
        requested_resolution=job["requested_resolution"],
        resolution=job["resolution"],
        # None: a job queued before migration 312 -- every asset of the site.
        asset_ids=None if asset_ids is None else tuple(UUID(str(a)) for a in asset_ids),
    )
    try:
        ctx = await prepare_export(portal_user_id, site_id, request)
        if ctx is None:
            raise ExportFailure("site_not_accessible", "The site is no longer accessible to you.")
        estimate = estimate_export(ctx.request, ctx.site_assets, ctx.catalog_rows)
        if estimate.cells > max_cells:
            raise ExportFailure(
                "export_too_large",
                "The export is too large. Choose a shorter time range or a coarser resolution.",
            )

        async def keep_lease() -> None:
            if not await extend_lease(job_id, worker_id):
                raise ExportFailure("lease_lost", "The export was taken over by another worker.")

        result = await build_export_zip(portal_user_id, site_id, ctx, on_asset_done=keep_lease)
        if not await complete_job(
            job_id, worker_id, result.file_name, result.content, result.asset_count, result.row_count, retention
        ):
            logger.warning("report export %s: completion not recorded (job no longer held)", job_id)
    except ExportFailure as exc:
        if exc.code != "lease_lost":
            await fail_job(job_id, worker_id, exc.code, exc.message)
        logger.info("report export %s failed: %s", job_id, exc.code)
    except ApiContractError as exc:
        await fail_job(job_id, worker_id, exc.code, exc.detail)
    except asyncio.CancelledError:
        # Shutdown: leave the job PROCESSING; its lease lapses and the next
        # worker claims it again (bounded by MAX_ATTEMPTS).
        raise
    except Exception:
        logger.exception("report export %s failed unexpectedly", job_id)
        await fail_job(
            job_id,
            worker_id,
            "export_failed",
            "The export could not be generated because of an unexpected error. Retry it; if it fails again, "
            "choose a shorter time range.",
        )


class ReportExportWorker:
    """Polls for queued jobs and runs them one at a time."""

    def __init__(self, *, poll_seconds: float, max_cells: int, retention: timedelta) -> None:
        self.poll_seconds = poll_seconds
        self.max_cells = max_cells
        self.retention = retention
        self.worker_id = f"{socket.gethostname()}:{os.getpid()}:{uuid4().hex[:8]}"
        self._task: asyncio.Task | None = None
        self._last_purge: float | None = None   # None: purge on the first iteration

    def start(self) -> None:
        if self._task is None:
            self._task = asyncio.create_task(self._loop(), name="report-export-worker")

    async def stop(self) -> None:
        if self._task is None:
            return
        self._task.cancel()
        try:
            await self._task
        except asyncio.CancelledError:
            pass
        self._task = None

    async def run_once(self) -> bool:
        """Purge when due, then claim and run one job. True when a job ran."""

        loop = asyncio.get_running_loop()
        if self._last_purge is None or loop.time() - self._last_purge >= PURGE_EVERY_SECONDS:
            self._last_purge = loop.time()
            await purge_expired()
        job = await claim_job(self.worker_id)
        if job is None:
            return False
        await run_job(job, self.worker_id, max_cells=self.max_cells, retention=self.retention)
        return True

    async def _loop(self) -> None:
        while True:
            try:
                ran = await self.run_once()
            except asyncio.CancelledError:
                raise
            except Exception:
                logger.exception("report export worker iteration failed")
                ran = False
            if not ran:
                await asyncio.sleep(self.poll_seconds)
