"""live-telemetry accepts the customer API session (ADR-023 stage 3).

The edge proxy routes the customer host's /api/live/* straight to
live-telemetry, so it must recognise the customer session cookie
(ems_session, signed with the customer API's own secret) as well as the
Administration App session it accepted before -- and must refuse a
customer-cookie WebSocket whose Origin is not the host it reached (a
cross-site page must not open a live stream with a customer's cookie).
Asset authorization stays per identity (admin.portal_user_can_access_asset,
faked here).
"""

from __future__ import annotations

import json
import time
from base64 import b64encode
from uuid import UUID

import itsdangerous
import pytest
from fastapi.testclient import TestClient
from starlette.websockets import WebSocketDisconnect

from src import live_main
from src.auth.customer_session import read_customer_identity, same_origin

CUSTOMER_SECRET = "customer-live-test-secret-0123456789abcdefghij"
ASSET_ID = "55555555-5555-4555-8555-555555555555"
ORIGIN = {"Origin": "http://testserver"}

CUSTOMER = {"portal_user_id": 801, "username": "c@customer.example", "display_name": "Customer",
            "role_code": "VIEWER", "organization_id": "11111111-1111-4111-8111-111111111111",
            "access_scope_mode": "ORGANIZATION", "site_ids": []}
STAFF = {"portal_user_id": 802, "username": "s@wisewatts.example", "display_name": "Staff",
         "role_code": "ADMIN", "organization_id": None, "access_scope_mode": "GLOBAL", "site_ids": []}


def _cookie(identity: dict, secret: str = CUSTOMER_SECRET, *, age_seconds: int = 0) -> str:
    class Signer(itsdangerous.TimestampSigner):
        def get_timestamp(self) -> int:
            return int(time.time()) - age_seconds

    payload = b64encode(json.dumps({"portal_identity": identity}).encode("utf-8"))
    return Signer(secret).sign(payload).decode("utf-8")


@pytest.fixture
def live(monkeypatch):
    seen: list[tuple[int, str]] = []

    async def can_access(actor_id: int, asset_id: UUID) -> bool:
        seen.append((actor_id, str(asset_id)))
        return actor_id in (801, 802, 42)

    async def state(actor_id: int, asset_id: UUID) -> list[dict]:
        return [{"point": "kw", "value": 1.5, "actor": actor_id}]

    monkeypatch.setattr(live_main, "actor_can_access_asset", can_access)
    monkeypatch.setattr(live_main, "fetch_asset_state", state)
    monkeypatch.setattr(live_main.settings, "customer_session_secret", CUSTOMER_SECRET)
    monkeypatch.setattr(live_main.settings, "customer_allow_staff", False)
    return TestClient(live_main.app), seen


def _ws(client, cookie_header: str | None, headers: dict | None = None):
    h = dict(headers or {})
    if cookie_header:
        h["Cookie"] = cookie_header
    return client.websocket_connect(f"/api/live/assets/{ASSET_ID}/ws", headers=h)


def test_customer_cookie_same_origin_opens_the_stream(live) -> None:
    client, seen = live
    with _ws(client, f"ems_session={_cookie(CUSTOMER)}", ORIGIN) as ws:
        message = ws.receive_json()
    assert message["type"] == "snapshot" and message["points"][0]["actor"] == 801
    assert seen == [(801, ASSET_ID)]


@pytest.mark.parametrize("headers", [{}, {"Origin": "https://evil.example"}, {"Origin": "null"}])
def test_customer_cookie_without_same_origin_is_refused(live, headers) -> None:
    client, seen = live
    with pytest.raises(WebSocketDisconnect) as closed:
        with _ws(client, f"ems_session={_cookie(CUSTOMER)}", headers) as ws:
            ws.receive_json()
    assert closed.value.code == 4401 and seen == []


