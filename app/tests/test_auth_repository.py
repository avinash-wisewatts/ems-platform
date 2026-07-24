from contextlib import asynccontextmanager

import pytest

from src.auth.repository import (
    get_portal_user_for_authentication,
)


class FakeCursor:
    def __init__(self, row: dict) -> None:
        self.row = row
        self.statement: str = ""
        self.parameters: tuple | None = None

    async def __aenter__(self):
        return self

    async def __aexit__(
        self,
        exc_type,
        exc,
        traceback,
    ) -> None:
        return None

    async def execute(
        self,
        statement: str,
        parameters: tuple,
    ) -> None:
        self.statement = statement
        self.parameters = parameters

    async def fetchone(self) -> dict:
        return self.row


class FakeConnection:
    def __init__(self, cursor: FakeCursor) -> None:
        self.fake_cursor = cursor

    def cursor(self) -> FakeCursor:
        return self.fake_cursor


@pytest.mark.asyncio
async def test_authentication_repository_loads_selected_site_scope(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    row = {
        "portal_user_id": 42,
        "username": "operator@example.com",
        "display_name": "Scoped Operator",
        "password_hash": "$argon2id$test-placeholder",
        "role_code": "OPERATOR",
        "organization_id": (
            "11111111-1111-1111-1111-111111111111"
        ),
        "access_scope_mode": "SELECTED_SITES",
        "site_ids": [
            "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",
            "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb",
        ],
        "is_active": True,
        "failed_login_count": 0,
        "locked_until": None,
    }

    cursor = FakeCursor(row)
    connection = FakeConnection(cursor)

    @asynccontextmanager
    async def fake_database_connection():
        yield connection

    monkeypatch.setattr(
        "src.auth.repository.database_connection",
        fake_database_connection,
    )

    result = await get_portal_user_for_authentication(
        "operator@example.com"
    )

    assert result is not None
    assert result.access_scope_mode == "SELECTED_SITES"
    assert result.site_ids == (
        "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",
        "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb",
    )
    assert "access_scope_mode" in cursor.statement
    assert "site_ids" in cursor.statement
    assert cursor.parameters == ("operator@example.com",)
