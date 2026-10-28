"""Migration 314 -- server-side customer sessions (admin.portal_sessions),
against the disposable ems_test database (ADR-023).

Each test runs in one transaction that is rolled back, calling the session
functions as the roles that use them (SET LOCAL ROLE): ems_customer_api
(customer API: create / touch / revoke) and ems_app (live-telemetry:
read-only get_portal_session_user).

- sign-out revokes: a revoked session is refused by touch and get;
- idle and absolute expiry are enforced; touch slides the idle expiry, at
  most once a minute and never past the absolute expiry;
- deactivating an account or changing its password revokes every open
  session of it, and re-activation does not revive them;
- an inactive account cannot create a session;
- only the 32-byte token hash is stored; nobody but the owner reads the
  table; each role can call only its own functions.
"""

from __future__ import annotations

import hashlib
import os
import secrets

import psycopg
import pytest
from psycopg import errors

CONNINFO = (
    f"host={os.environ['EMS_APP_DB_HOST']} "
    f"port={os.environ['EMS_APP_DB_PORT']} "
    f"dbname={os.environ['EMS_APP_DB_NAME']} "
    f"user={os.environ['EMS_APP_DB_USER']} "
    f"password={os.environ['EMS_APP_DB_PASSWORD']}"
)
CUSTOMER_API = "ems_customer_api"
LIVE = "ems_app"
IDLE, ABSOLUTE = 28800, 604800

ORG = "00000000-0000-0000-0000-0000000000b4"
USERS = {
    "customer": "cs.customer@test",
    "other": "cs.other@test",
}


@pytest.fixture(scope="module", autouse=True)
def seed() -> dict[str, int]:
    ids: dict[str, int] = {}
    with psycopg.connect(CONNINFO) as conn, conn.cursor() as cur:
        cur.execute(
            "INSERT INTO metadata.organizations (id, name, code) VALUES (%s, 'CS_ORG', 'CS_ORG') "
            "ON CONFLICT (id) DO NOTHING",
            (ORG,),
        )
        for key, username in USERS.items():
            cur.execute(
                """
                INSERT INTO admin.portal_users
                    (username, display_name, password_hash, role_code, organization_id, access_scope_mode, created_by)
                VALUES (%s, %s, '$argon2id$placeholder', 'VIEWER', %s, 'ORGANIZATION', 'customer-session-test')
                ON CONFLICT (username) DO NOTHING
                """,
                (username, username, ORG),
            )
            cur.execute("SELECT portal_user_id FROM admin.portal_users WHERE username = %s", (username,))
            ids[key] = cur.fetchone()[0]
        conn.commit()
    return ids


@pytest.fixture
def cur():
    """One transaction per test, always rolled back."""

    with psycopg.connect(CONNINFO) as conn, conn.cursor() as cursor:
        try:
            yield cursor
        finally:
            conn.rollback()


def _token() -> bytes:
    return hashlib.sha256(secrets.token_urlsafe(32).encode("utf-8")).digest()


def _as(cur, role: str | None, sql: str, params: tuple = ()):
    cur.execute(f"SET LOCAL ROLE {role}" if role else "RESET ROLE")
    cur.execute(sql, params)
    row = cur.fetchone() if cur.description else None
    cur.execute("RESET ROLE")
    return row[0] if row else None


def _create(cur, user_id: int, token: bytes, idle: int = IDLE, absolute: int = ABSOLUTE) -> bool:
    return _as(cur, CUSTOMER_API, "SELECT admin.create_portal_session(%s, %s, 'CUSTOMER', %s, %s)",
               (user_id, token, idle, absolute))


def _touch(cur, token: bytes, audience: str = "CUSTOMER") -> int | None:
    return _as(cur, CUSTOMER_API, "SELECT admin.touch_portal_session(%s, %s, %s)", (token, audience, IDLE))


def _get(cur, token: bytes) -> int | None:
    return _as(cur, LIVE, "SELECT admin.get_portal_session_user(%s, 'CUSTOMER')", (token,))


def _revoke(cur, token: bytes) -> bool:
    return _as(cur, CUSTOMER_API, "SELECT admin.revoke_portal_session(%s, 'LOGOUT')", (token,))


def _row(cur, token: bytes) -> tuple:
    cur.execute(
        "SELECT revoked_reason, idle_expires_at - now(), absolute_expires_at - now(), last_seen_at = now() "
        "FROM admin.portal_sessions WHERE session_token_hash = %s",
        (token,),
    )
    return cur.fetchone()


