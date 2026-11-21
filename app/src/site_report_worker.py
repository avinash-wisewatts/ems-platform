"""Reports -> Create report: the background worker (ADR-025).

One process (compose service `report-worker`), one job at a time (RK-1).
Each loop: refresh the heartbeat; every 5 minutes create due automatic
reports (no back-fill, A61, A70); every 10 minutes purge expired and
recycle-bin versions (A78, A85); claim and run one attempt.

An attempt:
  1. checks the read identity (automation account or requesting WiseWatts
     Admin) -- failing stops it, no automatic retry (A90);
  2. for an AUTOMATIC report before its 12-hour deadline, probes the final
     period minutes; while data is still arriving it waits (Pending, re-check
     every 30 minutes, A64-A67);
  3. checks the 1-minute retention floors (A71);
  4. loads the period from EMS (ems_loader), generates and validates the PDF
     in a worker thread (generate.generate_report);
  5. publishes atomically (version + file + latest pointer) or records why it
     failed: insufficient data and validation failures are final; temporary
     failures are retried automatically up to 3 times at 15 / 30 / 60 minutes
     (A68), by the database.
"""

from __future__ import annotations

import asyncio
import logging
import os
import socket
import time
from datetime import datetime, timedelta, timezone
from pathlib import Path
from uuid import UUID, uuid4
from zoneinfo import ZoneInfo

from src import site_report_service as svc

logger = logging.getLogger("site_report_worker")

LEASE = timedelta(minutes=10)
SCHEDULE_EVERY = 300.0
PURGE_EVERY = 600.0
POLL_SECONDS = 30.0


