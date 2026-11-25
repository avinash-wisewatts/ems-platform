"""WhatsApp Phase 1 -- GET / PUT /api/v1/alert-rules/{rule_id}/whatsapp
(src.routers.alerts_api, src.alert_whatsapp_service; phase-1-plan §7.3).

The database is faked at src.alert_whatsapp_service._execute, so the real
request validation, phone parsing (phonenumbers) and result mapping run. The
SECURITY DEFINER functions themselves are tested in
test_alert_whatsapp_config_db.py.

Covers: authentication; alert.configure at the middleware (PUT) and at the
route (GET and PUT); same-origin / JSON guards; 200/403/404/409/415/422
mapping; messages_active always false; masking; and that no submitted or
stored phone number ever appears in an error body or a log line.
Every number is fictional: +1 202-555-01xx (NANP fiction range) and
+61 491 570 006-159 (ACMA fiction range).
"""

from __future__ import annotations

import logging
from datetime import datetime, timezone
from uuid import UUID

import psycopg
import pytest

from src.alert_rules_service import AlertRuleCreate, rule_args
from src.alert_whatsapp_service import (
    WhatsAppConfigError,
    WhatsAppConfigIn,
    mask_phone,
    normalize_phone,
    prepare_recipients,
)
from src.auth.authorization import PortalPermission, required_permission_for_request
from tests.test_alerts_api_routes import JSON, RULE_BODY, RULE_ID, SITE_ID, _login, data  # noqa: F401  (fixture)

SERVICE = "src.alert_whatsapp_service"
PATH = f"/api/v1/alert-rules/{RULE_ID}/whatsapp"
T0 = datetime(2026, 11, 24, 6, 0, tzinfo=timezone.utc)
P0, P1, P2 = "+12025550100", "+12025550101", "+12025550102"  # fictional
RECIPIENT = "99999999-9999-4999-8999-999999999999"
BUSINESS = "Fictional Hotels Pvt Ltd"  # fictional customer legal name (R9)
SHOWN = {"version": "TEST-1", "text": f"Test-only wording naming {BUSINESS}.", "business_name": BUSINESS,
         "unavailable_reason": None}


class FakeDb:
    """Stands in for the migration 331/332 functions behind _execute."""

    def __init__(self) -> None:
        self.calls: list[tuple] = []
        self.save_result = ("ok", 2)
        self.get_result = "ok"
        self.statement: dict | None = dict(SHOWN)

    async def execute(self, sql, params, *, commit):
        if "save_portal_alert_rule_whatsapp" in sql:
            self.calls.append(("save", params, commit))
            return [{"result": self.save_result[0], "revision": self.save_result[1]}]
        if "get_portal_alert_rule_whatsapp(" in sql:
            self.calls.append(("get", params, commit))
            if self.get_result != "ok":
                return [{"result": self.get_result, "enabled": None, "revision": None, "recipients": None}]
            return [{
                "result": "ok", "enabled": True, "revision": 2,
                "recipients": [{
                    "recipient_id": RECIPIENT, "phone_e164": P0, "consent_state": "CONFIRMED",
                    "consent_confirmed_at": T0.isoformat(), "consent_confirmed_by_name": "Asha Admin",
                    "consent_statement_version": "TEST-1", "consent_business_name": BUSINESS,
                }],
                "consent_statement": self.statement,
            }]
        raise AssertionError(sql)


@pytest.fixture
def db(monkeypatch) -> FakeDb:
    fake = FakeDb()
    monkeypatch.setattr(f"{SERVICE}._execute", fake.execute)
    return fake


def body(**kw) -> dict:
    payload = {"enabled": True, "revision": 1, "consent_statement_version": "TEST-1", "consent_business_name": BUSINESS,
               "recipients": [{"recipient_id": None, "phone": P0, "opt_in_confirmed": True}]}
    payload.update(kw)
    return payload


def _no_numbers(text: str) -> None:
    for phone in (P0, P1, P2, "2025550100", "202-555-0100", "0100"):
        assert phone not in text, text


# --- permission map ---------------------------------------------------------------------

