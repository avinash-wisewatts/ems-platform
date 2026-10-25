"""Reports tab -- migration 309 export job functions against the disposable
ems_test database: owner and tenant isolation, the active-job limit, the
worker claim / lease / attempt rules, completion and failure only by the
holding worker, file expiry and purge, and the ems_app-only grants.
"""

from __future__ import annotations

import os
from datetime import datetime, timedelta, timezone

import psycopg
import pytest


CONNINFO = (
    f"host={os.environ['EMS_APP_DB_HOST']} "
    f"port={os.environ['EMS_APP_DB_PORT']} "
    f"dbname={os.environ['EMS_APP_DB_NAME']} "
    f"user={os.environ['EMS_APP_DB_USER']} "
    f"password={os.environ['EMS_APP_DB_PASSWORD']}"
)

ORG_A = "00000000-0000-0000-0000-0000000000c9"
ORG_B = "00000000-0000-0000-0000-0000000001c9"
SITE_A = "00000000-0000-0000-0000-0000000002c9"
SITE_A2 = "00000000-0000-0000-0000-0000000003c9"
SITE_B = "00000000-0000-0000-0000-0000000004c9"
USERS = {
    "global": ("rx.global@test", "ADMIN", None, "GLOBAL"),
    "org_a": ("rx.orga@test", "OPERATOR", ORG_A, "ORGANIZATION"),
    "org_a2": ("rx.orga2@test", "VIEWER", ORG_A, "ORGANIZATION"),
    "org_b": ("rx.orgb@test", "OPERATOR", ORG_B, "ORGANIZATION"),
    "sel_a": ("rx.sel-a@test", "VIEWER", ORG_A, "SELECTED_SITES"),
}
T0 = datetime(2026, 10, 1, tzinfo=timezone.utc)
T1 = T0 + timedelta(days=1)


@pytest.fixture(scope="module", autouse=True)
def seed() -> None:
    with psycopg.connect(CONNINFO) as conn:
        with conn.cursor() as cur:
            for org, code in ((ORG_A, "RX_ORG_A"), (ORG_B, "RX_ORG_B")):
                cur.execute(
                    "INSERT INTO metadata.organizations (id, name, code) VALUES (%s, %s, %s) "
                    "ON CONFLICT (id) DO NOTHING",
                    (org, code, code),
                )
            for site, org, code in ((SITE_A, ORG_A, "RX_SITE_A"), (SITE_A2, ORG_A, "RX_SITE_A2"), (SITE_B, ORG_B, "RX_SITE_B")):
                cur.execute(
                    "INSERT INTO metadata.sites (id, organization_id, name, code) VALUES (%s, %s, %s, %s) "
                    "ON CONFLICT (id) DO NOTHING",
                    (site, org, code, code),
                )
            ids = {}
            for key, (username, role, org, scope) in USERS.items():
                cur.execute(
                    """
                    INSERT INTO admin.portal_users
                        (username, display_name, password_hash, role_code, organization_id, access_scope_mode, created_by)
                    VALUES (%s, %s, '$argon2id$placeholder', %s, %s, %s, 'report-export-test')
                    ON CONFLICT (username) DO NOTHING
                    """,
                    (username, username, role, org, scope),
                )
                cur.execute("SELECT portal_user_id FROM admin.portal_users WHERE username = %s", (username,))
                ids[key] = cur.fetchone()[0]
            cur.execute(
                "INSERT INTO admin.portal_user_site_access (portal_user_id, site_id, created_by_portal_user_id) "
                "VALUES (%s, %s, %s) ON CONFLICT DO NOTHING",
                (ids["sel_a"], SITE_A, ids["global"]),
            )
        conn.commit()


@pytest.fixture
def conn():
    with psycopg.connect(CONNINFO, autocommit=True) as connection:
        with connection.cursor() as cur:
            cur.execute(
                "DELETE FROM analytics.report_export_jobs WHERE site_id IN (%s, %s, %s)", (SITE_A, SITE_A2, SITE_B)
            )
        yield connection


def _uid(conn, key: str) -> int:
    with conn.cursor() as cur:
        cur.execute("SELECT portal_user_id FROM admin.portal_users WHERE username = %s", (USERS[key][0],))
        return cur.fetchone()[0]


def _rows(conn, sql: str, params: tuple = ()) -> list[tuple]:
    with conn.cursor() as cur:
        cur.execute(sql, params)
        return cur.fetchall() if cur.description else []


def _create(conn, key: str, site: str = SITE_A, max_active: int = 3) -> list[tuple]:
    return _rows(
        conn,
        "SELECT id, status FROM analytics.create_portal_report_export_job(%s, %s, %s, %s, 'auto', '1h', %s)",
        (_uid(conn, key), site, T0, T1, max_active),
    )


