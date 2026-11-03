"""Initial administrator provisioning (src.provision_portal_admin) and the
account-field policy it shares with the Admin -> Users API
(src.user_account_policy). Database calls are faked; the real
admin.create_managed_portal_user path is exercised in test_user_management_db.py.
"""

from __future__ import annotations

import asyncio
import io
import os
import stat

import pytest

import src.provision_portal_admin as provisioning
from src.auth.models import PortalUserAuthenticationRecord
from src.user_account_policy import (
    PASSWORD_MIN_LENGTH,
    AccountPolicyError,
    generate_temporary_password,
    normalize_email,
    normalize_username,
    validate_password,
)


# --- policy -----------------------------------------------------------------------------------


def test_temporary_passwords_are_random_and_satisfy_the_policy() -> None:
    passwords = {generate_temporary_password() for _ in range(50)}
    assert len(passwords) == 50
    for password in passwords:
        assert validate_password(password) == password
        assert len(password) >= PASSWORD_MIN_LENGTH


def test_username_normalization() -> None:
    assert normalize_username("  Admin_User ") == "admin_user"
    for bad in ("", "ab", "has space", "-leading", "semi;colon"):
        with pytest.raises(AccountPolicyError):
            normalize_username(bad)


def test_email_validation() -> None:
    assert normalize_email(" a.b@example.com ") == "a.b@example.com"
    for bad in ("", "plain", "a@b", "a b@example.com", "a@@example.com"):
        with pytest.raises(AccountPolicyError):
            normalize_email(bad)


def test_password_policy() -> None:
    with pytest.raises(AccountPolicyError):
        validate_password("x" * (PASSWORD_MIN_LENGTH - 1))
    with pytest.raises(AccountPolicyError):
        validate_password("x" * 129)
    with pytest.raises(AccountPolicyError):
        validate_password(" " * 20)
    with pytest.raises(AccountPolicyError):
        validate_password("Admin_User_Long", username="admin_user_long")


# --- provisioning -------------------------------------------------------------------------------


def _record(username: str, *, role="ADMIN", scope="GLOBAL", active=True, portal_user_id=1) -> PortalUserAuthenticationRecord:
    return PortalUserAuthenticationRecord(
        portal_user_id=portal_user_id, username=username, display_name=username, password_hash="$argon2id$x",
        role_code=role, is_active=active, failed_login_count=0, locked_until=None,
        organization_id=None if scope == "GLOBAL" else "00000000-0000-0000-0000-000000000001",
        access_scope_mode=scope,
    )


class Fakes:
    def __init__(self, monkeypatch, existing: dict[str, PortalUserAuthenticationRecord]) -> None:
        self.existing = existing
        self.created: list[dict] = []
        self.fail: Exception | None = None
        monkeypatch.setattr(provisioning, "get_portal_user_for_authentication", self.lookup)
        monkeypatch.setattr(provisioning, "create_managed_user", self.create)
        monkeypatch.setattr(provisioning, "DatabaseError", FakeDatabaseError)

    async def lookup(self, username: str):
        return self.existing.get(username)

    async def create(self, **kwargs) -> int:
        if self.fail:
            raise self.fail
        self.created.append(kwargs)
        return 42


class FakeDatabaseError(Exception):
    def __init__(self, sqlstate: str) -> None:
        super().__init__(sqlstate)
        self.sqlstate = sqlstate


class Tty(io.StringIO):
    def isatty(self) -> bool:
        return True


def _run(**kwargs) -> int:
    params = dict(username="admin_user", display_name="EMS Administrator", email="admin@example.com",
                  actor_username="owner@wisewatts.test", password_file=None)
    params.update(kwargs)
    return asyncio.run(provisioning.provision(**params))


def test_creates_admin_global_via_the_managed_function_and_writes_the_password_once(monkeypatch, tmp_path) -> None:
    fakes = Fakes(monkeypatch, {"owner@wisewatts.test": _record("owner@wisewatts.test", portal_user_id=7)})
    target = tmp_path / "admin_user_password.txt"
    out, err = io.StringIO(), io.StringIO()

    assert _run(password_file=str(target), out=out, err=err) == provisioning.EXIT_CREATED
    [created] = fakes.created
    assert created["actor_portal_user_id"] == 7
    assert created["username"] == "admin_user"
    assert (created["role_code"], created["access_scope_mode"], created["organization_id"], created["site_ids"]) == (
        "ADMIN", "GLOBAL", None, ()
    )
    password = target.read_text(encoding="utf-8").strip()
    validate_password(password)
    assert created["password_hash"].startswith("$argon2id$")
    assert password not in created["password_hash"]
    assert password not in out.getvalue() and password not in err.getvalue()
    if os.name == "posix":
        assert stat.S_IMODE(target.stat().st_mode) == 0o600


def test_existing_account_is_never_modified(monkeypatch, tmp_path) -> None:
    fakes = Fakes(monkeypatch, {"admin_user": _record("admin_user"), "owner@wisewatts.test": _record("owner@wisewatts.test")})
    target = tmp_path / "pw.txt"
    err = io.StringIO()
    assert _run(password_file=str(target), err=err) == provisioning.EXIT_EXISTS
    assert fakes.created == [] and not target.exists()
    assert "Nothing was changed" in err.getvalue()


@pytest.mark.parametrize(
    "actor",
    [None, _record("owner@wisewatts.test", active=False), _record("owner@wisewatts.test", role="OPERATOR"),
     _record("owner@wisewatts.test", scope="ORGANIZATION")],
)
def test_actor_must_be_an_active_global_administrator(monkeypatch, tmp_path, actor) -> None:
    fakes = Fakes(monkeypatch, {"owner@wisewatts.test": actor} if actor else {})
    assert _run(password_file=str(tmp_path / "pw.txt"), err=io.StringIO()) == provisioning.EXIT_INVALID
    assert fakes.created == []


def test_an_existing_password_file_is_never_overwritten(monkeypatch, tmp_path) -> None:
    fakes = Fakes(monkeypatch, {"owner@wisewatts.test": _record("owner@wisewatts.test")})
    target = tmp_path / "pw.txt"
    target.write_text("keep me", encoding="utf-8")
    assert _run(password_file=str(target), err=io.StringIO()) == provisioning.EXIT_DESTINATION
    assert fakes.created == [] and target.read_text(encoding="utf-8") == "keep me"


def test_refuses_to_print_a_password_to_a_pipe(monkeypatch) -> None:
    fakes = Fakes(monkeypatch, {"owner@wisewatts.test": _record("owner@wisewatts.test")})
    assert _run(out=io.StringIO(), err=io.StringIO()) == provisioning.EXIT_DESTINATION
    assert fakes.created == []


def test_prints_once_to_an_interactive_terminal(monkeypatch) -> None:
    fakes = Fakes(monkeypatch, {"owner@wisewatts.test": _record("owner@wisewatts.test")})
    out = Tty()
    assert _run(out=out, err=io.StringIO()) == provisioning.EXIT_CREATED
    assert len(fakes.created) == 1
    assert "One-time initial password for admin_user" in out.getvalue()


def test_database_refusal_discards_the_prepared_file(monkeypatch, tmp_path) -> None:
    fakes = Fakes(monkeypatch, {"owner@wisewatts.test": _record("owner@wisewatts.test")})
    fakes.fail = FakeDatabaseError("23505")
    target = tmp_path / "pw.txt"
    assert _run(password_file=str(target), err=io.StringIO()) == provisioning.EXIT_EXISTS
    assert not target.exists()
