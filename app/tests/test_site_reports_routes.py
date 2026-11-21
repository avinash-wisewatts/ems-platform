"""Reports -> Create report routes (ADR-025).

Customer portal API (src.routers.site_reports): view/download for every
profile (A5), PDF download headers, site access re-checked (T-SEC-1/2/7); the
only write is on-demand generation, for Site Admins and WiseWatts Admins
(report.generate, ADR-025 Amendment 1, A113) -- Operators and Viewers are
refused, cross-origin and non-JSON writes are refused. Administration App pages (src.routers.admin_site_reports):
WiseWatts Admins only, enforced in the route whether EMS_ADMIN_STAFF_ONLY is
off or on (A2, A3, A12; T-ADM-3/4), cross-origin posts refused, permanent
deletion requires the typed confirmation (A111; T-DEL-11).
Data access is faked; the database rules are in test_site_reports_db.py.
"""

from __future__ import annotations

from datetime import date, datetime, timedelta, timezone
from uuid import UUID, uuid4

import pytest
from fastapi.testclient import TestClient

import src.site_report_service as svc
from src.auth.models import AuthenticatedPortalUser
from src.auth.security import AuthenticationStatus
from src.auth.service import AuthenticationResult
from tests.test_customer_api import FakeServerSessions  # noqa: F401  (session store fake)

SITE_ID = "22222222-2222-4222-8222-222222222222"
ORG_ID = "11111111-1111-4111-8111-111111111111"
REPORT_ID = uuid4()
VERSION_ID = uuid4()
ORIGIN = {"Origin": "http://testserver"}
NOW = datetime(2026, 11, 2, 6, 0, tzinfo=timezone.utc)

STAFF = AuthenticatedPortalUser(portal_user_id=900, username="staff@wisewatts.example", display_name="Staff",
                                role_code="ADMIN", access_scope_mode="GLOBAL")
TENANT_ADMIN = AuthenticatedPortalUser(portal_user_id=901, username="admin@radisson.example", display_name="Radisson Admin",
                                       role_code="ADMIN", organization_id=ORG_ID, access_scope_mode="ORGANIZATION")
OPERATOR = AuthenticatedPortalUser(portal_user_id=903, username="operator@radisson.example", display_name="Operator",
                                   role_code="OPERATOR", organization_id=ORG_ID, access_scope_mode="ORGANIZATION")
VIEWER = AuthenticatedPortalUser(portal_user_id=902, username="viewer@radisson.example", display_name="Viewer",
                                 role_code="VIEWER", organization_id=ORG_ID, access_scope_mode="SELECTED_SITES",
                                 site_ids=(SITE_ID,))


