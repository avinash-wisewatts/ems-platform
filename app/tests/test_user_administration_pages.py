"""Administration App user management (server-rendered, /administration/users)
-- the complete staff workflow that replaces the EMS Web App's Admin -> Users
screen on staging (ADR-023: the web app is customer-host only there).

Route-level tests with the database layer faked; the database rules
themselves (scope, self-protection, audit) are tested against the disposable
database in test_user_management_db.py and test_portal_user_audit_history_db.py.

Covered here:
- authorization: user.manage for every user page (reads too), own password for
  every signed-in role, non-administrators get /forbidden;
- create: shared account policy, generated temporary password shown once
  (no-store), chosen password policy-checked;
- details edit, administrator password reset (generate / set, never one's own,
  another ADMIN only by GLOBAL staff), own password change (current password,
  lockout, failure counting);
- audit history rendering (labels, actor visibility, unavailable history);
- organization filter;
- cross-origin form posts refused before anything is written;
- a user outside the actor's scope is never shown or changed.
"""

from __future__ import annotations

from datetime import datetime, timedelta, timezone
from typing import Any

import pytest

from src.auth.authorization import PortalPermission, required_permission_for_request
from src.auth.models import AuthenticatedPortalUser, PortalUserAuthenticationRecord

ORG_A = "11111111-1111-4111-8111-111111111111"
ORG_B = "22222222-2222-4222-8222-222222222222"
SITE_A1 = "33333333-3333-4333-8333-333333333333"
SAME_ORIGIN = {"Origin": "http://testserver"}
NOW = datetime(2026, 11, 4, 12, 0, tzinfo=timezone.utc)

IDENTITIES = {
    "global_admin": dict(portal_user_id=700, role_code="ADMIN", access_scope_mode="GLOBAL", organization_id=None),
    "org_admin": dict(portal_user_id=710, role_code="ADMIN", access_scope_mode="ORGANIZATION", organization_id=ORG_A),
    "operator": dict(portal_user_id=720, role_code="OPERATOR", access_scope_mode="ORGANIZATION", organization_id=ORG_A),
    "viewer": dict(portal_user_id=730, role_code="VIEWER", access_scope_mode="ORGANIZATION", organization_id=ORG_A),
}


def _row(portal_user_id: int, *, role: str = "VIEWER", scope: str = "ORGANIZATION", org: str | None = ORG_A,
         username: str | None = None, active: bool = True) -> dict[str, Any]:
    username = username or f"user{portal_user_id}@example.com"
    return {
        "portal_user_id": portal_user_id,
        "username": username,
        "display_name": f"User {portal_user_id}",
        "email": username,
        "role_code": role,
        "organization_id": org,
        "access_scope_mode": scope,
        "site_ids": [],
        "is_active": active,
        "created_at": NOW,
        "updated_at": NOW,
    }


class FakeDatabaseError(Exception):
    def __init__(self, sqlstate: str, message: str) -> None:
        super().__init__(message)
        self.sqlstate = sqlstate

        class _Diag:
            message_primary = message
            constraint_name = None

        self.diag = _Diag()


class Store:
    def __init__(self) -> None:
        self.calls: list[tuple[str, dict]] = []
        self.users: list[dict[str, Any]] = []
        self.audit: list[dict[str, Any]] | Exception = []
        self.fail_with: Exception | None = None

    def of(self, name: str) -> list[dict]:
        return [kwargs for call, kwargs in self.calls if call == name]

    async def list_users(self, *, actor_portal_user_id: int):
        return list(self.users)

    async def list_audit(self, **kwargs):
        self.calls.append(("audit", kwargs))
        if isinstance(self.audit, Exception):
            raise self.audit
        return list(self.audit)

    async def _write(self, name: str, kwargs: dict):
        self.calls.append((name, kwargs))
        if self.fail_with is not None:
            raise self.fail_with

    async def create(self, **kwargs):
        await self._write("create", kwargs)
        return 900

    async def apply(self, **kwargs):
        await self._write("apply", kwargs)

    async def reset(self, **kwargs):
        await self._write("reset", kwargs)

    async def change_own(self, **kwargs):
        await self._write("change_own", kwargs)

    async def organizations(self):
        return [
            {"id": ORG_A, "organization_name": "Org A", "organization_code": "ORG_A"},
            {"id": ORG_B, "organization_name": "Org B", "organization_code": "ORG_B"},
        ]

    async def sites(self, *, portal_user_id: int):
        return [{"id": SITE_A1, "organization_id": ORG_A, "organization_name": "Org A",
                 "site_code": "A1", "site_name": "Site A1"}]


