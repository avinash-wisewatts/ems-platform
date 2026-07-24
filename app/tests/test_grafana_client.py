import json
from pathlib import Path

import httpx
import pytest

from src.grafana_client import (
    DATASOURCE_UID,
    FOLDER_UID,
    GrafanaApiError,
    GrafanaClient,
)


class FakeResponse:
    def __init__(
        self,
        *,
        status_code: int = 200,
        payload=None,
        text: str = "",
    ) -> None:
        self.status_code = status_code
        self._payload = payload
        self.text = text

    def json(self):
        return self._payload


@pytest.mark.asyncio
async def test_create_organization_returns_grafana_org_id(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    client = GrafanaClient()

    async def fake_request(
        method: str,
        path: str,
        *,
        org_id=None,
        json_payload=None,
    ):
        assert method == "POST"
        assert path == "/api/orgs"
        assert org_id is None
        assert json_payload == {"name": "Organization One"}

        return FakeResponse(
            payload={
                "message": "Organization created",
                "orgId": 7,
            }
        )

    monkeypatch.setattr(client, "_request", fake_request)

    organization_id = await client.create_organization(
        "Organization One"
    )

    assert organization_id == 7


@pytest.mark.asyncio
async def test_create_organization_rejects_missing_org_id(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    client = GrafanaClient()

    async def fake_request(*args, **kwargs):
        return FakeResponse(
            payload={"message": "Organization created"}
        )

    monkeypatch.setattr(client, "_request", fake_request)

    with pytest.raises(
        GrafanaApiError,
        match="did not include orgId",
    ):
        await client.create_organization("Organization One")


@pytest.mark.asyncio
async def test_get_datasource_by_uid_returns_none_for_404(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    client = GrafanaClient()

    async def fake_request(*args, **kwargs):
        raise GrafanaApiError(
            "Grafana returned HTTP 404: datasource not found"
        )

    monkeypatch.setattr(client, "_request", fake_request)

    result = await client.get_datasource_by_uid(7)

    assert result is None


@pytest.mark.asyncio
async def test_create_datasource_uses_stable_uid(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    client = GrafanaClient()
    captured: dict = {}

    async def fake_request(
        method: str,
        path: str,
        *,
        org_id=None,
        json_payload=None,
    ):
        captured.update(
            {
                "method": method,
                "path": path,
                "org_id": org_id,
                "json_payload": json_payload,
            }
        )

        return FakeResponse(payload={"message": "Datasource added"})

    monkeypatch.setattr(client, "_request", fake_request)

    client.datasource_password = "reader-password"

    await client.create_datasource(7)

    assert captured["method"] == "POST"
    assert captured["path"] == "/api/datasources"
    assert captured["org_id"] == 7
    assert captured["json_payload"]["uid"] == DATASOURCE_UID
    assert captured["json_payload"]["secureJsonData"] == {
        "password": "reader-password"
    }


@pytest.mark.asyncio
async def test_ensure_folder_creates_missing_folder(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    client = GrafanaClient()
    calls: list[tuple[str, str, int | None]] = []

    async def fake_request(
        method: str,
        path: str,
        *,
        org_id=None,
        json_payload=None,
    ):
        calls.append((method, path, org_id))

        if method == "GET":
            raise GrafanaApiError(
                "Grafana returned HTTP 404: folder not found"
            )

        assert json_payload == {
            "uid": FOLDER_UID,
            "title": "EMS",
        }

        return FakeResponse(payload={"uid": FOLDER_UID})

    monkeypatch.setattr(client, "_request", fake_request)

    await client.ensure_folder(7)

    assert calls == [
        ("GET", f"/api/folders/{FOLDER_UID}", 7),
        ("POST", "/api/folders", 7),
    ]


@pytest.mark.asyncio
async def test_import_dashboards_posts_each_json_file(
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
) -> None:
    dashboard_one = {
        "uid": "dashboard-one",
        "title": "Dashboard One",
    }
    dashboard_two = {
        "uid": "dashboard-two",
        "title": "Dashboard Two",
    }

    first = tmp_path / "energy"
    second = tmp_path / "environment"
    first.mkdir()
    second.mkdir()

    (first / "one.json").write_text(
        json.dumps(dashboard_one),
        encoding="utf-8",
    )
    (second / "two.json").write_text(
        json.dumps(dashboard_two),
        encoding="utf-8",
    )

    monkeypatch.setattr(
        "src.grafana_client.DASHBOARD_DIRECTORY",
        tmp_path,
    )

    client = GrafanaClient()
    payloads: list[dict] = []

    async def fake_request(
        method: str,
        path: str,
        *,
        org_id=None,
        json_payload=None,
    ):
        assert method == "POST"
        assert path == "/api/dashboards/db"
        assert org_id == 7

        payloads.append(json_payload)

        return FakeResponse(
            payload={"status": "success"}
        )

    monkeypatch.setattr(client, "_request", fake_request)

    await client.import_dashboards(7)

    assert len(payloads) == 2
    assert {
        payload["dashboard"]["uid"]
        for payload in payloads
    } == {
        "dashboard-one",
        "dashboard-two",
    }
    assert all(
        payload["folderUid"] == FOLDER_UID
        for payload in payloads
    )
    assert all(payload["overwrite"] is True for payload in payloads)


@pytest.mark.asyncio
async def test_request_wraps_http_failure(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    client = GrafanaClient()

    class FailingAsyncClient:
        async def __aenter__(self):
            return self

        async def __aexit__(
            self,
            exc_type,
            exc,
            traceback,
        ) -> None:
            return None

        async def request(self, *args, **kwargs):
            raise httpx.ConnectError(
                "connection refused"
            )

    monkeypatch.setattr(
        "src.grafana_client.httpx.AsyncClient",
        lambda **kwargs: FailingAsyncClient(),
    )

    with pytest.raises(
        GrafanaApiError,
        match="Grafana request failed",
    ):
        await client.list_organizations()

@pytest.mark.asyncio
async def test_provision_organization_reuses_existing_org_id(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    client = GrafanaClient()
    calls: list[tuple[str, int]] = []

    async def unexpected_list():
        raise AssertionError(
            "Existing mappings must bypass Grafana name lookup."
        )

    async def unexpected_create(name: str):
        raise AssertionError(
            "Existing mappings must not create a Grafana organization."
        )

    async def fake_get_datasource(org_id: int):
        calls.append(("get_datasource", org_id))
        return {"uid": DATASOURCE_UID}

    async def fake_ensure_folder(org_id: int):
        calls.append(("ensure_folder", org_id))

    async def fake_import_dashboards(org_id: int):
        calls.append(("import_dashboards", org_id))

    monkeypatch.setattr(
        client,
        "list_organizations",
        unexpected_list,
    )
    monkeypatch.setattr(
        client,
        "create_organization",
        unexpected_create,
    )
    monkeypatch.setattr(
        client,
        "get_datasource_by_uid",
        fake_get_datasource,
    )
    monkeypatch.setattr(
        client,
        "ensure_folder",
        fake_ensure_folder,
    )
    monkeypatch.setattr(
        client,
        "import_dashboards",
        fake_import_dashboards,
    )

    result = await client.provision_organization(
        organization_name="Organization One",
        existing_org_id=7,
    )

    assert result == 7
    assert calls == [
        ("get_datasource", 7),
        ("ensure_folder", 7),
        ("import_dashboards", 7),
    ]


@pytest.mark.asyncio
async def test_provision_organization_creates_missing_resources(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    client = GrafanaClient()
    calls: list[tuple[str, object]] = []

    async def fake_list_organizations():
        calls.append(("list_organizations", None))
        return []

    async def fake_create_organization(name: str):
        calls.append(("create_organization", name))
        return 9

    async def fake_get_datasource(org_id: int):
        calls.append(("get_datasource", org_id))
        return None

    async def fake_create_datasource(org_id: int):
        calls.append(("create_datasource", org_id))

    async def fake_ensure_folder(org_id: int):
        calls.append(("ensure_folder", org_id))

    async def fake_import_dashboards(org_id: int):
        calls.append(("import_dashboards", org_id))

    monkeypatch.setattr(
        client,
        "list_organizations",
        fake_list_organizations,
    )
    monkeypatch.setattr(
        client,
        "create_organization",
        fake_create_organization,
    )
    monkeypatch.setattr(
        client,
        "get_datasource_by_uid",
        fake_get_datasource,
    )
    monkeypatch.setattr(
        client,
        "create_datasource",
        fake_create_datasource,
    )
    monkeypatch.setattr(
        client,
        "ensure_folder",
        fake_ensure_folder,
    )
    monkeypatch.setattr(
        client,
        "import_dashboards",
        fake_import_dashboards,
    )

    result = await client.provision_organization(
        organization_name="Organization Nine",
    )

    assert result == 9
    assert calls == [
        ("list_organizations", None),
        ("create_organization", "Organization Nine"),
        ("get_datasource", 9),
        ("create_datasource", 9),
        ("ensure_folder", 9),
        ("import_dashboards", 9),
    ]