# --- lifecycle ---------------------------------------------------------------------------

def test_sign_in_check_and_sign_out(cur, seed) -> None:
    token = _token()
    assert _create(cur, seed["customer"], token) is True
    assert _touch(cur, token) == seed["customer"]
    assert _get(cur, token) == seed["customer"]
    assert _revoke(cur, token) is True
    assert _touch(cur, token) is None and _get(cur, token) is None
    assert _revoke(cur, token) is False                              # already revoked: no-op
    assert _row(cur, token)[0] == "LOGOUT"


def test_sessions_are_independent(cur, seed) -> None:
    first, second = _token(), _token()
    assert _create(cur, seed["customer"], first) and _create(cur, seed["customer"], second)
    _revoke(cur, first)
    assert _touch(cur, first) is None and _touch(cur, second) == seed["customer"]


def test_unknown_token_and_wrong_audience_are_refused(cur, seed) -> None:
    token = _token()
    _create(cur, seed["customer"], token)
    assert _touch(cur, _token()) is None and _get(cur, _token()) is None
    assert _touch(cur, token, audience="ADMIN") is None


def test_only_a_32_byte_hash_is_stored(cur, seed) -> None:
    with pytest.raises(errors.CheckViolation):
        _create(cur, seed["customer"], b"raw-token-not-a-sha256-digest")


# --- expiry --------------------------------------------------------------------------------

def test_idle_expiry(cur, seed) -> None:
    token = _token()
    _create(cur, seed["customer"], token)
    cur.execute("UPDATE admin.portal_sessions SET idle_expires_at = now() - interval '1 second' "
                "WHERE session_token_hash = %s", (token,))
    assert _touch(cur, token) is None and _get(cur, token) is None


def test_absolute_expiry(cur, seed) -> None:
    token = _token()
    _create(cur, seed["customer"], token)
    cur.execute("UPDATE admin.portal_sessions SET absolute_expires_at = now() - interval '1 second', "
                "idle_expires_at = now() - interval '1 second' WHERE session_token_hash = %s", (token,))
    assert _touch(cur, token) is None and _get(cur, token) is None


def test_touch_slides_idle_expiry_at_most_once_a_minute_and_within_the_absolute(cur, seed) -> None:
    from datetime import timedelta

    token = _token()
    _create(cur, seed["customer"], token, idle=600, absolute=900)
    cur.execute("UPDATE admin.portal_sessions SET idle_expires_at = now() + interval '30 seconds', "
                "last_seen_at = now() - interval '30 seconds' WHERE session_token_hash = %s", (token,))
    _touch(cur, token)                                                 # seen 30 s ago: not written
    assert _row(cur, token)[1] == timedelta(seconds=30)
    cur.execute("UPDATE admin.portal_sessions SET last_seen_at = now() - interval '2 minutes', "
                "absolute_expires_at = now() + interval '5 minutes' WHERE session_token_hash = %s", (token,))
    _touch(cur, token)                                                 # slides, capped at the absolute expiry
    _, idle_left, absolute_left, seen_now = _row(cur, token)
    assert idle_left == absolute_left == timedelta(minutes=5) and seen_now


def test_get_is_read_only(cur, seed) -> None:
    token = _token()
    _create(cur, seed["customer"], token)
    cur.execute("UPDATE admin.portal_sessions SET last_seen_at = now() - interval '2 minutes' "
                "WHERE session_token_hash = %s", (token,))
    _get(cur, token)
    assert _row(cur, token)[3] is False


@pytest.mark.parametrize("idle,absolute", [(299, ABSOLUTE), (86401, ABSOLUTE), (IDLE, IDLE - 1), (IDLE, 2592001)])
def test_lifetimes_are_bounded(cur, seed, idle, absolute) -> None:
    with pytest.raises(errors.RaiseException):
        _create(cur, seed["customer"], _token(), idle, absolute)


# --- account changes -----------------------------------------------------------------------