@pytest.fixture
def store(monkeypatch) -> Store:
    fake = Store()
    m = "src.main"
    monkeypatch.setattr(f"{m}.list_manageable_users", fake.list_users)
    monkeypatch.setattr(f"{m}.list_managed_user_audit", fake.list_audit)
    monkeypatch.setattr(f"{m}.create_managed_user", fake.create)
    monkeypatch.setattr(f"{m}.apply_managed_user_changes", fake.apply)
    monkeypatch.setattr(f"{m}.reset_managed_user_password", fake.reset)
    monkeypatch.setattr(f"{m}.list_organizations", fake.organizations)
    monkeypatch.setattr(f"{m}.list_accessible_sites", fake.sites)
    monkeypatch.setattr(f"{m}.DatabaseError", FakeDatabaseError)
    monkeypatch.setattr(f"{m}.hash_portal_password", lambda password: f"$argon2id$fake${len(password)}")
    monkeypatch.setattr("src.own_password.change_own_password", fake.change_own)
    monkeypatch.setattr("src.own_password.hash_portal_password", lambda password: f"$argon2id$fake${len(password)}")
    return fake


def sign_in(portal_client, monkeypatch, key: str) -> AuthenticatedPortalUser:
    from src.auth.security import AuthenticationStatus
    from src.auth.service import AuthenticationResult

    identity = AuthenticatedPortalUser(username=f"{key}@example.com", display_name=key, site_ids=(), **IDENTITIES[key])

    async def fake_authenticate(username, password, **kwargs):
        return AuthenticationResult(authenticated=True, user=identity, status=AuthenticationStatus.AUTHENTICATED)

    monkeypatch.setattr("src.main.authenticate_portal_user", fake_authenticate)
    response = portal_client.post("/login", data={"username": identity.username, "password": "x", "next_path": "/administration"})
    assert response.status_code == 303
    return identity


# --- authorization --------------------------------------------------------------------------


@pytest.mark.parametrize("method,path", [
    ("GET", "/administration/users"),
    ("GET", "/administration/users/new"),
    ("GET", "/administration/users/42"),
    ("GET", "/administration/users/42/edit"),
    ("POST", "/administration/users/42/details"),
    ("POST", "/administration/users/42/password"),
])
def test_every_user_page_requires_user_manage(method, path):
    assert required_permission_for_request(method, path) is PortalPermission.USER_MANAGE


@pytest.mark.parametrize("method", ["GET", "POST"])
def test_own_password_page_is_open_to_every_signed_in_role(method):
    assert required_permission_for_request(method, "/administration/account/password") is PortalPermission.DASHBOARD_VIEW


@pytest.mark.parametrize("key", ["operator", "viewer"])
@pytest.mark.parametrize("path", ["/administration/users", "/administration/users/701"])
def test_non_administrators_get_forbidden_for_user_pages(portal_client, monkeypatch, store, key, path):
    sign_in(portal_client, monkeypatch, key)
    response = portal_client.get(path)
    assert response.status_code == 303 and response.headers["location"] == "/forbidden"
    assert store.calls == []


@pytest.mark.parametrize("key", ["operator", "viewer"])
def test_non_administrators_cannot_reset_or_edit(portal_client, monkeypatch, store, key):
    sign_in(portal_client, monkeypatch, key)
    store.users = [_row(701)]
    for path, data in (("/administration/users/701/password", {"password_mode": "generate"}),
                       ("/administration/users/701/details", {"display_name": "X", "email": "x@example.com"})):
        response = portal_client.post(path, data=data, headers=SAME_ORIGIN)
        assert response.status_code == 303 and response.headers["location"] == "/forbidden"
    assert store.of("reset") == [] and store.of("apply") == []


def test_signed_out_user_pages_redirect_to_login(portal_client, store):
    response = portal_client.get("/administration/users/701")
    assert response.status_code == 303 and response.headers["location"].startswith("/login?next_path=")
    response = portal_client.get("/administration/account/password")
    assert response.status_code == 303 and response.headers["location"].startswith("/login?next_path=")


# --- cross-origin form posts ----------------------------------------------------------------


