"""WhatsApp delivery -- provider client, sender worker, settings and the
signature-verified receipt webhook (ADR-026 A4-A6). No network, no database:
httpx.MockTransport stands in for Meta, an in-memory fake for migration 333's
functions (tested for real in test_alert_whatsapp_delivery_db.py).
Fictional numbers only; nothing is sent.
"""

from __future__ import annotations

import asyncio
import hashlib
import hmac
import json
import logging
from datetime import datetime, timedelta, timezone
from uuid import uuid4

import httpx
import pytest
from fastapi.testclient import TestClient

from src.whatsapp_config import WhatsAppSettings
from src.whatsapp_provider import (
    MetaWhatsAppClient,
    SendResult,
    build_payload,
    classify_response,
    clean_param,
    template_parameters,
)
from src.whatsapp_sender import WhatsAppSender, retry_delay

A, B = "+12025550101", "+12025550102"  # fictional
TOKEN = "test-token-not-real"
SECRET = "test-app-secret-not-real"
VERIFY = "test-verify-token-not-real"

MESSAGE = {
    "business_name": "Fictional A Hotels Pvt Ltd", "site_name": "Alpha", "site_timezone": "Asia/Kolkata",
    "rule_name": "Chiller overload", "asset_name": "Chiller 1", "parameter_name": "Active Power",
    "qualifier": "TOTAL", "unit_symbol": "kW", "comparator": "GT", "threshold": 50, "tolerance": None,
    "trigger_value": 61.5, "triggered_at": "2026-11-18T06:00:00+00:00",
}


def settings(**kw) -> WhatsAppSettings:
    base = dict(EMS_WHATSAPP_SENDING_ENABLED=True, EMS_WHATSAPP_ACCESS_TOKEN=TOKEN, EMS_WHATSAPP_PHONE_NUMBER_ID="1234567890",
                EMS_WHATSAPP_TEMPLATE_NAME="ems_alert_v1", EMS_WHATSAPP_RECIPIENT_ALLOWLIST=f"{A}, {B}",
                EMS_WHATSAPP_APP_SECRET=SECRET, EMS_WHATSAPP_WEBHOOK_VERIFY_TOKEN=VERIFY)
    base.update(kw)
    return WhatsAppSettings(**base)


# --- message ----------------------------------------------------------------------------

def test_template_parameters_are_the_six_variables_in_order_in_site_time():
    assert template_parameters(MESSAGE) == [
        "Fictional A Hotels Pvt Ltd", "Chiller overload", "Chiller 1", "Active Power greater than 50 kW", "61.5 kW",
        "18 Nov 2026, 11:30 IST",
    ]


def test_equal_to_includes_the_tolerance_and_qualifiers_are_named():
    params = template_parameters(dict(MESSAGE, comparator="EQ", tolerance=0.5, parameter_name="Voltage", qualifier="L1",
                                      unit_symbol="V", threshold=230))
    assert params[3] == "Voltage (L1) equal to 230 V ± 0.5 V"


def test_parameters_never_contain_newlines_tabs_or_long_space_runs():
    assert clean_param("Line one\n\tline   two     end") == "Line one line two end"
    assert clean_param("") == "—" and clean_param(None) == "—"
    assert len(clean_param("x" * 500)) == 200


def test_payload_is_a_template_message_to_the_individual_number():
    payload = build_payload(settings(), A, MESSAGE)
    assert payload["to"] == "12025550101" and payload["recipient_type"] == "individual"
    assert payload["template"]["name"] == "ems_alert_v1" and payload["template"]["language"] == {"code": "en"}
    assert len(payload["template"]["components"][0]["parameters"]) == 6


# --- provider classification -----------------------------------------------------------

