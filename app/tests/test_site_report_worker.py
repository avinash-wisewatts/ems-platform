"""Reports -> Create report worker against the disposable database (ADR-025).

The real worker loop, database functions, engine, PDF renderer and validator
run end to end; only the EMS telemetry reads are replaced by deterministic
synthetic readings (the loader is tested separately). Covers publication with
coverage and settings snapshot (A58, A80), waiting for late data (A64-A65),
automation identity failure (A90), insufficient data (A48), retention
(A71), temporary failure retry (A68) and the heartbeat.
"""

from __future__ import annotations

import os
from datetime import date, datetime, timedelta, timezone
from pathlib import Path

import psycopg
import pytest

from tests.report_engine_support import RADISSON_ROSTER, TEMPERATURE_SENSORS, synthetic_assets
from src import site_report_service as svc
from src.report_engine.ems_loader import LoadResult, RetentionExceededError

CONNINFO = (
    f"host={os.environ['EMS_APP_DB_HOST']} port={os.environ['EMS_APP_DB_PORT']} "
    f"dbname={os.environ['EMS_APP_DB_NAME']} user={os.environ['EMS_APP_DB_USER']} "
    f"password={os.environ['EMS_APP_DB_PASSWORD']}"
)
ORG = "00000000-0000-0000-0000-0000000b5e01"
SITE = "00000000-0000-0000-0000-0000000b5e11"
STAFF = "srw.staff@test"
AUTOMATION = "srw.automation@test"
WEEK_START = date(2026, 10, 18)


def asset_id(i: int) -> str:
    return f"00000000-0000-0000-0000-0000000b6{i:03d}"


@pytest.fixture(scope="module", autouse=True)
def seed():
    with psycopg.connect(CONNINFO) as conn, conn.cursor() as cur:
        cur.execute("INSERT INTO metadata.organizations (id, name, code) VALUES (%s, 'SRW Org', 'SRW_ORG') ON CONFLICT (id) DO NOTHING", (ORG,))
        cur.execute("INSERT INTO metadata.sites (id, organization_id, name, code, timezone) VALUES (%s, %s, 'SRW Coimbatore', "
                    "'SRW_SITE', 'Asia/Kolkata') ON CONFLICT (id) DO NOTHING", (SITE, ORG))
        for i, (name, _, _) in enumerate(RADISSON_ROSTER):
            cur.execute("INSERT INTO metadata.assets (id, organization_id, site_id, name, external_id, metering_requirement, "
                        "lifecycle_status) VALUES (%s, %s, %s, %s, %s, 'NOT_REQUIRED', 'ACTIVE') ON CONFLICT (id) DO NOTHING",
                        (asset_id(i), ORG, SITE, name, f"SRW_{i}"))
        for username, role, org, scope in ((STAFF, "ADMIN", None, "GLOBAL"), (AUTOMATION, "ADMIN", ORG, "SELECTED_SITES")):
            cur.execute("""INSERT INTO admin.portal_users (username, display_name, password_hash, role_code, organization_id,
                                                         access_scope_mode, created_by)
                           VALUES (%s, %s, '$argon2id$placeholder', %s, %s, %s, 'srw-test') ON CONFLICT (username) DO NOTHING""",
                        (username, username, role, org, scope))
        cur.execute("INSERT INTO admin.portal_user_site_access (portal_user_id, site_id, created_by_portal_user_id) "
                    "SELECT a.portal_user_id, %s, s.portal_user_id FROM admin.portal_users a, admin.portal_users s "
                    "WHERE a.username = %s AND s.username = %s ON CONFLICT DO NOTHING", (SITE, AUTOMATION, STAFF))
        conn.commit()


def q(conn, sql, params=()):
    with conn.cursor() as cur:
        cur.execute(sql, params)
        return cur.fetchall() if cur.description else []


def staff_id(conn) -> int:
    return q(conn, "SELECT portal_user_id FROM admin.portal_users WHERE username = %s", (STAFF,))[0][0]


@pytest.fixture
def conn():
    with psycopg.connect(CONNINFO, autocommit=True) as connection:
        q(connection, "DELETE FROM analytics.site_report_profiles WHERE site_id = %s", (SITE,))
        q(connection, "UPDATE admin.portal_users SET is_active = TRUE WHERE username = %s", (AUTOMATION,))
        staff = staff_id(connection)
        q(connection, "SELECT * FROM analytics.enrol_site_report_profile(%s, %s)", (staff, SITE))
        for i, (name, group, area) in enumerate(RADISSON_ROSTER):
            q(connection, "SELECT * FROM analytics.set_site_report_asset(%s, %s, %s, %s, %s, %s)",
              (staff, SITE, asset_id(i), group, area, i))
        today = q(connection, "SELECT (now() AT TIME ZONE 'Asia/Kolkata')::date")[0][0]
        for i, (name, _, _) in enumerate(RADISSON_ROSTER):
            if name in TEMPERATURE_SENSORS:
                q(connection, "SELECT * FROM analytics.add_asset_report_setting(%s, %s, 'TEMPERATURE_SETPOINT', "
                              "'{\"value_c\": 24.0}'::jsonb, %s)", (staff, asset_id(i), today))
        # Settings saved "today" are effective from now; back-date them (test only) so they cover October.
        q(connection, "UPDATE analytics.asset_report_setting_versions SET effective_from = '2026-01-01' WHERE site_id = %s", (SITE,))
        yield connection


