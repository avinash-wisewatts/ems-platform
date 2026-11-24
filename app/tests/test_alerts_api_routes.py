"""ADR-024 alerts API (src.routers.alerts_api) -- route contract with the data
layer faked: authentication, the dedicated write permissions (alert.configure
ADMIN only, alert.acknowledge ADMIN/OPERATOR) at the middleware and route, the
same-origin / JSON guards on every write, request validation, database result
-> HTTP mapping, and the response contracts (Coming Soon delivery, no staff
identity). The database functions themselves are tested in
test_alert_rules_db.py.
"""

from __future__ import annotations

from datetime import datetime, time, timezone
from uuid import UUID, uuid4

import pytest

from src.alert_rules_service import AlertRuleError, WhatsAppRuleSummary
from src.auth.models import AuthenticatedPortalUser
from src.auth.security import AuthenticationStatus
from src.auth.service import AuthenticationResult

ROUTER = "src.routers.alerts_api"
SITE_ID = "22222222-2222-4222-8222-222222222222"
OTHER_SITE = "33333333-3333-4333-8333-333333333333"
ASSET_ID = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
RULE_ID = "55555555-5555-4555-8555-555555555555"
ALERT_ID = "77777777-7777-4777-8777-777777777777"
JSON = {"Content-Type": "application/json"}
T0 = datetime(2026, 11, 18, 6, 0, tzinfo=timezone.utc)

RULE_BODY = {
    "name": "High power",
    "asset_id": ASSET_ID,
    "parameter_code": "ACTIVE_POWER",
    "qualifier": "TOTAL",
    "comparator": "GT",
    "threshold": 50,
    "schedule": {"start_time": "22:00", "end_time": "06:00", "weekdays": ["MON", "TUE"]},
    "reminder_minutes": 15,
    "delivery": {"email": True, "whatsapp": False},
}


def _rule_row(**kw) -> dict:
    row = {
        "rule_id": UUID(RULE_ID), "site_id": UUID(SITE_ID), "name": "High power", "asset_id": UUID(ASSET_ID),
        "asset_name": "Chiller 1", "parameter_code": "ACTIVE_POWER", "qualifier": "TOTAL",
        "parameter_name": "Active Power", "unit_symbol": "kW", "comparator": "GT", "comparison_mode": "FIXED",
        "threshold": 50, "tolerance": None, "schedule_start": time(22, 0), "schedule_end": time(6, 0),
        "weekdays": 3, "reminder_minutes": 15, "email_requested": True, "whatsapp_requested": False,
        "enabled": True, "version": 1, "created_at": T0, "updated_at": T0, "active_alert_id": None,
    }
    row.update(kw)
    return row


def _alert_row(**kw) -> dict:
    row = {
        "alert_id": UUID(ALERT_ID), "site_id": UUID(SITE_ID), "rule_id": UUID(RULE_ID), "rule_name": "High power",
        "rule_deleted": False, "asset_id": UUID(ASSET_ID), "asset_name": "Chiller 1", "parameter_code": "ACTIVE_POWER",
        "qualifier": "TOTAL", "parameter_name": "Active Power", "unit_symbol": "kW", "comparator": "GT",
        "threshold": 50, "tolerance": None, "state": "ACTIVE", "event_at": T0, "triggered_at": T0,
        "trigger_value": 61.0, "last_value": 62.5, "last_value_at": T0, "data_unavailable": False,
        "resolved_at": None, "resolved_value": None, "ended_at": None, "ended_reason_code": None,
        "acknowledged_at": None, "acknowledged_by_name": None, "previous_occurrence_count": 0,
        "most_recent_previous_triggered_at": None,
    }
    row.update(kw)
    return row


class FakeData:
    def __init__(self) -> None:
        self.calls: list[tuple] = []
        self.result: str = "ok"
        self.alert = _alert_row()
        # Migration 331: configurer-only WhatsApp summaries (None = refused).
        self.whatsapp_summaries: dict | None = {UUID(RULE_ID): WhatsAppRuleSummary(enabled=True, recipient_count=2)}

    async def site(self, portal_user_id, site_id):
        self.calls.append(("site", portal_user_id, str(site_id)))
        return {"site_id": SITE_ID, "site_name": "S", "timezone": "Asia/Kolkata"} if str(site_id) == SITE_ID else None

    async def alerts(self, portal_user_id, site_id, states, dt_from, dt_to, limit, before):
        self.calls.append(("alerts", portal_user_id, states, limit, before))
        return [self.alert]

    async def alert_detail(self, portal_user_id, alert_id):
        self.calls.append(("alert", portal_user_id, str(alert_id)))
        return self.alert if str(alert_id) == ALERT_ID else None

    async def rules(self, portal_user_id, site_id):
        return [_rule_row()]

    async def rule(self, portal_user_id, rule_id):
        return _rule_row() if str(rule_id) == RULE_ID else None

    async def summaries(self, portal_user_id, site_id):
        self.calls.append(("whatsapp_summaries", portal_user_id, str(site_id)))
        return self.whatsapp_summaries

    async def parameters(self, portal_user_id, site_id, asset_id):
        return [{"asset_id": UUID(ASSET_ID), "asset_name": "Chiller 1", "parameter_code": "ACTIVE_POWER",
                 "parameter_name": "Active Power", "qualifier": "TOTAL", "unit_symbol": "kW"}]

    def _write(self, name):
        async def write(portal_user_id, *args):
            self.calls.append((name, portal_user_id, *args))
            if self.result != "ok":
                raise AlertRuleError(self.result)
            return {"result": "ok", "rule_id": UUID(RULE_ID), "alert_id": UUID(ALERT_ID), "version": 1}
        return write


