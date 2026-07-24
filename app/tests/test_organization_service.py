from contextlib import asynccontextmanager

import pytest
from psycopg.errors import OperationalError

from src.onboarding.organization_service import create_organization


class FakeCursor:
    def __init__(self, row: dict) -> None:
        self.row = row
        self.statement = None
        self.parameters = None

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

    async def fetchone(self) -> dict:
        return self.row


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


@pytest.mark.asyncio
async def test_create_organization_calls_controlled_function(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    cursor = FakeCursor(
        {
            "organization_result": {
                "success": True,
                "entity_type": "ORGANIZATION",
                "entity_id": "org-1",
                "organization_id": "org-1",
                "organization_code": "ORG_1",
                "organization_name": "Organization One",
                "timezone": "Asia/Kolkata",
                "lifecycle_status": "ACTIVE",
                "commissioning_status": None,
                "validation_warnings": [],
                "blocking_conditions": [],
                "audit_transaction_id": (
                    "11111111-1111-4111-8111-111111111111"
                ),
            }
        }
    )
    connection = FakeConnection(cursor)

    @asynccontextmanager
    async def fake_database_connection():
        yield connection

    monkeypatch.setattr(
        "src.onboarding.organization_service.database_connection",
        fake_database_connection,
    )

    result = await create_organization(
        name="Organization One",
        code="ORG_1",
        timezone="Asia/Kolkata",
        lifecycle_status="ACTIVE",
        requested_by="superadmin@example.com",
    )

    assert "admin.create_organization" in cursor.statement
    assert cursor.parameters == (
        "Organization One",
        "ORG_1",
        "Asia/Kolkata",
        "ACTIVE",
        "superadmin@example.com",
    )
    assert connection.committed is True
    assert connection.rolled_back is False
    assert result["entity_type"] == "ORGANIZATION"
    assert result["entity_id"] == "org-1"
    assert result["organization_code"] == "ORG_1"


@pytest.mark.asyncio
async def test_create_organization_rolls_back_database_error(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    class FailingCursor(FakeCursor):
        async def execute(
            self,
            statement: str,
            parameters: tuple,
        ) -> None:
            raise OperationalError("database unavailable")

    cursor = FailingCursor({})
    connection = FakeConnection(cursor)

    @asynccontextmanager
    async def fake_database_connection():
        yield connection

    monkeypatch.setattr(
        "src.onboarding.organization_service.database_connection",
        fake_database_connection,
    )

    with pytest.raises(OperationalError):
        await create_organization(
            name="Organization One",
            code="ORG_1",
            timezone="Asia/Kolkata",
            lifecycle_status="ACTIVE",
            requested_by="superadmin@example.com",
        )

    assert connection.committed is False
    assert connection.rolled_back is True

@pytest.mark.asyncio
async def test_get_grafana_provisioning_reads_controlled_function(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    cursor = FakeCursor(
        {
            "provisioning_result": {
                "organization_id": "org-1",
                "provisioning_status": "PROVISIONED",
                "grafana_org_id": 7,
                "attempt_count": 1,
                "last_error": None,
            }
        }
    )
    connection = FakeConnection(cursor)

    @asynccontextmanager
    async def fake_database_connection():
        yield connection

    monkeypatch.setattr(
        "src.onboarding.organization_service.database_connection",
        fake_database_connection,
    )

    from src.onboarding.organization_service import (
        get_grafana_provisioning,
    )

    result = await get_grafana_provisioning("org-1")

    assert "admin.get_grafana_provisioning" in cursor.statement
    assert cursor.parameters == ("org-1",)
    assert connection.committed is False
    assert connection.rolled_back is True
    assert result["grafana_org_id"] == 7


@pytest.mark.asyncio
async def test_mark_grafana_provisioning_pending_commits(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    cursor = FakeCursor(
        {
            "provisioning_result": {
                "organization_id": "org-1",
                "provisioning_status": "PENDING",
                "grafana_org_id": None,
                "attempt_count": 2,
                "last_error": None,
            }
        }
    )
    connection = FakeConnection(cursor)

    @asynccontextmanager
    async def fake_database_connection():
        yield connection

    monkeypatch.setattr(
        "src.onboarding.organization_service.database_connection",
        fake_database_connection,
    )

    from src.onboarding.organization_service import (
        mark_grafana_provisioning_pending,
    )

    result = await mark_grafana_provisioning_pending("org-1")

    assert "admin.mark_grafana_provisioning_pending" in cursor.statement
    assert cursor.parameters == ("org-1",)
    assert connection.committed is True
    assert connection.rolled_back is False
    assert result["provisioning_status"] == "PENDING"


@pytest.mark.asyncio
async def test_mark_grafana_provisioning_failed_commits_error(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    cursor = FakeCursor(
        {
            "provisioning_result": {
                "organization_id": "org-1",
                "provisioning_status": "FAILED",
                "grafana_org_id": None,
                "attempt_count": 2,
                "last_error": "Grafana unavailable",
            }
        }
    )
    connection = FakeConnection(cursor)

    @asynccontextmanager
    async def fake_database_connection():
        yield connection

    monkeypatch.setattr(
        "src.onboarding.organization_service.database_connection",
        fake_database_connection,
    )

    from src.onboarding.organization_service import (
        mark_grafana_provisioning_failed,
    )

    result = await mark_grafana_provisioning_failed(
        "org-1",
        "Grafana unavailable",
    )

    assert "admin.mark_grafana_provisioning_failed" in cursor.statement
    assert cursor.parameters == (
        "org-1",
        "Grafana unavailable",
    )
    assert connection.committed is True
    assert connection.rolled_back is False
    assert result["provisioning_status"] == "FAILED"


@pytest.mark.asyncio
async def test_mark_grafana_provisioning_complete_commits_mapping(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    cursor = FakeCursor(
        {
            "provisioning_result": {
                "organization_id": "org-1",
                "provisioning_status": "PROVISIONED",
                "grafana_org_id": 7,
                "attempt_count": 2,
                "last_error": None,
            }
        }
    )
    connection = FakeConnection(cursor)

    @asynccontextmanager
    async def fake_database_connection():
        yield connection

    monkeypatch.setattr(
        "src.onboarding.organization_service.database_connection",
        fake_database_connection,
    )

    from src.onboarding.organization_service import (
        mark_grafana_provisioning_complete,
    )

    result = await mark_grafana_provisioning_complete(
        "org-1",
        7,
    )

    assert "admin.mark_grafana_provisioning_complete" in cursor.statement
    assert cursor.parameters == (
        "org-1",
        7,
    )
    assert connection.committed is True
    assert connection.rolled_back is False
    assert result["provisioning_status"] == "PROVISIONED"
    assert result["grafana_org_id"] == 7