@pytest.mark.parametrize("path,data", [
    ("/administration/users", {"display_name": "N", "username": "n@example.com", "email": "n@example.com",
                               "role_code": "VIEWER", "access_scope_mode": "ORGANIZATION", "organization_id": ORG_A}),
    ("/administration/users/701/details", {"display_name": "X", "email": "x@example.com"}),
    ("/administration/users/701/password", {"password_mode": "generate"}),
    ("/administration/users/701/role", {"role_code": "OPERATOR"}),
    ("/administration/users/701/status", {"is_active": "false"}),
    ("/administration/account/password", {"current_password": "a", "new_password": "b", "new_password_confirm": "b"}),
])
def test_cross_origin_posts_are_refused_before_anything_runs(portal_client, monkeypatch, store, path, data):
    sign_in(portal_client, monkeypatch, "global_admin")
    store.users = [_row(701)]
    response = portal_client.post(path, data=data, headers={"Origin": "https://evil.example"})
    assert response.status_code == 403
    assert "Cross-origin" in response.text
    assert [c for c, _ in store.calls if c != "audit"] == []


# --- list -----------------------------------------------------------------------------------


def test_list_offers_search_role_status_and_organization_filters_for_staff(portal_client, monkeypatch, store):
    sign_in(portal_client, monkeypatch, "global_admin")
    store.users = [_row(701, org=ORG_A), _row(702, org=None, scope="GLOBAL", role="ADMIN")]
    page = portal_client.get("/administration/users").text
    for marker in ("data-user-search", "data-user-role", "data-user-status", "data-user-organization"):
        assert marker in page
    assert f'data-organization="{ORG_A}"' in page and 'data-organization="__global"' in page


def test_tenant_administrators_get_no_organization_filter(portal_client, monkeypatch, store):
    sign_in(portal_client, monkeypatch, "org_admin")
    store.users = [_row(701)]
    page = portal_client.get("/administration/users").text
    assert "<select data-user-organization>" not in page
    assert "Org B" not in page


# --- create ---------------------------------------------------------------------------------


CREATE = {"display_name": "  New   Person ", "username": " New.Person@Example.com ", "email": "new.person@example.com",
          "role_code": "VIEWER", "access_scope_mode": "ORGANIZATION", "organization_id": ORG_A}


def test_create_with_a_generated_password_shows_it_once_and_not_again(portal_client, monkeypatch, store):
    sign_in(portal_client, monkeypatch, "global_admin")
    response = portal_client.post("/administration/users", data={**CREATE, "password_mode": "generate"}, headers=SAME_ORIGIN)
    assert response.status_code == 201
    assert "no-store" in response.headers["cache-control"]
    [created] = store.of("create")
    assert created["username"] == "new.person@example.com"
    assert created["display_name"] == "New Person"
    assert created["password_hash"].startswith("$argon2id$")
    assert "data-temporary-password" in response.text
    shown = response.text.split("<code>", 1)[1].split("</code>", 1)[0]
    assert len(shown) >= 12 and created["password_hash"] == f"$argon2id$fake${len(shown)}"
    again = portal_client.get("/administration/users")
    assert shown not in again.text and "data-temporary-password" not in again.text


def test_create_with_a_chosen_password_is_policy_checked(portal_client, monkeypatch, store):
    sign_in(portal_client, monkeypatch, "global_admin")
    short = portal_client.post("/administration/users", data={**CREATE, "password_mode": "set", "password": "short"},
                               headers=SAME_ORIGIN)
    assert short.status_code == 400 and "at least 12 characters" in short.text
    same = portal_client.post("/administration/users",
                              data={**CREATE, "password_mode": "set", "password": "new.person@example.com"},
                              headers=SAME_ORIGIN)
    assert same.status_code == 400 and "cannot be the username" in same.text
    assert store.of("create") == []
    ok = portal_client.post("/administration/users",
                            data={**CREATE, "password_mode": "set", "password": "Chosen-Password-42"}, headers=SAME_ORIGIN)
    assert ok.status_code == 201 and "data-temporary-password" not in ok.text


def test_create_rejects_an_invalid_username_or_email(portal_client, monkeypatch, store):
    sign_in(portal_client, monkeypatch, "global_admin")
    bad_user = portal_client.post("/administration/users", data={**CREATE, "username": "bad name"}, headers=SAME_ORIGIN)
    bad_mail = portal_client.post("/administration/users", data={**CREATE, "email": "not-an-email"}, headers=SAME_ORIGIN)
    assert bad_user.status_code == 400 and bad_mail.status_code == 400
    assert store.of("create") == []


