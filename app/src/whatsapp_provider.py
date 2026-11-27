"""Meta WhatsApp Business Cloud API client and the alert message (ADR-026 D1).

One template message per delivery (business-initiated messages outside the
24-hour window must use an approved template). The template is created and
approved in Meta Business Manager by WiseWatts Product (D8); its body takes
six text variables, in this order:

    {{1}} business name (the customer, R9)   {{4}} condition, e.g. "Active Power greater than 50 kW"
    {{2}} alert rule name                     {{5}} value that triggered it, e.g. "61 kW"
    {{3}} asset name                          {{6}} when, in the site's timezone

Outcome classification (one message per occurrence and recipient, D7):
- submitted: the provider accepted the message and returned its id.
- retry:     certainly not delivered and worth retrying (connection never
             made, HTTP 429, provider throttling, 5xx before acceptance,
             expired/invalid token which an operator can fix).
- failed:    permanent refusal (invalid number, template problem, ...), or
             a read timeout after the request was sent: the provider may have
             accepted it, so it is NOT retried, to avoid a duplicate.

Nothing here logs or returns a phone number or a token.
"""

from __future__ import annotations

import asyncio
import re
from dataclasses import dataclass
from datetime import datetime
from decimal import Decimal, InvalidOperation
from typing import Any, Literal
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

import httpx

from src.whatsapp_config import WhatsAppSettings

Outcome = Literal["submitted", "retry", "failed"]

# Meta error codes that are transient (throttling / temporary service issues).
RETRYABLE_ERROR_CODES = frozenset({4, 80007, 130429, 131000, 131016, 131048, 131056, 133004})
# Auth problems: every message would fail the same way until the token is fixed.
AUTH_ERROR_CODES = frozenset({190, 200, 10})

COMPARATOR_TEXT = {"GT": "greater than", "LT": "less than", "EQ": "equal to"}
_MAX_PARAM = 200


@dataclass(frozen=True)
class SendResult:
    outcome: Outcome
    message_id: str | None = None
    error_code: str | None = None


def _number(value: Any) -> str:
    try:
        d = Decimal(str(value))
    except (InvalidOperation, ValueError):
        return "—"
    text = format(d.normalize(), "f")
    return text.rstrip("0").rstrip(".") if "." in text else text


def _with_unit(value: Any, unit: str | None) -> str:
    text = _number(value)
    return f"{text} {unit}" if unit and text != "—" else text


def clean_param(value: Any) -> str:
    """Template variables may not contain newlines, tabs or 4+ spaces in a row."""
    text = re.sub(r"\s+", " ", str(value if value is not None else "")).strip()
    return (text or "—")[:_MAX_PARAM]


def format_when(triggered_at: str | datetime | None, timezone: str | None) -> str:
    if triggered_at is None:
        return "—"
    moment = triggered_at if isinstance(triggered_at, datetime) else datetime.fromisoformat(str(triggered_at))
    try:
        zone = ZoneInfo(timezone) if timezone else ZoneInfo("UTC")
    except ZoneInfoNotFoundError:
        zone = ZoneInfo("UTC")
    local = moment.astimezone(zone)
    return f"{local:%d %b %Y, %H:%M} {local.tzname() or zone.key}"


def template_parameters(message: dict[str, Any]) -> list[str]:
    """The six body variables, from the snapshot queued with the delivery."""
    parameter = message.get("parameter_name") or ""
    qualifier = message.get("qualifier")
    if qualifier and qualifier not in ("TOTAL", "AVG"):
        parameter = f"{parameter} ({qualifier})"
    unit = message.get("unit_symbol")
    condition = f"{parameter} {COMPARATOR_TEXT.get(message.get('comparator') or '', 'compared with')} " \
                f"{_with_unit(message.get('threshold'), unit)}"
    if message.get("comparator") == "EQ" and message.get("tolerance") is not None:
        condition += f" ± {_with_unit(message.get('tolerance'), unit)}"
    return [
        clean_param(message.get("business_name")),
        clean_param(message.get("rule_name")),
        clean_param(message.get("asset_name")),
        clean_param(condition),
        clean_param(_with_unit(message.get("trigger_value"), unit)),
        clean_param(format_when(message.get("triggered_at"), message.get("site_timezone"))),
    ]


def build_payload(settings: WhatsAppSettings, phone_e164: str, message: dict[str, Any]) -> dict[str, Any]:
    return {
        "messaging_product": "whatsapp",
        "recipient_type": "individual",
        "to": phone_e164.lstrip("+"),
        "type": "template",
        "template": {
            "name": settings.template_name,
            "language": {"code": settings.template_language},
            "components": [
                {
                    "type": "body",
                    "parameters": [{"type": "text", "text": p} for p in template_parameters(message)],
                }
            ],
        },
    }


def classify_response(status_code: int, body: Any) -> SendResult:
    error = body.get("error") if isinstance(body, dict) else None
    if 200 <= status_code < 300:
        messages = body.get("messages") if isinstance(body, dict) else None
        message_id = messages[0].get("id") if isinstance(messages, list) and messages and isinstance(messages[0], dict) else None
        if isinstance(message_id, str) and re.fullmatch(r"[A-Za-z0-9_.=:+/-]{1,128}", message_id):
            return SendResult("submitted", message_id=message_id)
        # Accepted without a usable id: it may be sent, so never retried.
        return SendResult("failed", error_code="NO_MESSAGE_ID")
    code = error.get("code") if isinstance(error, dict) else None
    error_code = f"META_{code}" if isinstance(code, int) else f"HTTP_{status_code}"
    if status_code == 429 or status_code >= 500 or code in RETRYABLE_ERROR_CODES or code in AUTH_ERROR_CODES \
            or status_code == 401:
        return SendResult("retry", error_code=error_code)
    return SendResult("failed", error_code=error_code)


class MetaWhatsAppClient:
    def __init__(self, settings: WhatsAppSettings, client: httpx.AsyncClient | None = None) -> None:
        self.settings = settings
        self._client = client or httpx.AsyncClient(timeout=settings.request_timeout_seconds)

    @property
    def url(self) -> str:
        base = self.settings.graph_api_base.rstrip("/")
        return f"{base}/{self.settings.graph_api_version}/{self.settings.phone_number_id}/messages"

    async def send_alert(self, phone_e164: str, message: dict[str, Any]) -> SendResult:
        token = self.settings.access_token.get_secret_value() if self.settings.access_token else ""
        try:
            # One overall deadline (httpx timeouts are per phase): the sender
            # relies on the request ending within the lease it checked.
            response = await asyncio.wait_for(
                self._client.post(
                    self.url,
                    json=build_payload(self.settings, phone_e164, message),
                    headers={"Authorization": f"Bearer {token}"},
                ),
                timeout=self.settings.request_timeout_seconds,
            )
        except (httpx.ConnectError, httpx.ConnectTimeout, httpx.PoolTimeout):
            return SendResult("retry", error_code="CONNECT_ERROR")
        except (httpx.TimeoutException, asyncio.TimeoutError):
            # The request was sent; the provider may have accepted it.
            return SendResult("failed", error_code="TIMEOUT_UNCONFIRMED")
        except httpx.HTTPError:
            return SendResult("failed", error_code="HTTP_ERROR_UNCONFIRMED")
        try:
            body = response.json()
        except ValueError:
            body = None
        return classify_response(response.status_code, body)

    async def aclose(self) -> None:
        await self._client.aclose()
