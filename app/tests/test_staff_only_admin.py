"""Staff-only Administration App (EMS_ADMIN_STAFF_ONLY, ADR-023) and the
audience gate of src.auth.service.authenticate_portal_user.

- The audience gate runs after full password verification; an identity
  outside the audience gets INVALID_CREDENTIALS and neither a login success
  nor a failure is recorded (trying the wrong host cannot lock an account).
- With the flag off (the default) the Administration App behaves exactly as
  before: any active portal identity can sign in.
- With the flag on, only GLOBAL-scope (staff) identities can sign in, and an
  existing non-staff session is signed out on its next request.
"""

from __future__ import annotations

import pytest

from src.auth.audience import customer_audience, staff_audience
from src.auth.models import AuthenticatedPortalUser, PortalUserAuthenticationRecord
from src.auth.security import AuthenticationStatus, hash_portal_password
from src.auth.service import AuthenticationResult, authenticate_portal_user

ORG_ID = "11111111-1111-4111-8111-111111111111"
PASSWORD = "correct horse battery staple"


def _record(scope: str, org: str | None) -> PortalUserAuthenticationRecord:
    return PortalUserAuthenticationRecord(
        portal_user_id=9, username="u@example.com", display_name="U", password_hash=hash_portal_password(PASSWORD),
        role_code="VIEWER", is_active=True, failed_login_count=0, locked_until=None,
        organization_id=org, access_scope_mode=scope, site_ids=(),
    )


@pytest.fixture
def repository(monkeypatch):
    calls = {"success": 0, "failure": 0, "record": None}

    async def get_user(username):
        return calls["record"]

    async def success(portal_user_id):
        calls["success"] += 1

    async def failure(portal_user_id):
        calls["failure"] += 1

    monkeypatch.setattr("src.auth.service.get_portal_user_for_authentication", get_user)
    monkeypatch.setattr("src.auth.service.record_portal_login_success", success)
    monkeypatch.setattr("src.auth.service.record_portal_login_failure", failure)
    return calls


async def test_identity_outside_the_audience_is_invalid_and_nothing_is_recorded(repository) -> None:
    repository["record"] = _record("ORGANIZATION", ORG_ID)
    result = await authenticate_portal_user("u@example.com", PASSWORD, audience=staff_audience)
    assert (result.authenticated, result.user, result.status) == (False, None, AuthenticationStatus.INVALID_CREDENTIALS)
    assert (repository["success"], repository["failure"]) == (0, 0)


async def test_identity_inside_the_audience_signs_in_and_records_success(repository) -> None:
    repository["record"] = _record("GLOBAL", None)
    result = await authenticate_portal_user("u@example.com", PASSWORD, audience=staff_audience)
    assert result.authenticated and result.user.access_scope_mode == "GLOBAL"
    assert (repository["success"], repository["failure"]) == (1, 0)


async def test_wrong_password_still_records_a_failure_with_an_audience(repository) -> None:
    repository["record"] = _record("ORGANIZATION", ORG_ID)
    result = await authenticate_portal_user("u@example.com", "wrong", audience=staff_audience)
    assert not result.authenticated
    assert (repository["success"], repository["failure"]) == (0, 1)


async def test_no_audience_is_the_previous_behaviour(repository) -> None:
    repository["record"] = _record("ORGANIZATION", ORG_ID)
    assert (await authenticate_portal_user("u@example.com", PASSWORD)).authenticated
    assert repository["success"] == 1


def _identity(scope: str) -> AuthenticatedPortalUser:
    return AuthenticatedPortalUser(
        portal_user_id=9, username="u", display_name="U", role_code="VIEWER",
        organization_id=None if scope == "GLOBAL" else ORG_ID, access_scope_mode=scope,
    )


@pytest.mark.parametrize("scope,staff,customer,customer_with_staff", [
    ("GLOBAL", True, False, True),
    ("ORGANIZATION", False, True, True),
    ("SELECTED_SITES", False, True, True),
])
def test_audience_predicates(scope, staff, customer, customer_with_staff) -> None:
    assert staff_audience(_identity(scope)) is staff
    assert customer_audience(allow_staff=False)(_identity(scope)) is customer
    assert customer_audience(allow_staff=True)(_identity(scope)) is customer_with_staff


# --- the Administration App --------------------------------------------------------------

def _login(portal_client, monkeypatch, scope: str):
    identity = _identity(scope)

    async def fake(username, password, *, audience=None):
        if audience is not None and not audience(identity):
            return AuthenticationResult(False, None, AuthenticationStatus.INVALID_CREDENTIALS)
        return AuthenticationResult(True, identity, AuthenticationStatus.AUTHENTICATED)

    monkeypatch.setattr("src.main.authenticate_portal_user", fake)
    return portal_client.post("/login", data={"username": "u", "password": "x", "next_path": "/app/"})


@pytest.fixture
def staff_only(monkeypatch):
    from src.config import get_settings

    monkeypatch.setattr(get_settings(), "admin_staff_only", True)


def test_flag_off_customers_can_still_sign_in_as_today(portal_client, monkeypatch) -> None:
    assert _login(portal_client, monkeypatch, "ORGANIZATION").status_code == 303


def test_flag_on_customers_get_the_generic_login_failure(portal_client, monkeypatch, staff_only) -> None:
    response = _login(portal_client, monkeypatch, "ORGANIZATION")
    assert response.status_code == 401
    assert "Invalid username or password." in response.text
    assert portal_client.get("/api/v1/me").status_code == 401


def test_flag_on_staff_sign_in(portal_client, monkeypatch, staff_only) -> None:
    assert _login(portal_client, monkeypatch, "GLOBAL").status_code == 303
    assert portal_client.get("/api/v1/me").status_code == 200


def test_turning_the_flag_on_signs_out_existing_customer_sessions(portal_client, monkeypatch) -> None:
    from src.config import get_settings

    assert _login(portal_client, monkeypatch, "ORGANIZATION").status_code == 303
    assert portal_client.get("/api/v1/me").status_code == 200
    monkeypatch.setattr(get_settings(), "admin_staff_only", True)
    response = portal_client.get("/administration/organizations")
    assert response.status_code == 303 and response.headers["location"].startswith("/login")
    monkeypatch.setattr(get_settings(), "admin_staff_only", False)
    assert portal_client.get("/api/v1/me").status_code == 401        # the session was cleared