def test_tenant_administrators_cannot_create_global_users(portal_client, monkeypatch, store):
    sign_in(portal_client, monkeypatch, "org_admin")
    response = portal_client.post("/administration/users", data={**CREATE, "access_scope_mode": "GLOBAL"},
                                  headers=SAME_ORIGIN)
    assert response.status_code == 400 and store.of("create") == []


def test_database_refusal_message_is_shown_on_create(portal_client, monkeypatch, store):
    sign_in(portal_client, monkeypatch, "org_admin")
    store.fail_with = FakeDatabaseError("42501", "Target scope is outside the actor organization.")
    response = portal_client.post("/administration/users", data=CREATE, headers=SAME_ORIGIN)
    assert response.status_code == 409 and "Target scope is outside the actor organization." in response.text


# --- detail, details edit -------------------------------------------------------------------


def test_detail_page_shows_identity_access_reset_and_history(portal_client, monkeypatch, store):
    sign_in(portal_client, monkeypatch, "global_admin")
    store.users = [_row(701, org=ORG_A)]
    store.audit = [
        {"audit_id": "a2", "created_at": NOW, "event_type": "USER_ROLE_CHANGED", "actor_portal_user_id": 700,
         "actor_display_name": "Staff Admin", "actor_is_staff": True, "previous_role_code": "VIEWER",
         "new_role_code": "OPERATOR", "event_payload": {}},
        {"audit_id": "a1", "created_at": NOW - timedelta(days=1), "event_type": "USER_DETAILS_CHANGED",
         "actor_portal_user_id": None, "actor_display_name": None, "actor_is_staff": False,
         "previous_role_code": None, "new_role_code": None,
         "event_payload": {"previous_display_name": "Old", "new_display_name": "User 701"}},
    ]
    response = portal_client.get("/administration/users/701")
    assert response.status_code == 200 and "no-store" in response.headers["cache-control"]
    page = response.text
    assert "Org A" in page and "data-user-details-form" in page and "data-reset-password-form" in page
    assert page.count("data-audit-row") == 2
    assert "Role changed" in page and "Role: VIEWER -&gt; OPERATOR" in page
    assert "Name: Old -&gt; User 701" in page and "Another administrator" in page
    [audit_call] = store.of("audit")
    assert audit_call == {"actor_portal_user_id": 700, "target_portal_user_id": 701, "limit": 50}


def test_unavailable_history_does_not_break_the_page(portal_client, monkeypatch, store):
    sign_in(portal_client, monkeypatch, "global_admin")
    store.users = [_row(701)]
    store.audit = FakeDatabaseError("42883", "function admin.list_manageable_portal_user_audit does not exist")
    response = portal_client.get("/administration/users/701")
    assert response.status_code == 200 and "not available yet" in response.text
    assert "does not exist" not in response.text


def test_a_user_outside_the_scope_is_never_shown_or_changed(portal_client, monkeypatch, store):
    sign_in(portal_client, monkeypatch, "org_admin")
    store.users = [_row(701)]  # 799 is not manageable
    assert portal_client.get("/administration/users/799").headers["location"] == "/administration/users"
    for path, data in (("/administration/users/799/details", {"display_name": "X", "email": "x@example.com"}),
                       ("/administration/users/799/password", {"password_mode": "generate"})):
        response = portal_client.post(path, data=data, headers=SAME_ORIGIN)
        assert response.status_code == 303 and response.headers["location"] == "/administration/users"
    assert store.of("apply") == [] and store.of("reset") == [] and store.of("audit") == []


def test_details_edit_saves_normalized_name_and_email(portal_client, monkeypatch, store):
    sign_in(portal_client, monkeypatch, "org_admin")
    store.users = [_row(701)]
    response = portal_client.post("/administration/users/701/details",
                                  data={"display_name": "  Renamed   User ", "email": "renamed@example.com"},
                                  headers=SAME_ORIGIN)
    assert response.status_code == 200 and "Name and e-mail saved." in response.text
    [applied] = store.of("apply")
    assert applied["details"] == ("Renamed User", "renamed@example.com")
    assert applied["role_code"] is None and applied["access_scope"] is None and applied["is_active"] is None


