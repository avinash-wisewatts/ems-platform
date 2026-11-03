"""EMS Web App Admin -> Users JSON API (src.routers.user_management_api).

Route-level tests through the real Administration App (src.main): the real
PortalAuthenticationMiddleware, the signed ems_admin_session cookie and the
real permission map; only the database-facing service functions are faked.
The database functions themselves (self-protection, scope containment,
tenant isolation, audit) are tested against the real database in
test_user_management_db.py.
"""

from __future__ import annotations

from datetime import datetime, timezone
from typing import Any

import pytest

from src.auth.models import AuthenticatedPortalUser, PortalUserAuthenticationRecord
from src.auth.security import AuthenticationStatus, hash_portal_password
from src.auth.service import AuthenticationResult

API = "/api/admin/v1"
ORIGIN = {"Origin": "http://testserver"}
ORG_A = "00000000-0000-0000-0000-00000000aa01"
ORG_B = "00000000-0000-0000-0000-00000000bb01"
SITE_A1 = "00000000-0000-0000-0000-0000000a0001"
SITE_A2 = "00000000-0000-0000-0000-0000000a0002"
NOW = datetime(2026, 11, 3, 10, 0, tzinfo=timezone.utc)

ACTORS = {
    "global_admin": dict(portal_user_id=700, role_code="ADMIN", access_scope_mode="GLOBAL", organization_id=None, site_ids=()),
    "org_admin": dict(portal_user_id=701, role_code="ADMIN", access_scope_mode="ORGANIZATION", organization_id=ORG_A, site_ids=()),
    "sites_admin": dict(portal_user_id=702, role_code="ADMIN", access_scope_mode="SELECTED_SITES", organization_id=ORG_A, site_ids=(SITE_A1,)),
    "operator": dict(portal_user_id=703, role_code="OPERATOR", access_scope_mode="GLOBAL", organization_id=None, site_ids=()),
    "viewer": dict(portal_user_id=704, role_code="VIEWER", access_scope_mode="ORGANIZATION", organization_id=ORG_A, site_ids=()),
}


def _row(portal_user_id: int, **overrides: Any) -> dict[str, Any]:
    row = {
        "portal_user_id": portal_user_id,
        "username": f"user{portal_user_id}@example.com",
        "display_name": f"User {portal_user_id}",
        "email": f"user{portal_user_id}@example.com",
        "role_code": "VIEWER",
        "organization_id": ORG_A,
        "access_scope_mode": "ORGANIZATION",
        "site_ids": [],
        "is_active": True,
        "created_at": NOW,
        "updated_at": NOW,
    }
    row.update(overrides)
    return row


class FakeDatabaseError(Exception):
    """Stands in for psycopg.errors.DatabaseError with sqlstate / diag."""

    def __init__(self, sqlstate: str, message: str, constraint: str | None = None) -> None:
        super().__init__(message)
        self.sqlstate = sqlstate
        self.diag = type("Diag", (), {"message_primary": message, "constraint_name": constraint})()


class FakeUserStore:
    """Records every service call; rows are what list_manageable_users returns."""

    def __init__(self) -> None:
        self.rows: list[dict[str, Any]] = [
            _row(700, username="admin@wisewatts.test", role_code="ADMIN", access_scope_mode="GLOBAL", organization_id=None),
            _row(701, role_code="ADMIN"),
            _row(710),
            _row(711, access_scope_mode="SELECTED_SITES", site_ids=[SITE_A1], is_active=False),
        ]
        self.calls: list[tuple[str, dict[str, Any]]] = []
        self.fail_with: Exception | None = None

    async def list_manageable_users(self, *, actor_portal_user_id: int):
        self.calls.append(("list", {"actor": actor_portal_user_id}))
        return list(self.rows)

    async def create(self, **kwargs):
        self.calls.append(("create", kwargs))
        if self.fail_with:
            raise self.fail_with
        new_id = 900
        self.rows.append(
            _row(
                new_id,
                username=kwargs["username"],
                display_name=kwargs["display_name"],
                email=kwargs["email"],
                role_code=kwargs["role_code"],
                access_scope_mode=kwargs["access_scope_mode"],
                organization_id=kwargs["organization_id"],
                site_ids=list(kwargs["site_ids"]),
                is_active=kwargs["is_active"],
            )
        )
        return new_id

    async def apply(self, **kwargs):
        self.calls.append(("apply", kwargs))
        if self.fail_with:
            raise self.fail_with

    async def reset(self, **kwargs):
        self.calls.append(("reset", kwargs))
        if self.fail_with:
            raise self.fail_with

    async def change_own(self, **kwargs):
        self.calls.append(("change_own", kwargs))

    async def organizations(self):
        return [
            {"id": ORG_A, "organization_code": "ORG_A", "organization_name": "Org A", "description": None, "is_active": True},
            {"id": ORG_B, "organization_code": "ORG_B", "organization_name": "Org B", "description": None, "is_active": True},
        ]

    async def sites(self, *, portal_user_id: int):
        return [
            {"id": SITE_A1, "organization_id": ORG_A, "organization_code": "ORG_A", "organization_name": "Org A",
             "site_code": "A1", "site_name": "Site A1", "timezone": "Asia/Kolkata", "address": {}, "is_active": True},
            {"id": SITE_A2, "organization_id": ORG_A, "organization_code": "ORG_A", "organization_name": "Org A",
             "site_code": "A2", "site_name": "Site A2", "timezone": "Asia/Kolkata", "address": {}, "is_active": True},
        ]

    def of(self, name: str) -> list[dict[str, Any]]:
        return [kwargs for call, kwargs in self.calls if call == name]


