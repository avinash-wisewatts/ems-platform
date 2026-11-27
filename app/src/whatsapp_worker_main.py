"""Entry point of the `whatsapp-sender` compose service (ADR-026 A4).

    python -m src.whatsapp_worker_main

Idles (heartbeat only, no database or provider connection) unless every
provider setting is present and EMS_WHATSAPP_SENDING_ENABLED is on; the
database kill switch and per-recipient eligibility are enforced on top of
that by analytics.claim_whatsapp_deliveries. Database credentials come from
app/.env (ems_app); provider secrets from app/whatsapp.env.
"""

from __future__ import annotations

import asyncio
import logging
import os
import signal

from src.config import get_settings
from src.database import close_database_pool, open_database_pool
from src.whatsapp_config import get_whatsapp_settings
from src.whatsapp_provider import MetaWhatsAppClient
from src.whatsapp_sender import WhatsAppSender


async def main() -> None:
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s %(message)s")
    # httpx logs request URLs at INFO; keep it quiet (no ids or numbers in logs).
    logging.getLogger("httpx").setLevel(logging.WARNING)
    log = logging.getLogger("whatsapp_worker_main")
    get_settings()  # validates the database configuration
    settings = get_whatsapp_settings()
    heartbeat = os.environ.get("EMS_WHATSAPP_WORKER_HEARTBEAT_FILE")
    stop = asyncio.Event()
    loop = asyncio.get_running_loop()
    for sig in (signal.SIGTERM, signal.SIGINT):
        try:
            loop.add_signal_handler(sig, stop.set)
        except NotImplementedError:   # pragma: no cover (Windows)
            pass

    problems = settings.provider_problems()
    if problems:
        log.warning("WhatsApp sender idle: %s.", "; ".join(problems))
        idle = WhatsAppSender(settings, provider=None, heartbeat_file=heartbeat)  # type: ignore[arg-type]
        while not stop.is_set():
            idle.beat()
            try:
                await asyncio.wait_for(stop.wait(), timeout=60)
            except asyncio.TimeoutError:
                pass
        return

    await open_database_pool()
    client = MetaWhatsAppClient(settings)
    sender = WhatsAppSender(settings, client, heartbeat_file=heartbeat)
    log.info("WhatsApp sender started (%d allowlisted number(s)).", len(settings.allowlist))
    task = asyncio.create_task(sender.run_forever(), name="whatsapp-sender")
    try:
        await stop.wait()
    finally:
        task.cancel()
        try:
            await task
        except asyncio.CancelledError:
            pass
        await client.aclose()
        await close_database_pool()
        log.info("WhatsApp sender stopped")


if __name__ == "__main__":
    asyncio.run(main())