def test_details_edit_validates_and_skips_no_op(portal_client, monkeypatch, store):
    sign_in(portal_client, monkeypatch, "org_admin")
    store.users = [_row(701)]
    bad = portal_client.post("/administration/users/701/details", data={"display_name": "X", "email": "nope"},
                             headers=SAME_ORIGIN)
    assert bad.status_code == 400 and "valid email" in bad.text
    same = portal_client.post("/administration/users/701/details",
                              data={"display_name": "User 701", "email": "user701@example.com"}, headers=SAME_ORIGIN)
    assert same.status_code == 200 and "No changes to save." in same.text
    assert store.of("apply") == []


def test_duplicate_email_is_reported_without_internals(portal_client, monkeypatch, store):
    sign_in(portal_client, monkeypatch, "org_admin")
    store.users = [_row(701)]
    err = FakeDatabaseError("23505", "duplicate key value violates unique constraint")
    err.diag.constraint_name = "ux_portal_users_email"
    store.fail_with = err
    response = portal_client.post("/administration/users/701/details",
                                  data={"display_name": "User 701", "email": "taken@example.com"}, headers=SAME_ORIGIN)
    assert response.status_code == 409 and "already exists" in response.text
    assert "duplicate key" not in response.text


# --- administrator password reset -------------------------------------------------------------


def test_reset_with_a_generated_password_shows_it_once(portal_client, monkeypatch, store):
    sign_in(portal_client, monkeypatch, "org_admin")
    store.users = [_row(701)]
    response = portal_client.post("/administration/users/701/password", data={"password_mode": "generate"},
                                  headers=SAME_ORIGIN)
    assert response.status_code == 200 and "no-store" in response.headers["cache-control"]
    [reset] = store.of("reset")
    assert reset["actor_portal_user_id"] == 710 and reset["target_portal_user_id"] == 701
    shown = response.text.split("<code>", 1)[1].split("</code>", 1)[0]
    assert reset["password_hash"] == f"$argon2id$fake${len(shown)}"
    assert "issue #172" in response.text
    assert shown not in portal_client.get("/administration/users/701").text


def test_reset_with_a_chosen_password_is_checked(portal_client, monkeypatch, store):
    sign_in(portal_client, monkeypatch, "org_admin")
    store.users = [_row(701)]
    mismatch = portal_client.post("/administration/users/701/password",
                                  data={"password_mode": "set", "password": "Chosen-Password-42", "password_confirm": "other"},
                                  headers=SAME_ORIGIN)
    short = portal_client.post("/administration/users/701/password",
                               data={"password_mode": "set", "password": "short", "password_confirm": "short"},
                               headers=SAME_ORIGIN)
    assert mismatch.status_code == 400 and short.status_code == 400
    assert store.of("reset") == []
    ok = portal_client.post("/administration/users/701/password",
                            data={"password_mode": "set", "password": "Chosen-Password-42",
                                  "password_confirm": "Chosen-Password-42"}, headers=SAME_ORIGIN)
    assert ok.status_code == 200 and "data-temporary-password" not in ok.text and len(store.of("reset")) == 1


def test_nobody_resets_their_own_password_here(portal_client, monkeypatch, store):
    sign_in(portal_client, monkeypatch, "global_admin")
    store.users = [_row(700, role="ADMIN", scope="GLOBAL", org=None)]
    page = portal_client.get("/administration/users/700").text
    assert "data-reset-password-form" not in page and "/administration/account/password" in page
    response = portal_client.post("/administration/users/700/password", data={"password_mode": "generate"},
                                  headers=SAME_ORIGIN)
    assert response.status_code == 403 and store.of("reset") == []


def test_tenant_administrators_cannot_reset_another_administrator(portal_client, monkeypatch, store):
    sign_in(portal_client, monkeypatch, "org_admin")
    store.users = [_row(711, role="ADMIN")]
    assert "data-reset-password-form" not in portal_client.get("/administration/users/711").text
    response = portal_client.post("/administration/users/711/password", data={"password_mode": "generate"},
                                  headers=SAME_ORIGIN)
    assert response.status_code == 403 and "WiseWatts staff" in response.text
    assert store.of("reset") == []


def test_staff_can_reset_another_administrator(portal_client, monkeypatch, store):
    sign_in(portal_client, monkeypatch, "global_admin")
    store.users = [_row(711, role="ADMIN")]
    response = portal_client.post("/administration/users/711/password", data={"password_mode": "generate"},
                                  headers=SAME_ORIGIN)
    assert response.status_code == 200 and len(store.of("reset")) == 1