def _claim(conn, worker: str = "w1", lease: str = "10 minutes", attempts: int = 3) -> list[tuple]:
    return _rows(
        conn,
        "SELECT id, status, attempts, worker_id FROM analytics.claim_report_export_job(%s, %s::interval, %s)",
        (worker, lease, attempts),
    )


def _claim_job(conn, job_id, worker: str = "w1") -> None:
    """Claim until job_id is held (other tests' rows are deleted first, so
    it is the oldest QUEUED job)."""

    claimed = _claim(conn, worker)
    assert claimed and claimed[0][0] == job_id


# --- creation and tenant / owner isolation ------------------------------------

def test_create_queues_a_job_for_an_accessible_site(conn) -> None:
    rows = _create(conn, "org_a")
    assert len(rows) == 1 and rows[0][1] == "QUEUED"


def test_create_for_another_organizations_site_returns_no_row(conn) -> None:
    assert _create(conn, "org_b", SITE_A) == []
    assert _create(conn, "sel_a", SITE_A2) == []


def test_jobs_are_visible_only_to_their_owner(conn) -> None:
    job_id = _create(conn, "org_a")[0][0]
    for key, visible in (("org_a", True), ("org_a2", False), ("org_b", False), ("global", False)):
        listed = [r[0] for r in _rows(conn, "SELECT id FROM analytics.list_portal_report_export_jobs(%s, 50)", (_uid(conn, key),))]
        got = _rows(conn, "SELECT id FROM analytics.get_portal_report_export_job(%s, %s)", (_uid(conn, key), job_id))
        assert (job_id in listed) is visible
        assert bool(got) is visible


def test_job_is_hidden_once_the_owner_loses_site_access(conn) -> None:
    uid = _uid(conn, "sel_a")
    grant = (
        "INSERT INTO admin.portal_user_site_access (portal_user_id, site_id, created_by_portal_user_id) "
        "VALUES (%s, %s, %s) ON CONFLICT DO NOTHING"
    )
    # SITE_A stays assigned throughout (a SELECTED_SITES user keeps >= 1 site).
    _rows(conn, grant, (uid, SITE_A2, _uid(conn, "global")))
    job_id = _create(conn, "sel_a", SITE_A2)[0][0]
    _rows(conn, "DELETE FROM admin.portal_user_site_access WHERE portal_user_id = %s AND site_id = %s", (uid, SITE_A2))
    assert _rows(conn, "SELECT id FROM analytics.get_portal_report_export_job(%s, %s)", (uid, job_id)) == []
    assert _rows(conn, "SELECT id FROM analytics.list_portal_report_export_jobs(%s, 50)", (uid,)) == []
    assert _rows(conn, "SELECT id FROM analytics.retry_portal_report_export_job(%s, %s)", (uid, job_id)) == []


def test_active_job_limit_raises_54000(conn) -> None:
    _create(conn, "org_a", max_active=2)
    _create(conn, "org_a", max_active=2)
    with pytest.raises(psycopg.errors.ProgramLimitExceeded):
        _create(conn, "org_a", max_active=2)
    # Another user is not affected by org_a's jobs.
    assert _create(conn, "org_a2", max_active=2)


# --- worker claim, lease, completion, failure ---------------------------------

def test_claim_takes_the_oldest_queued_job_once(conn) -> None:
    first = _create(conn, "org_a")[0][0]
    second = _create(conn, "org_a")[0][0]
    a = _claim(conn, "w1")
    b = _claim(conn, "w2")
    assert [a[0][0], b[0][0]] == [first, second]
    assert a[0][1:] == ("PROCESSING", 1, "w1")
    assert _claim(conn, "w3") == []


def test_lapsed_lease_is_reclaimed_then_failed_after_max_attempts(conn) -> None:
    job_id = _create(conn, "org_a")[0][0]
    assert _claim(conn, "w1", lease="-1 second", attempts=2)[0][2] == 1
    reclaimed = _claim(conn, "w2", lease="-1 second", attempts=2)
    assert reclaimed[0][0] == job_id and reclaimed[0][2] == 2
    assert _claim(conn, "w3", attempts=2) == []
    status = _rows(conn, "SELECT status, error_code FROM analytics.report_export_jobs WHERE id = %s", (job_id,))
    assert status == [("FAILED", "worker_interrupted")]


def test_only_the_holding_worker_can_complete_or_fail(conn) -> None:
    job_id = _create(conn, "org_a")[0][0]
    _claim_job(conn, job_id, "w1")
    args = (job_id, "PK-zip", 2, 10)
    assert _rows(
        conn, "SELECT analytics.complete_report_export_job(%s, 'w2', 'x.zip', %s::bytea, %s, %s, '1 hour')", args
    ) == [(False,)]
    assert _rows(conn, "SELECT analytics.fail_report_export_job(%s, 'w2', 'c', 'm')", (job_id,)) == [(False,)]
    assert _rows(conn, "SELECT analytics.extend_report_export_lease(%s, 'w2', '1 hour')", (job_id,)) == [(False,)]
    assert _rows(conn, "SELECT analytics.extend_report_export_lease(%s, 'w1', '1 hour')", (job_id,)) == [(True,)]
    assert _rows(
        conn, "SELECT analytics.complete_report_export_job(%s, 'w1', 'x.zip', %s::bytea, %s, %s, '1 hour')", args
    ) == [(True,)]
    job = _rows(
        conn,
        "SELECT status, file_size_bytes, asset_count, row_count, expires_at > now() "
        "FROM analytics.report_export_jobs WHERE id = %s",
        (job_id,),
    )
    assert job == [("COMPLETED", 6, 2, 10, True)]


