from contextlib import asynccontextmanager

import pytest

from src.user_management_service import (
    change_managed_user_role,
    create_managed_user,
    list_manageable_users,
    set_managed_user_active,
)


class FakeCursor:
    def __init__(
        self,
        *,
        row: dict | None = None,
        rows: list[dict] | None = None,
    ) -> None:
        self.row = row
        self.rows = rows or []
        self.statement: str | None = None
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

    async def fetchone(self) -> dict | None:
        return self.row

    async def fetchall(self) -> list[dict]:
        return self.rows


class FakeConnection:
    def __init__(self, cursor: FakeCursor) -> None:
        self.fake_cursor = cursor
        self.committed = False
        self.rolled_back = False

    def cursor(self) -> FakeCursor:
        return self.fake_cursor

    async def commit(self) -> None:
        self.committed = True

    async def rollback(self) -> None:
        self.rolled_back = True


def install_connection(
    monkeypatch: pytest.MonkeyPatch,
    connection: FakeConnection,
) -> None:
    @asynccontextmanager
    async def fake_database_connection():
        yield connection

    monkeypatch.setattr(
        "src.user_management_service.database_connection",
        fake_database_connection,
    )


@pytest.mark.asyncio
async def test_list_manageable_users_calls_controlled_function(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    expected = [
        {
            "portal_user_id": 42,
            "username": "viewer@example.com",
            "display_name": "Test Viewer",
            "email": "viewer@example.com",
            "role_code": "VIEWER",
            "organization_id": (
                "11111111-1111-1111-1111-111111111111"
            ),
            "is_active": True,
        }
    ]
    cursor = FakeCursor(rows=expected)
    connection = FakeConnection(cursor)
    install_connection(monkeypatch, connection)

    result = await list_manageable_users(actor_portal_user_id=10)

    assert "admin.list_manageable_portal_users" in cursor.statement
    assert cursor.parameters == (10,)
    assert result == expected
    assert connection.committed is False
    assert connection.rolled_back is True


@pytest.mark.asyncio
async def test_create_managed_user_commits(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    cursor = FakeCursor(row={"portal_user_id": 42})
    connection = FakeConnection(cursor)
    install_connection(monkeypatch, connection)

    result = await create_managed_user(
        actor_portal_user_id=10,
        username="viewer@example.com",
        display_name="Test Viewer",
        email="viewer@example.com",
        password_hash="$argon2id$test-placeholder",
        role_code="VIEWER",
        organization_id=(
            "11111111-1111-1111-1111-111111111111"
        ),
    )

    assert "admin.create_managed_portal_user" in cursor.statement
    assert cursor.parameters == (
        10,
        "viewer@example.com",
        "Test Viewer",
        "viewer@example.com",
        "$argon2id$test-placeholder",
        "VIEWER",
        "11111111-1111-1111-1111-111111111111",
    )
    assert result == 42
    assert connection.committed is True
    assert connection.rolled_back is False


@pytest.mark.asyncio
async def test_change_managed_user_role_commits(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    cursor = FakeCursor()
    connection = FakeConnection(cursor)
    install_connection(monkeypatch, connection)

    await change_managed_user_role(
        actor_portal_user_id=10,
        target_portal_user_id=42,
        role_code="OPERATOR",
        organization_id=(
            "11111111-1111-1111-1111-111111111111"
        ),
    )

    assert "admin.change_managed_portal_user_role" in cursor.statement
    assert cursor.parameters == (
        10,
        42,
        "OPERATOR",
        "11111111-1111-1111-1111-111111111111",
    )
    assert connection.committed is True


@pytest.mark.asyncio
async def test_set_managed_user_active_commits(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    cursor = FakeCursor()
    connection = FakeConnection(cursor)
    install_connection(monkeypatch, connection)

    await set_managed_user_active(
        actor_portal_user_id=10,
        target_portal_user_id=42,
        is_active=False,
    )

    assert "admin.set_managed_portal_user_active" in cursor.statement
    assert cursor.parameters == (10, 42, False)
    assert connection.committed is True