@pytest.fixture
def data(monkeypatch) -> FakeData:
    fake = FakeData()
    for attr, fn in {
        "fetch_analytics_site": fake.site, "fetch_site_alerts": fake.alerts, "fetch_alert": fake.alert_detail,
        "fetch_rules": fake.rules, "fetch_rule": fake.rule, "fetch_parameters": fake.parameters,
        "create_rule": fake._write("create"), "update_rule": fake._write("update"),
        "set_rule_enabled": fake._write("enabled"), "delete_rule": fake._write("delete"),
        "acknowledge_alert": fake._write("ack"), "fetch_summaries": fake.summaries,
    }.items():
        monkeypatch.setattr(f"{ROUTER}.{attr}", fn)
    return fake


def _login(portal_client, monkeypatch, role="ADMIN", scope="ORGANIZATION", uid=900) -> None:
    async def fake_authenticate(username: str, password: str) -> AuthenticationResult:
        return AuthenticationResult(
            authenticated=True,
            user=AuthenticatedPortalUser(
                portal_user_id=uid, username=username, display_name="User", role_code=role,
                access_scope_mode=scope,
                organization_id=None if scope == "GLOBAL" else "11111111-1111-4111-8111-111111111111",
            ),
            status=AuthenticationStatus.AUTHENTICATED,
        )

    monkeypatch.setattr("src.main.authenticate_portal_user", fake_authenticate)
    response = portal_client.post("/login", data={"username": f"u{uid}@example.com", "password": "pw", "next_path": "/"})
    assert response.status_code == 303


WRITES = [
    ("post", f"/api/v1/sites/{SITE_ID}/alert-rules", RULE_BODY),
    ("patch", f"/api/v1/alert-rules/{RULE_ID}", {**RULE_BODY, "version": 1}),
    ("post", f"/api/v1/alert-rules/{RULE_ID}/enable", None),
    ("post", f"/api/v1/alert-rules/{RULE_ID}/disable", None),
    ("delete", f"/api/v1/alert-rules/{RULE_ID}", None),
]


def _call(client, method, path, body, headers=None):
    kwargs = {"headers": headers if headers is not None else (JSON if body is not None else {})}
    if body is not None:
        kwargs["json"] = body
    return client.request(method.upper(), path, **kwargs)


@pytest.mark.parametrize("method,path,body", WRITES + [
    ("get", f"/api/v1/sites/{SITE_ID}/alerts", None),
    ("get", f"/api/v1/alerts/{ALERT_ID}", None),
    ("post", f"/api/v1/alerts/{ALERT_ID}/acknowledge", None),
    ("get", f"/api/v1/sites/{SITE_ID}/alert-rules", None),
    ("get", f"/api/v1/sites/{SITE_ID}/alert-rules/parameters", None),
    ("get", f"/api/v1/alert-rules/{RULE_ID}", None),
])
def test_every_route_requires_authentication(portal_client, data, method, path, body) -> None:
    response = _call(portal_client, method, path, body)
    assert response.status_code == 401


@pytest.mark.parametrize("role,scope", [("OPERATOR", "ORGANIZATION"), ("VIEWER", "ORGANIZATION"),
                                        ("OPERATOR", "GLOBAL"), ("VIEWER", "GLOBAL")])
@pytest.mark.parametrize("method,path,body", WRITES)
def test_rule_writes_need_alert_configure(portal_client, monkeypatch, data, role, scope, method, path, body) -> None:
    _login(portal_client, monkeypatch, role=role, scope=scope)
    response = _call(portal_client, method, path, body)
    assert response.status_code == 403 and response.json()["error"] == "forbidden"
    assert not [c for c in data.calls if c[0] in ("create", "update", "enabled", "delete")]