def test_the_put_path_needs_alert_configure_at_the_middleware() -> None:
    assert required_permission_for_request("PUT", PATH) == PortalPermission.ALERT_CONFIGURE
    assert required_permission_for_request("PUT", PATH + "/") == PortalPermission.ALERT_CONFIGURE
    # GET passes the middleware as dashboard.view; the route itself requires alert.configure.
    assert required_permission_for_request("GET", PATH) == PortalPermission.DASHBOARD_VIEW


# --- authentication and permission ------------------------------------------------------

@pytest.mark.parametrize("method", ["get", "put"])
def test_requires_authentication(portal_client, data, db, method) -> None:
    response = portal_client.request(method.upper(), PATH, json=body() if method == "put" else None,
                                     headers=JSON if method == "put" else {})
    assert response.status_code == 401
    assert db.calls == []


@pytest.mark.parametrize("role,scope", [("OPERATOR", "ORGANIZATION"), ("VIEWER", "ORGANIZATION"),
                                        ("OPERATOR", "GLOBAL"), ("VIEWER", "GLOBAL")])
@pytest.mark.parametrize("method", ["get", "put"])
def test_only_configurers_reach_it(portal_client, monkeypatch, data, db, role, scope, method) -> None:
    _login(portal_client, monkeypatch, role=role, scope=scope)
    response = portal_client.request(method.upper(), PATH, json=body() if method == "put" else None,
                                     headers=JSON if method == "put" else {})
    assert response.status_code == 403 and response.json()["error"] == "forbidden"
    assert db.calls == []  # D16: not even a read reaches the database


@pytest.mark.parametrize("scope", ["ORGANIZATION", "GLOBAL"])
def test_admin_reads_with_the_session_identity(portal_client, monkeypatch, data, db, scope) -> None:
    _login(portal_client, monkeypatch, role="ADMIN", scope=scope, uid=902)
    response = portal_client.get(PATH)
    assert response.status_code == 200
    payload = response.json()
    assert payload["messages_active"] is False and payload["max_recipients"] == 10
    assert payload["enabled"] is True and payload["revision"] == 2 and payload["rule_id"] == RULE_ID
    [recipient] = payload["recipients"]
    assert recipient["phone_e164"] == P0 and recipient["phone_masked"] == "+1 ••••••0100"
    assert recipient["consent"] == {"state": "CONFIRMED", "confirmed_at": "2026-11-24T06:00:00Z",
                                    "confirmed_by_name": "Asha Admin", "statement_version": "TEST-1",
                                    "business_name": BUSINESS}
    # The approved wording, rendered with the customer business (R9), to show for a new number.
    assert payload["consent_statement"] == {"version": "TEST-1", "text": f"Test-only wording naming {BUSINESS}.",
                                            "business_name": BUSINESS}
    assert payload["consent_unavailable_reason"] is None
    assert db.calls == [("get", (902, UUID(RULE_ID)), False)]


def test_no_approved_wording_reads_as_null(portal_client, monkeypatch, data, db) -> None:
    _login(portal_client, monkeypatch)
    db.statement = None
    payload = portal_client.get(PATH).json()
    assert payload["consent_statement"] is None and payload["consent_unavailable_reason"] == "statement_missing"


def test_pending_legal_review_reads_as_null_with_its_reason(portal_client, monkeypatch, data, db) -> None:
    _login(portal_client, monkeypatch)
    db.statement = {"version": "TEST-1", "text": None, "business_name": None, "unavailable_reason": "legal_review_pending"}
    payload = portal_client.get(PATH).json()
    assert payload["consent_statement"] is None and payload["consent_unavailable_reason"] == "legal_review_pending"


def test_no_legal_business_name_reads_as_null_with_its_reason(portal_client, monkeypatch, data, db) -> None:
    """R9: without the customer's legal name the wording cannot be shown, so it cannot be confirmed."""
    _login(portal_client, monkeypatch)
    db.statement = {"version": "TEST-1", "text": None, "business_name": None, "unavailable_reason": "business_name_missing"}
    payload = portal_client.get(PATH).json()
    assert payload["consent_statement"] is None and payload["consent_unavailable_reason"] == "business_name_missing"


# --- save -------------------------------------------------------------------------------

