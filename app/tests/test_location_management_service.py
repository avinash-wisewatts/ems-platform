from contextlib import asynccontextmanager

import pytest
from psycopg.errors import OperationalError

from src.location_management_service import (
    create_building,
    create_floor,
    create_site,
    create_space,
    list_accessible_physical_locations,
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
        "src.location_management_service.database_connection",
        fake_database_connection,
    )


@pytest.mark.asyncio
@pytest.mark.parametrize(
    (
        "operation",
        "kwargs",
        "function_name",
        "parameters",
        "result_column",
        "entity_type",
        "entity_id",
    ),
    [
        (
            create_site,
            {
                "portal_user_id": 10,
                "organization_id": "11111111-1111-1111-1111-111111111111",
                "name": "Main Site",
                "code": "MAIN_SITE",
                "timezone": "Europe/London",
                "lifecycle_status": "ACTIVE",
            },
            "admin.create_site",
            (
                10,
                "11111111-1111-1111-1111-111111111111",
                "Main Site",
                "MAIN_SITE",
                "Europe/London",
                "ACTIVE",
            ),
            "site_result",
            "SITE",
            "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",
        ),
        (
            create_building,
            {
                "portal_user_id": 10,
                "site_id": "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",
                "name": "Building A",
                "code": "BLDG_A",
            },
            "admin.create_building",
            (
                10,
                "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",
                "Building A",
                "BLDG_A",
            ),
            "building_result",
            "BUILDING",
            "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb",
        ),
        (
            create_floor,
            {
                "portal_user_id": 10,
                "building_id": "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb",
                "name": "First Floor",
                "code": "FLOOR_1",
            },
            "admin.create_floor",
            (
                10,
                "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb",
                "First Floor",
                "FLOOR_1",
            ),
            "floor_result",
            "FLOOR",
            "cccccccc-cccc-cccc-cccc-cccccccccccc",
        ),
        (
            create_space,
            {
                "portal_user_id": 10,
                "floor_id": "cccccccc-cccc-cccc-cccc-cccccccccccc",
                "name": "Plant Room",
                "code": "PLANT_ROOM",
            },
            "admin.create_space",
            (
                10,
                "cccccccc-cccc-cccc-cccc-cccccccccccc",
                "Plant Room",
                "PLANT_ROOM",
            ),
            "space_result",
            "SPACE",
            "dddddddd-dddd-dddd-dddd-dddddddddddd",
        ),
    ],
)
async def test_creation_calls_controlled_function_and_commits(
    monkeypatch: pytest.MonkeyPatch,
    operation,
    kwargs: dict,
    function_name: str,
    parameters: tuple,
    result_column: str,
    entity_type: str,
    entity_id: str,
) -> None:
    entity_key = f"{entity_type.lower()}_id"
    cursor = FakeCursor(
        row={
            result_column: {
                entity_key: entity_id,
                "lifecycle_status": "ACTIVE",
                "audit_transaction_id": (
                    "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee"
                ),
            }
        }
    )
    connection = FakeConnection(cursor)
    install_connection(monkeypatch, connection)

    result = await operation(**kwargs)

    assert function_name in cursor.statement
    assert cursor.parameters == parameters
    assert connection.committed is True
    assert connection.rolled_back is False
    assert result["entity_type"] == entity_type
    assert result["entity_id"] == entity_id
    assert result[entity_key] == entity_id


@pytest.mark.asyncio
async def test_list_accessible_physical_locations_rolls_back_read(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    expected = [
        {
            "organization_id": "11111111-1111-1111-1111-111111111111",
            "organization_code": "ORG_1",
            "organization_name": "Organization One",
            "site_id": "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",
            "site_code": "SITE_1",
            "site_name": "Site One",
            "building_id": None,
            "building_code": None,
            "building_name": None,
            "floor_id": None,
            "floor_code": None,
            "floor_name": None,
            "space_id": None,
            "space_code": None,
            "space_name": None,
        }
    ]
    cursor = FakeCursor(rows=expected)
    connection = FakeConnection(cursor)
    install_connection(monkeypatch, connection)

    result = await list_accessible_physical_locations(
        portal_user_id=10,
    )

    assert "admin.list_accessible_physical_locations" in cursor.statement
    assert cursor.parameters == (10,)
    assert result == expected
    assert connection.committed is False
    assert connection.rolled_back is True


@pytest.mark.asyncio
async def test_creation_rolls_back_database_error(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    class FailingCursor(FakeCursor):
        async def execute(
            self,
            statement: str,
            parameters: tuple,
        ) -> None:
            raise OperationalError("database unavailable")

    cursor = FailingCursor()
    connection = FakeConnection(cursor)
    install_connection(monkeypatch, connection)

    with pytest.raises(OperationalError):
        await create_site(
            portal_user_id=10,
            organization_id="11111111-1111-1111-1111-111111111111",
            name="Main Site",
            code="MAIN_SITE",
            timezone="Europe/London",
            lifecycle_status="ACTIVE",
        )

    assert connection.committed is False
    assert connection.rolled_back is True