@pytest.fixture
async def pool():
    from src.database import close_database_pool, open_database_pool

    await open_database_pool()
    yield
    await close_database_pool()


@pytest.fixture
def ems(monkeypatch):
    """Replace only the EMS telemetry reads with synthetic readings."""

    state = {"complete": None, "retention": False, "drop": None, "boom": False}

    async def load_period(uid, site_id, zone, roster, start, end, on_asset_done=None):
        if state["boom"]:
            raise ConnectionError("temporary database failure")
        assets = synthetic_assets(date(2026, 10, 11), 14, drop=state["drop"])
        for _ in roster:
            if on_asset_done:
                await on_asset_done()
        return LoadResult(assets=assets, temperature_assets=set(), reconstructed_minutes=0)

    async def final_hour_completeness(uid, site_id, roster, end):
        return state["complete"] if state["complete"] is not None else (len(roster), len(roster))

    async def check_retention(site_id, start, as_of, needs_measurements=True):
        if state["retention"]:
            raise RetentionExceededError("EMS no longer holds the 1-minute power and temperature data needed for this period.")

    monkeypatch.setattr("src.report_engine.ems_loader.load_period", load_period)
    monkeypatch.setattr("src.report_engine.ems_loader.final_hour_completeness", final_hour_completeness)
    monkeypatch.setattr("src.report_engine.ems_loader.check_retention", check_retention)
    return state


def worker(tmp_path: Path):
    from src.site_report_worker import SiteReportWorker

    return SiteReportWorker(heartbeat_file=str(tmp_path / "hb"))


def latest_attempts(conn, report_id):
    return q(conn, "SELECT status, error_code, trigger, retry_no, wait_message FROM analytics.site_report_attempts "
                   "WHERE report_id = %s ORDER BY created_at", (report_id,))


async def test_manual_generation_publishes_a_validated_version(conn, pool, ems, tmp_path):
    report_id, _ = q(conn, "SELECT * FROM analytics.request_site_report_generation(%s, %s, 'WEEKLY', %s)",
                     (staff_id(conn), SITE, WEEK_START))[0]
    w = worker(tmp_path)
    assert await w.run_once() is True
    assert (tmp_path / "hb").exists()
    status = q(conn, "SELECT analytics.site_report_display_status(%s)", (report_id,))[0][0]
    assert status == "GENERATED", latest_attempts(conn, report_id)
    version = q(conn, "SELECT version_no, state, incomplete_data, comparison_incomplete, coverage, settings_snapshot, "
                      "page_count, file_name, trigger FROM analytics.site_report_versions WHERE report_id = %s", (report_id,))[0]
    assert version[:4] == (1, "AVAILABLE", False, False)
    assert version[4]["current"]["hvac"]["available_pct"] == 100.0
    assert any(s["setting"] == "TEMPERATURE_SETPOINT" for s in version[5]["settings"])
    assert version[6] >= 6 and version[7].endswith(".pdf") and version[8] == "HISTORICAL"
    content = q(conn, "SELECT content FROM analytics.site_report_files f JOIN analytics.site_report_versions v "
                      "ON v.id = f.version_id WHERE v.report_id = %s", (report_id,))[0][0]
    assert bytes(content).startswith(b"%PDF-")


async def test_insufficient_data_fails_without_retry(conn, pool, ems, tmp_path):
    ems["drop"] = {n: [("2026-10-18 00:01", "2026-10-22 00:00")] for n, g, _ in RADISSON_ROSTER if g == "KITCHEN"}
    report_id, _ = q(conn, "SELECT * FROM analytics.request_site_report_generation(%s, %s, 'WEEKLY', %s)",
                     (staff_id(conn), SITE, WEEK_START))[0]
    await worker(tmp_path).run_once()
    attempts = latest_attempts(conn, report_id)
    assert attempts == [("FAILED", "insufficient_data", "HISTORICAL", 0, None)]
    message = q(conn, "SELECT error_message FROM analytics.site_report_attempts WHERE report_id = %s", (report_id,))[0][0]
    assert "Kitchen energy readings available" in message