def test_save_normalises_numbers_commits_and_returns_the_reloaded_configuration(portal_client, monkeypatch, data, db) -> None:
    _login(portal_client, monkeypatch, uid=903)
    payload = body(recipients=[
        {"recipient_id": RECIPIENT, "phone": "+1 (202) 555-0100", "opt_in_confirmed": False},
        {"phone": "+1 202 555 0101", "opt_in_confirmed": True},
    ])
    response = portal_client.put(PATH, json=payload, headers=JSON)
    assert response.status_code == 200, response.text
    assert response.json()["messages_active"] is False
    (kind, params, commit), (reload_kind, *_rest) = db.calls
    assert (kind, commit, reload_kind) == ("save", True, "get")
    user, rule, enabled, recipients, revision, shown_version, shown_business = params
    assert (user, rule, enabled, revision, shown_version, shown_business) == (903, UUID(RULE_ID), True, 1, "TEST-1",
                                                                              BUSINESS)
    assert recipients.obj == [
        {"recipient_id": RECIPIENT, "phone": P0, "opt_in_confirmed": False},
        {"recipient_id": None, "phone": P1, "opt_in_confirmed": True},
    ]


@pytest.mark.parametrize("headers,status_code", [
    ({**JSON, "Sec-Fetch-Site": "cross-site"}, 403),
    ({**JSON, "Origin": "https://evil.example"}, 403),
    ({"Content-Type": "text/plain"}, 415),
])
def test_save_refuses_cross_site_and_non_json(portal_client, monkeypatch, data, db, headers, status_code) -> None:
    _login(portal_client, monkeypatch)
    import json as _json
    response = portal_client.put(PATH, content=_json.dumps(body()).encode(), headers=headers)
    assert response.status_code == status_code
    assert db.calls == []


@pytest.mark.parametrize("payload", [
    {"enabled": True, "revision": 1, "recipients": [], "unexpected": 1},
    {"enabled": True, "revision": -1, "recipients": []},
    {"enabled": True, "recipients": []},
    {"enabled": True, "revision": 1, "recipients": [{"phone": P0, "opt_in_confirmed": True, "name": "Asha"}]},
    {"enabled": True, "revision": 1, "recipients": [{"phone": P0 * 3, "opt_in_confirmed": True}]},
])
def test_malformed_requests_are_refused_generically_without_echoing_input(portal_client, monkeypatch, data, db, payload) -> None:
    _login(portal_client, monkeypatch)
    response = portal_client.put(PATH, json=payload, headers=JSON)
    assert response.status_code == 422 and response.json()["error"] == "invalid_request"
    _no_numbers(response.text)
    assert db.calls == []


@pytest.mark.parametrize("recipients,code,index", [
    ([{"phone": "12025550100", "opt_in_confirmed": True}], "whatsapp_invalid_phone", 0),
    ([{"phone": P0, "opt_in_confirmed": True}, {"phone": "+1 202 555", "opt_in_confirmed": True}],
     "whatsapp_invalid_phone", 1),
    ([{"phone": "+15555550100", "opt_in_confirmed": True}], "whatsapp_invalid_phone", 0),
    ([{"phone": P0, "opt_in_confirmed": True}, {"phone": "+1 (202) 555-0100", "opt_in_confirmed": True}],
     "whatsapp_duplicate_phone", 1),
    ([{"phone": f"+1202555{n:04d}", "opt_in_confirmed": True} for n in range(100, 111)],
     "whatsapp_too_many_recipients", None),
    ([], "whatsapp_recipients_required", None),
])
def test_validation_refusals_name_the_position_never_the_number(portal_client, monkeypatch, data, db, recipients, code, index) -> None:
    _login(portal_client, monkeypatch)
    response = portal_client.put(PATH, json=body(recipients=recipients), headers=JSON)
    assert response.status_code == 422
    payload = response.json()
    assert payload["error"] == code and payload.get("recipient_index") == index
    _no_numbers(response.text)
    assert db.calls == []  # refused before the database