@pytest.mark.parametrize("cookie", [
    lambda: f"ems_session={_cookie(CUSTOMER, secret='another-secret-entirely-0123456789abcdef')}",
    lambda: f"ems_session={_cookie(CUSTOMER, age_seconds=30000)}",                   # older than max age
    lambda: f"ems_session={_cookie(STAFF)}",                                         # outside the audience
    lambda: f"ems_admin_session={_cookie(CUSTOMER)}",                                # customer secret, admin name
    lambda: "ems_session=not-a-signed-value",
])
def test_invalid_customer_cookies_are_refused(live, cookie) -> None:
    client, seen = live
    with pytest.raises(WebSocketDisconnect) as closed:
        with _ws(client, cookie(), ORIGIN) as ws:
            ws.receive_json()
    assert closed.value.code == 4401 and seen == []


def test_staff_allowed_on_the_customer_host_only_when_configured(live, monkeypatch) -> None:
    client, _ = live
    monkeypatch.setattr(live_main.settings, "customer_allow_staff", True)
    with _ws(client, f"ems_session={_cookie(STAFF)}", ORIGIN) as ws:
        assert ws.receive_json()["points"][0]["actor"] == 802


def test_customer_cookie_is_ignored_when_not_configured(live, monkeypatch) -> None:
    client, seen = live
    monkeypatch.setattr(live_main.settings, "customer_session_secret", None)
    with pytest.raises(WebSocketDisconnect) as closed:
        with _ws(client, f"ems_session={_cookie(CUSTOMER)}", ORIGIN) as ws:
            ws.receive_json()
    assert closed.value.code == 4401 and seen == []


def test_administration_session_still_works_as_before(live) -> None:
    client, _ = live
    admin_identity = dict(CUSTOMER, portal_user_id=42)
    admin_cookie = _cookie(admin_identity, secret=live_main.settings.session_secret)
    # The admin-portal proxy path sends no browser Origin; unchanged behaviour.
    with _ws(client, f"{live_main.settings.session_cookie_name}={admin_cookie}") as ws:
        assert ws.receive_json()["points"][0]["actor"] == 42


def test_inaccessible_asset_is_still_refused_for_a_customer(live, monkeypatch) -> None:
    client, _ = live

    async def no(actor_id, asset_id):
        return False

    monkeypatch.setattr(live_main, "actor_can_access_asset", no)
    with pytest.raises(WebSocketDisconnect) as closed:
        with _ws(client, f"ems_session={_cookie(CUSTOMER)}", ORIGIN) as ws:
            ws.receive_json()
    assert closed.value.code == 4404


def test_http_snapshot_accepts_the_customer_session(live) -> None:
    client, _ = live
    response = client.get(f"/api/live/assets/{ASSET_ID}", headers={"Cookie": f"ems_session={_cookie(CUSTOMER)}"})
    assert response.status_code == 200 and response.json()["points"][0]["actor"] == 801
    assert client.get(f"/api/live/assets/{ASSET_ID}").status_code == 401


def test_reader_and_origin_helpers() -> None:
    kwargs = dict(secret=CUSTOMER_SECRET, cookie_name="ems_session", max_age_seconds=300, allow_staff=False)
    assert read_customer_identity(f"a=b; ems_session={_cookie(CUSTOMER)}", **kwargs).portal_user_id == 801
    assert read_customer_identity(None, **kwargs) is None
    assert read_customer_identity("ems_session=", **kwargs) is None
    assert read_customer_identity('ems_session="unterminated', **kwargs) is None
    assert same_origin("https://app.example.test", "app.example.test")
    assert same_origin("https://App.Example.Test:8443", "app.example.test:8443")
    assert not same_origin("https://evil.example", "app.example.test")
    assert not same_origin(None, "app.example.test") and not same_origin("null", "app.example.test")


def test_the_handshake_is_accepted_before_any_check() -> None:
    # Over a real server a pre-accept close becomes an HTTP 403 handshake
    # denial (browser close code 1006), and useAssetLiveSocket.ts would keep
    # reconnecting; only post-accept closes deliver 4401 / 4404.
    import inspect

    source = inspect.getsource(live_main.live_asset_websocket)
    accept = source.index("await websocket.accept()")
    assert accept < source.index("portal_identity(") < source.index("close(code=4401)")
    assert accept < source.index("actor_can_access_asset(")