class FakeReports:
    def __init__(self) -> None:
        self.calls: list[tuple] = []
        self.generate_error: Exception | None = None
        # Users the database rule allows to generate (active ADMIN with site access, not the automation account).
        self.db_can_generate: set[int] = {900, 901}

    def install(self, monkeypatch) -> None:
        async def portal_schedule(uid, site_id):
            return {"enrolled": True, "weekly_enabled": True, "monthly_enabled": False, "site_timezone": "Asia/Kolkata",
                    "can_generate": uid in self.db_can_generate} if str(site_id) == SITE_ID else None

        async def portal_reports(uid, site_id, report_type, limit=200):
            self.calls.append(("list", uid, report_type))
            return [{"report_id": REPORT_ID, "report_type": "WEEKLY", "period_start_date": date(2026, 10, 25),
                     "period_end_date": date(2026, 10, 31), "comparison_start_date": date(2026, 10, 18),
                     "comparison_end_date": date(2026, 10, 24), "status": "GENERATED", "status_reason": None,
                     "latest_version_id": VERSION_ID, "latest_version_no": 1, "generated_at": NOW,
                     "expires_at": NOW + timedelta(days=60), "download_version_id": VERSION_ID, "incomplete_data": False,
                     "comparison_incomplete": True, "coverage_summary": {"hvac_available_pct": 99.0}, "version_count": 1}]

        async def portal_versions(uid, report_id):
            return [] if report_id != REPORT_ID else [{
                "version_id": VERSION_ID, "version_no": 1, "generated_at": NOW, "trigger": "AUTOMATIC",
                "generated_by_staff": False, "expires_at": NOW + timedelta(days=60), "state": "AVAILABLE",
                "incomplete_data": False, "comparison_incomplete": True, "coverage": {"current": {}},
                "settings_snapshot": {"settings": []}, "file_name": "Radisson_Blu_Coimbatore_Weekly.pdf",
                "file_size_bytes": 12345, "page_count": 11}]

        async def portal_file(uid, version_id):
            return {"file_name": "Radisson_Blu_Coimbatore_Weekly.pdf", "content": b"%PDF-1.7 test", "sha256": "0" * 64} \
                if version_id == VERSION_ID else None

        async def portal_generate(uid, site_id, report_type, period_start):
            self.calls.append(("generate", uid, str(site_id), report_type, period_start))
            if self.generate_error is not None:
                raise self.generate_error
            return {"report_id": REPORT_ID, "attempt_id": uuid4(), "action": "GENERATE", "trigger": "HISTORICAL"}

        monkeypatch.setattr(svc, "portal_generate", portal_generate)
        for name, fn in (("portal_schedule", portal_schedule), ("portal_reports", portal_reports),
                         ("portal_versions", portal_versions), ("portal_file", portal_file)):
            monkeypatch.setattr(svc, name, fn)

        def recorder(name):
            async def fn(*args, **kwargs):
                self.calls.append((name, *args))
                if name == "delete":
                    return NOW + timedelta(days=7)
                if name == "add_setting":
                    return {"effective_from": datetime.now(timezone.utc) + timedelta(days=30), "effective_date": date(2030, 1, 1)}
                return {}
            return fn

        for name in ("enrol", "set_automation_account", "set_schedule", "set_roster_asset", "remove_roster_asset",
                     "add_setting", "withdraw_setting", "request_generation", "request_regeneration", "retry", "delete",
                     "restore", "permanently_delete"):
            monkeypatch.setattr(svc, name, recorder(name))

        async def admin_profile(uid, site_id):
            return {"site_id": UUID(SITE_ID), "organization_id": UUID(ORG_ID), "enrolled": True,
                    "automation_portal_user_id": None, "automation_username": None, "automation_problem": "account_not_set",
                    "weekly_enabled": True, "monthly_enabled": True, "weekly_resumed_at": NOW, "monthly_resumed_at": NOW,
                    "weekly_changed_at": None, "monthly_changed_at": None, "enrolled_at": NOW, "site_timezone": "Asia/Kolkata"}

        async def admin_assets(uid, site_id):
            return [{"asset_id": uuid4(), "asset_name": "Chiller1", "report_group": "HVAC_CHILLERS", "area": None,
                     "display_order": 1, "in_roster": True}]

        async def empty(*args, **kwargs):
            return []

        monkeypatch.setattr(svc, "admin_profile", admin_profile)
        monkeypatch.setattr(svc, "admin_assets", admin_assets)
        monkeypatch.setattr(svc, "admin_settings", empty)
        monkeypatch.setattr(svc, "admin_reports", empty)

        async def site_workspace(*, portal_user_id, site_id):
            return {"site_id": site_id, "site_name": "Coimbatore", "organization_name": "Radisson Blu", "site_code": "CBE",
                    "lifecycle_status": "ACTIVE", "timezone": "Asia/Kolkata", "address": {}}

        monkeypatch.setattr("src.location_management_service.get_site_workspace", site_workspace)

        async def users(*, actor_portal_user_id):
            return []

        monkeypatch.setattr("src.user_management_service.list_manageable_users", users)


@pytest.fixture
def reports(monkeypatch) -> FakeReports:
    fake = FakeReports()
    fake.install(monkeypatch)
    return fake


@pytest.fixture(autouse=True)
def server_sessions(monkeypatch):
    from tests.test_customer_api import FakeServerSessions as Store

    fake = Store()
    monkeypatch.setattr("src.auth.server_session.create_server_session", fake.create)
    monkeypatch.setattr("src.auth.server_session.touch_server_session", fake.touch)
    monkeypatch.setattr("src.auth.server_session.revoke_server_session", fake.revoke)
    return fake


@pytest.fixture
def customer_client():
    import src.config as config
    import src.customer_main as customer_main

    config.use_core_settings(customer_main.settings)
    try:
        yield TestClient(customer_main.app, follow_redirects=False)
    finally:
        config._core_settings = None