@pytest.mark.parametrize("result,status_code", [
    ("not_found", 404), ("forbidden", 403), ("whatsapp_config_stale", 409), ("whatsapp_consent_statement_changed", 409),
    ("whatsapp_consent_required", 422), ("whatsapp_consent_statement_missing", 422),
    ("whatsapp_business_name_missing", 422), ("whatsapp_consent_legal_review_pending", 422),
    ("whatsapp_unknown_recipient", 422), ("whatsapp_too_many_recipients", 422),
])
def test_database_refusals_map_to_http(portal_client, monkeypatch, data, db, result, status_code) -> None:
    _login(portal_client, monkeypatch)
    db.save_result = (result, 1)
    response = portal_client.put(PATH, json=body(), headers=JSON)
    assert response.status_code == status_code
    assert response.json()["error"] == result
    _no_numbers(response.text)
    assert [c[0] for c in db.calls] == ["save"]  # no reload after a refusal


def test_new_opt_ins_explain_that_the_wording_is_not_approved(portal_client, monkeypatch, data, db) -> None:
    _login(portal_client, monkeypatch)
    db.save_result = ("whatsapp_consent_statement_missing", 0)
    response = portal_client.put(PATH, json=body(revision=0), headers=JSON)
    assert response.json()["detail"] == (
        "New WhatsApp numbers cannot be added yet: the opt-in confirmation wording has not been approved."
    )


@pytest.mark.parametrize("result,status_code", [("not_found", 404), ("forbidden", 403)])
def test_read_refusals_map_to_http(portal_client, monkeypatch, data, db, result, status_code) -> None:
    _login(portal_client, monkeypatch)
    db.get_result = result
    response = portal_client.get(PATH)
    assert response.status_code == status_code


def test_unknown_rule_id_shape_is_a_validation_error(portal_client, monkeypatch, data, db) -> None:
    _login(portal_client, monkeypatch)
    assert portal_client.get("/api/v1/alert-rules/not-a-uuid/whatsapp").status_code == 422
    assert db.calls == []


# --- the retired flag never travels -----------------------------------------------------

def test_rule_writes_never_forward_the_retired_whatsapp_flag() -> None:
    rule = AlertRuleCreate.model_validate({**RULE_BODY, "delivery": {"email": True, "whatsapp": True}})
    args = rule_args(rule)
    assert args["whatsapp"] is False and args["email"] is True


# --- phone handling (unit) --------------------------------------------------------------

@pytest.mark.parametrize("raw,expected", [
    (P0, P0), ("+1 202-555-0100", P0), (" +1 (202) 555 0101 ", P1), ("+61 491 570 156", "+61491570156"),
])
def test_normalize_phone_returns_e164(raw, expected) -> None:
    assert normalize_phone(raw) == expected


@pytest.mark.parametrize("raw", ["2025550100", "+1", "+15555550100", "+0202555010", "", "abc", "+1 202 555 01000000"])
def test_normalize_phone_refuses_without_echoing_the_number(raw) -> None:
    with pytest.raises(WhatsAppConfigError) as caught:
        normalize_phone(raw, 3)
    assert caught.value.code == "whatsapp_invalid_phone" and caught.value.index == 3
    assert str(caught.value) == "whatsapp_invalid_phone" and caught.value.__cause__ is None
    if raw:
        assert raw.strip() not in caught.value.detail


@pytest.mark.parametrize("e164,masked", [(P0, "+1 ••••••0100"), ("+61491570156", "+61 •••••0156")])
def test_mask_shows_the_country_code_and_last_four_only(e164, masked) -> None:
    assert mask_phone(e164) == masked


def test_prepare_recipients_rejects_duplicates_after_normalisation() -> None:
    config = WhatsAppConfigIn.model_validate(body(recipients=[{"phone": P0}, {"phone": "+1 202 555 0100"}]))
    with pytest.raises(WhatsAppConfigError) as caught:
        prepare_recipients(config)
    assert (caught.value.code, caught.value.index) == ("whatsapp_duplicate_phone", 1)


def test_prepare_recipients_allows_disabling_with_no_recipients() -> None:
    assert prepare_recipients(WhatsAppConfigIn.model_validate(body(enabled=False, recipients=[]))) == []


# --- database errors never leak a number into logs or tracebacks (review R2) ---------