@pytest.fixture
def store(monkeypatch) -> FakeUserStore:
    fake = FakeUserStore()
    module = "src.routers.user_management_api"
    monkeypatch.setattr(f"{module}.list_manageable_users", fake.list_manageable_users)
    monkeypatch.setattr(f"{module}.create_managed_user_with_status", fake.create)
    monkeypatch.setattr(f"{module}.apply_managed_user_changes", fake.apply)
    monkeypatch.setattr(f"{module}.reset_managed_user_password", fake.reset)
    monkeypatch.setattr(f"{module}.change_own_password", fake.change_own)
    monkeypatch.setattr(f"{module}.list_organizations", fake.organizations)
    monkeypatch.setattr(f"{module}.list_accessible_sites", fake.sites)
    monkeypatch.setattr(f"{module}.DatabaseError", FakeDatabaseError)
    # Hashing is real but slow; the format is what matters here.
    monkeypatch.setattr(f"{module}.hash_portal_password", lambda password: f"$argon2id$fake${len(password)}")
    return fake


def sign_in(client, monkeypatch, actor_key: str) -> AuthenticatedPortalUser:
    identity = AuthenticatedPortalUser(username=f"{actor_key}@example.com", display_name=actor_key, **ACTORS[actor_key])

    async def fake_authenticate(username: str, password: str) -> AuthenticationResult:
        return AuthenticationResult(authenticated=True, user=identity, status=AuthenticationStatus.AUTHENTICATED)

    monkeypatch.setattr("src.main.authenticate_portal_user", fake_authenticate)
    response = client.post("/login", data={"username": identity.username, "password": "x", "next_path": "/app/"})
    assert response.status_code == 303
    return identity


# --- authentication / authorization ---------------------------------------------------------


def test_unauthenticated_request_gets_json_401_not_a_login_redirect(portal_client) -> None:
    response = portal_client.get(f"{API}/users")
    assert response.status_code == 401
    assert response.json()["error"] == "unauthenticated"


@pytest.mark.parametrize("actor", ["operator", "viewer"])
@pytest.mark.parametrize(
    "method,path",
    [("GET", "/users"), ("GET", "/users/options"), ("GET", "/users/710"), ("POST", "/users"),
     ("PATCH", "/users/710"), ("POST", "/users/710/password"), ("POST", "/me/password")],
)
def test_non_administrators_are_refused_every_route(portal_client, monkeypatch, store, actor, method, path) -> None:
    sign_in(portal_client, monkeypatch, actor)
    response = portal_client.request(method, f"{API}{path}", json={}, headers=ORIGIN)
    assert response.status_code == 403
    assert response.json()["error"] == "forbidden"
    assert not any(call in {"create", "apply", "reset", "change_own"} for call, _ in store.calls)


def test_unknown_admin_api_path_is_denied(portal_client, monkeypatch, store) -> None:
    sign_in(portal_client, monkeypatch, "global_admin")
    assert portal_client.get(f"{API}/organizations").status_code == 403


def test_me_advertises_user_manage_in_the_administration_app(portal_client, monkeypatch) -> None:
    sign_in(portal_client, monkeypatch, "org_admin")
    assert "user.manage" in portal_client.get("/api/v1/me").json()["permissions"]


