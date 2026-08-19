from uuid import UUID

import pytest

from src.auth.models import AuthenticatedPortalUser
from src.auth.security import AuthenticationStatus
from src.auth.service import AuthenticationResult

ORGANIZATION_ID = UUID("11111111-1111-4111-8111-111111111111")
SITE_ID = UUID("22222222-2222-4222-8222-222222222222")


def login(portal_client, monkeypatch, *, scope="GLOBAL"):
    async def fake_authenticate(username: str, password: str):
        return AuthenticationResult(
            authenticated=True,
            user=AuthenticatedPortalUser(
                portal_user_id=500,
                username="admin@example.com",
                display_name="Site Admin",
                role_code="ADMIN",
                access_scope_mode=scope,
                organization_id=None if scope == "GLOBAL" else str(ORGANIZATION_ID),
                site_ids=(str(SITE_ID),) if scope == "SELECTED_SITES" else (),
            ),
            status=AuthenticationStatus.AUTHENTICATED,
        )
    monkeypatch.setattr("src.main.authenticate_portal_user", fake_authenticate)
    response = portal_client.post("/login", data={
        "username": "admin@example.com", "password": "valid-password",
        "next_path": "/administration/sites",
    })
    assert response.status_code == 303


@pytest.fixture(autouse=True)
def page_reads(monkeypatch):
    async def organizations(**kwargs):
        return [{"id": ORGANIZATION_ID, "organization_code": "ORG_1", "organization_name": "Organization One"}]
    async def sites(*, portal_user_id: int):
        assert portal_user_id == 500
        return []
    async def sectors():
        return []
    async def sub_sectors(sector_id=None):
        return []
    monkeypatch.setattr("src.main._site_page_organizations", lambda user: organizations())
    monkeypatch.setattr("src.main.list_manageable_sites", sites)
    monkeypatch.setattr("src.main.list_sectors", sectors)
    monkeypatch.setattr("src.main.list_sub_sectors", sub_sectors)


def test_site_page_lists_all_accessible_sites_without_active_organization(portal_client, monkeypatch):
    login(portal_client, monkeypatch)
    async def sites(*, portal_user_id: int):
        return [
            {"site_id": SITE_ID, "organization_id": ORGANIZATION_ID,
             "organization_code": "ORG_1", "organization_name": "Organization One",
             "site_code": "SITE_1", "site_name": "Site One", "timezone": "Asia/Kolkata",
             "address": {}, "lifecycle_status": "ACTIVE", "is_active": True},
        ]
    monkeypatch.setattr("src.main.list_manageable_sites", sites)
    response = portal_client.get("/administration/sites")
    assert response.status_code == 200
    assert "Site One" in response.text
    assert "Organization One" in response.text
    assert f'/administration/sites/{SITE_ID}' in response.text
    assert ">View</a>" in response.text
    assert ">Select</button>" in response.text
    assert 'action="/context/site"' in response.text


def test_site_page_filters_to_selected_organization(portal_client, monkeypatch):
    login(portal_client, monkeypatch)
    other_org = UUID("33333333-3333-4333-8333-333333333333")
    async def organizations(user):
        return [
            {"id": ORGANIZATION_ID, "organization_name": "Organization One"},
            {"id": other_org, "organization_name": "Organization Two"},
        ]
    async def sites(*, portal_user_id: int):
        return [
            {"site_id": SITE_ID, "organization_id": ORGANIZATION_ID, "organization_name": "Organization One", "organization_code": "ORG_1", "site_name": "Alpha", "site_code": "ALPHA", "timezone": "UTC", "address": {}, "lifecycle_status": "ACTIVE", "is_active": True},
            {"site_id": UUID("44444444-4444-4444-8444-444444444444"), "organization_id": other_org, "organization_name": "Organization Two", "organization_code": "ORG_2", "site_name": "Beta", "site_code": "BETA", "timezone": "UTC", "address": {}, "lifecycle_status": "ACTIVE", "is_active": True},
        ]
    monkeypatch.setattr("src.main._site_page_organizations", organizations)
    monkeypatch.setattr("src.main.list_manageable_sites", sites)
    response = portal_client.get(f"/administration/sites?organization_id={ORGANIZATION_ID}")
    assert "Alpha" in response.text
    assert "Beta" not in response.text


def test_create_site_uses_selected_accessible_organization(portal_client, monkeypatch):
    login(portal_client, monkeypatch)
    captured = {}
    async def create(**kwargs):
        captured.update(kwargs)
        return {"site_id": str(SITE_ID), "success": True}
    monkeypatch.setattr("src.main.create_site_workspace", create)
    response = portal_client.post("/administration/sites", data={
        "organization_id": str(ORGANIZATION_ID), "site_name": "Main Site",
        "site_timezone": "Europe/London", "lifecycle_status": "ACTIVE",
        "address_line1": "1 Main Road", "city": "London", "country": "UK",
        "sub_sector_id": "55555555-5555-4555-8555-555555555555",
    }, follow_redirects=False)
    assert response.status_code == 303
    assert response.headers["location"] == f"/administration/sites/{SITE_ID}"
    assert captured["organization_id"] == str(ORGANIZATION_ID)
    assert captured["sub_sector_id"] == "55555555-5555-4555-8555-555555555555"
    assert captured["code"] == "MAIN_SITE"
    assert captured["address"]["line1"] == "1 Main Road"


def test_selected_sites_scope_cannot_open_create_page(portal_client, monkeypatch):
    login(portal_client, monkeypatch, scope="SELECTED_SITES")
    response = portal_client.get("/administration/sites/new", follow_redirects=False)
    assert response.status_code == 303
    assert response.headers["location"] == "/forbidden"


def test_site_detail_and_edit_are_loaded_through_scope_checked_contract(portal_client, monkeypatch):
    login(portal_client, monkeypatch)
    site = {"site_id": str(SITE_ID), "organization_id": str(ORGANIZATION_ID),
            "organization_name": "Organization One", "site_name": "Site One",
            "site_code": "SITE_1", "timezone": "Asia/Kolkata", "address": {},
            "lifecycle_status": "ACTIVE", "created_at": None, "updated_at": None}
    async def get_site(**kwargs):
        return site
    monkeypatch.setattr("src.main.get_site_workspace", get_site)
    detail = portal_client.get(f"/administration/sites/{SITE_ID}")
    edit = portal_client.get(f"/administration/sites/{SITE_ID}/edit")
    assert detail.status_code == 200 and "Site One" in detail.text
    assert edit.status_code == 200 and "Save changes" in edit.text


def test_inaccessible_site_redirects_without_disclosure(portal_client, monkeypatch):
    login(portal_client, monkeypatch)
    async def get_site(**kwargs):
        return None
    monkeypatch.setattr("src.main.get_site_workspace", get_site)
    response = portal_client.get(f"/administration/sites/{SITE_ID}", follow_redirects=False)
    assert response.status_code == 303
    assert response.headers["location"] == "/administration/sites?context_error=1"
