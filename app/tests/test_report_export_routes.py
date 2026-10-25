"""Reports tab -- /api/v1 report-export routes: authentication, site and job
authorization (404, never 403, for another user's job or an inaccessible
site), request validation, immediate vs background mode, the JSON /
cross-site guard on the POST routes, retry and download security.

Data access is faked: the Analytics fetchers (tests/report_export_fixtures.py)
and an in-memory job store standing in for the migration 309 functions,
which enforce the same owner rule (tests/test_report_export_jobs_db.py).
"""

from __future__ import annotations

import io
import zipfile
from datetime import datetime, timedelta, timezone
from uuid import UUID, uuid4

import pytest

from src.auth.models import AuthenticatedPortalUser
from src.auth.security import AuthenticationStatus
from src.auth.service import AuthenticationResult
from src.config import get_settings
from src.report_export_worker import ActiveJobLimitError
from tests.report_export_fixtures import OTHER_SITE_ID, SITE, SITE_ID, FakeAnalytics


ROUTER = "src.routers.report_exports"
FROM, TO = "2026-09-20T00:00:00Z", "2026-09-20T03:00:00Z"
JSON = {"Content-Type": "application/json"}


class FakeJobs:
    """In-memory stand-in for the migration 309 portal functions (owner-only)."""

    def __init__(self, max_active: int = 3) -> None:
        self.rows: dict[str, dict] = {}
        self.files: dict[str, tuple[str, bytes]] = {}
        self.max_active = max_active

    async def create(self, portal_user_id, site_id, request, max_active, asset_ids):
        if str(site_id) != SITE_ID:
            return None
        active = [r for r in self.rows.values() if r["portal_user_id"] == portal_user_id and r["status"] in ("QUEUED", "PROCESSING")]
        if len(active) >= max_active:
            raise ActiveJobLimitError()
        now = datetime.now(timezone.utc)
        row = {
            "id": uuid4(), "portal_user_id": portal_user_id, "site_id": UUID(str(site_id)),
            "range_from": request.dt_from, "range_to": request.dt_to,
            "requested_resolution": request.requested_resolution, "resolution": request.resolution,
            "status": "QUEUED", "attempts": 0, "error_code": None, "error_message": None, "created_at": now,
            "started_at": None, "completed_at": None, "expires_at": None, "file_name": None,
            "file_size_bytes": None, "asset_count": None, "row_count": None, "asset_ids": list(asset_ids),
        }
        self.rows[str(row["id"])] = row
        return row

    async def list(self, portal_user_id, limit=50):
        return [r for r in self.rows.values() if r["portal_user_id"] == portal_user_id][:limit]

    async def get(self, portal_user_id, job_id):
        row = self.rows.get(str(job_id))
        return row if row and row["portal_user_id"] == portal_user_id else None

    async def retry(self, portal_user_id, job_id):
        row = await self.get(portal_user_id, job_id)
        if row is None or row["status"] != "FAILED":
            return None
        row.update(status="QUEUED", attempts=0, error_code=None, error_message=None)
        return row

    async def file(self, portal_user_id, job_id):
        row = await self.get(portal_user_id, job_id)
        if row is None or row["status"] != "COMPLETED" or row["expires_at"] <= datetime.now(timezone.utc):
            return None
        name, content = self.files[str(job_id)]
        return {"file_name": name, "content": content}

    def finish(self, job_id, *, status="COMPLETED", expires_in=timedelta(hours=1), content=b"PK\x05\x06" + b"\0" * 18):
        row = self.rows[str(job_id)]
        row.update(status=status, completed_at=datetime.now(timezone.utc), expires_at=datetime.now(timezone.utc) + expires_in,
                   file_name="Coimbatore_export.zip")
        if status == "FAILED":
            row.update(error_code="export_failed", error_message="The export could not be generated.", expires_at=None)
        self.files[str(job_id)] = ("Coimbatore_export.zip", content)


@pytest.fixture
def jobs(monkeypatch) -> FakeJobs:
    store = FakeJobs()
    monkeypatch.setattr(f"{ROUTER}.create_job", store.create)
    monkeypatch.setattr(f"{ROUTER}.list_jobs", store.list)
    monkeypatch.setattr(f"{ROUTER}.get_job", store.get)
    monkeypatch.setattr(f"{ROUTER}.retry_job", store.retry)
    monkeypatch.setattr(f"{ROUTER}.get_job_file", store.file)

    async def sites(portal_user_id):
        return [{"site_id": SITE_ID, "site_name": SITE["site_name"]}]

    monkeypatch.setattr(f"{ROUTER}.fetch_accessible_sites", sites)
    return store