def test_me_for_a_viewer_has_no_user_manage(portal_client, monkeypatch) -> None:
    sign_in(portal_client, monkeypatch, "viewer")
    assert "user.manage" not in portal_client.get("/api/v1/me").json()["permissions"]


# --- listing / options -------------------------------------------------------------------------


def test_list_users_is_the_database_manageable_set_with_names_and_no_secrets(portal_client, monkeypatch, store) -> None:
    sign_in(portal_client, monkeypatch, "global_admin")
    response = portal_client.get(f"{API}/users")
    assert response.status_code == 200
    assert response.headers["cache-control"] == "no-store"
    users = {u["portal_user_id"]: u for u in response.json()["users"]}
    assert set(users) == {700, 701, 710, 711}
    assert store.of("list") == [{"actor": 700}]                       # scope comes from the session
    assert users[700]["is_self"] is True and users[710]["is_self"] is False
    assert users[710]["organization_name"] == "Org A"
    assert users[711]["sites"] == [{"site_id": SITE_A1, "site_name": "Site A1", "site_code": "A1"}]
    assert users[701]["role_label"] == "Administrator"
    body = response.text.lower()
    assert "password" not in body and "argon2" not in body and "hash" not in body


def test_get_user_outside_scope_is_404(portal_client, monkeypatch, store) -> None:
    sign_in(portal_client, monkeypatch, "org_admin")
    assert portal_client.get(f"{API}/users/9999").status_code == 404
    assert portal_client.get(f"{API}/users/710").json()["user"]["username"] == "user710@example.com"


def test_options_for_global_admin(portal_client, monkeypatch, store) -> None:
    sign_in(portal_client, monkeypatch, "global_admin")
    body = portal_client.get(f"{API}/users/options").json()
    assert [r["role_code"] for r in body["roles"]] == ["ADMIN", "OPERATOR", "VIEWER"]
    assert all(r["assignable"] for r in body["roles"])
    assert "user.manage" in next(r for r in body["roles"] if r["role_code"] == "ADMIN")["permissions"]
    assert "user.manage" not in next(r for r in body["roles"] if r["role_code"] == "OPERATOR")["permissions"]
    assert [s["access_scope_mode"] for s in body["scopes"]] == ["GLOBAL", "ORGANIZATION", "SELECTED_SITES"]
    assert {o["organization_id"] for o in body["organizations"]} == {ORG_A, ORG_B}
    assert body["password_policy"]["min_length"] == 12


def test_options_for_organization_admin_never_offer_global_or_other_tenants(portal_client, monkeypatch, store) -> None:
    sign_in(portal_client, monkeypatch, "org_admin")
    body = portal_client.get(f"{API}/users/options").json()
    assert [s["access_scope_mode"] for s in body["scopes"]] == ["ORGANIZATION", "SELECTED_SITES"]
    assert [o["organization_id"] for o in body["organizations"]] == [ORG_A]


# --- create ----------------------------------------------------------------------------------------


def _new_user(**overrides: Any) -> dict[str, Any]:
    body = {
        "username": "New.User@Example.com",
        "display_name": "  New   User ",
        "email": "new.user@example.com",
        "role_code": "VIEWER",
        "access_scope_mode": "SELECTED_SITES",
        "organization_id": ORG_A,
        "site_ids": [SITE_A1],
    }
    body.update(overrides)
    return body


def test_create_with_generated_password_returns_it_once_and_stores_only_a_hash(portal_client, monkeypatch, store) -> None:
    sign_in(portal_client, monkeypatch, "global_admin")
    response = portal_client.post(f"{API}/users", json=_new_user(), headers=ORIGIN)
    assert response.status_code == 201
    assert response.headers["cache-control"] == "no-store"
    temporary = response.json()["temporary_password"]
    assert temporary and len(temporary) >= 12
    created = store.of("create")[0]
    assert created["username"] == "new.user@example.com"
    assert created["display_name"] == "New User"
    assert created["password_hash"].startswith("$argon2id$") and temporary not in created["password_hash"]
    assert created["access_scope_mode"] == "SELECTED_SITES" and created["site_ids"] == (SITE_A1,)
    assert created["is_active"] is True and created["actor_portal_user_id"] == 700
    assert response.json()["user"]["username"] == "new.user@example.com"