async def test_database_errors_are_logged_without_detail_or_cause(monkeypatch, caplog) -> None:
    import contextlib

    from src import alert_whatsapp_service as service

    class Boom:
        async def execute(self, *a, **k):
            raise psycopg.errors.CheckViolation(f'new row violates check constraint; Failing row contains ({P0}).')

        async def __aenter__(self):
            return self

        async def __aexit__(self, *exc):
            return False

    class Conn:
        def cursor(self):
            return Boom()

        async def rollback(self):
            return None

        async def commit(self):
            return None

    @contextlib.asynccontextmanager
    async def fake_connection():
        yield Conn()

    monkeypatch.setattr("src.database.database_connection", fake_connection)
    caplog.set_level(logging.DEBUG)
    with pytest.raises(RuntimeError) as caught:
        await service._execute("SELECT 1", (), commit=True)
    assert caught.value.__cause__ is None and caught.value.__suppress_context__ is True
    assert P0 not in str(caught.value)
    assert "sqlstate=23514" in caplog.text
    _no_numbers(caplog.text)


def test_the_router_exposes_no_other_whatsapp_route(portal_app) -> None:
    """No send or test-send route on the portal (D12). Phase 2 adds only the
    read-only, masked delivery history; the receipt webhook is served by the
    customer API alone (test_customer_api)."""
    paths = {getattr(r, "path", "") for r in portal_app.routes}
    whatsapp = {p for p in paths if "whatsapp" in p.lower()}
    assert whatsapp == {"/api/v1/alert-rules/{rule_id}/whatsapp", "/api/v1/alert-rules/{rule_id}/whatsapp/deliveries"}


# --- delivery history (migration 333) ---------------------------------------------------

DELIVERIES = PATH + "/deliveries"
DELIVERY_ROW = {
    "result": "ok", "delivery_id": "aaaaaaaa-0000-4000-8000-000000000001", "alert_id": "bbbbbbbb-0000-4000-8000-000000000001",
    "recipient_id": RECIPIENT, "phone_masked": "•••• 0100", "status": "DELIVERED", "status_reason": None, "attempts": 1,
    "last_error_code": None, "created_at": T0, "submitted_at": T0, "sent_at": T0, "delivered_at": T0, "read_at": None,
    "failed_at": None,
}


class FakeDeliveriesDb:
    def __init__(self, rows):
        self.rows = rows
        self.calls: list[tuple] = []

    async def execute(self, sql, params, *, commit):
        assert "get_portal_alert_rule_whatsapp_deliveries" in sql
        self.calls.append((params, commit))
        return self.rows


@pytest.mark.parametrize("role,scope", [("OPERATOR", "ORGANIZATION"), ("VIEWER", "ORGANIZATION"), ("VIEWER", "GLOBAL")])
def test_delivery_history_is_for_configurers_only(portal_client, monkeypatch, data, role, scope) -> None:
    fake = FakeDeliveriesDb([DELIVERY_ROW])
    monkeypatch.setattr(f"{SERVICE}._execute", fake.execute)
    _login(portal_client, monkeypatch, role=role, scope=scope)
    assert portal_client.get(DELIVERIES).status_code == 403
    assert fake.calls == []


def test_delivery_history_is_masked_and_read_only(portal_client, monkeypatch, data) -> None:
    fake = FakeDeliveriesDb([DELIVERY_ROW])
    monkeypatch.setattr(f"{SERVICE}._execute", fake.execute)
    _login(portal_client, monkeypatch, role="ADMIN", scope="ORGANIZATION", uid=902)
    response = portal_client.get(DELIVERIES, params={"limit": 20})
    assert response.status_code == 200
    payload = response.json()
    assert payload["deliveries"][0]["phone_masked"] == "•••• 0100" and payload["deliveries"][0]["status"] == "DELIVERED"
    assert fake.calls == [((902, UUID(RULE_ID), 20), False)]
    _no_numbers(response.text.replace("•••• 0100", ""))


@pytest.mark.parametrize("code,status", [("not_found", 404), ("forbidden", 403)])
def test_delivery_history_refusals(portal_client, monkeypatch, data, code, status) -> None:
    fake = FakeDeliveriesDb([dict({k: None for k in DELIVERY_ROW}, result=code)])
    monkeypatch.setattr(f"{SERVICE}._execute", fake.execute)
    _login(portal_client, monkeypatch, role="ADMIN", scope="ORGANIZATION")
    assert portal_client.get(DELIVERIES).status_code == status