def _customer_login(client, monkeypatch, user):
    async def fake(username, password, *, audience=None):
        if audience is not None and not audience(user):
            return AuthenticationResult(False, None, AuthenticationStatus.INVALID_CREDENTIALS)
        return AuthenticationResult(True, user, AuthenticationStatus.AUTHENTICATED)

    monkeypatch.setattr("src.routers.customer_auth.authenticate_portal_user", fake)
    response = client.post("/auth/login", json={"username": user.username, "password": "x"}, headers=ORIGIN)
    assert response.status_code == 200, response.text


def _admin_login(portal_client, monkeypatch, user):
    async def fake(username, password, *, audience=None):
        if audience is not None and not audience(user):
            return AuthenticationResult(False, None, AuthenticationStatus.INVALID_CREDENTIALS)
        return AuthenticationResult(True, user, AuthenticationStatus.AUTHENTICATED)

    monkeypatch.setattr("src.main.authenticate_portal_user", fake)
    return portal_client.post("/login", data={"username": user.username, "password": "x", "next_path": "/"})


# ---------------------------------------------------------------------------
# Customer portal API: read-only (A5, A107)
# ---------------------------------------------------------------------------

def test_customer_api_only_write_route_is_generation():
    import src.customer_main as customer_main

    for route in customer_main.app.routes:
        path = getattr(route, "path", "")
        if "site-report" in path:
            allowed = {"GET", "HEAD", "POST"} if path == "/api/v1/sites/{site_id}/site-reports" else {"GET", "HEAD"}
            assert set(getattr(route, "methods", set())) <= allowed, path
    paths = {getattr(r, "path", "") for r in customer_main.app.routes}
    assert {"/api/v1/sites/{site_id}/site-reports", "/api/v1/site-reports/{report_id}/versions",
            "/api/v1/site-report-versions/{version_id}/download"} <= paths
    assert not any("/administration" in p for p in paths)


@pytest.mark.parametrize("path", [f"/api/v1/sites/{SITE_ID}/site-reports", f"/api/v1/site-reports/{REPORT_ID}/versions",
                                  f"/api/v1/site-report-versions/{VERSION_ID}/download"])
def test_routes_require_authentication(customer_client, path):
    assert customer_client.get(path).status_code == 401


@pytest.mark.parametrize("user", [VIEWER, TENANT_ADMIN])
def test_every_profile_lists_and_downloads(customer_client, monkeypatch, reports, user):
    _customer_login(customer_client, monkeypatch, user)
    body = customer_client.get(f"/api/v1/sites/{SITE_ID}/site-reports?type=WEEKLY").json()
    assert body["enrolled"] and body["weekly_enabled"] and not body["monthly_enabled"]
    item = body["reports"][0]
    assert (item["status"], item["status_label"], item["comparison_incomplete"], item["incomplete_data"]) == (
        "GENERATED", "Generated", True, False)
    assert reports.calls[0] == ("list", user.portal_user_id, "WEEKLY")
    versions = customer_client.get(f"/api/v1/site-reports/{REPORT_ID}/versions").json()["versions"]
    assert versions[0]["available"] and versions[0]["page_count"] == 11
    response = customer_client.get(f"/api/v1/site-report-versions/{VERSION_ID}/download")
    assert response.status_code == 200 and response.content.startswith(b"%PDF-")
    assert response.headers["content-type"] == "application/pdf"
    assert response.headers["cache-control"] == "private, no-store"
    assert response.headers["x-content-type-options"] == "nosniff"
    assert response.headers["content-disposition"].startswith('attachment; filename="Radisson_Blu_Coimbatore_Weekly.pdf"')


def test_inaccessible_site_report_or_version_is_404(customer_client, monkeypatch, reports):
    _customer_login(customer_client, monkeypatch, VIEWER)
    assert customer_client.get(f"/api/v1/sites/{uuid4()}/site-reports").status_code == 404
    assert customer_client.get(f"/api/v1/site-reports/{uuid4()}/versions").status_code == 404
    assert customer_client.get(f"/api/v1/site-report-versions/{uuid4()}/download").status_code == 404


def test_other_write_methods_are_not_allowed(customer_client, monkeypatch, reports):
    _customer_login(customer_client, monkeypatch, TENANT_ADMIN)
    for method, path in (("delete", f"/api/v1/sites/{SITE_ID}/site-reports"),
                         ("delete", f"/api/v1/site-reports/{REPORT_ID}/versions"),
                         ("post", f"/api/v1/site-reports/{REPORT_ID}/versions"),
                         ("post", f"/api/v1/site-report-versions/{VERSION_ID}/download")):
        assert getattr(customer_client, method)(path, headers=ORIGIN).status_code in (404, 405)
    assert not [c for c in reports.calls if c[0] != "list"]