def test_create_with_an_admin_chosen_password_does_not_echo_it(portal_client, monkeypatch, store) -> None:
    sign_in(portal_client, monkeypatch, "global_admin")
    response = portal_client.post(f"{API}/users", json=_new_user(password="Chosen-Password-123", is_active=False), headers=ORIGIN)
    assert response.status_code == 201
    assert response.json()["temporary_password"] is None
    assert "Chosen-Password-123" not in response.text
    assert store.of("create")[0]["is_active"] is False


@pytest.mark.parametrize(
    "overrides,fragment",
    [
        ({"username": ""}, "Username is required"),
        ({"username": "bad name"}, "Username may contain"),
        ({"display_name": "   "}, "Full name is required"),
        ({"email": "not-an-email"}, "valid email"),
        ({"password": "short"}, "at least 12"),
        ({"password": "new.user@example.com"}, "cannot be the username"),
        ({"access_scope_mode": "EVERYTHING"}, "Unsupported"),
        ({"access_scope_mode": "SELECTED_SITES", "site_ids": []}, "site"),
        ({"access_scope_mode": "ORGANIZATION", "organization_id": None, "site_ids": []}, "require an organization"),
    ],
)
def test_create_validation(portal_client, monkeypatch, store, overrides, fragment) -> None:
    sign_in(portal_client, monkeypatch, "global_admin")
    response = portal_client.post(f"{API}/users", json=_new_user(**overrides), headers=ORIGIN)
    assert response.status_code == 400, response.text
    assert fragment.lower() in response.json()["detail"].lower()
    assert store.of("create") == []


def test_duplicate_username_is_409(portal_client, monkeypatch, store) -> None:
    sign_in(portal_client, monkeypatch, "global_admin")
    store.fail_with = FakeDatabaseError("23505", "duplicate key", "ux_portal_users_username")
    response = portal_client.post(f"{API}/users", json=_new_user(), headers=ORIGIN)
    assert response.status_code == 409
    assert response.json()["error"] == "duplicate_username"


def test_duplicate_email_is_409(portal_client, monkeypatch, store) -> None:
    sign_in(portal_client, monkeypatch, "global_admin")
    store.fail_with = FakeDatabaseError("23505", "duplicate key", "ux_portal_users_email")
    assert portal_client.post(f"{API}/users", json=_new_user(), headers=ORIGIN).json()["error"] == "duplicate_email"


def test_database_authorization_refusal_is_403(portal_client, monkeypatch, store) -> None:
    sign_in(portal_client, monkeypatch, "global_admin")
    store.fail_with = FakeDatabaseError("42501", "Target scope is outside the actor organization.")
    response = portal_client.post(f"{API}/users", json=_new_user(), headers=ORIGIN)
    assert response.status_code == 403
    assert response.json()["detail"] == "Target scope is outside the actor organization."


def test_unexpected_database_error_is_not_leaked(portal_client, monkeypatch, store) -> None:
    sign_in(portal_client, monkeypatch, "global_admin")
    store.fail_with = FakeDatabaseError("XX000", "internal: relation admin.portal_users column x")
    response = portal_client.post(f"{API}/users", json=_new_user(), headers=ORIGIN)
    assert response.status_code == 409
    assert "admin.portal_users" not in response.text


def test_writes_without_same_origin_are_refused(portal_client, monkeypatch, store) -> None:
    sign_in(portal_client, monkeypatch, "global_admin")
    for headers in ({}, {"Origin": "https://evil.example"}, {"Origin": "null"}):
        assert portal_client.post(f"{API}/users", json=_new_user(), headers=headers).status_code == 403
        assert portal_client.patch(f"{API}/users/710", json={"is_active": False}, headers=headers).status_code == 403
        assert portal_client.post(f"{API}/users/710/password", json={}, headers=headers).status_code == 403
    assert store.of("create") == [] and store.of("apply") == [] and store.of("reset") == []


def test_unknown_fields_are_rejected(portal_client, monkeypatch, store) -> None:
    sign_in(portal_client, monkeypatch, "global_admin")
    response = portal_client.post(f"{API}/users", json=_new_user(password_hash="$argon2id$x"), headers=ORIGIN)
    assert response.status_code == 422
    assert store.of("create") == []


# --- privilege escalation -------------------------------------------------------------------


def test_organization_admin_cannot_create_global_users(portal_client, monkeypatch, store) -> None:
    sign_in(portal_client, monkeypatch, "org_admin")
    response = portal_client.post(
        f"{API}/users", json=_new_user(access_scope_mode="GLOBAL", organization_id=None, site_ids=[]), headers=ORIGIN
    )
    assert response.status_code == 403
    assert store.of("create") == []


