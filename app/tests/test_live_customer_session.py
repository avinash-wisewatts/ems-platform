"""live-telemetry accepts the customer API session (ADR-023 stage 3).

The edge proxy routes the customer host's /api/live/* straight to
live-telemetry, so it must recognise the customer session cookie
(ems_session, signed with the customer API's own secret) as well as the
Administration App session it accepted before -- and must refuse a
customer-cookie WebSocket whose Origin is not the host it reached (a
cross-site page must not open a live stream with a customer's cookie).
Asset authorization stays per identity (admin.portal_user_can_access_asset,
faked here).

Server-side sessions (migration 314): a customer cookie must also carry a
session token that admin.get_portal_session_user (faked here as
live_main.customer_session_user) maps to the same account. An open customer
WebSocket re-checks it every EMS_CUSTOMER_SESSION_RECHECK_SECONDS and is
closed with 4401 once the session is signed out, expired or deactivated.
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
from src.auth.customer_session import read_customer_session, same_origin

CUSTOMER_SECRET = "customer-live-test-secret-0123456789abcdefghij"
ASSET_ID = "55555555-5555-4555-8555-555555555555"
ORIGIN = {"Origin": "http://testserver"}

CUSTOMER = {"portal_user_id": 801, "username": "c@customer.example", "display_name": "Customer",
            "role_code": "VIEWER", "organization_id": "11111111-1111-4111-8111-111111111111",
            "access_scope_mode": "ORGANIZATION", "site_ids": []}
STAFF = {"portal_user_id": 802, "username": "s@wisewatts.example", "display_name": "Staff",
         "role_code": "ADMIN", "organization_id": None, "access_scope_mode": "GLOBAL", "site_ids": []}


def _token(identity: dict) -> str:
    return f"live-test-session-token-{identity['portal_user_id']}-0123456789abcdef"


def _cookie(identity: dict, secret: str = CUSTOMER_SECRET, *, age_seconds: int = 0,
            token: str | None = "default") -> str:
    class Signer(itsdangerous.TimestampSigner):
        def get_timestamp(self) -> int:
            return int(time.time()) - age_seconds

    session = {"portal_identity": identity}
    if token is not None:
        session["session_token"] = _token(identity) if token == "default" else token
    payload = b64encode(json.dumps(session).encode("utf-8"))
    return Signer(secret).sign(payload).decode("utf-8")


class FakeSessions:
    """admin.get_portal_session_user: token -> account of a live session."""

    def __init__(self) -> None:
        self.live = {_token(CUSTOMER): 801, _token(STAFF): 802}
        self.checks = 0
        self.down = False

    async def user(self, token: str) -> int | None:
        self.checks += 1
        if self.down:
            raise ConnectionError("database unavailable")
        return self.live.get(token)

    def revoke(self, identity: dict) -> None:
        self.live.pop(_token(identity), None)


@pytest.fixture
def sessions(monkeypatch) -> FakeSessions:
    fake = FakeSessions()
    monkeypatch.setattr(live_main, "customer_session_user", fake.user)
    return fake


@pytest.fixture
def live(monkeypatch, sessions):
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
    lambda: f"ems_session={_cookie(CUSTOMER, token=None)}",                          # pre-314 cookie: no token
    lambda: f"ems_session={_cookie(CUSTOMER, token='never-issued-0123456789abcdef')}",  # no such session
    lambda: f"ems_session={_cookie(CUSTOMER, token=_token(STAFF))}",                 # another account's session
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
    session = read_customer_session(f"a=b; ems_session={_cookie(CUSTOMER)}", **kwargs)
    assert (session.identity.portal_user_id, session.token) == (801, _token(CUSTOMER))
    assert read_customer_session(f"ems_session={_cookie(CUSTOMER, token=None)}", **kwargs) is None
    assert read_customer_session(None, **kwargs) is None
    assert read_customer_session("ems_session=", **kwargs) is None
    assert read_customer_session('ems_session="unterminated', **kwargs) is None
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


# --- server-side revocation (migration 314) -------------------------------------------

@pytest.fixture
def fast_recheck(monkeypatch):
    monkeypatch.setattr(live_main.settings, "customer_session_recheck_seconds", 0.05)


def test_revoked_session_cookie_cannot_open_a_stream(live, sessions) -> None:
    client, seen = live
    sessions.revoke(CUSTOMER)                                   # signed out before the handshake
    with pytest.raises(WebSocketDisconnect) as closed:
        with _ws(client, f"ems_session={_cookie(CUSTOMER)}", ORIGIN) as ws:
            ws.receive_json()
    assert closed.value.code == 4401 and seen == []


def test_an_open_stream_is_closed_when_its_session_is_signed_out(live, sessions, fast_recheck) -> None:
    client, _ = live
    with pytest.raises(WebSocketDisconnect) as closed:
        with _ws(client, f"ems_session={_cookie(CUSTOMER)}", ORIGIN) as ws:
            assert ws.receive_json()["type"] == "snapshot"
            time.sleep(0.3)                                     # several re-checks while still valid
            open_checks = sessions.checks
            sessions.revoke(CUSTOMER)                           # sign-out / deactivation / expiry in the database
            ws.receive_json()
    assert closed.value.code == 4401
    assert open_checks >= 3                                     # handshake + periodic re-checks


def test_an_open_stream_is_closed_when_its_cookie_expires(live, monkeypatch, fast_recheck) -> None:
    client, _ = live
    with pytest.raises(WebSocketDisconnect) as closed:
        with _ws(client, f"ems_session={_cookie(CUSTOMER, age_seconds=600)}", ORIGIN) as ws:
            assert ws.receive_json()["type"] == "snapshot"
            monkeypatch.setattr(live_main.settings, "customer_session_max_age_seconds", 300)
            ws.receive_json()
    assert closed.value.code == 4401


def test_session_check_outage_closes_without_4401(live, sessions, fast_recheck) -> None:
    client, _ = live
    # 1011 (server error), not 4401: the frontend reconnects with backoff.
    with pytest.raises(WebSocketDisconnect) as closed:
        with _ws(client, f"ems_session={_cookie(CUSTOMER)}", ORIGIN) as ws:
            assert ws.receive_json()["type"] == "snapshot"
            sessions.down = True
            ws.receive_json()
    assert closed.value.code == 1011
    sessions.down = True
    with pytest.raises(WebSocketDisconnect) as closed:
        with _ws(client, f"ems_session={_cookie(CUSTOMER)}", ORIGIN) as ws:
            ws.receive_json()
    assert closed.value.code == 1011


def test_administration_streams_are_not_rechecked(live, sessions, fast_recheck) -> None:
    client, _ = live
    admin_cookie = _cookie(dict(CUSTOMER, portal_user_id=42), secret=live_main.settings.session_secret)
    with _ws(client, f"{live_main.settings.session_cookie_name}={admin_cookie}") as ws:
        assert ws.receive_json()["points"][0]["actor"] == 42
        time.sleep(0.2)
    assert sessions.checks == 0


def test_http_snapshot_refuses_a_revoked_session(live, sessions) -> None:
    client, _ = live
    headers = {"Cookie": f"ems_session={_cookie(CUSTOMER)}"}
    assert client.get(f"/api/live/assets/{ASSET_ID}", headers=headers).status_code == 200
    sessions.revoke(CUSTOMER)
    assert client.get(f"/api/live/assets/{ASSET_ID}", headers=headers).status_code == 401
    sessions.down = True
    assert client.get(f"/api/live/assets/{ASSET_ID}", headers=headers).status_code == 503


def test_publishing_never_sends_to_a_revoked_stream_after_its_close(live, sessions, fast_recheck) -> None:
    import asyncio

    client, _ = live
    with pytest.raises(WebSocketDisconnect):
        with _ws(client, f"ems_session={_cookie(CUSTOMER)}", ORIGIN) as ws:
            ws.receive_json()
            sessions.revoke(CUSTOMER)
            ws.receive_json()
    # The closed socket left the hub: nothing remains to publish to.
    assert asyncio.run(live_main.hub.subscribers_for(UUID(ASSET_ID))) == ()
