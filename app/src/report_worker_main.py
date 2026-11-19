"""Entry point of the `report-worker` compose service (Reports -> Create report, ADR-025).

    python -m src.report_worker_main

Runs only where Reports is enabled (EMS_REPORTS_ENABLED, staging-only, A106);
otherwise it logs and idles so a mistakenly started container does nothing.
Database credentials come from the existing environment mechanism
(app/.env: the ems_app role on staging, A91).
"""

from __future__ import annotations

import asyncio
import logging
import os
import signal

from src.config import get_settings
from src.database import close_database_pool, open_database_pool
from src.site_report_worker import SiteReportWorker


async def main() -> None:
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s %(message)s")
    log = logging.getLogger("report_worker_main")
    settings = get_settings()
    heartbeat = os.environ.get("EMS_REPORT_WORKER_HEARTBEAT_FILE")
    stop = asyncio.Event()
    loop = asyncio.get_running_loop()
    for sig in (signal.SIGTERM, signal.SIGINT):
        try:
            loop.add_signal_handler(sig, stop.set)
        except NotImplementedError:   # pragma: no cover (Windows)
            pass
    worker = SiteReportWorker(heartbeat_file=heartbeat)
    if not settings.reports_enabled:
        log.warning("EMS_REPORTS_ENABLED is off: the report worker stays idle.")
        while not stop.is_set():
            worker.beat()
            try:
                await asyncio.wait_for(stop.wait(), timeout=60)
            except asyncio.TimeoutError:
                pass
        return
    await open_database_pool()
    task = asyncio.create_task(worker.run_forever(), name="site-report-worker")
    try:
        await stop.wait()
    finally:
        task.cancel()
        try:
            await task
        except asyncio.CancelledError:
            pass
        await close_database_pool()
        log.info("report worker stopped")


if __name__ == "__main__":
    asyncio.run(main())
