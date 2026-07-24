from contextlib import asynccontextmanager

import pytest

from src.onboarding.repository import list_accessible_sites


class FakeCursor:
    def __init__(self, rows: list[dict]) -> None:
        self.rows = rows
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

    async def fetchall(self) -> list[dict]:
        return self.rows


class FakeConnection:
    def __init__(self, cursor: FakeCursor) -> None:
        self.fake_cursor = cursor

    def cursor(self) -> FakeCursor:
        return self.fake_cursor


@pytest.mark.asyncio
async def test_list_accessible_sites_uses_controlled_scope_function(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    expected = [
        {
            "id": "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",
            "organization_id": (
                "11111111-1111-1111-1111-111111111111"
            ),
            "organization_code": "TEST_ORG",
            "organization_name": "Test Organization",
            "site_code": "SITE_ONE",
            "site_name": "Site One",
            "timezone": "Asia/Kolkata",
            "address": None,
            "is_active": True,
        }
    ]

    cursor = FakeCursor(expected)
    connection = FakeConnection(cursor)

    @asynccontextmanager
    async def fake_database_connection():
        yield connection

    monkeypatch.setattr(
        "src.onboarding.repository.database_connection",
        fake_database_connection,
    )

    result = await list_accessible_sites(
        portal_user_id=42,
    )

    assert result == expected
    assert "admin.list_accessible_sites" in cursor.statement
    assert cursor.parameters == (42,)