def test_me_advertises_report_view_for_every_role(customer_client, monkeypatch, reports):
    _customer_login(customer_client, monkeypatch, VIEWER)
    permissions = customer_client.get("/api/v1/me").json()["permissions"]
    assert "report.view" in permissions and "report.generate" not in permissions


# ---------------------------------------------------------------------------
# Customer portal: on-demand generation (ADR-025 Amendment 1, A113, A115)
# ---------------------------------------------------------------------------

GENERATE = {"report_type": "MONTHLY", "period_start": "2026-10-01"}


@pytest.mark.parametrize("user", [TENANT_ADMIN, STAFF])
def test_site_admins_and_wisewatts_admins_generate(customer_client, monkeypatch, reports, user):
    import src.customer_main as customer_main

    # WiseWatts Admins sign in to the customer app where staff sign-in is allowed (staging).
    monkeypatch.setattr(customer_main.settings, "customer_allow_staff", True)
    _customer_login(customer_client, monkeypatch, user)
    assert "report.generate" in customer_client.get("/api/v1/me").json()["permissions"]
    assert customer_client.get(f"/api/v1/sites/{SITE_ID}/site-reports").json()["can_generate"] is True
    response = customer_client.post(f"/api/v1/sites/{SITE_ID}/site-reports", json=GENERATE, headers=ORIGIN)
    assert response.status_code == 202, response.text
    assert response.json()["action"] == "GENERATE" and response.json()["trigger"] == "HISTORICAL"
    assert ("generate", user.portal_user_id, SITE_ID, "MONTHLY", date(2026, 10, 1)) in reports.calls


@pytest.mark.parametrize("user", [OPERATOR, VIEWER])
def test_operators_and_viewers_cannot_generate(customer_client, monkeypatch, reports, user):
    _customer_login(customer_client, monkeypatch, user)
    assert customer_client.get(f"/api/v1/sites/{SITE_ID}/site-reports").json()["can_generate"] is False
    response = customer_client.post(f"/api/v1/sites/{SITE_ID}/site-reports", json=GENERATE, headers=ORIGIN)
    assert response.status_code == 403
    assert not [c for c in reports.calls if c[0] == "generate"]


def test_can_generate_follows_the_database_rule(customer_client, monkeypatch, reports):
    """An ADMIN the database refuses (e.g. the designated automation account) is not offered generation."""

    reports.db_can_generate = set()
    _customer_login(customer_client, monkeypatch, TENANT_ADMIN)
    assert customer_client.get(f"/api/v1/sites/{SITE_ID}/site-reports").json()["can_generate"] is False


def test_generation_refuses_cross_origin_and_non_json(customer_client, monkeypatch, reports):
    _customer_login(customer_client, monkeypatch, TENANT_ADMIN)
    path = f"/api/v1/sites/{SITE_ID}/site-reports"
    assert customer_client.post(path, json=GENERATE, headers={"Origin": "https://evil.example"}).status_code == 403
    assert customer_client.post(path, json=GENERATE, headers={**ORIGIN, "Sec-Fetch-Site": "cross-site"}).status_code == 403
    assert customer_client.post(path, content="report_type=MONTHLY", headers={
        **ORIGIN, "Content-Type": "application/x-www-form-urlencoded"}).status_code == 415
    assert customer_client.post(path, json={"report_type": "DAILY", "period_start": "2026-10-01"},
                                headers=ORIGIN).status_code == 422
    assert not [c for c in reports.calls if c[0] == "generate"]


def test_generation_on_an_inaccessible_site_is_404(customer_client, monkeypatch, reports):
    _customer_login(customer_client, monkeypatch, TENANT_ADMIN)
    assert customer_client.post(f"/api/v1/sites/{uuid4()}/site-reports", json=GENERATE, headers=ORIGIN).status_code == 404


def test_database_refusal_is_returned_with_its_message(customer_client, monkeypatch, reports):
    _customer_login(customer_client, monkeypatch, TENANT_ADMIN)
    reports.generate_error = svc.SiteReportError("site_report_period_not_ended", svc.ERROR_TEXT["site_report_period_not_ended"], 400)
    response = customer_client.post(f"/api/v1/sites/{SITE_ID}/site-reports", json=GENERATE, headers=ORIGIN)
    assert response.status_code == 400
    assert response.json() == {"error": "site_report_period_not_ended", "detail": "The reporting period has not ended yet."}