def test_database_refusal_of_a_reset_is_shown(portal_client, monkeypatch, store):
    sign_in(portal_client, monkeypatch, "org_admin")
    store.users = [_row(701)]
    store.fail_with = FakeDatabaseError("42501", "Target user is outside the actor scope.")
    response = portal_client.post("/administration/users/701/password", data={"password_mode": "generate"},
                                  headers=SAME_ORIGIN)
    assert response.status_code == 409 and "outside the actor scope" in response.text
    assert "data-temporary-password" not in response.text


# --- own password ---------------------------------------------------------------------------


def _harness(monkeypatch, identity, password: str, *, locked: bool = False):
    from src.auth.security import hash_portal_password

    record = PortalUserAuthenticationRecord(
        portal_user_id=identity.portal_user_id, username=identity.username, display_name=identity.display_name,
        password_hash=hash_portal_password(password), role_code=identity.role_code, is_active=True,
        failed_login_count=5 if locked else 0,
        locked_until=(datetime.now(timezone.utc) + timedelta(minutes=10)) if locked else None,
        organization_id=identity.organization_id, access_scope_mode=identity.access_scope_mode, site_ids=identity.site_ids,
    )
    failures: list[int] = []

    async def lookup(username):
        return record if username == identity.username else None

    async def failure(portal_user_id):
        failures.append(portal_user_id)

    monkeypatch.setattr("src.own_password.get_portal_user_for_authentication", lookup)
    monkeypatch.setattr("src.own_password.record_portal_login_failure", failure)
    return failures


@pytest.mark.parametrize("key", ["global_admin", "org_admin", "operator", "viewer"])
def test_every_signed_in_role_can_change_its_own_password(portal_client, monkeypatch, store, key):
    identity = sign_in(portal_client, monkeypatch, key)
    _harness(monkeypatch, identity, "Current-Password-1")
    assert portal_client.get("/administration/account/password").status_code == 200
    response = portal_client.post("/administration/account/password",
                                  data={"current_password": "Current-Password-1", "new_password": "Brand-New-Pass-22",
                                        "new_password_confirm": "Brand-New-Pass-22"}, headers=SAME_ORIGIN)
    assert response.status_code == 200 and "Your password was changed." in response.text
    [changed] = store.of("change_own")
    assert changed["portal_user_id"] == identity.portal_user_id


def test_own_password_needs_the_current_password_and_counts_failures(portal_client, monkeypatch, store):
    identity = sign_in(portal_client, monkeypatch, "operator")
    failures = _harness(monkeypatch, identity, "Current-Password-1")
    response = portal_client.post("/administration/account/password",
                                  data={"current_password": "Wrong-Password-1", "new_password": "Brand-New-Pass-22",
                                        "new_password_confirm": "Brand-New-Pass-22"}, headers=SAME_ORIGIN)
    assert response.status_code == 400 and "current password is incorrect" in response.text
    assert failures == [identity.portal_user_id] and store.of("change_own") == []


def test_own_password_mismatch_and_policy(portal_client, monkeypatch, store):
    identity = sign_in(portal_client, monkeypatch, "viewer")
    _harness(monkeypatch, identity, "Current-Password-1")
    mismatch = portal_client.post("/administration/account/password",
                                  data={"current_password": "Current-Password-1", "new_password": "Brand-New-Pass-22",
                                        "new_password_confirm": "Different-Pass-22"}, headers=SAME_ORIGIN)
    short = portal_client.post("/administration/account/password",
                               data={"current_password": "Current-Password-1", "new_password": "short",
                                     "new_password_confirm": "short"}, headers=SAME_ORIGIN)
    assert mismatch.status_code == 400 and short.status_code == 400
    assert store.of("change_own") == []


def test_own_password_is_refused_while_locked(portal_client, monkeypatch, store):
    identity = sign_in(portal_client, monkeypatch, "viewer")
    failures = _harness(monkeypatch, identity, "Current-Password-1", locked=True)
    response = portal_client.post("/administration/account/password",
                                  data={"current_password": "Current-Password-1", "new_password": "Brand-New-Pass-22",
                                        "new_password_confirm": "Brand-New-Pass-22"}, headers=SAME_ORIGIN)
    assert response.status_code == 403 and "temporarily locked" in response.text
    assert failures == [] and store.of("change_own") == []


def test_header_links_to_change_my_password(portal_client, monkeypatch, store):
    sign_in(portal_client, monkeypatch, "viewer")
    assert "data-change-password-link" in portal_client.get("/administration/account/password").text
