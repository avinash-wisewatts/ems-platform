"""WhatsApp delivery receipts (ADR-026 A5) -- public, signature-verified.

    GET  /api/v1/webhooks/whatsapp   Meta subscription check (hub.verify_token)
    POST /api/v1/webhooks/whatsapp   status callbacks, X-Hub-Signature-256

Served by the customer API on the customer host (the only host the provider
can reach). No session: the HMAC-SHA256 signature over the raw body with the
Meta app secret is the only authentication, compared in constant time; the
customer middleware exempts exactly this path from the same-origin rule.

Only message STATUSES are processed (sent / delivered / read / failed),
mapped by provider message id. Inbound messages (including any STOP reply)
are acknowledged and ignored: their text is never stored or logged
(opt-out handling is a later, separately approved step). Recipient numbers
in the payload are never logged. Without EMS_WHATSAPP_APP_SECRET and
EMS_WHATSAPP_WEBHOOK_VERIFY_TOKEN the endpoint answers 404.
"""

from __future__ import annotations

import hashlib
import hmac
import json
import logging
from datetime import datetime, timezone
from typing import Any

from fastapi import APIRouter, Request
from fastapi.responses import JSONResponse, PlainTextResponse, Response

from src import whatsapp_delivery_service
from src.whatsapp_config import WhatsAppSettings, get_whatsapp_settings

logger = logging.getLogger(__name__)

WEBHOOK_PATH = "/api/v1/webhooks/whatsapp"
MAX_BODY_BYTES = 1_000_000
STATUSES = frozenset({"sent", "delivered", "read", "failed"})

router = APIRouter(include_in_schema=False)


def _settings() -> WhatsAppSettings:
    return get_whatsapp_settings()


def signature_valid(app_secret: str, body: bytes, header: str | None) -> bool:
    if not header or not header.startswith("sha256="):
        return False
    expected = hmac.new(app_secret.encode("utf-8"), body, hashlib.sha256).hexdigest()
    return hmac.compare_digest(expected, header[len("sha256="):].strip().lower())


def extract_statuses(payload: Any) -> list[dict[str, Any]]:
    """[{id, status, at, error_code}] from a Cloud API webhook payload; anything
    malformed is skipped."""
    found: list[dict[str, Any]] = []
    if not isinstance(payload, dict):
        return found
    for entry in payload.get("entry") or []:
        if not isinstance(entry, dict):
            continue
        for change in entry.get("changes") or []:
            if not isinstance(change, dict) or change.get("field") != "messages":
                continue
            value = change.get("value") if isinstance(change.get("value"), dict) else {}
            for item in value.get("statuses") or []:
                if not isinstance(item, dict):
                    continue
                message_id, status = item.get("id"), item.get("status")
                if not isinstance(message_id, str) or status not in STATUSES:
                    continue
                try:
                    at = datetime.fromtimestamp(int(item.get("timestamp")), tz=timezone.utc)
                except (TypeError, ValueError, OverflowError, OSError):
                    at = datetime.now(timezone.utc)
                error_code = None
                errors = item.get("errors")
                if isinstance(errors, list) and errors and isinstance(errors[0], dict) and isinstance(errors[0].get("code"), int):
                    error_code = f"META_{errors[0]['code']}"
                found.append({"id": message_id, "status": status, "at": at, "error_code": error_code})
    return found


@router.get(WEBHOOK_PATH)
async def verify_subscription(request: Request) -> Response:
    settings = _settings()
    if not settings.webhook_configured:
        return JSONResponse({"error": "not_found", "detail": "Not found."}, status_code=404)
    params = request.query_params
    token = settings.webhook_verify_token.get_secret_value()  # type: ignore[union-attr]
    if params.get("hub.mode") == "subscribe" and hmac.compare_digest(params.get("hub.verify_token") or "", token):
        return PlainTextResponse(params.get("hub.challenge") or "")
    return JSONResponse({"error": "forbidden", "detail": "Verification failed."}, status_code=403)


@router.post(WEBHOOK_PATH)
async def receive(request: Request) -> Response:
    settings = _settings()
    if not settings.webhook_configured:
        return JSONResponse({"error": "not_found", "detail": "Not found."}, status_code=404)
    declared = request.headers.get("content-length")
    if declared and declared.isdigit() and int(declared) > MAX_BODY_BYTES:
        return JSONResponse({"error": "payload_too_large", "detail": "Body too large."}, status_code=413)
    body = await request.body()
    if len(body) > MAX_BODY_BYTES:
        return JSONResponse({"error": "payload_too_large", "detail": "Body too large."}, status_code=413)
    secret = settings.app_secret.get_secret_value()  # type: ignore[union-attr]
    if not signature_valid(secret, body, request.headers.get("x-hub-signature-256")):
        logger.warning("WhatsApp webhook: signature check failed")
        return JSONResponse({"error": "unauthorized", "detail": "Invalid signature."}, status_code=401)
    try:
        payload = json.loads(body)
    except ValueError:
        return JSONResponse({"error": "invalid_request", "detail": "Body is not JSON."}, status_code=400)

    counts = {"applied": 0, "buffered": 0, "ignored": 0}
    for status in extract_statuses(payload):
        # A database error propagates as 500 so the provider retries the callback.
        result = await whatsapp_delivery_service.record_status(status["id"], status["status"], status["at"],
                                                               status["error_code"])
        counts[result] = counts.get(result, 0) + 1
    if any(counts.values()):
        logger.info("WhatsApp webhook statuses: %s", counts)
    return JSONResponse({"ok": True, **counts})