@pytest.mark.parametrize("status,body,expected", [
    (200, {"messages": [{"id": "wamid.ABC123"}]}, SendResult("submitted", message_id="wamid.ABC123")),
    (200, {"messages": []}, SendResult("failed", error_code="NO_MESSAGE_ID")),
    (429, {"error": {"code": 130429}}, SendResult("retry", error_code="META_130429")),
    (400, {"error": {"code": 131048}}, SendResult("retry", error_code="META_131048")),
    (503, None, SendResult("retry", error_code="HTTP_503")),
    (401, {"error": {"code": 190}}, SendResult("retry", error_code="META_190")),
    (400, {"error": {"code": 131026}}, SendResult("failed", error_code="META_131026")),
    (400, {"error": {"code": 132001}}, SendResult("failed", error_code="META_132001")),
    (404, None, SendResult("failed", error_code="HTTP_404")),
])
def test_classify_response(status, body, expected):
    assert classify_response(status, body) == expected


def _client(handler, **overrides) -> tuple[MetaWhatsAppClient, list[httpx.Request]]:
    seen: list[httpx.Request] = []

    async def wrapped(request: httpx.Request) -> httpx.Response:
        seen.append(request)
        response = handler(request)
        return await response if asyncio.iscoroutine(response) else response

    s = settings(**overrides)
    return MetaWhatsAppClient(s, httpx.AsyncClient(transport=httpx.MockTransport(wrapped))), seen


def test_client_posts_to_the_phone_number_endpoint_with_the_bearer_token():
    client, seen = _client(lambda r: httpx.Response(200, json={"messages": [{"id": "wamid.OK"}]}))
    assert asyncio.run(client.send_alert(A, MESSAGE)) == SendResult("submitted", message_id="wamid.OK")
    request = seen[0]
    assert str(request.url) == "https://graph.facebook.com/v26.0/1234567890/messages"
    assert request.headers["authorization"] == f"Bearer {TOKEN}"
    assert json.loads(request.content)["to"] == "12025550101"


def test_a_connection_that_never_opened_is_retried():
    def refuse(request):
        raise httpx.ConnectError("refused", request=request)
    client, _ = _client(refuse)
    assert asyncio.run(client.send_alert(A, MESSAGE)) == SendResult("retry", error_code="CONNECT_ERROR")


def test_a_read_timeout_is_not_retried_to_avoid_a_duplicate():
    def slow(request):
        raise httpx.ReadTimeout("slow", request=request)
    client, _ = _client(slow)
    assert asyncio.run(client.send_alert(A, MESSAGE)) == SendResult("failed", error_code="TIMEOUT_UNCONFIRMED")


def test_the_whole_request_has_one_deadline_and_is_then_not_retried():
    async def hang(request):
        await asyncio.sleep(30)
        return httpx.Response(200, json={"messages": [{"id": "wamid.TOO_LATE"}]})
    client, _ = _client(hang, EMS_WHATSAPP_REQUEST_TIMEOUT_SECONDS=1)
    assert asyncio.run(client.send_alert(A, MESSAGE)) == SendResult("failed", error_code="TIMEOUT_UNCONFIRMED")


# --- settings ---------------------------------------------------------------------------

def test_provider_problems_name_settings_never_values():
    problems = WhatsAppSettings(EMS_WHATSAPP_ACCESS_TOKEN=TOKEN).provider_problems()
    assert "EMS_WHATSAPP_SENDING_ENABLED is off" in problems
    assert any("PHONE_NUMBER_ID" in p for p in problems) and any("TEMPLATE_NAME" in p for p in problems)
    assert any("ALLOWLIST is empty" in p for p in problems)
    assert not any(TOKEN in p for p in problems)
    assert settings().provider_problems() == []


def test_the_allowlist_admits_only_listed_numbers_and_empty_admits_nobody():
    s = settings()
    assert s.allows(A) and s.allows(B) and not s.allows("+12025550199")
    assert not settings(EMS_WHATSAPP_RECIPIENT_ALLOWLIST="").allows(A)
    assert settings(EMS_WHATSAPP_RECIPIENT_ALLOWLIST="not-a-number").allowlist == frozenset()
    assert settings(EMS_WHATSAPP_RECIPIENT_ALLOWLIST="", EMS_WHATSAPP_ALLOWLIST_DISABLED=True).allows(A)


