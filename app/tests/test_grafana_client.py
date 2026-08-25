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
        headers: dict | None = None,
    ) -> None:
        self.status_code = status_code
        self._payload = payload
        self.text = text
        self.headers = headers or {}

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
async def test_get_datasource_by_uid_scopes_by_org_id(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """
    Regression test: verify the org-scoping mechanism this application
    actually relies on (the X-Grafana-Org-Id header threaded through
    _request(), not organization switching or any other mechanism) is what
    get_datasource_by_uid() uses -- live staging evidence (org 1 empty,
    org 2 holding the real datasource, both GET-by-uid and GET-list
    consistently agreeing) ruled out org-scoping as the live defect, and
    this test pins that behavior so it can't silently regress.
    """
    client = GrafanaClient()
    captured: dict = {}

    async def fake_request(
        method: str,
        path: str,
        *,
        org_id=None,
        json_payload=None,
    ):
        captured["org_id"] = org_id
        return FakeResponse(
            payload={"uid": DATASOURCE_UID, "orgId": org_id, "version": 3}
        )

    monkeypatch.setattr(client, "_request", fake_request)

    result = await client.get_datasource_by_uid(2)

    assert captured["org_id"] == 2
    assert result["orgId"] == 2


@pytest.mark.asyncio
async def test_create_datasource_uses_stable_uid_and_verifies_write(
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
        if method == "POST":
            captured.update(
                {
                    "method": method,
                    "path": path,
                    "org_id": org_id,
                    "json_payload": json_payload,
                }
            )
            return FakeResponse(payload={"message": "Datasource added"})

        assert method == "GET"
        assert path == f"/api/datasources/uid/{DATASOURCE_UID}"
        return FakeResponse(
            payload={"uid": DATASOURCE_UID, "orgId": org_id, "version": 1}
        )

    monkeypatch.setattr(client, "_request", fake_request)

    client.datasource_password = "reader-password"

    verified = await client.create_datasource(7)

    assert captured["method"] == "POST"
    assert captured["path"] == "/api/datasources"
    assert captured["org_id"] == 7
    assert captured["json_payload"]["uid"] == DATASOURCE_UID
    assert captured["json_payload"]["secureJsonData"] == {
        "password": "reader-password"
    }
    assert verified["version"] == 1


@pytest.mark.asyncio
async def test_create_datasource_raises_when_not_found_after_write(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """
    Regression test: a POST that Grafana accepts (HTTP < 400) is not proof
    the datasource actually exists afterward. create_datasource() must
    verify by re-reading, and fail loudly if the datasource is missing.
    """
    client = GrafanaClient()

    async def fake_request(
        method: str,
        path: str,
        *,
        org_id=None,
        json_payload=None,
    ):
        if method == "POST":
            return FakeResponse(payload={"message": "Datasource added"})

        raise GrafanaApiError("Grafana returned HTTP 404: not found")

    monkeypatch.setattr(client, "_request", fake_request)

    with pytest.raises(GrafanaApiError, match="was not found"):
        await client.create_datasource(7)


@pytest.mark.asyncio
async def test_update_datasource_uses_stable_uid_and_current_password(
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
        if method == "PUT":
            captured.update(
                {
                    "method": method,
                    "path": path,
                    "org_id": org_id,
                    "json_payload": json_payload,
                }
            )
            return FakeResponse(payload={"message": "Datasource updated"})

        assert method == "GET"
        if path.endswith("/health"):
            return FakeResponse(payload={"status": "OK"})
        return FakeResponse(
            payload={"uid": DATASOURCE_UID, "orgId": org_id, "version": 2}
        )

    monkeypatch.setattr(client, "_request", fake_request)

    client.datasource_password = "rotated-password"

    verified = await client.update_datasource(7, existing_datasource_id=42)

    assert captured["method"] == "PUT"
    assert captured["path"] == f"/api/datasources/uid/{DATASOURCE_UID}"
    assert captured["org_id"] == 7
    assert captured["json_payload"]["uid"] == DATASOURCE_UID
    assert captured["json_payload"]["secureJsonData"] == {
        "password": "rotated-password"
    }
    assert verified["version"] == 2


@pytest.mark.asyncio
async def test_update_datasource_payload_includes_existing_id_and_org_id(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """
    Regression test: Grafana 11.6's documented UID-update request body
    includes the datasource's numeric `id` and `orgId`. The previous
    implementation omitted both, which is the change this test pins.
    """
    client = GrafanaClient()
    captured: dict = {}

    async def fake_request(
        method: str,
        path: str,
        *,
        org_id=None,
        json_payload=None,
    ):
        if method == "PUT":
            captured["json_payload"] = json_payload
            return FakeResponse(payload={"message": "Datasource updated"})

        if path.endswith("/health"):
            return FakeResponse(payload={"status": "OK"})
        return FakeResponse(
            payload={"uid": DATASOURCE_UID, "orgId": org_id, "version": 2}
        )

    monkeypatch.setattr(client, "_request", fake_request)

    await client.update_datasource(7, existing_datasource_id=42)

    assert captured["json_payload"]["id"] == 42
    assert captured["json_payload"]["orgId"] == 7


@pytest.mark.asyncio
async def test_update_datasource_raises_when_post_update_health_check_fails(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """
    Regression test for the exact failure mode discovered live: the
    reconciliation route returned HTTP 200 (proving GrafanaClient's PUT
    itself didn't raise), yet Grafana org 2's ems-timescaledb datasource
    kept failing its health check with
    "password authentication failed for user \"grafana_reader\"". A PUT
    Grafana accepts is not proof it took effect. update_datasource() must
    detect this via the datasource's own post-write health check and raise
    loudly instead of letting a no-op masquerade as success.
    """
    client = GrafanaClient()

    async def fake_request(
        method: str,
        path: str,
        *,
        org_id=None,
        json_payload=None,
    ):
        if method == "PUT":
            return FakeResponse(payload={"message": "Datasource updated"})

        if path.endswith("/health"):
            return FakeResponse(
                payload={
                    "status": "ERROR",
                    "message": (
                        'password authentication failed for user '
                        '"grafana_reader"'
                    ),
                }
            )
        return FakeResponse(
            payload={"uid": DATASOURCE_UID, "orgId": org_id, "version": 1}
        )

    monkeypatch.setattr(client, "_request", fake_request)

    with pytest.raises(GrafanaApiError, match="did not take effect"):
        await client.update_datasource(7, existing_datasource_id=42)


@pytest.mark.asyncio
async def test_update_datasource_succeeds_when_health_ok_even_if_version_unchanged(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """
    Regression test for a false-negative discovered live on staging
    (2026-08-25): Grafana 11.6's PUT /api/datasources/uid/:uid left
    `version` unchanged (even in the PUT's own response body) despite the
    write genuinely taking effect -- proven live by a fresh PostgreSQL
    session, opened by Grafana immediately after the PUT, authenticating
    successfully as `grafana_reader` (PostgreSQL accepts only the single
    currently-set password for a role, so this is conclusive). Treating an
    unchanged `version` as failure was therefore itself a bug:
    update_datasource() must succeed here based on the health check, not
    raise merely because `version` didn't move.
    """
    client = GrafanaClient()

    async def fake_request(
        method: str,
        path: str,
        *,
        org_id=None,
        json_payload=None,
    ):
        if method == "PUT":
            return FakeResponse(payload={"message": "Datasource updated"})

        if path.endswith("/health"):
            return FakeResponse(payload={"status": "OK"})
        return FakeResponse(
            payload={"uid": DATASOURCE_UID, "orgId": org_id, "version": 1}
        )

    monkeypatch.setattr(client, "_request", fake_request)

    verified = await client.update_datasource(7, existing_datasource_id=42)

    assert verified["version"] == 1


@pytest.mark.asyncio
async def test_update_datasource_error_describes_write_response_without_leaking_password(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """
    Diagnostic enrichment added after the live incident where a PUT
    Grafana accepted (no GrafanaApiError raised) still left `version`
    unchanged: the failure message must describe the actual write
    response (status code, any redirect target) so a future occurrence
    doesn't require external manual probing to diagnose -- while still
    never including the request payload (and therefore never the
    password) anywhere in that description.
    """
    client = GrafanaClient()
    client.datasource_password = "must-never-appear-in-errors"

    async def fake_request(
        method: str,
        path: str,
        *,
        org_id=None,
        json_payload=None,
    ):
        if method == "PUT":
            return FakeResponse(
                status_code=302,
                text="<html>redirecting to login</html>",
                headers={"location": "/login"},
            )
        if path.endswith("/health"):
            return FakeResponse(payload={"status": "ERROR"})
        return FakeResponse(
            payload={"uid": DATASOURCE_UID, "orgId": org_id, "version": 1}
        )

    monkeypatch.setattr(client, "_request", fake_request)

    with pytest.raises(GrafanaApiError) as excinfo:
        await client.update_datasource(7, existing_datasource_id=42)

    message = str(excinfo.value)
    assert "HTTP 302" in message
    assert "/login" in message
    assert "must-never-appear-in-errors" not in message


@pytest.mark.asyncio
async def test_update_datasource_raises_when_disappears_after_write(
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
        if method == "PUT":
            return FakeResponse(payload={"message": "Datasource updated"})

        raise GrafanaApiError("Grafana returned HTTP 404: not found")

    monkeypatch.setattr(client, "_request", fake_request)

    with pytest.raises(GrafanaApiError, match="was not found"):
        await client.update_datasource(7, existing_datasource_id=42)


@pytest.mark.asyncio
async def test_create_and_update_datasource_payloads_do_not_drift(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """Both operations must build their write payload from the same helper."""
    client = GrafanaClient()
    client.datasource_password = "shared-password"

    captured_payloads: list[dict] = []
    version = {"value": 0}

    async def fake_request(
        method: str,
        path: str,
        *,
        org_id=None,
        json_payload=None,
    ):
        if method in ("POST", "PUT"):
            captured_payloads.append(json_payload)
            version["value"] += 1
            return FakeResponse(payload={"message": "ok"})

        return FakeResponse(
            payload={
                "uid": DATASOURCE_UID,
                "orgId": org_id,
                "version": version["value"],
                "status": "OK",
            }
        )

    monkeypatch.setattr(client, "_request", fake_request)

    await client.create_datasource(7)
    await client.update_datasource(7, existing_datasource_id=42)

    create_payload, update_payload = captured_payloads

    # The update payload additionally carries `id`/`orgId`, which only make
    # sense for an existing record, so compare the common fields (i.e. the
    # fields built by _datasource_payload()) rather than the full payloads.
    common_fields = set(create_payload)
    assert common_fields <= set(update_payload)
    assert create_payload == {
        field: update_payload[field] for field in common_fields
    }
    assert update_payload["id"] == 42
    assert update_payload["orgId"] == 7


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
async def test_grafana_api_error_never_contains_password(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """
    GrafanaApiError messages are shown to administrators (via the
    reconciliation route's `error` rendering) and may end up in logs.
    Confirm a failing write never leaks the datasource password into the
    exception text, even though the payload that triggered the failure
    contained it.
    """
    client = GrafanaClient()
    client.datasource_password = "super-secret-value"

    async def fake_request(
        method: str,
        path: str,
        *,
        org_id=None,
        json_payload=None,
    ):
        if method == "PUT":
            raise GrafanaApiError(
                "Grafana returned HTTP 400: Bad Request"
            )
        return FakeResponse(payload={"uid": DATASOURCE_UID, "version": 1})

    monkeypatch.setattr(client, "_request", fake_request)

    with pytest.raises(GrafanaApiError) as excinfo:
        await client.update_datasource(7, existing_datasource_id=42)

    assert "super-secret-value" not in str(excinfo.value)


@pytest.mark.asyncio
async def test_provision_organization_reconciles_existing_datasource(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """
    Regression test for the stale-datasource-credential bug: an existing
    datasource must be reconciled (updated), never silently left as-is, and
    the verified post-write state must be reported back to the caller.
    """
    client = GrafanaClient()
    calls: list[tuple[str, object]] = []

    async def unexpected_list():
        raise AssertionError(
            "Existing mappings must bypass Grafana name lookup."
        )

    async def unexpected_create(name: str):
        raise AssertionError(
            "Existing mappings must not create a Grafana organization."
        )

    async def unexpected_create_datasource(org_id: int):
        raise AssertionError(
            "An existing datasource must be updated, not created."
        )

    async def fake_get_datasource(org_id: int):
        calls.append(("get_datasource", org_id))
        return {"id": 42, "uid": DATASOURCE_UID, "version": 1}

    async def fake_update_datasource(org_id: int, existing_datasource_id):
        calls.append(
            ("update_datasource", (org_id, existing_datasource_id))
        )
        return {"uid": DATASOURCE_UID, "version": 2}

    async def fake_ensure_folder(org_id: int):
        calls.append(("ensure_folder", org_id))

    async def fake_import_dashboards(org_id: int):
        calls.append(("import_dashboards", org_id))

    monkeypatch.setattr(client, "list_organizations", unexpected_list)
    monkeypatch.setattr(client, "create_organization", unexpected_create)
    monkeypatch.setattr(client, "get_datasource_by_uid", fake_get_datasource)
    monkeypatch.setattr(
        client, "create_datasource", unexpected_create_datasource
    )
    monkeypatch.setattr(client, "update_datasource", fake_update_datasource)
    monkeypatch.setattr(client, "ensure_folder", fake_ensure_folder)
    monkeypatch.setattr(
        client, "import_dashboards", fake_import_dashboards
    )

    result = await client.provision_organization(
        organization_name="Organization One",
        existing_org_id=7,
    )

    assert result == {
        "grafana_org_id": 7,
        "datasource_action": "updated",
        "datasource_uid": DATASOURCE_UID,
        "datasource_name": "EMS TimescaleDB",
        "datasource_version": 2,
    }
    assert calls == [
        ("get_datasource", 7),
        ("update_datasource", (7, 42)),
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
        return {"uid": DATASOURCE_UID, "version": 1}

    async def unexpected_update_datasource(org_id: int, existing_datasource_id):
        raise AssertionError(
            "A missing datasource must be created, not updated."
        )

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
        "update_datasource",
        unexpected_update_datasource,
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

    assert result == {
        "grafana_org_id": 9,
        "datasource_action": "created",
        "datasource_uid": DATASOURCE_UID,
        "datasource_name": "EMS TimescaleDB",
        "datasource_version": 1,
    }
    assert calls == [
        ("list_organizations", None),
        ("create_organization", "Organization Nine"),
        ("get_datasource", 9),
        ("create_datasource", 9),
        ("ensure_folder", 9),
        ("import_dashboards", 9),
    ]