def test_deactivation_revokes_every_session_and_reactivation_does_not_revive(cur, seed) -> None:
    mine, theirs = [_token(), _token()], _token()
    for token in mine:
        _create(cur, seed["customer"], token)
    _create(cur, seed["other"], theirs)
    cur.execute("UPDATE admin.portal_users SET is_active = FALSE WHERE portal_user_id = %s", (seed["customer"],))
    assert [_touch(cur, t) for t in mine] == [None, None]
    assert [_row(cur, t)[0] for t in mine] == ["ACCOUNT_DEACTIVATED"] * 2
    assert _touch(cur, theirs) == seed["other"]                        # another account is untouched
    assert _create(cur, seed["customer"], _token()) is False           # nor can it sign in again
    cur.execute("UPDATE admin.portal_users SET is_active = TRUE WHERE portal_user_id = %s", (seed["customer"],))
    assert [_touch(cur, t) for t in mine] == [None, None]
    assert [_get(cur, t) for t in mine] == [None, None]


def test_password_change_revokes_every_session(cur, seed) -> None:
    token = _token()
    _create(cur, seed["customer"], token)
    cur.execute("UPDATE admin.portal_users SET password_hash = '$argon2id$changed' WHERE portal_user_id = %s",
                (seed["customer"],))
    assert _touch(cur, token) is None and _row(cur, token)[0] == "PASSWORD_CHANGED"


def test_unrelated_account_updates_do_not_revoke(cur, seed) -> None:
    token = _token()
    _create(cur, seed["customer"], token)
    cur.execute("UPDATE admin.portal_users SET display_name = 'Renamed', failed_login_count = 1 "
                "WHERE portal_user_id = %s", (seed["customer"],))
    assert _touch(cur, token) == seed["customer"]


def test_dead_sessions_are_purged_at_the_next_sign_in(cur, seed) -> None:
    dead, alive = _token(), _token()
    _create(cur, seed["customer"], dead)
    _create(cur, seed["customer"], alive)
    _revoke(cur, dead)
    _create(cur, seed["customer"], _token())
    cur.execute("SELECT count(*) FROM admin.portal_sessions WHERE session_token_hash = ANY(%s)", ([dead, alive],))
    assert cur.fetchone()[0] == 1


# --- privileges ------------------------------------------------------------------------------

@pytest.mark.parametrize("role", [CUSTOMER_API, LIVE, "ems_investigator"])
def test_no_role_reads_or_writes_the_table_directly(cur, role) -> None:
    with pytest.raises(errors.InsufficientPrivilege):
        _as(cur, role, "SELECT count(*) FROM admin.portal_sessions")


def test_table_acl_is_owner_only_despite_investigator_default_privileges(cur) -> None:
    # The test database reproduces staging's ems_investigator default
    # privileges (scripts/test/staging_role_parity.sql), which granted the
    # new table SELECT and failed the first staging release of 314.
    cur.execute(
        "SELECT count(*) FROM pg_default_acl d CROSS JOIN LATERAL aclexplode(d.defaclacl) a "
        "WHERE d.defaclnamespace = 'admin'::regnamespace AND d.defaclobjtype = 'r' "
        "AND a.grantee = 'ems_investigator'::regrole AND a.privilege_type = 'SELECT'"
    )
    assert cur.fetchone()[0] == 1
    cur.execute(
        "SELECT array_agg(DISTINCT pg_get_userbyid(a.grantee)) FROM pg_class c CROSS JOIN LATERAL aclexplode(c.relacl) a "
        "WHERE c.oid = 'admin.portal_sessions'::regclass"
    )
    assert cur.fetchone()[0] in (None, ["ems_admin"])


@pytest.mark.parametrize("sql", [
    "SELECT admin.create_portal_session(1, %s, 'CUSTOMER', 28800, 604800)",
    "SELECT admin.touch_portal_session(%s, 'CUSTOMER', 28800)",
    "SELECT admin.revoke_portal_session(%s, 'LOGOUT')",
])
def test_live_telemetry_cannot_write_sessions(cur, sql) -> None:
    with pytest.raises(errors.InsufficientPrivilege):
        _as(cur, LIVE, sql, (_token(),))


def test_no_public_execute_and_definer_functions(cur) -> None:
    cur.execute(
        """
        SELECT p.proname, p.prosecdef, has_function_privilege('public', p.oid, 'EXECUTE')
        FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
        WHERE n.nspname = 'admin'
          AND p.proname IN ('create_portal_session', 'touch_portal_session', 'get_portal_session_user',
                            'revoke_portal_session', 'revoke_portal_sessions_on_account_change')
        ORDER BY 1
        """
    )
    rows = cur.fetchall()
    assert len(rows) == 5
    assert all(definer and not public for _, definer, public in rows)