def test_the_lease_must_cover_the_request_and_bounds_the_batch():
    assert settings().lease_seconds == 300 and settings().effective_batch_size == 10      # 300 // (15 + 10)
    assert settings(EMS_WHATSAPP_LEASE_SECONDS=60).effective_batch_size == 2
    assert settings(EMS_WHATSAPP_LEASE_SECONDS=30, EMS_WHATSAPP_REQUEST_TIMEOUT_SECONDS=30).effective_batch_size == 1
    problems = settings(EMS_WHATSAPP_LEASE_SECONDS=30, EMS_WHATSAPP_REQUEST_TIMEOUT_SECONDS=30).provider_problems()
    assert any("LEASE_SECONDS must exceed" in p for p in problems)


def test_the_token_is_never_shown_in_settings_repr():
    assert TOKEN not in repr(settings()) and SECRET not in repr(settings())


# --- sender worker ----------------------------------------------------------------------

class FakeService:
    def __init__(self, claimed, refuse_begin=()):
        self.claimed = list(claimed)
        self.results = []
        self.begun = []
        self.limits = []
        self.refuse_begin = set(refuse_begin)

    async def claim(self, worker_id, limit, lease):
        self.limits.append((limit, lease))
        batch, self.claimed = self.claimed[:limit], self.claimed[limit:]
        return batch

    async def begin_send(self, delivery_id, worker_id, min_remaining):
        self.begun.append((delivery_id, min_remaining))
        return delivery_id not in self.refuse_begin

    async def record_result(self, delivery_id, worker_id, outcome, **kw):
        self.results.append((delivery_id, outcome, kw))
        return {"SUBMITTED": "SUBMITTED", "RETRY": "PENDING", "FAILED": "FAILED"}[outcome]

    async def purge(self):
        return {"deliveries": 0, "status_events": 0, "enqueue_errors": 0}

    async def overview(self):
        return {"pending": len(self.claimed)}


class FakeProvider:
    def __init__(self, outcomes):
        self.outcomes = dict(outcomes)
        self.sent = []

    async def send_alert(self, phone, message):
        self.sent.append(phone)
        return self.outcomes[phone]


def delivery(phone, attempts=1):
    return {"delivery_id": uuid4(), "phone_e164": phone, "message": MESSAGE, "attempts": attempts,
            "created_at": datetime.now(timezone.utc)}


def test_each_recipient_gets_its_own_request_and_one_failure_does_not_stop_another():
    d1, d2 = delivery(A), delivery(B)
    service = FakeService([d1, d2])
    provider = FakeProvider({A: SendResult("failed", error_code="META_131026"), B: SendResult("submitted", message_id="wamid.B")})
    asyncio.run(WhatsAppSender(settings(), provider, service=service, worker_id="w").run_once())
    assert provider.sent == [A, B]
    assert [(r[0], r[1]) for r in service.results] == [(d1["delivery_id"], "FAILED"), (d2["delivery_id"], "SUBMITTED")]
    assert service.results[1][2] == {"message_id": "wamid.B"}


def test_transient_failures_are_retried_with_backoff():
    d1 = delivery(A, attempts=3)
    service = FakeService([d1])
    provider = FakeProvider({A: SendResult("retry", error_code="META_130429")})
    before = datetime.now(timezone.utc)
    asyncio.run(WhatsAppSender(settings(), provider, service=service, worker_id="w").run_once())
    _, outcome, kw = service.results[0]
    assert outcome == "RETRY" and kw["error_code"] == "META_130429"
    assert before + timedelta(seconds=119) <= kw["retry_at"] <= datetime.now(timezone.utc) + timedelta(seconds=121)
    assert [retry_delay(n).total_seconds() for n in (1, 2, 3, 6, 20)] == [30, 60, 120, 900, 900]


