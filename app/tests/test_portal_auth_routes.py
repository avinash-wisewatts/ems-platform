from collections.abc import Callable

import pytest

from src.auth.models import AuthenticatedPortalUser
from src.auth.security import AuthenticationStatus
from src.auth.service import AuthenticationResult


def successful_result(
    *,
    role_code: str = "OPERATOR",
) -> AuthenticationResult:
    return AuthenticationResult(
        authenticated=True,
        user=AuthenticatedPortalUser(
            portal_user_id=100,
            username="operator@example.com",
            display_name="Test Operator",
            role_code=role_code,

            organization_id=(
                None
                if role_code == "ADMIN"
                else "11111111-1111-1111-1111-111111111111"
            ),
            access_scope_mode=(
                None
                if role_code == "ADMIN"
                else "ORGANIZATION"
            ),
            site_ids=(),
        ),
        status=AuthenticationStatus.AUTHENTICATED,
    )


def failed_result() -> AuthenticationResult:
    return AuthenticationResult(
        authenticated=False,
        user=None,
        status=AuthenticationStatus.INVALID_CREDENTIALS,
    )


def install_authenticator(
    monkeypatch: pytest.MonkeyPatch,
    result_factory: Callable[[], AuthenticationResult],
) -> list[tuple[str, str]]:
    calls: list[tuple[str, str]] = []

    async def fake_authenticate(
        username: str,
        password: str,
    ) -> AuthenticationResult:
        calls.append((username, password))
        return result_factory()

    monkeypatch.setattr(
        "src.main.authenticate_portal_user",
        fake_authenticate,
    )

    return calls


def test_health_is_public(
    portal_client,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    from contextlib import asynccontextmanager

    class FakeCursor:
        async def __aenter__(self):
            return self

        async def __aexit__(
            self,
            exc_type,
            exc,
            traceback,
        ) -> None:
            return None

        async def execute(self, statement: object) -> None:
            # The production route passes psycopg.sql.SQL, not a plain string.
            assert statement is not None

        async def fetchone(self):
            return {
                "database_ok": True,
                "database_name": "ems_test",
                "database_user": "ems_admin",
                "server_version": "PostgreSQL 16 test",
                "timescaledb_version": "2.28.2",
            }


    class FakeConnection:
        def cursor(self) -> FakeCursor:
            return FakeCursor()

    @asynccontextmanager
    async def fake_database_connection():
        yield FakeConnection()

    monkeypatch.setattr(
        "src.main.database_connection",
        fake_database_connection,
    )

    response = portal_client.get("/health")

    assert response.status_code == 200
    assert response.json()["status"] == "ok"


def test_login_page_is_public(portal_client) -> None:
    response = portal_client.get("/login")

    assert response.status_code == 200
    assert "login" in response.text.lower()
    cache_control = response.headers["cache-control"]

    assert "no-store" in cache_control
    assert "no-cache" in cache_control
    assert "must-revalidate" in cache_control
    assert "private" in cache_control


def test_unauthenticated_protected_request_redirects_to_login(
    portal_client,
) -> None:
    response = portal_client.get(
        "/onboarding/device?draft_token=abc"
    )

    assert response.status_code == 303
    assert response.headers["location"] == (
        "/login?"
        "next_path=%2Fonboarding%2Fdevice%3Fdraft_token%3Dabc"
    )
    cache_control = response.headers["cache-control"]

    assert "no-store" in cache_control
    assert "no-cache" in cache_control
    assert "must-revalidate" in cache_control
    assert "private" in cache_control
    assert "max-age=0" in cache_control


def test_failed_login_uses_generic_error(
    portal_client,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    calls = install_authenticator(
        monkeypatch,
        failed_result,
    )

    response = portal_client.post(
        "/login",
        data={
            "username": " Missing@Example.COM ",
            "password": "wrong-password",
            "next_path": "/onboarding/device",
        },
    )

    assert response.status_code == 401
    assert "Invalid username or password." in response.text
    assert "Missing@Example.COM" in response.text
    assert calls == [
        (
            " Missing@Example.COM ",
            "wrong-password",
        )
    ]


def test_successful_login_establishes_session(
    portal_client,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    install_authenticator(
        monkeypatch,
        successful_result,
    )

    response = portal_client.post(
        "/login",
        data={
            "username": "operator@example.com",
            "password": "valid-password",
            "next_path": "/",
        },
    )

    assert response.status_code == 303
    assert response.headers["location"] == "/"
    assert "ems_admin_session" in portal_client.cookies

    protected_response = portal_client.get("/")

    assert protected_response.status_code == 303
    assert protected_response.headers["location"] == (
        "/onboarding/organization"
    )


def test_successful_login_rejects_external_next_path(
    portal_client,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    install_authenticator(
        monkeypatch,
        successful_result,
    )

    response = portal_client.post(
        "/login",
        data={
            "username": "operator@example.com",
            "password": "valid-password",
            "next_path": "https://evil.example",
        },
    )

    assert response.status_code == 303
    assert response.headers["location"] == (
        "/onboarding/organization"
    )


def test_authenticated_login_page_redirects_existing_session(
    portal_client,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    install_authenticator(
        monkeypatch,
        successful_result,
    )

    login_response = portal_client.post(
        "/login",
        data={
            "username": "operator@example.com",
            "password": "valid-password",
            "next_path": "/",
        },
    )
    assert login_response.status_code == 303

    response = portal_client.get(
        "/login?next_path=%2Fonboarding%2Fsite"
    )

    assert response.status_code == 303
    assert response.headers["location"] == "/onboarding/site"


def test_logout_clears_session(
    portal_client,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    install_authenticator(
        monkeypatch,
        successful_result,
    )

    login_response = portal_client.post(
        "/login",
        data={
            "username": "operator@example.com",
            "password": "valid-password",
            "next_path": "/",
        },
    )
    assert login_response.status_code == 303

    logout_response = portal_client.post("/logout")

    assert logout_response.status_code == 303
    assert logout_response.headers["location"] == "/login"

    protected_response = portal_client.get("/")

    assert protected_response.status_code == 303
    assert protected_response.headers["location"].startswith(
        "/login?next_path="
    )


def test_get_logout_is_not_allowed(
    portal_client,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    install_authenticator(
        monkeypatch,
        successful_result,
    )

    portal_client.post(
        "/login",
        data={
            "username": "operator@example.com",
            "password": "valid-password",
            "next_path": "/",
        },
    )

    response = portal_client.get("/logout")

    assert response.status_code == 405
