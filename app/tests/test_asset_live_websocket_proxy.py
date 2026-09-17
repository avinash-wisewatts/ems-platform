"""Asset View live WebSocket proxy (main.py::proxy_asset_live_websocket).

Same-origin admin-portal proxy in front of the live-telemetry service's
portal-session WebSocket (live_main.py::live_asset_websocket) -- see that
module's own docstring for the full rationale.

These tests never open a real upstream connection: `websockets.connect` is
monkeypatched at `src.main.websockets.connect` with a fake connection that
records what URL/headers it was called with and lets a test script canned
messages in either direction. This proves the proxy's own auth/authorization
gate, the exact upstream URL/asset_id it forwards, and the relay behavior,
without any network or database dependency (mirrors the existing pattern of
monkeypatching service-layer functions used throughout this test suite).
"""

from __future__ import annotations

import asyncio

import pytest

from src.auth.models import AuthenticatedPortalUser
from src.auth.security import AuthenticationStatus
from src.auth.service import AuthenticationResult


SITE_ID = "22222222-2222-4222-8222-222222222222"
ASSET_ID = "88888888-8888-4888-8888-888888888888"
OTHER_ASSET_ID = "99999999-9999-4999-8999-999999999999"


def _login_global_admin(portal_client, monkeypatch: pytest.MonkeyPatch) -> None:
    async def fake_authenticate(username: str, password: str) -> AuthenticationResult:
        return AuthenticationResult(
            authenticated=True,
            user=AuthenticatedPortalUser(
                portal_user_id=500,
                username="admin@example.com",
                display_name="Platform Admin",
                role_code="ADMIN",
                access_scope_mode="GLOBAL",
            ),
            status=AuthenticationStatus.AUTHENTICATED,
        )

    monkeypatch.setattr("src.main.authenticate_portal_user", fake_authenticate)
    response = portal_client.post(
        "/login",
        data={"username": "admin@example.com", "password": "valid-password", "next_path": "/"},
    )
    assert response.status_code == 303


class _FakeUpstreamConnection:
    """Stands in for a `websockets` client connection object."""

    def __init__(self, messages_to_send: list[str], *, hang_after: bool = False) -> None:
        self._messages_to_send = list(messages_to_send)
        self._hang_after = hang_after
        self.sent_messages: list[str] = []
        self.closed = False

    def __aiter__(self):
        return self._message_iter()

    async def _message_iter(self):
        for message in self._messages_to_send:
            yield message
        if self._hang_after:
            # Simulate a connection that stays open (real telemetry stream)
            # until the client side closes it -- the relay's other pump
            # (client -> upstream) is what should end the wait in that case.
            await asyncio.Event().wait()

    async def send(self, message: str) -> None:
        self.sent_messages.append(message)

    async def close(self) -> None:
        self.closed = True


class _FakeConnect:
    """Mimics `async with websockets.connect(url, **kwargs) as upstream:`."""

    def __init__(self, connection: _FakeUpstreamConnection | None = None, *, raises: Exception | None = None) -> None:
        self.connection = connection
        self.raises = raises
        self.called_with_url: str | None = None
        self.called_with_kwargs: dict | None = None

    def __call__(self, url: str, **kwargs):
        self.called_with_url = url
        self.called_with_kwargs = kwargs
        return self

    async def __aenter__(self):
        if self.raises is not None:
            raise self.raises
        assert self.connection is not None
        return self.connection

    async def __aexit__(self, *exc_info) -> bool:
        return False


def test_asset_live_ws_requires_authentication(portal_client) -> None:
    with pytest.raises(Exception):
        with portal_client.websocket_connect(f"/api/live/assets/{ASSET_ID}/ws"):
            pass


def test_asset_live_ws_inaccessible_asset_is_rejected(portal_client, monkeypatch) -> None:
    _login_global_admin(portal_client, monkeypatch)

    async def no(portal_user_id, asset_id):
        return False

    monkeypatch.setattr("src.main.portal_user_can_access_asset", no)

    with pytest.raises(Exception):
        with portal_client.websocket_connect(f"/api/live/assets/{ASSET_ID}/ws"):
            pass