@pytest.fixture
def analytics(monkeypatch) -> FakeAnalytics:
    fake = FakeAnalytics()
    fake.install(monkeypatch, ROUTER)
    return fake


def _login(portal_client, monkeypatch, portal_user_id: int = 500) -> None:
    async def fake_authenticate(username: str, password: str) -> AuthenticationResult:
        return AuthenticationResult(
            authenticated=True,
            user=AuthenticatedPortalUser(
                portal_user_id=portal_user_id, username=username, display_name="User",
                role_code="VIEWER", access_scope_mode="GLOBAL",
            ),
            status=AuthenticationStatus.AUTHENTICATED,
        )

    monkeypatch.setattr("src.main.authenticate_portal_user", fake_authenticate)
    response = portal_client.post(
        "/login", data={"username": f"user{portal_user_id}@example.com", "password": "pw", "next_path": "/"}
    )
    assert response.status_code == 303


def _create(portal_client, site_id=SITE_ID, body=None, headers=JSON):
    return portal_client.post(
        f"/api/v1/sites/{site_id}/report-exports",
        json=body or {"from": FROM, "to": TO, "resolution": "1h"},
        headers=headers,
    )


# --- authentication -------------------------------------------------------------

@pytest.mark.parametrize(
    ("method", "path"),
    [
        ("get", f"/api/v1/sites/{SITE_ID}/report-exports/estimate?from={FROM}&to={TO}"),
        ("get", f"/api/v1/sites/{SITE_ID}/report-exports/file?from={FROM}&to={TO}"),
        ("post", f"/api/v1/sites/{SITE_ID}/report-exports"),
        ("get", "/api/v1/report-exports"),
        ("get", f"/api/v1/report-exports/{uuid4()}"),
        ("post", f"/api/v1/report-exports/{uuid4()}/retry"),
        ("get", f"/api/v1/report-exports/{uuid4()}/file"),
    ],
)
def test_every_route_requires_authentication(portal_client, method, path) -> None:
    response = getattr(portal_client, method)(path)
    assert response.status_code == 401
    assert response.json()["error"] == "unauthenticated"


# --- estimate and immediate download ----------------------------------------------

def test_estimate_reports_mode_and_size(portal_client, monkeypatch, analytics, jobs) -> None:
    _login(portal_client, monkeypatch)
    response = portal_client.get(f"/api/v1/sites/{SITE_ID}/report-exports/estimate", params={"from": FROM, "to": TO, "resolution": "1h"})
    assert response.status_code == 200
    body = response.json()
    assert (body["asset_count"], body["column_count"], body["bucket_count"], body["mode"]) == (3, 14, 3, "immediate")


def test_estimate_and_download_for_an_inaccessible_site_are_404(portal_client, monkeypatch, analytics, jobs) -> None:
    _login(portal_client, monkeypatch)
    for path in ("estimate", "file"):
        response = portal_client.get(f"/api/v1/sites/{OTHER_SITE_ID}/report-exports/{path}", params={"from": FROM, "to": TO})
        assert response.status_code == 404
    assert _create(portal_client, OTHER_SITE_ID).status_code == 404
    assert not jobs.rows


def test_invalid_range_is_422_before_any_read(portal_client, monkeypatch, analytics, jobs) -> None:
    _login(portal_client, monkeypatch)
    response = portal_client.get(
        f"/api/v1/sites/{SITE_ID}/report-exports/file", params={"from": TO, "to": FROM, "resolution": "1h"}
    )
    assert response.status_code == 422
    assert response.json()["error"] == "invalid_time_range"
    assert analytics.calls == []