# ---------------------------------------------------------------------------
# Administration App pages: WiseWatts Admins only (A2-A4, A6, A12)
# ---------------------------------------------------------------------------

ADMIN_GETS = [f"/administration/sites/{SITE_ID}/reporting", f"/administration/sites/{SITE_ID}/reports",
              f"/administration/sites/{SITE_ID}/reporting/assets/{uuid4()}", f"/administration/site-reports/{REPORT_ID}"]
ADMIN_POSTS = [
    (f"/administration/sites/{SITE_ID}/reporting/enrol", {}),
    (f"/administration/sites/{SITE_ID}/reporting/schedule", {"report_type": "WEEKLY", "enabled": "false"}),
    (f"/administration/sites/{SITE_ID}/reporting/assets/{uuid4()}/roster", {"action": "remove"}),
    (f"/administration/sites/{SITE_ID}/reporting/assets/{uuid4()}/settings",
     {"setting_key": "TEMPERATURE_SETPOINT", "value_c": "24", "effective_date": "2030-01-01"}),
    (f"/administration/sites/{SITE_ID}/reports/generate", {"report_type": "WEEKLY", "period_start": "2026-10-28"}),
    (f"/administration/site-reports/{REPORT_ID}/regenerate", {"site_id": SITE_ID}),
    (f"/administration/site-reports/{REPORT_ID}/retry", {"site_id": SITE_ID}),
    (f"/administration/site-reports/{REPORT_ID}/delete", {"site_id": SITE_ID, "confirm": "yes"}),
    (f"/administration/site-reports/{REPORT_ID}/restore", {"site_id": SITE_ID}),
    (f"/administration/site-reports/{REPORT_ID}/purge", {"site_id": SITE_ID, "confirm": "PERMANENTLY DELETE"}),
]


def test_tenant_admin_is_refused_on_every_reporting_page_with_switch_off(portal_client, monkeypatch, reports):
    """T-ADM-3 with EMS_ADMIN_STAFF_ONLY off: the tenant Admin can sign in, but every reporting page is 403."""

    from src.config import get_settings

    monkeypatch.setattr(get_settings(), "admin_staff_only", False)
    assert _admin_login(portal_client, monkeypatch, TENANT_ADMIN).status_code == 303
    for path in ADMIN_GETS:
        assert portal_client.get(path).status_code == 403, path
    for path, data in ADMIN_POSTS:
        assert portal_client.post(path, data=data, headers=ORIGIN).status_code == 403, path
    assert reports.calls == []


def test_tenant_admin_cannot_reach_reporting_pages_with_switch_on(portal_client, monkeypatch, reports):
    """T-ADM-3 with EMS_ADMIN_STAFF_ONLY on: the tenant Admin cannot sign in at all."""

    from src.config import get_settings

    monkeypatch.setattr(get_settings(), "admin_staff_only", True)
    assert _admin_login(portal_client, monkeypatch, TENANT_ADMIN).status_code == 401
    for path in ADMIN_GETS:
        response = portal_client.get(path)
        assert response.status_code == 303 and response.headers["location"].startswith("/login"), path
    for path, data in ADMIN_POSTS:
        assert portal_client.post(path, data=data, headers=ORIGIN).status_code in (303, 401, 403), path
    assert reports.calls == []


@pytest.mark.parametrize("switch", [False, True])
def test_staff_admin_reaches_reporting_pages_with_either_switch_state(portal_client, monkeypatch, reports, switch):
    from src.config import get_settings

    monkeypatch.setattr(get_settings(), "admin_staff_only", switch)
    assert _admin_login(portal_client, monkeypatch, STAFF).status_code == 303
    for path in ADMIN_GETS[:2]:
        response = portal_client.get(path)
        assert response.status_code == 200, (path, response.text[:300])
    page = portal_client.get(f"/administration/sites/{SITE_ID}/reporting").text
    assert "Automation account" in page and "Report data-quality thresholds" in page and "Fixed and controlled by WiseWatts" in page
    page = portal_client.get(f"/administration/sites/{SITE_ID}/reports").text
    assert "Recycle bin" in page and "Generate report" in page