def test_a_number_off_the_allowlist_is_never_sent_to():
    stranger = "+12025550199"
    service = FakeService([delivery(stranger)])
    provider = FakeProvider({})
    asyncio.run(WhatsAppSender(settings(), provider, service=service, worker_id="w").run_once())
    assert provider.sent == []
    assert service.results[0][1:] == ("FAILED", {"error_code": "NOT_ALLOWLISTED"})


def test_a_send_starts_only_after_the_in_flight_mark_succeeds():
    d1, d2 = delivery(A), delivery(B)
    service = FakeService([d1, d2], refuse_begin={d1["delivery_id"]})
    provider = FakeProvider({B: SendResult("submitted", message_id="wamid.B")})
    asyncio.run(WhatsAppSender(settings(), provider, service=service, worker_id="w").run_once())
    assert provider.sent == [B]                                     # d1: lease short/lost or switch off
    assert [r[0] for r in service.results] == [d2["delivery_id"]]   # nothing recorded for d1
    assert {m for _, m in service.begun} == {timedelta(seconds=25)}  # request timeout 15 s + 10 s margin
    assert service.limits == [(10, timedelta(seconds=300))]


def test_a_full_batch_asks_for_another_cycle():
    service = FakeService([delivery(A) for _ in range(3)])
    sender = WhatsAppSender(settings(EMS_WHATSAPP_BATCH_SIZE=2), FakeProvider({A: SendResult("submitted", message_id="wamid.X")}),
                            service=service, worker_id="w")
    assert asyncio.run(sender.run_once()) is True
    assert asyncio.run(sender.run_once()) is False


def test_logs_never_contain_a_number_or_the_token(caplog):
    caplog.set_level(logging.DEBUG)
    service = FakeService([delivery(A), delivery("+12025550199")])
    provider = FakeProvider({A: SendResult("submitted", message_id="wamid.L")})
    asyncio.run(WhatsAppSender(settings(), provider, service=service, worker_id="w").run_once())
    text = caplog.text
    assert "2025550101" not in text and "2025550199" not in text and TOKEN not in text
    assert "SUBMITTED" in text and "allowlist" in text


def test_the_heartbeat_is_refreshed(tmp_path):
    beat = tmp_path / "hb"
    asyncio.run(WhatsAppSender(settings(), FakeProvider({}), service=FakeService([]), heartbeat_file=str(beat),
                               worker_id="w").run_once())
    assert beat.exists()


# --- receipt webhook (customer API) -----------------------------------------------------

@pytest.fixture
def webhook(monkeypatch):
    import src.config as config
    import src.customer_main as customer_main
    import src.routers.whatsapp_webhook as wh

    config.use_core_settings(customer_main.settings)
    current = {"settings": settings()}
    monkeypatch.setattr(wh, "_settings", lambda: current["settings"])
    recorded = []

    async def record_status(message_id, status, at, code):
        recorded.append((message_id, status, at, code))
        return "applied"

    monkeypatch.setattr(wh.whatsapp_delivery_service, "record_status", record_status)
    try:
        yield TestClient(customer_main.app, follow_redirects=False), recorded, current
    finally:
        config._core_settings = None


def _signed(body: bytes, secret: str = SECRET) -> dict:
    return {"X-Hub-Signature-256": "sha256=" + hmac.new(secret.encode(), body, hashlib.sha256).hexdigest(),
            "Content-Type": "application/json"}


PAYLOAD = {
    "object": "whatsapp_business_account",
    "entry": [{"id": "1", "changes": [{"field": "messages", "value": {
        "messaging_product": "whatsapp",
        "statuses": [
            {"id": "wamid.D1", "status": "delivered", "timestamp": "1763445600", "recipient_id": "12025550101"},
            {"id": "wamid.F1", "status": "failed", "timestamp": "1763445601", "recipient_id": "12025550102",
             "errors": [{"code": 131026, "title": "Message undeliverable"}]},
            {"id": "wamid.X", "status": "deleted", "timestamp": "1763445602"},
        ],
        "messages": [{"from": "12025550101", "id": "wamid.IN", "type": "text", "text": {"body": "STOP"}}],
    }}]}],
}