def test_immediate_download_is_a_private_zip_attachment(portal_client, monkeypatch, analytics, jobs) -> None:
    _login(portal_client, monkeypatch)
    response = portal_client.get(
        f"/api/v1/sites/{SITE_ID}/report-exports/file", params={"from": FROM, "to": TO, "resolution": "1h"}
    )
    assert response.status_code == 200
    assert response.headers["content-type"] == "application/zip"
    assert response.headers["cache-control"] == "no-store"
    assert response.headers["content-disposition"].startswith("attachment; filename=")
    with zipfile.ZipFile(io.BytesIO(response.content)) as archive:
        assert sorted(archive.namelist()) == ["AHU 2.csv", "Chiller_1.csv", "Spare Pump.csv"]
    # Reads are keyed on the session's portal user, never on anything the browser sent.
    assert {args[0] for kind, args in analytics.calls if kind in ("energy", "points", "site", "catalog")} == {500}


def test_immediate_download_refuses_a_large_export(portal_client, monkeypatch, analytics, jobs) -> None:
    _login(portal_client, monkeypatch)
    monkeypatch.setattr(get_settings(), "report_export_immediate_max_cells", 10)
    response = portal_client.get(
        f"/api/v1/sites/{SITE_ID}/report-exports/file", params={"from": FROM, "to": TO, "resolution": "1h"}
    )
    assert response.status_code == 422
    assert response.json()["error"] == "export_requires_background"
    estimate = portal_client.get(
        f"/api/v1/sites/{SITE_ID}/report-exports/estimate", params={"from": FROM, "to": TO, "resolution": "1h"}
    )
    assert estimate.json()["mode"] == "background"


# --- background jobs ----------------------------------------------------------------

def test_create_queues_a_job(portal_client, monkeypatch, analytics, jobs) -> None:
    _login(portal_client, monkeypatch)
    response = _create(portal_client)
    assert response.status_code == 202
    body = response.json()
    assert (body["status"], body["status_label"], body["resolution"], body["download_url"]) == ("QUEUED", "Queued", "1h", None)
    assert body["site_name"] == SITE["site_name"]
    assert jobs.rows[body["job_id"]]["portal_user_id"] == 500


def test_create_rejects_non_json_and_cross_site_requests(portal_client, monkeypatch, analytics, jobs) -> None:
    _login(portal_client, monkeypatch)
    form = portal_client.post(
        f"/api/v1/sites/{SITE_ID}/report-exports",
        content=f"from={FROM}&to={TO}",
        headers={"Content-Type": "application/x-www-form-urlencoded"},
    )
    assert form.status_code in (415, 422)
    # A cross-site HTML form can send a JSON-looking body only as text/plain.
    plain = portal_client.post(
        f"/api/v1/sites/{SITE_ID}/report-exports",
        content='{"from": "%s", "to": "%s"}' % (FROM, TO),
        headers={"Content-Type": "text/plain"},
    )
    assert plain.status_code in (415, 422)
    retry_plain = portal_client.post(f"/api/v1/report-exports/{uuid4()}/retry", content="{}", headers={"Content-Type": "text/plain"})
    assert retry_plain.status_code == 415
    cross = _create(portal_client, headers={**JSON, "Sec-Fetch-Site": "cross-site"})
    assert cross.status_code == 403
    assert not jobs.rows


def test_create_refuses_an_export_over_the_background_limit(portal_client, monkeypatch, analytics, jobs) -> None:
    _login(portal_client, monkeypatch)
    monkeypatch.setattr(get_settings(), "report_export_max_cells", 10)
    response = _create(portal_client)
    assert response.status_code == 422
    assert response.json()["error"] == "export_too_large"
    assert not jobs.rows


def test_active_job_limit_is_429(portal_client, monkeypatch, analytics, jobs) -> None:
    _login(portal_client, monkeypatch)
    for _ in range(get_settings().report_export_max_active_jobs):
        assert _create(portal_client).status_code == 202
    response = _create(portal_client)
    assert response.status_code == 429
    assert response.json()["error"] == "too_many_active_exports"


def test_jobs_are_listed_only_for_their_owner(portal_client, monkeypatch, analytics, jobs) -> None:
    _login(portal_client, monkeypatch, 500)
    job_id = _create(portal_client).json()["job_id"]
    assert [j["job_id"] for j in portal_client.get("/api/v1/report-exports").json()["jobs"]] == [job_id]
    assert portal_client.get(f"/api/v1/report-exports/{job_id}").status_code == 200

    _login(portal_client, monkeypatch, 501)
    assert portal_client.get("/api/v1/report-exports").json()["jobs"] == []
    assert portal_client.get(f"/api/v1/report-exports/{job_id}").status_code == 404
    assert portal_client.get(f"/api/v1/report-exports/{job_id}/file").status_code == 404
    assert portal_client.post(f"/api/v1/report-exports/{job_id}/retry", json={}, headers=JSON).status_code == 404