def test_organization_admin_always_creates_inside_their_own_organization(portal_client, monkeypatch, store) -> None:
    sign_in(portal_client, monkeypatch, "org_admin")
    response = portal_client.post(
        f"{API}/users", json=_new_user(access_scope_mode="ORGANIZATION", organization_id=ORG_B, site_ids=[]), headers=ORIGIN
    )
    assert response.status_code == 201
    assert store.of("create")[0]["organization_id"] == ORG_A


def test_selected_sites_admin_cannot_grant_sites_they_lack(portal_client, monkeypatch, store) -> None:
    sign_in(portal_client, monkeypatch, "sites_admin")
    response = portal_client.post(f"{API}/users", json=_new_user(site_ids=[SITE_A1, SITE_A2]), headers=ORIGIN)
    assert response.status_code == 403
    assert portal_client.post(
        f"{API}/users", json=_new_user(access_scope_mode="ORGANIZATION", site_ids=[]), headers=ORIGIN
    ).status_code == 403
    assert store.of("create") == []


@pytest.mark.parametrize(
    "patch",
    [{"role_code": "VIEWER"}, {"is_active": False}, {"access_scope_mode": "ORGANIZATION", "organization_id": ORG_A}],
)
def test_administrators_cannot_change_their_own_role_scope_or_status(portal_client, monkeypatch, store, patch) -> None:
    sign_in(portal_client, monkeypatch, "global_admin")
    response = portal_client.patch(f"{API}/users/700", json=patch, headers=ORIGIN)
    assert response.status_code == 403
    assert store.of("apply") == []


def test_administrators_may_edit_their_own_details(portal_client, monkeypatch, store) -> None:
    sign_in(portal_client, monkeypatch, "global_admin")
    response = portal_client.patch(f"{API}/users/700", json={"display_name": "Renamed Admin"}, headers=ORIGIN)
    assert response.status_code == 200
    assert store.of("apply")[0]["details"] == ("Renamed Admin", "user700@example.com")


def test_administrators_cannot_reset_their_own_password(portal_client, monkeypatch, store) -> None:
    sign_in(portal_client, monkeypatch, "global_admin")
    assert portal_client.post(f"{API}/users/700/password", json={}, headers=ORIGIN).status_code == 403
    assert store.of("reset") == []


def test_unknown_role_is_rejected(portal_client, monkeypatch, store) -> None:
    sign_in(portal_client, monkeypatch, "global_admin")
    assert portal_client.patch(f"{API}/users/710", json={"role_code": "PLATFORM_ADMIN"}, headers=ORIGIN).status_code == 400


# --- edit --------------------------------------------------------------------------------------------


def test_edit_applies_only_what_changed_in_one_call(portal_client, monkeypatch, store) -> None:
    sign_in(portal_client, monkeypatch, "global_admin")
    response = portal_client.patch(
        f"{API}/users/710",
        json={
            "display_name": "User 710",                      # unchanged
            "email": "changed@example.com",
            "role_code": "operator",
            "access_scope_mode": "SELECTED_SITES",
            "organization_id": ORG_A,
            "site_ids": [SITE_A2],
            "is_active": True,                               # unchanged
        },
        headers=ORIGIN,
    )
    assert response.status_code == 200, response.text
    [applied] = store.of("apply")
    assert applied["target_portal_user_id"] == 710 and applied["actor_portal_user_id"] == 700
    assert applied["details"] == ("User 710", "changed@example.com")
    assert applied["role_code"] == "OPERATOR"
    assert applied["access_scope"] == ("SELECTED_SITES", ORG_A, (SITE_A2,))
    assert applied["is_active"] is None


def test_edit_with_no_change_writes_nothing(portal_client, monkeypatch, store) -> None:
    sign_in(portal_client, monkeypatch, "global_admin")
    response = portal_client.patch(
        f"{API}/users/711",
        json={"role_code": "VIEWER", "is_active": False, "access_scope_mode": "SELECTED_SITES",
              "organization_id": ORG_A, "site_ids": [SITE_A1]},
        headers=ORIGIN,
    )
    assert response.status_code == 200
    assert store.of("apply") == []