async def test_retention_exceeded_fails_clearly(conn, pool, ems, tmp_path):
    ems["retention"] = True
    report_id, _ = q(conn, "SELECT * FROM analytics.request_site_report_generation(%s, %s, 'WEEKLY', %s)",
                     (staff_id(conn), SITE, WEEK_START))[0]
    await worker(tmp_path).run_once()
    assert latest_attempts(conn, report_id)[0][:2] == ("FAILED", "retention_exceeded")


async def test_temporary_failure_is_retried_in_15_minutes(conn, pool, ems, tmp_path):
    ems["boom"] = True
    report_id, _ = q(conn, "SELECT * FROM analytics.request_site_report_generation(%s, %s, 'WEEKLY', %s)",
                     (staff_id(conn), SITE, WEEK_START))[0]
    await worker(tmp_path).run_once()
    attempts = latest_attempts(conn, report_id)
    assert attempts[0][:2] == ("FAILED", "generation_failed") and attempts[1][:4] == ("PENDING", None, "RETRY_AUTO", 1)
    delay = q(conn, "SELECT b.not_before - a.finished_at FROM analytics.site_report_attempts a JOIN "
                    "analytics.site_report_attempts b ON b.retry_of = a.id WHERE a.report_id = %s", (report_id,))[0][0]
    assert round(delay.total_seconds() / 60) == 15


async def automatic_attempt(conn):
    """An AUTOMATIC attempt for the week 18-24 Oct, due now (simulates the scheduler at Sun 06:00 IST)."""

    staff = staff_id(conn)
    automation = q(conn, "SELECT portal_user_id FROM admin.portal_users WHERE username = %s", (AUTOMATION,))[0][0]
    q(conn, "SELECT * FROM analytics.set_site_report_automation_account(%s, %s, %s)", (staff, SITE, automation))
    report_id = q(conn, "SELECT analytics.site_report_ensure(%s, 'WEEKLY', %s)", (SITE, WEEK_START))[0][0]
    q(conn, "INSERT INTO analytics.site_report_attempts (report_id, trigger, identity_kind) VALUES (%s, 'AUTOMATIC', 'AUTOMATION')",
      (report_id,))
    return report_id


async def test_automatic_attempt_waits_for_late_data_before_the_deadline(conn, pool, ems, tmp_path, monkeypatch):
    report_id = await automatic_attempt(conn)
    ems["complete"] = (20, 23)
    # Pretend it is Sun 25-Oct 07:00 IST: after the +6 h first check, before the +12 h deadline.
    import src.site_report_worker as module

    class Clock(datetime):
        @classmethod
        def now(cls, tz=None):
            return datetime(2026, 10, 25, 1, 30, tzinfo=timezone.utc)

    monkeypatch.setattr(module, "datetime", Clock)
    await worker(tmp_path).run_once()
    status, error, trigger, retry, wait = latest_attempts(conn, report_id)[0]
    assert (status, trigger) == ("PENDING", "AUTOMATIC") and wait.startswith("Waiting for EMS data (20 of 23 meters complete)")
    not_before = q(conn, "SELECT not_before FROM analytics.site_report_attempts WHERE report_id = %s", (report_id,))[0][0]
    assert not_before == datetime(2026, 10, 25, 2, 0, tzinfo=timezone.utc)      # re-check in 30 minutes


async def test_automatic_attempt_generates_at_the_deadline_even_if_incomplete(conn, pool, ems, tmp_path, monkeypatch):
    report_id = await automatic_attempt(conn)
    ems["complete"] = (20, 23)
    ems["drop"] = {"Kitchen GF Sandwich Toaster": [("2026-10-24 12:00", "2026-10-25 00:00")]}
    import src.site_report_worker as module

    class Clock(datetime):
        @classmethod
        def now(cls, tz=None):
            return datetime(2026, 10, 25, 6, 31, tzinfo=timezone.utc)          # after the 12 h deadline

    monkeypatch.setattr(module, "datetime", Clock)
    await worker(tmp_path).run_once()
    assert q(conn, "SELECT analytics.site_report_display_status(%s)", (report_id,))[0][0] == "GENERATED"
    assert q(conn, "SELECT incomplete_data, automation_portal_user_id IS NOT NULL, generated_by IS NULL "
                   "FROM analytics.site_report_versions WHERE report_id = %s", (report_id,))[0] == (True, True, True)


async def test_inactive_automation_account_stops_generation(conn, pool, ems, tmp_path):
    report_id = await automatic_attempt(conn)
    q(conn, "UPDATE admin.portal_users SET is_active = FALSE WHERE username = %s", (AUTOMATION,))
    await worker(tmp_path).run_once()
    attempts = latest_attempts(conn, report_id)
    assert attempts == [("FAILED", "automation_not_authorized", "AUTOMATIC", 0, None)]      # no automatic retry