def test_staff_actions_reach_the_database_functions(portal_client, monkeypatch, reports):
    _admin_login(portal_client, monkeypatch, STAFF)
    for path, data in ADMIN_POSTS:
        response = portal_client.post(path, data=data, headers=ORIGIN)
        assert response.status_code == 303, (path, response.text[:200])
    names = [c[0] for c in reports.calls]
    assert names == ["enrol", "set_schedule", "remove_roster_asset", "add_setting", "request_generation",
                     "request_regeneration", "retry", "delete", "restore", "permanently_delete"]
    generation = next(c for c in reports.calls if c[0] == "request_generation")
    assert generation[3:] == ("WEEKLY", date(2026, 10, 25))          # any day -> its Sunday
    purge = next(c for c in reports.calls if c[0] == "permanently_delete")
    assert purge[1:] == (STAFF.portal_user_id, REPORT_ID, True)


def test_permanent_deletion_without_typed_confirmation_is_not_confirmed(portal_client, monkeypatch, reports):
    _admin_login(portal_client, monkeypatch, STAFF)
    portal_client.post(f"/administration/site-reports/{REPORT_ID}/purge", data={"site_id": SITE_ID, "confirm": "yes"},
                       headers=ORIGIN)
    assert reports.calls[-1] == ("permanently_delete", STAFF.portal_user_id, REPORT_ID, False)


def test_report_history_offers_no_permanent_deletion(portal_client, monkeypatch, reports):
    """T-DEL-11: Delete permanently appears only in the recycle bin section."""

    async def active(uid, site_id, state="ACTIVE"):
        if state != "ACTIVE":
            return []
        return [{"report_id": REPORT_ID, "report_type": "WEEKLY", "period_start_date": date(2026, 10, 25),
                 "period_end_date": date(2026, 10, 31), "comparison_start_date": date(2026, 10, 18),
                 "comparison_end_date": date(2026, 10, 24), "state": "ACTIVE", "status": "GENERATED", "status_reason": None,
                 "deleted_at": None, "deleted_by_username": None, "restore_until": None, "latest_version_id": VERSION_ID,
                 "latest_version_no": 1, "generated_at": NOW, "expires_at": NOW + timedelta(days=60),
                 "download_version_id": VERSION_ID, "incomplete_data": True, "comparison_incomplete": False,
                 "version_count": 1, "next_purge_at": None}]

    monkeypatch.setattr(svc, "admin_reports", active)
    _admin_login(portal_client, monkeypatch, STAFF)
    page = portal_client.get(f"/administration/sites/{SITE_ID}/reports").text
    history = page.split("Recycle bin")[0]
    assert "Incomplete data" in history and "Delete permanently" not in history and "/purge" not in history
    assert "The recycle bin is empty." in page


def test_cross_origin_post_is_refused(portal_client, monkeypatch, reports):
    _admin_login(portal_client, monkeypatch, STAFF)
    response = portal_client.post(f"/administration/site-reports/{REPORT_ID}/delete",
                                  data={"site_id": SITE_ID, "confirm": "yes"}, headers={"Origin": "https://evil.example"})
    assert response.status_code == 403 and reports.calls == []


def test_site_detail_links_only_for_wisewatts_admins(portal_client, monkeypatch, reports):
    from src.config import get_settings

    monkeypatch.setattr(get_settings(), "admin_staff_only", False)
    monkeypatch.setattr("src.main.get_site_workspace", lambda **kw: _site(), raising=False)
    _admin_login(portal_client, monkeypatch, TENANT_ADMIN)
    page = portal_client.get(f"/administration/sites/{SITE_ID}")
    assert "/reporting" not in page.text


async def _site():
    return {"site_id": SITE_ID, "site_name": "Coimbatore", "organization_name": "Radisson Blu", "site_code": "CBE",
            "lifecycle_status": "ACTIVE", "timezone": "Asia/Kolkata", "address": {}}


def test_schedule_validation_is_light_and_shared():
    """The Administration App validates schedules without the engine's heavy dependencies."""

    import subprocess
    import sys

    probe = ("import sys; import src.routers.admin_site_reports; "
             "print(any(m in sys.modules for m in ('pandas', 'numpy', 'matplotlib', 'reportlab')))")
    result = subprocess.run([sys.executable, "-c", probe], capture_output=True, text=True, timeout=120)
    assert result.returncode == 0, result.stderr
    assert result.stdout.strip().splitlines()[-1] == "False"