def test_deactivate_and_reactivate(portal_client, monkeypatch, store) -> None:
    sign_in(portal_client, monkeypatch, "org_admin")
    assert portal_client.patch(f"{API}/users/710", json={"is_active": False}, headers=ORIGIN).status_code == 200
    assert portal_client.patch(f"{API}/users/711", json={"is_active": True}, headers=ORIGIN).status_code == 200
    assert [a["is_active"] for a in store.of("apply")] == [False, True]


def test_edit_outside_scope_is_404_and_writes_nothing(portal_client, monkeypatch, store) -> None:
    sign_in(portal_client, monkeypatch, "org_admin")
    assert portal_client.patch(f"{API}/users/9999", json={"is_active": False}, headers=ORIGIN).status_code == 404
    assert store.of("apply") == []


# --- password reset / own password change ----------------------------------------------------------


def test_password_reset_generates_a_temporary_password(portal_client, monkeypatch, store) -> None:
    sign_in(portal_client, monkeypatch, "org_admin")
    response = portal_client.post(f"{API}/users/710/password", json={}, headers=ORIGIN)
    assert response.status_code == 200
    assert response.headers["cache-control"] == "no-store"
    temporary = response.json()["temporary_password"]
    [reset] = store.of("reset")
    assert reset["target_portal_user_id"] == 710 and reset["actor_portal_user_id"] == 701
    assert reset["password_hash"].startswith("$argon2id$") and temporary not in reset["password_hash"]


def test_password_reset_with_chosen_password_is_policy_checked(portal_client, monkeypatch, store) -> None:
    sign_in(portal_client, monkeypatch, "org_admin")
    assert portal_client.post(f"{API}/users/710/password", json={"password": "short"}, headers=ORIGIN).status_code == 400
    response = portal_client.post(f"{API}/users/710/password", json={"password": "A-Long-Enough-Pass1"}, headers=ORIGIN)
    assert response.status_code == 200 and response.json()["temporary_password"] is None


def _record(identity: AuthenticatedPortalUser, password: str, *, active: bool = True) -> PortalUserAuthenticationRecord:
    return PortalUserAuthenticationRecord(
        portal_user_id=identity.portal_user_id, username=identity.username, display_name=identity.display_name,
        password_hash=hash_portal_password(password), role_code=identity.role_code, is_active=active,
        failed_login_count=0, locked_until=None, organization_id=identity.organization_id,
        access_scope_mode=identity.access_scope_mode, site_ids=identity.site_ids,
    )


def test_own_password_change_requires_the_current_password(portal_client, monkeypatch, store) -> None:
    identity = sign_in(portal_client, monkeypatch, "global_admin")
    record = _record(identity, "Current-Password-1")
    failures: list[int] = []

    async def lookup(username: str):
        return record if username == identity.username else None

    async def failure(portal_user_id: int) -> None:
        failures.append(portal_user_id)

    monkeypatch.setattr("src.routers.user_management_api.get_portal_user_for_authentication", lookup)
    monkeypatch.setattr("src.routers.user_management_api.record_portal_login_failure", failure)

    wrong = portal_client.post(
        f"{API}/me/password", json={"current_password": "Wrong-Password-1", "new_password": "Brand-New-Pass-22"}, headers=ORIGIN
    )
    assert wrong.status_code == 400 and wrong.json()["error"] == "invalid_current_password"
    assert failures == [700] and store.of("change_own") == []

    weak = portal_client.post(
        f"{API}/me/password", json={"current_password": "Current-Password-1", "new_password": "short"}, headers=ORIGIN
    )
    assert weak.status_code == 400

    ok = portal_client.post(
        f"{API}/me/password", json={"current_password": "Current-Password-1", "new_password": "Brand-New-Pass-22"}, headers=ORIGIN
    )
    assert ok.status_code == 204
    [changed] = store.of("change_own")
    assert changed["portal_user_id"] == 700 and changed["password_hash"].startswith("$argon2id$")


# --- boundary: the customer API never serves user management ----------------------------------


def test_customer_api_has_no_user_management_routes() -> None:
    from src.customer_main import app as customer_app

    paths = {getattr(route, "path", "") for route in customer_app.routes}
    assert not any(path.startswith("/api/admin") for path in paths)
    assert not getattr(customer_app.state, "user_management_api", False)


def test_user_management_routes_are_not_under_the_analytics_api() -> None:
    from src.routers.analytics_api import router as analytics_router

    for route in analytics_router.routes:
        assert "users" not in getattr(route, "path", "")
        assert not (set(getattr(route, "methods", set())) & {"PATCH", "PUT", "DELETE"})