def test_subscription_check_echoes_the_challenge_only_with_the_verify_token(webhook):
    client, _, _ = webhook
    ok = client.get("/api/v1/webhooks/whatsapp", params={"hub.mode": "subscribe", "hub.verify_token": VERIFY,
                                                          "hub.challenge": "12345"})
    assert ok.status_code == 200 and ok.text == "12345"
    bad = client.get("/api/v1/webhooks/whatsapp", params={"hub.mode": "subscribe", "hub.verify_token": "wrong",
                                                           "hub.challenge": "12345"})
    assert bad.status_code == 403 and "12345" not in bad.text


def test_signed_statuses_are_recorded_without_session_or_origin(webhook, caplog):
    client, recorded, _ = webhook
    caplog.set_level(logging.DEBUG)
    body = json.dumps(PAYLOAD).encode()
    response = client.post("/api/v1/webhooks/whatsapp", content=body, headers=_signed(body))
    assert response.status_code == 200 and response.json()["applied"] == 2
    assert [(r[0], r[1], r[3]) for r in recorded] == [("wamid.D1", "delivered", None), ("wamid.F1", "failed", "META_131026")]
    assert recorded[0][2] == datetime.fromtimestamp(1763445600, tz=timezone.utc)
    # Inbound message text and recipient numbers are never logged.
    assert "STOP" not in caplog.text and "2025550101" not in caplog.text


@pytest.mark.parametrize("headers", [{}, {"X-Hub-Signature-256": "sha256=00"}, {"X-Hub-Signature-256": "md5=abc"}])
def test_unsigned_or_wrongly_signed_callbacks_are_refused(webhook, headers):
    client, recorded, _ = webhook
    body = json.dumps(PAYLOAD).encode()
    response = client.post("/api/v1/webhooks/whatsapp", content=body, headers={"Content-Type": "application/json", **headers})
    assert response.status_code == 401 and recorded == []


def test_a_signature_from_another_secret_or_a_tampered_body_is_refused(webhook):
    client, recorded, _ = webhook
    body = json.dumps(PAYLOAD).encode()
    assert client.post("/api/v1/webhooks/whatsapp", content=body, headers=_signed(body, "other-secret")).status_code == 401
    tampered = body.replace(b"delivered", b"read")
    assert client.post("/api/v1/webhooks/whatsapp", content=tampered, headers=_signed(body)).status_code == 401
    assert recorded == []


def test_an_unconfigured_webhook_does_not_exist(webhook):
    client, _, current = webhook
    current["settings"] = settings(EMS_WHATSAPP_APP_SECRET=None)
    body = json.dumps(PAYLOAD).encode()
    assert client.post("/api/v1/webhooks/whatsapp", content=body, headers=_signed(body)).status_code == 404
    assert client.get("/api/v1/webhooks/whatsapp").status_code == 404


def test_oversized_and_non_json_bodies_are_refused(webhook):
    client, recorded, _ = webhook
    big = b"{" + b" " * 1_000_001 + b"}"
    assert client.post("/api/v1/webhooks/whatsapp", content=big, headers=_signed(big)).status_code == 413
    junk = b"not json"
    assert client.post("/api/v1/webhooks/whatsapp", content=junk, headers=_signed(junk)).status_code == 400
    assert recorded == []


def test_the_exemption_covers_only_the_webhook_path(webhook):
    """Other customer API writes still need same-origin and a session."""
    client, _, _ = webhook
    assert client.post("/api/v1/alerts/00000000-0000-4000-8000-000000000000/acknowledge").status_code == 403
    assert client.get("/api/v1/alert-rules/00000000-0000-4000-8000-000000000000/whatsapp/deliveries").status_code == 401