def test_completed_job_downloads_for_its_owner_only(portal_client, monkeypatch, analytics, jobs) -> None:
    _login(portal_client, monkeypatch, 500)
    job_id = _create(portal_client).json()["job_id"]
    jobs.finish(job_id)
    status = portal_client.get(f"/api/v1/report-exports/{job_id}").json()
    assert (status["status_label"], status["download_url"]) == ("Completed", f"/api/v1/report-exports/{job_id}/file")
    response = portal_client.get(status["download_url"])
    assert response.status_code == 200
    assert response.headers["cache-control"] == "no-store"
    assert response.headers["content-type"] == "application/zip"
    assert 'filename="Coimbatore_export.zip"' in response.headers["content-disposition"]


def test_expired_or_unfinished_job_download_is_410(portal_client, monkeypatch, analytics, jobs) -> None:
    _login(portal_client, monkeypatch)
    queued = _create(portal_client).json()["job_id"]
    assert portal_client.get(f"/api/v1/report-exports/{queued}/file").status_code == 410
    expired = _create(portal_client).json()["job_id"]
    jobs.finish(expired, expires_in=timedelta(seconds=-1))
    assert portal_client.get(f"/api/v1/report-exports/{expired}").json()["download_url"] is None
    assert portal_client.get(f"/api/v1/report-exports/{expired}/file").status_code == 410


def test_failed_job_shows_its_message_and_can_be_retried(portal_client, monkeypatch, analytics, jobs) -> None:
    _login(portal_client, monkeypatch)
    job_id = _create(portal_client).json()["job_id"]
    assert portal_client.post(f"/api/v1/report-exports/{job_id}/retry", json={}, headers=JSON).status_code == 409
    jobs.finish(job_id, status="FAILED")
    failed = portal_client.get(f"/api/v1/report-exports/{job_id}").json()
    assert (failed["status_label"], failed["error_message"]) == ("Failed", "The export could not be generated.")
    assert portal_client.post(
        f"/api/v1/report-exports/{job_id}/retry", json={}, headers={**JSON, "Sec-Fetch-Site": "cross-site"}
    ).status_code == 403
    retried = portal_client.post(f"/api/v1/report-exports/{job_id}/retry", json={}, headers=JSON)
    assert retried.status_code == 202
    assert (retried.json()["status"], retried.json()["error_message"]) == ("QUEUED", None)


def test_unknown_job_is_404(portal_client, monkeypatch, analytics, jobs) -> None:
    _login(portal_client, monkeypatch)
    assert portal_client.get(f"/api/v1/report-exports/{uuid4()}").status_code == 404
    assert portal_client.get("/api/v1/report-exports/not-a-uuid").status_code == 422


def test_routes_require_the_report_export_permission(portal_client, monkeypatch, analytics, jobs) -> None:
    from src.auth.authorization import ROLE_PERMISSIONS, PortalPermission, PortalRole

    _login(portal_client, monkeypatch)
    monkeypatch.setitem(
        ROLE_PERMISSIONS, PortalRole.VIEWER, ROLE_PERMISSIONS[PortalRole.VIEWER] - {PortalPermission.REPORT_EXPORT}
    )
    assert portal_client.get("/api/v1/report-exports").status_code == 403
    assert _create(portal_client).status_code == 403
    response = portal_client.get(f"/api/v1/sites/{SITE_ID}/report-exports/file", params={"from": FROM, "to": TO})
    assert response.status_code == 403
    assert analytics.calls == [] and not jobs.rows
    # Other /api/v1 reads are unaffected.
    assert portal_client.get("/api/v1/me").status_code == 200


# --- asset selection ------------------------------------------------------------------

def test_estimate_counts_only_the_selected_assets(portal_client, monkeypatch, analytics, jobs) -> None:
    from tests.report_export_fixtures import ASSET_B

    _login(portal_client, monkeypatch)
    response = portal_client.get(
        f"/api/v1/sites/{SITE_ID}/report-exports/estimate",
        params={"from": FROM, "to": TO, "resolution": "1h", "asset_id": [ASSET_B]},
    )
    assert response.status_code == 200
    assert (response.json()["asset_count"], response.json()["column_count"]) == (1, 6)