@pytest.mark.parametrize("role,scope,allowed", [
    ("ADMIN", "ORGANIZATION", True), ("OPERATOR", "ORGANIZATION", True), ("VIEWER", "ORGANIZATION", False),
    ("ADMIN", "GLOBAL", True), ("OPERATOR", "GLOBAL", True), ("VIEWER", "GLOBAL", False),
])
def test_acknowledge_permission(portal_client, monkeypatch, data, role, scope, allowed) -> None:
    _login(portal_client, monkeypatch, role=role, scope=scope)
    response = portal_client.post(f"/api/v1/alerts/{ALERT_ID}/acknowledge")
    assert response.status_code == (200 if allowed else 403)
    assert bool([c for c in data.calls if c[0] == "ack"]) is allowed


@pytest.mark.parametrize("scope", ["ORGANIZATION", "GLOBAL"])
@pytest.mark.parametrize("method,path,body", WRITES)
def test_admin_writes_reach_the_database_with_the_session_identity(portal_client, monkeypatch, data, scope, method, path, body) -> None:
    _login(portal_client, monkeypatch, role="ADMIN", scope=scope, uid=901)
    response = _call(portal_client, method, path, body)
    assert response.status_code in (200, 201, 204), response.text
    writes = [c for c in data.calls if c[0] in ("create", "update", "enabled", "delete")]
    assert len(writes) == 1 and writes[0][1] == 901


@pytest.mark.parametrize("headers,status_code", [
    ({**JSON, "Sec-Fetch-Site": "cross-site"}, 403),
    ({**JSON, "Origin": "https://evil.example"}, 403),
    ({"Content-Type": "text/plain"}, 415),
])
def test_writes_refuse_cross_site_and_non_json(portal_client, monkeypatch, data, headers, status_code) -> None:
    _login(portal_client, monkeypatch)
    response = portal_client.post(f"/api/v1/sites/{SITE_ID}/alert-rules", content=b'{"name": "x"}', headers=headers)
    assert response.status_code == status_code
    assert not [c for c in data.calls if c[0] == "create"]


def test_acknowledge_refuses_cross_site(portal_client, monkeypatch, data) -> None:
    _login(portal_client, monkeypatch, role="OPERATOR")
    response = portal_client.post(f"/api/v1/alerts/{ALERT_ID}/acknowledge", headers={"Sec-Fetch-Site": "cross-site"})
    assert response.status_code == 403
    assert not [c for c in data.calls if c[0] == "ack"]


@pytest.mark.parametrize("change", [
    {"schedule": {"start_time": "25:00", "end_time": "06:00", "weekdays": ["MON"]}},
    {"schedule": {"start_time": "22:00", "end_time": "06:00", "weekdays": ["FUNDAY"]}},
    {"comparator": "NE"},
    {"unexpected": True},
    {"delivery": {"email": True, "sms": True}},
])
def test_request_validation(portal_client, monkeypatch, data, change) -> None:
    _login(portal_client, monkeypatch)
    response = portal_client.post(f"/api/v1/sites/{SITE_ID}/alert-rules", json={**RULE_BODY, **change}, headers=JSON)
    assert response.status_code == 422
    assert not [c for c in data.calls if c[0] == "create"]


def test_reminder_choices_and_weekdays_are_checked_before_the_database(portal_client, monkeypatch, data) -> None:
    _login(portal_client, monkeypatch)
    response = portal_client.post(f"/api/v1/sites/{SITE_ID}/alert-rules", json={**RULE_BODY, "reminder_minutes": 60}, headers=JSON)
    assert (response.status_code, response.json()["error"]) == (422, "invalid_reminder")
    body = {**RULE_BODY, "schedule": {**RULE_BODY["schedule"], "weekdays": []}}
    response = portal_client.post(f"/api/v1/sites/{SITE_ID}/alert-rules", json=body, headers=JSON)
    assert (response.status_code, response.json()["error"]) == (422, "invalid_weekdays")
    assert not [c for c in data.calls if c[0] == "create"]


@pytest.mark.parametrize("result,status_code", [
    ("not_found", 404), ("forbidden", 403), ("name_taken", 409), ("rule_limit_reached", 409),
    ("version_conflict", 409), ("counter_not_allowed", 422), ("tolerance_required", 422),
    ("parameter_not_available", 422),
])
def test_database_results_map_to_http(portal_client, monkeypatch, data, result, status_code) -> None:
    _login(portal_client, monkeypatch)
    data.result = result
    response = portal_client.post(f"/api/v1/sites/{SITE_ID}/alert-rules", json=RULE_BODY, headers=JSON)
    assert response.status_code == status_code
    expected_code = "not_found" if result == "not_found" else result
    assert response.json()["error"] == expected_code