class SiteReportWorker:
    def __init__(self, *, poll_seconds: float = POLL_SECONDS, heartbeat_file: str | None = None) -> None:
        self.poll_seconds = poll_seconds
        self.heartbeat = Path(heartbeat_file) if heartbeat_file else None
        self.worker_id = f"{socket.gethostname()}:{os.getpid()}:{uuid4().hex[:8]}"
        self._last_schedule: float | None = None
        self._last_purge: float | None = None

    def beat(self) -> None:
        if self.heartbeat is not None:
            try:
                self.heartbeat.touch()
            except OSError:
                logger.warning("heartbeat file could not be written")

    async def run_forever(self) -> None:
        logger.info("site report worker %s started", self.worker_id)
        while True:
            try:
                ran = await self.run_once()
            except asyncio.CancelledError:
                raise
            except Exception:
                logger.exception("site report worker iteration failed")
                ran = False
            if not ran:
                await asyncio.sleep(self.poll_seconds)

    async def run_once(self, now: datetime | None = None) -> bool:
        self.beat()
        clock = time.monotonic()
        current = now or datetime.now(timezone.utc)
        if self._last_schedule is None or clock - self._last_schedule >= SCHEDULE_EVERY:
            self._last_schedule = clock
            created = await svc.schedule_due(current)
            if created:
                logger.info("scheduled %s automatic report(s)", created)
        if self._last_purge is None or clock - self._last_purge >= PURGE_EVERY:
            self._last_purge = clock
            result = await svc.purge(current)
            if any(result.values()):
                logger.info("purge: %s", result)
        job = await svc.claim(self.worker_id, LEASE)
        if job is None:
            return False
        await self.run_attempt(job)
        return True

    async def run_attempt(self, job: dict) -> None:
        attempt_id = UUID(str(job["attempt_id"]))
        started = time.monotonic()
        logger.info("attempt %s: %s %s %s (%s, retry %s)", attempt_id, job["site_name"], job["report_type"],
                    job["period_start_date"], job["trigger"], job["retry_no"])
        try:
            outcome = await self._generate(job, attempt_id)
            logger.info("attempt %s: %s in %.0f s", attempt_id, outcome, time.monotonic() - started)
        except asyncio.CancelledError:
            raise   # shutdown: the lease lapses and the attempt is retried
        except Exception:
            logger.exception("attempt %s failed unexpectedly", attempt_id)
            await svc.fail(attempt_id, self.worker_id, "generation_failed",
                           "Generation failed unexpectedly and will be retried automatically.", True)

    async def _generate(self, job: dict, attempt_id: UUID) -> str:
        from src.report_engine import ENGINE_VERSION
        from src.report_engine.ems_loader import RetentionExceededError, check_retention, final_hour_completeness, load_period
        from src.report_engine.periods import RECHECK_INTERVAL, period_for
        from src.report_engine.settings import baseline_note, roster_and_settings, settings_snapshot

        problem = await svc.read_identity_problem(attempt_id)
        if problem:
            code = "automation_not_authorized" if job["identity_kind"] == "AUTOMATION" else "requester_not_authorized"
            message = ("The WiseWatts automation account is deactivated, not set, or no longer restricted to this site "
                       f"({problem}). Automatic generation has stopped." if code == "automation_not_authorized"
                       else "The requesting user is no longer a Site Admin or WiseWatts Admin with access to this site.")
            await svc.fail(attempt_id, self.worker_id, code, message, False)
            return code

        zone = ZoneInfo(job["site_timezone"])
        period = period_for(job["report_type"], job["period_start_date"])
        site_id = UUID(str(job["site_id"]))
        identity = int(job["read_identity_portal_user_id"])
        rows = await svc.worker_settings(site_id)
        layout, settings = roster_and_settings(rows, zone)
        if not layout.entries:
            await svc.fail(attempt_id, self.worker_id, "roster_empty",
                           "The site's reporting asset list is empty. A WiseWatts Admin must configure it.", False)
            return "roster_empty"

        now = datetime.now(timezone.utc)
        end_instant = period.end_instant(zone)
        if job["identity_kind"] == "AUTOMATION" and now < period.deadline(zone):
            complete, total = await final_hour_completeness(identity, site_id, layout.entries, end_instant)
            if complete < total:
                not_before = min(now + RECHECK_INTERVAL, period.deadline(zone))
                await svc.defer(attempt_id, self.worker_id, not_before,
                                f"Waiting for EMS data ({complete} of {total} meters complete); "
                                f"next check {not_before.astimezone(zone):%d-%b-%Y %H:%M}.")
                return "waiting"

        load_from, load_to = period.load_range_utc(zone)
        try:
            from src.analytics_trends_service import fetch_analytics_as_of

            await check_retention(site_id, load_from, await fetch_analytics_as_of())
        except RetentionExceededError as exc:
            await svc.fail(attempt_id, self.worker_id, "retention_exceeded", str(exc), False)
            return "retention_exceeded"

        async def keep_lease() -> None:
            self.beat()
            if not await svc.extend_lease(attempt_id, self.worker_id, LEASE):
                raise LeaseLostError()

        try:
            loaded = await load_period(identity, site_id, zone, layout.entries, load_from, load_to, on_asset_done=keep_lease)
        except LeaseLostError:
            logger.warning("attempt %s: lease lost during load", attempt_id)
            return "lease_lost"
        await keep_lease()

        from src.report_engine.generate import InsufficientDataError, generate_report
        from src.report_engine.validate_pdf import PdfValidationError

        local_start = period.local_bounds(zone)[0]
        snapshot = settings_snapshot(rows, local_start, period.end_instant(zone),
                                     period.load_range_utc(zone)[0].astimezone(zone),
                                     await svc.worker_baselines(site_id))
        try:
            result = await asyncio.to_thread(generate_report, job["site_name"], period, loaded.assets, layout, settings,
                                             baseline_note(snapshot))
        except InsufficientDataError as exc:
            await svc.fail(attempt_id, self.worker_id, "insufficient_data", str(exc), False)
            return "insufficient_data"
        except PdfValidationError as exc:
            await svc.fail(attempt_id, self.worker_id, f"pdf_validation_failed:{exc.check}",
                           f"The report failed its quality check and was not published ({exc.check}).", False)
            return "pdf_validation_failed"

        version = await svc.complete(
            attempt_id, self.worker_id, file_name=result.file_name, content=result.pdf, sha256=result.check.sha256,
            page_count=result.check.pages, incomplete_data=result.quality.incomplete_data,
            comparison_incomplete=result.quality.comparison_incomplete, coverage=result.quality.coverage,
            settings_snapshot=snapshot, engine_version=ENGINE_VERSION,
        )
        return f"published version {version}" if version else "not published (lease lost or report deleted)"


class LeaseLostError(Exception):
    """Another worker took the attempt over (its lease lapsed)."""