def test_more_than_the_maximum_assets_is_422(portal_client, monkeypatch, analytics, jobs) -> None:
    from tests.report_export_fixtures import ASSET_A, ASSET_B

    _login(portal_client, monkeypatch)
    monkeypatch.setattr(get_settings(), "report_export_max_assets", 1)
    selected = portal_client.get(
        f"/api/v1/sites/{SITE_ID}/report-exports/estimate",
        params={"from": FROM, "to": TO, "resolution": "1h", "asset_id": [ASSET_A, ASSET_B]},
    )
    assert (selected.status_code, selected.json()["error"]) == (422, "too_many_assets")
    # Without a selection the whole site counts against the same maximum.
    whole_site = portal_client.get(
        f"/api/v1/sites/{SITE_ID}/report-exports/file", params={"from": FROM, "to": TO, "resolution": "1h"}
    )
    assert (whole_site.status_code, whole_site.json()["error"]) == (422, "too_many_assets")
    created = _create(portal_client, body={"from": FROM, "to": TO, "resolution": "1h", "asset_ids": [ASSET_A, ASSET_B]})
    assert (created.status_code, created.json()["error"]) == (422, "too_many_assets")
    assert not jobs.rows


def test_an_asset_that_is_not_on_the_site_is_422(portal_client, monkeypatch, analytics, jobs) -> None:
    _login(portal_client, monkeypatch)
    for path in ("estimate", "file"):
        response = portal_client.get(
            f"/api/v1/sites/{SITE_ID}/report-exports/{path}",
            params={"from": FROM, "to": TO, "resolution": "1h", "asset_id": [str(uuid4())]},
        )
        assert (response.status_code, response.json()["error"]) == (422, "invalid_assets")
    created = _create(portal_client, body={"from": FROM, "to": TO, "resolution": "1h", "asset_ids": [str(uuid4())]})
    assert (created.status_code, created.json()["error"]) == (422, "invalid_assets")
    assert not jobs.rows


def test_immediate_download_exports_the_selected_assets(portal_client, monkeypatch, analytics, jobs) -> None:
    from tests.report_export_fixtures import ASSET_A

    _login(portal_client, monkeypatch)
    response = portal_client.get(
        f"/api/v1/sites/{SITE_ID}/report-exports/file",
        params={"from": FROM, "to": TO, "resolution": "1h", "asset_id": [ASSET_A]},
    )
    assert response.status_code == 200
    with zipfile.ZipFile(io.BytesIO(response.content)) as archive:
        assert archive.namelist() == ["Chiller_1.csv"]


def test_a_job_keeps_its_selection(portal_client, monkeypatch, analytics, jobs) -> None:
    from tests.report_export_fixtures import ASSET_A, ASSET_B, ASSET_C

    _login(portal_client, monkeypatch)
    response = _create(portal_client, body={"from": FROM, "to": TO, "resolution": "1h", "asset_ids": [ASSET_B]})
    assert response.status_code == 202
    assert response.json()["asset_ids"] == [ASSET_B]
    # A whole-site request is stored as the site's current assets.
    whole_site = _create(portal_client)
    assert sorted(whole_site.json()["asset_ids"]) == sorted([ASSET_A, ASSET_B, ASSET_C])


def test_one_minute_export_for_fourteen_days_is_a_background_job(portal_client, monkeypatch, analytics, jobs) -> None:
    from tests.report_export_fixtures import ASSET_A

    _login(portal_client, monkeypatch)
    params = {"from": "2026-09-06T00:00:00Z", "to": "2026-09-20T00:00:00Z", "resolution": "1m", "asset_id": [ASSET_A]}
    estimate = portal_client.get(f"/api/v1/sites/{SITE_ID}/report-exports/estimate", params=params)
    assert estimate.status_code == 200
    assert (estimate.json()["bucket_count"], estimate.json()["mode"]) == (20160, "background")
    too_long = portal_client.get(
        f"/api/v1/sites/{SITE_ID}/report-exports/estimate", params={**params, "from": "2026-09-05T23:59:00Z"}
    )
    assert (too_long.status_code, too_long.json()["error"]) == (422, "time_range_too_large")