def test_file_is_served_only_to_the_owner_while_unexpired(conn) -> None:
    job_id = _create(conn, "org_a")[0][0]
    _claim_job(conn, job_id)
    _rows(conn, "SELECT analytics.complete_report_export_job(%s, 'w1', 'site.zip', 'PKDATA'::bytea, 1, 1, '1 hour')", (job_id,))
    owner = _uid(conn, "org_a")
    assert _rows(conn, "SELECT file_name, content FROM analytics.get_portal_report_export_file(%s, %s)", (owner, job_id)) == [
        ("site.zip", b"PKDATA")
    ]
    for key in ("org_a2", "org_b", "global"):
        assert _rows(conn, "SELECT 1 FROM analytics.get_portal_report_export_file(%s, %s)", (_uid(conn, key), job_id)) == []

    _rows(conn, "UPDATE analytics.report_export_jobs SET expires_at = now() - interval '1 second' WHERE id = %s", (job_id,))
    assert _rows(conn, "SELECT 1 FROM analytics.get_portal_report_export_file(%s, %s)", (owner, job_id)) == []
    assert _rows(conn, "SELECT expired_files FROM analytics.purge_report_exports('30 days')") [0][0] >= 1
    assert _rows(conn, "SELECT status FROM analytics.report_export_jobs WHERE id = %s", (job_id,)) == [("EXPIRED",)]
    assert _rows(conn, "SELECT count(*) FROM analytics.report_export_files WHERE job_id = %s", (job_id,)) == [(0,)]


def test_purge_deletes_old_finished_jobs_only(conn) -> None:
    old = _create(conn, "org_a")[0][0]
    queued = _create(conn, "org_a")[0][0]
    _claim_job(conn, old)
    _rows(conn, "SELECT analytics.fail_report_export_job(%s, 'w1', 'export_failed', 'boom')", (old,))
    _rows(
        conn,
        "UPDATE analytics.report_export_jobs SET created_at = now() - interval '31 days' WHERE id IN (%s, %s)",
        (old, queued),
    )
    _rows(conn, "SELECT * FROM analytics.purge_report_exports('30 days')")
    remaining = {r[0] for r in _rows(conn, "SELECT id FROM analytics.report_export_jobs WHERE id IN (%s, %s)", (old, queued))}
    assert remaining == {queued}


def test_retry_requeues_only_a_failed_job_of_the_owner(conn) -> None:
    job_id = _create(conn, "org_a")[0][0]
    owner = _uid(conn, "org_a")
    retry = "SELECT status, attempts, error_code FROM analytics.retry_portal_report_export_job(%s, %s)"
    assert _rows(conn, retry, (owner, job_id)) == []  # QUEUED, not FAILED
    _claim_job(conn, job_id)
    _rows(conn, "SELECT analytics.fail_report_export_job(%s, 'w1', 'export_failed', 'boom')", (job_id,))
    assert _rows(conn, retry, (_uid(conn, "org_a2"), job_id)) == []
    assert _rows(conn, retry, (owner, job_id)) == [("QUEUED", 0, None)]


# --- privileges ---------------------------------------------------------------

def test_tables_are_not_directly_accessible_and_functions_are_ems_app_only(conn) -> None:
    for table in ("analytics.report_export_jobs", "analytics.report_export_files"):
        for role in ("ems_app", "grafana_reader"):
            for privilege in ("SELECT", "INSERT", "UPDATE", "DELETE"):
                assert _rows(conn, "SELECT has_table_privilege(%s, %s, %s)", (role, table, privilege)) == [(False,)]
    functions = _rows(
        conn,
        """
        SELECT p.oid::regprocedure::text, p.prosecdef,
               has_function_privilege('public', p.oid, 'EXECUTE'),
               has_function_privilege('ems_app', p.oid, 'EXECUTE')
        FROM pg_proc AS p JOIN pg_namespace AS n ON n.oid = p.pronamespace
        WHERE n.nspname = 'analytics' AND p.proname LIKE '%%report_export%%'
        """,
    )
    # Migration 309's ten, plus migration 312's create with selected assets.
    assert len(functions) == 11
    for name, definer, public_exec, app_exec in functions:
        assert definer and not public_exec and app_exec, name