def test_create_passes_the_definition_and_returns_the_rule_with_coming_soon_delivery(portal_client, monkeypatch, data) -> None:
    _login(portal_client, monkeypatch)
    response = portal_client.post(f"/api/v1/sites/{SITE_ID}/alert-rules", json=RULE_BODY, headers=JSON)
    assert response.status_code == 201
    body = response.json()
    assert body["delivery"] == {"email": {"requested": True, "status": "COMING_SOON"},
                                "whatsapp": {"requested": False, "status": "COMING_SOON"}}
    assert body["schedule"] == {"start_time": "22:00", "end_time": "06:00", "weekdays": ["MON", "TUE"],
                                "every_day": False, "timezone": "Asia/Kolkata"}
    create = [c for c in data.calls if c[0] == "create"][0]
    assert str(create[2]) == SITE_ID


def test_alert_list_state_filter_and_cursor(portal_client, monkeypatch, data) -> None:
    _login(portal_client, monkeypatch, role="VIEWER")
    response = portal_client.get(f"/api/v1/sites/{SITE_ID}/alerts?state=RESOLVED&state=ENDED&limit=1")
    assert response.status_code == 200
    call = [c for c in data.calls if c[0] == "alerts"][0]
    assert call[2] == ["ENDED", "RESOLVED"] and call[3] == 1
    assert response.json()["next_before"] is not None
    assert portal_client.get(f"/api/v1/sites/{SITE_ID}/alerts?state=OPEN").status_code == 422
    assert portal_client.get(f"/api/v1/sites/{OTHER_SITE}/alerts").status_code == 404


def test_alert_shape_never_carries_a_staff_identity(portal_client, monkeypatch, data) -> None:
    _login(portal_client, monkeypatch, role="VIEWER")
    data.alert = _alert_row(acknowledged_at=T0, acknowledged_by_name="WiseWatts Support")
    body = portal_client.get(f"/api/v1/alerts/{ALERT_ID}").json()
    assert body["acknowledgement"] == {"acknowledged_at": "2026-11-18T06:00:00Z", "acknowledged_by": "WiseWatts Support"}
    assert body["state"] == "ACTIVE"
    flat = str(body)
    for forbidden in ("acknowledged_by_type", "portal_user", "condition_key", "device_id", "logical_point"):
        assert forbidden not in flat
    assert portal_client.get(f"/api/v1/alerts/{uuid4()}").status_code == 404


def test_rule_reads_and_parameters(portal_client, monkeypatch, data) -> None:
    _login(portal_client, monkeypatch, role="VIEWER")
    rules = portal_client.get(f"/api/v1/sites/{SITE_ID}/alert-rules").json()
    assert rules["max_active_rules"] == 25 and rules["rules"][0]["name"] == "High power"
    params = portal_client.get(f"/api/v1/sites/{SITE_ID}/alert-rules/parameters").json()
    assert params["parameters"][0]["parameter"]["unit"] == "kW"
    assert portal_client.get(f"/api/v1/alert-rules/{uuid4()}").status_code == 404


# --- migration 331: the configurer-only WhatsApp summary in rule responses (D16) ---

@pytest.mark.parametrize("role,scope", [("ADMIN", "ORGANIZATION"), ("ADMIN", "GLOBAL")])
def test_rule_responses_carry_the_whatsapp_summary_for_configurers(portal_client, monkeypatch, data, role, scope) -> None:
    _login(portal_client, monkeypatch, role=role, scope=scope)
    listed = portal_client.get(f"/api/v1/sites/{SITE_ID}/alert-rules").json()["rules"][0]
    single = portal_client.get(f"/api/v1/alert-rules/{RULE_ID}").json()
    for rule in (listed, single):
        assert rule["whatsapp"] == {"enabled": True, "recipient_count": 2}
        # The retired Coming Soon preference is still reported, never as requested.
        assert rule["delivery"]["whatsapp"] == {"requested": False, "status": "COMING_SOON"}


@pytest.mark.parametrize("role,scope", [("OPERATOR", "ORGANIZATION"), ("VIEWER", "ORGANIZATION"),
                                        ("OPERATOR", "GLOBAL"), ("VIEWER", "GLOBAL")])
def test_rule_responses_carry_no_whatsapp_information_for_other_roles(portal_client, monkeypatch, data, role, scope) -> None:
    _login(portal_client, monkeypatch, role=role, scope=scope)
    listed = portal_client.get(f"/api/v1/sites/{SITE_ID}/alert-rules").json()["rules"][0]
    single = portal_client.get(f"/api/v1/alert-rules/{RULE_ID}").json()
    assert listed["whatsapp"] is None and single["whatsapp"] is None
    assert not [c for c in data.calls if c[0] == "whatsapp_summaries"]  # not even asked


def test_a_refused_summary_leaves_whatsapp_null(portal_client, monkeypatch, data) -> None:
    """E.g. a designated report automation account (R5): the database refuses."""
    _login(portal_client, monkeypatch)
    data.whatsapp_summaries = None
    assert portal_client.get(f"/api/v1/alert-rules/{RULE_ID}").json()["whatsapp"] is None
