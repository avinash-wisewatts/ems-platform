from contextlib import asynccontextmanager

import pytest
from psycopg.errors import OperationalError

from src.asset_management_service import (
    create_asset,
    list_accessible_assets,
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

    async def __aexit__(self, exc_type, exc, traceback) -> None:
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
        "src.asset_management_service.database_connection",
        fake_database_connection,
    )


@pytest.mark.asyncio
async def test_create_asset_calls_controlled_function_and_commits(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    cursor = FakeCursor(
        row={
            "asset_result": {
                "success": True,
                "entity_type": "ASSET",
                "entity_id": (
                    "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
                ),
                "asset_id": (
                    "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
                ),
                "lifecycle_status": "ACTIVE",
                "commissioning_status": "INCOMPLETE",
                "validation_warnings": [],
                "blocking_conditions": [
                    "MISSING_DIRECT_METER"
                ],
                "audit_transaction_id": (
                    "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
                ),
            }
        }
    )
    connection = FakeConnection(cursor)
    install_connection(monkeypatch, connection)

    result = await create_asset(
        portal_user_id=10,
        organization_id=(
            "11111111-1111-4111-8111-111111111111"
        ),
        site_id="22222222-2222-4222-8222-222222222222",
        asset_name="Main Chiller",
        asset_type_id=(
            "33333333-3333-4333-8333-333333333333"
        ),
        lifecycle_status="ACTIVE",
        metering_requirement="DIRECT_METER_REQUIRED",
        parent_asset_id=None,
        building_id=(
            "44444444-4444-4444-8444-444444444444"
        ),
        floor_id=None,
        space_id=None,
    )

    assert "admin.create_asset" in cursor.statement
    assert cursor.parameters == (
        10,
        "11111111-1111-4111-8111-111111111111",
        "22222222-2222-4222-8222-222222222222",
        "Main Chiller",
        "33333333-3333-4333-8333-333333333333",
        "ACTIVE",
        "DIRECT_METER_REQUIRED",
        "44444444-4444-4444-8444-444444444444",
        None,
        None,
        None,
    )
    assert connection.committed is True
    assert connection.rolled_back is False
    assert result["entity_type"] == "ASSET"
    assert result["entity_id"] == (
        "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
    )
    assert result["commissioning_status"] == "INCOMPLETE"
    assert result["blocking_conditions"] == [
        "MISSING_DIRECT_METER"
    ]


@pytest.mark.asyncio
async def test_list_accessible_assets_rolls_back_read(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    expected = [
        {
            "organization_id": (
                "11111111-1111-4111-8111-111111111111"
            ),
            "organization_code": "ORG_1",
            "organization_name": "Organization One",
            "site_id": "22222222-2222-4222-8222-222222222222",
            "site_code": "SITE_1",
            "site_name": "Main Site",
            "asset_id": "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
            "asset_name": "Main Chiller",
            "asset_type_id": None,
            "asset_type_name": None,
            "parent_asset_id": None,
            "parent_asset_name": None,
            "building_id": None,
            "building_name": None,
            "floor_id": None,
            "floor_name": None,
            "space_id": None,
            "space_name": None,
            "lifecycle_status": "ACTIVE",
            "metering_requirement": "NOT_REQUIRED",
            "coverage_status": "NOT_REQUIRED",
        }
    ]
    cursor = FakeCursor(rows=expected)
    connection = FakeConnection(cursor)
    install_connection(monkeypatch, connection)

    result = await list_accessible_assets(
        portal_user_id=10,
    )

    assert "admin.list_accessible_assets" in cursor.statement
    assert cursor.parameters == (10,)
    assert result == expected
    assert connection.committed is False
    assert connection.rolled_back is True


@pytest.mark.asyncio
async def test_create_asset_rolls_back_database_error(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    class FailingCursor(FakeCursor):
        async def execute(
            self,
            statement: str,
            parameters: tuple,
        ) -> None:
            raise OperationalError("database unavailable")

    connection = FakeConnection(FailingCursor())
    install_connection(monkeypatch, connection)

    with pytest.raises(OperationalError):
        await create_asset(
            portal_user_id=10,
            organization_id=(
                "11111111-1111-4111-8111-111111111111"
            ),
            site_id=(
                "22222222-2222-4222-8222-222222222222"
            ),
            asset_name="Main Chiller",
            asset_type_id=None,
            lifecycle_status="ACTIVE",
            metering_requirement="NOT_REQUIRED",
            parent_asset_id=None,
            building_id=None,
            floor_id=None,
            space_id=None,
        )

    assert connection.committed is False
    assert connection.rolled_back is True


@pytest.mark.asyncio
async def test_update_asset_calls_controlled_function_and_commits(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    cursor = FakeCursor(
        row={
            "asset_result": {
                "success": True,
                "entity_type": "ASSET",
                "entity_id": (
                    "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
                ),
                "asset_id": (
                    "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
                ),
                "lifecycle_status": "INACTIVE",
                "commissioning_status": "NOT_STARTED",
                "validation_warnings": [],
                "blocking_conditions": [],
                "audit_transaction_id": (
                    "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
                ),
            }
        }
    )
    connection = FakeConnection(cursor)
    install_connection(monkeypatch, connection)

    from src.asset_management_service import update_asset

    result = await update_asset(
        portal_user_id=10,
        asset_id="aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
        asset_name="Updated Chiller",
        asset_type_id=(
            "33333333-3333-4333-8333-333333333333"
        ),
        lifecycle_status="INACTIVE",
        metering_requirement="DIRECT_METER_REQUIRED",
        parent_asset_id=(
            "44444444-4444-4444-8444-444444444444"
        ),
        building_id=(
            "55555555-5555-4555-8555-555555555555"
        ),
        floor_id=(
            "66666666-6666-4666-8666-666666666666"
        ),
        space_id=(
            "77777777-7777-4777-8777-777777777777"
        ),
    )

    assert "admin.update_asset" in cursor.statement
    assert cursor.parameters == (
        10,
        "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
        "Updated Chiller",
        "33333333-3333-4333-8333-333333333333",
        "INACTIVE",
        "DIRECT_METER_REQUIRED",
        "55555555-5555-4555-8555-555555555555",
        "66666666-6666-4666-8666-666666666666",
        "77777777-7777-4777-8777-777777777777",
        "44444444-4444-4444-8444-444444444444",
    )
    assert connection.committed is True
    assert connection.rolled_back is False
    assert result["entity_type"] == "ASSET"
    assert result["lifecycle_status"] == "INACTIVE"


@pytest.mark.asyncio
async def test_update_asset_rolls_back_database_error(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    class FailingCursor(FakeCursor):
        async def execute(
            self,
            statement: str,
            parameters: tuple,
        ) -> None:
            raise OperationalError("database unavailable")

    connection = FakeConnection(FailingCursor())
    install_connection(monkeypatch, connection)

    from src.asset_management_service import update_asset

    with pytest.raises(OperationalError):
        await update_asset(
            portal_user_id=10,
            asset_id=(
                "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
            ),
            asset_name="Updated Chiller",
            asset_type_id=(
                "33333333-3333-4333-8333-333333333333"
            ),
            lifecycle_status="INACTIVE",
            metering_requirement="NOT_REQUIRED",
            parent_asset_id=None,
            building_id=None,
            floor_id=None,
            space_id=None,
        )

    assert connection.committed is False
    assert connection.rolled_back is True
