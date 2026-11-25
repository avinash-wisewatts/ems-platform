"""WhatsApp sender worker (ADR-026 A4; report-worker pattern).

Each cycle: refresh the heartbeat; hourly purge (90-day history) and a
periodic overview log line; claim up to batch_size due deliveries (the
database re-checks eligibility and leases them); send each one with its own
provider request -- one recipient's failure never affects another -- and
record the outcome. Transient failures are retried with exponential backoff
inside the 60-minute window (D7); the database turns anything later into
FAILED / EXPIRED.

At most once: immediately before the provider request the delivery is
marked in flight (analytics.begin_whatsapp_send), which succeeds only while
this worker's lease has the whole request time left. If the worker stalls
past its lease after that point, no other worker re-sends it: the next claim
records FAILED / SEND_UNCONFIRMED (and a late acceptance from the stalled
worker is still recorded). Ambiguous request failures (timeouts after the
request was sent) are likewise never retried.

Safety: a number not on EMS_WHATSAPP_RECIPIENT_ALLOWLIST is never sent to
(recorded FAILED / NOT_ALLOWLISTED). Logs carry delivery ids, outcomes and
error codes only -- never a phone number, message text or token.
"""

from __future__ import annotations

import asyncio
import logging
import os
import socket
import time
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any, Protocol
from uuid import UUID

from src import whatsapp_delivery_service as default_service
from src.whatsapp_config import WhatsAppSettings
from src.whatsapp_provider import SendResult

logger = logging.getLogger(__name__)

BASE_BACKOFF_SECONDS = 30
MAX_BACKOFF_SECONDS = 15 * 60
PURGE_EVERY_SECONDS = 3600
OVERVIEW_EVERY_SECONDS = 300


def retry_delay(attempts: int) -> timedelta:
    """30 s, 60 s, 120 s, ... capped at 15 minutes (attempts counts this one)."""
    return timedelta(seconds=min(BASE_BACKOFF_SECONDS * 2 ** max(attempts - 1, 0), MAX_BACKOFF_SECONDS))


class Provider(Protocol):
    async def send_alert(self, phone_e164: str, message: dict[str, Any]) -> SendResult: ...


class WhatsAppSender:
    def __init__(self, settings: WhatsAppSettings, provider: Provider, *, service: Any = default_service,
                 heartbeat_file: str | None = None, worker_id: str | None = None) -> None:
        self.settings = settings
        self.provider = provider
        self.service = service
        self.heartbeat = Path(heartbeat_file) if heartbeat_file else None
        self.worker_id = worker_id or f"whatsapp-sender:{socket.gethostname()}:{os.getpid()}"
        self._last_purge = 0.0
        self._last_overview = 0.0

    def beat(self) -> None:
        if self.heartbeat is not None:
            try:
                self.heartbeat.touch()
            except OSError:
                logger.warning("heartbeat file could not be written")

    async def run_forever(self) -> None:
        while True:
            try:
                busy = await self.run_once()
            except asyncio.CancelledError:
                raise
            except Exception:   # keep the worker alive; the lease lapses and the delivery is retried
                logger.exception("WhatsApp sender cycle failed")
                busy = False
            if not busy:
                await asyncio.sleep(self.settings.poll_seconds)

    async def housekeeping(self) -> None:
        now = time.monotonic()
        if now - self._last_purge >= PURGE_EVERY_SECONDS:
            self._last_purge = now
            purged = await self.service.purge()
            if any(purged.values()):
                logger.info("purged WhatsApp records: %s", purged)
        if now - self._last_overview >= OVERVIEW_EVERY_SECONDS:
            self._last_overview = now
            logger.info("WhatsApp delivery overview: %s", await self.service.overview())

    async def run_once(self) -> bool:
        """One cycle. True when a full batch was claimed (more may be due)."""
        self.beat()
        await self.housekeeping()
        limit = self.settings.effective_batch_size
        claimed = await self.service.claim(self.worker_id, limit, timedelta(seconds=self.settings.lease_seconds))
        for delivery in claimed:
            self.beat()
            await self.deliver(delivery)
        return len(claimed) >= limit

    async def deliver(self, delivery: dict[str, Any]) -> str | None:
        delivery_id: UUID = delivery["delivery_id"]
        if not self.settings.allows(delivery["phone_e164"]):
            status = await self.service.record_result(delivery_id, self.worker_id, "FAILED", error_code="NOT_ALLOWLISTED")
            logger.warning("delivery %s refused: number not on the recipient allowlist", delivery_id)
            return status
        if not await self.service.begin_send(delivery_id, self.worker_id,
                                             timedelta(seconds=self.settings.send_margin_seconds)):
            logger.warning("delivery %s not sent: lease too short or lost, or sending switched off", delivery_id)
            return None
        result = await self.provider.send_alert(delivery["phone_e164"], delivery["message"])
        if result.outcome == "submitted":
            status = await self.service.record_result(delivery_id, self.worker_id, "SUBMITTED",
                                                      message_id=result.message_id)
        elif result.outcome == "retry":
            retry_at = datetime.now(timezone.utc) + retry_delay(int(delivery["attempts"]))
            status = await self.service.record_result(delivery_id, self.worker_id, "RETRY",
                                                      error_code=result.error_code, retry_at=retry_at)
        else:
            status = await self.service.record_result(delivery_id, self.worker_id, "FAILED",
                                                      error_code=result.error_code)
        if status is None:
            logger.warning("delivery %s: lease lost before the outcome was recorded (%s)", delivery_id, result.outcome)
        else:
            logger.info("delivery %s: %s -> %s%s", delivery_id, result.outcome, status,
                        f" ({result.error_code})" if result.error_code else "")
        return status