def test_asset_live_ws_relays_snapshot_and_telemetry(portal_client, monkeypatch) -> None:
    _login_global_admin(portal_client, monkeypatch)

    async def yes(portal_user_id, asset_id):
        assert str(asset_id) == ASSET_ID
        return True

    monkeypatch.setattr("src.main.portal_user_can_access_asset", yes)

    snapshot = '{"type":"snapshot","asset_id":"%s","points":[]}' % ASSET_ID
    telemetry = '{"type":"telemetry","asset_id":"%s","points":[{"logical_point":"ACTIVE_POWER_TOTAL"}]}' % ASSET_ID
    fake_connect = _FakeConnect(_FakeUpstreamConnection([snapshot, telemetry]))
    monkeypatch.setattr("src.main.websockets.connect", fake_connect)

    with portal_client.websocket_connect(f"/api/live/assets/{ASSET_ID}/ws") as ws:
        assert ws.receive_text() == snapshot
        assert ws.receive_text() == telemetry

    # The proxy authorized and connected upstream using the SAME asset_id
    # from the URL -- never a different one a client could smuggle in.
    assert fake_connect.called_with_url == f"ws://live-telemetry:8090/api/live/assets/{ASSET_ID}/ws"


def test_asset_live_ws_cannot_be_redirected_to_another_assets_data(portal_client, monkeypatch) -> None:
    """A client connecting to asset A's URL can never receive asset B's
    upstream URL/connection -- the path parameter is the only asset_id ever
    used, both for the authorization check and the upstream URL."""
    _login_global_admin(portal_client, monkeypatch)

    checked_asset_ids: list[str] = []

    async def yes(portal_user_id, asset_id):
        checked_asset_ids.append(str(asset_id))
        return True

    monkeypatch.setattr("src.main.portal_user_can_access_asset", yes)

    fake_connect = _FakeConnect(_FakeUpstreamConnection(["{}"]))
    monkeypatch.setattr("src.main.websockets.connect", fake_connect)

    with portal_client.websocket_connect(f"/api/live/assets/{ASSET_ID}/ws") as ws:
        ws.receive_text()

    assert checked_asset_ids == [ASSET_ID]
    assert ASSET_ID in fake_connect.called_with_url
    assert OTHER_ASSET_ID not in fake_connect.called_with_url


def test_asset_live_ws_forwards_session_cookie_upstream(portal_client, monkeypatch) -> None:
    """live_asset_websocket independently re-authenticates using this
    cookie -- the proxy's own check does not replace it."""
    _login_global_admin(portal_client, monkeypatch)

    async def yes(portal_user_id, asset_id):
        return True

    monkeypatch.setattr("src.main.portal_user_can_access_asset", yes)

    fake_connect = _FakeConnect(_FakeUpstreamConnection(["{}"]))
    monkeypatch.setattr("src.main.websockets.connect", fake_connect)

    with portal_client.websocket_connect(f"/api/live/assets/{ASSET_ID}/ws") as ws:
        ws.receive_text()

    headers = fake_connect.called_with_kwargs["additional_headers"]
    assert "Cookie" in headers
    assert headers["Cookie"]


def test_asset_live_ws_upstream_unreachable_closes_cleanly(portal_client, monkeypatch) -> None:
    _login_global_admin(portal_client, monkeypatch)

    async def yes(portal_user_id, asset_id):
        return True

    monkeypatch.setattr("src.main.portal_user_can_access_asset", yes)
    monkeypatch.setattr(
        "src.main.websockets.connect",
        _FakeConnect(raises=OSError("connection refused")),
    )

    with pytest.raises(Exception):
        with portal_client.websocket_connect(f"/api/live/assets/{ASSET_ID}/ws"):
            pass


def test_asset_live_ws_relay_is_content_agnostic(portal_client, monkeypatch) -> None:
    """The relay never parses frame content -- a non-JSON / unexpected
    string upstream is still relayed as-is, never raises server-side. The
    frontend, not this proxy, is responsible for validating message shape."""
    _login_global_admin(portal_client, monkeypatch)

    async def yes(portal_user_id, asset_id):
        return True

    monkeypatch.setattr("src.main.portal_user_can_access_asset", yes)

    fake_connect = _FakeConnect(_FakeUpstreamConnection(["not json at all", "{}", ""]))
    monkeypatch.setattr("src.main.websockets.connect", fake_connect)

    with portal_client.websocket_connect(f"/api/live/assets/{ASSET_ID}/ws") as ws:
        assert ws.receive_text() == "not json at all"
        assert ws.receive_text() == "{}"
        assert ws.receive_text() == ""
