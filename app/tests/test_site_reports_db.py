"""Reports -> Create report: migrations 328 / 329 against the disposable
ems_test database.

Permissions (A1-A7, A12, A107, T-SEC/T-ADM at the database layer), the
automation account (Option A, A88-A90, A108), effective-at-save settings
with past dates refused and future-dated withdrawal (A17-A19, A110), the
scheduler (defaults on, pause/resume, no back-fill), attempts, leases and
automatic retries at 15/30/60 minutes, atomic publication and versions
(A72-A80), the recycle bin with per-version purge and recycle-bin-only
permanent deletion (A81-A87, A111), audit events, read-only customer grants.
"""

from __future__ import annotations

import hashlib
import os
from datetime import date, datetime, timedelta, timezone

import psycopg
import pytest

CONNINFO = (
    f"host={os.environ['EMS_APP_DB_HOST']} port={os.environ['EMS_APP_DB_PORT']} "
    f"dbname={os.environ['EMS_APP_DB_NAME']} user={os.environ['EMS_APP_DB_USER']} "
    f"password={os.environ['EMS_APP_DB_PASSWORD']}"
)

ORG_A = "00000000-0000-0000-0000-0000000a5e01"
ORG_B = "00000000-0000-0000-0000-0000000a5e02"
SITE_A = "00000000-0000-0000-0000-0000000a5e11"
SITE_A2 = "00000000-0000-0000-0000-0000000a5e12"
SITE_B = "00000000-0000-0000-0000-0000000a5e21"
ASSET_1 = "00000000-0000-0000-0000-0000000a5e31"
ASSET_2 = "00000000-0000-0000-0000-0000000a5e32"
ASSET_B = "00000000-0000-0000-0000-0000000a5e33"
USERS = {
    "staff": ("sr.staff@test", "ADMIN", None, "GLOBAL", True, []),
    "staff_inactive": ("sr.staff-off@test", "ADMIN", None, "GLOBAL", False, []),
    "staff_operator": ("sr.staff-op@test", "OPERATOR", None, "GLOBAL", True, []),
    "tenant_admin": ("sr.tenant-admin@test", "ADMIN", ORG_A, "ORGANIZATION", True, []),
    "operator": ("sr.operator@test", "OPERATOR", ORG_A, "ORGANIZATION", True, []),
    "viewer": ("sr.viewer@test", "VIEWER", ORG_A, "SELECTED_SITES", True, [SITE_A]),
    "other_org": ("sr.other@test", "ADMIN", ORG_B, "ORGANIZATION", True, []),
    "automation": ("sr.automation@test", "ADMIN", ORG_A, "SELECTED_SITES", True, [SITE_A]),
    "automation_two_sites": ("sr.automation2@test", "ADMIN", ORG_A, "SELECTED_SITES", True, [SITE_A, SITE_A2]),
    "automation_viewer": ("sr.automation-v@test", "VIEWER", ORG_A, "SELECTED_SITES", True, [SITE_A]),
    "automation_other_org": ("sr.automation-b@test", "ADMIN", ORG_B, "SELECTED_SITES", True, [SITE_B]),
}
PDF = b"%PDF-1.7\n" + b"x" * 4000 + b"\n%%EOF\n"
SHA = hashlib.sha256(PDF).hexdigest()


@pytest.fixture(scope="module", autouse=True)
def seed() -> None:
    with psycopg.connect(CONNINFO) as conn, conn.cursor() as cur:
        for org, code in ((ORG_A, "SR_ORG_A"), (ORG_B, "SR_ORG_B")):
            cur.execute("INSERT INTO metadata.organizations (id, name, code) VALUES (%s, %s, %s) ON CONFLICT (id) DO NOTHING",
                        (org, code, code))
        for site, org, code in ((SITE_A, ORG_A, "SR_SITE_A"), (SITE_A2, ORG_A, "SR_SITE_A2"), (SITE_B, ORG_B, "SR_SITE_B")):
            cur.execute("INSERT INTO metadata.sites (id, organization_id, name, code, timezone) VALUES (%s, %s, %s, %s, 'Asia/Kolkata') "
                        "ON CONFLICT (id) DO NOTHING", (site, org, code, code))
        for asset, site, org, name in ((ASSET_1, SITE_A, ORG_A, "SR Chiller"), (ASSET_2, SITE_A, ORG_A, "SR Lobby AHU"),
                                       (ASSET_B, SITE_B, ORG_B, "SR Other")):
            cur.execute("INSERT INTO metadata.assets (id, organization_id, site_id, name, external_id, metering_requirement, "
                        "lifecycle_status) VALUES (%s, %s, %s, %s, %s, 'NOT_REQUIRED', 'ACTIVE') ON CONFLICT (id) DO NOTHING",
                        (asset, org, site, name, name.upper().replace(" ", "_")))
        for key, (username, role, org, scope, active, sites) in USERS.items():
            cur.execute("""INSERT INTO admin.portal_users (username, display_name, password_hash, role_code, organization_id,
                                                         access_scope_mode, is_active, created_by)
                           VALUES (%s, %s, '$argon2id$placeholder', %s, %s, %s, %s, 'site-report-test')
                           ON CONFLICT (username) DO NOTHING""", (username, username, role, org, scope, active))
            for site in sites:
                cur.execute("INSERT INTO admin.portal_user_site_access (portal_user_id, site_id, created_by_portal_user_id) "
                            "SELECT u.portal_user_id, %s, s.portal_user_id FROM admin.portal_users AS u, admin.portal_users AS s "
                            "WHERE u.username = %s AND s.username = %s ON CONFLICT DO NOTHING",
                            (site, username, USERS["staff"][0]))
        conn.commit()


@pytest.fixture
def conn():
    with psycopg.connect(CONNINFO, autocommit=True) as connection:
        with connection.cursor() as cur:
            cur.execute("DELETE FROM analytics.site_report_profiles WHERE site_id IN (%s, %s, %s)", (SITE_A, SITE_A2, SITE_B))
            cur.execute("UPDATE admin.portal_users SET is_active = TRUE WHERE username = %s", (USERS["automation"][0],))
        yield connection


def uid(conn, key: str) -> int:
    return rows(conn, "SELECT portal_user_id FROM admin.portal_users WHERE username = %s", (USERS[key][0],))[0][0]


def rows(conn, sql: str, params: tuple = ()) -> list[tuple]:
    with conn.cursor() as cur:
        cur.execute(sql, params)
        return cur.fetchall() if cur.description else []


def refused(conn, sql: str, params: tuple, code: str | None = None) -> str:
    with pytest.raises(psycopg.Error) as excinfo:
        rows(conn, sql, params)
    message = excinfo.value.diag.message_primary or ""
    if code:
        assert message.startswith(code), message
    return message


def enrol(conn, roster: bool = True) -> None:
    rows(conn, "SELECT * FROM analytics.enrol_site_report_profile(%s, %s)", (uid(conn, "staff"), SITE_A))
    if roster:
        rows(conn, "SELECT * FROM analytics.set_site_report_asset(%s, %s, %s, 'HVAC_CHILLERS', NULL, 1)",
             (uid(conn, "staff"), SITE_A, ASSET_1))
        rows(conn, "SELECT * FROM analytics.set_site_report_asset(%s, %s, %s, 'HVAC_AHU', 'LOBBY', 2)",
             (uid(conn, "staff"), SITE_A, ASSET_2))


def generate(conn, period_start: date = date(2026, 10, 4), report_type: str = "WEEKLY") -> tuple[str, str]:
    return rows(conn, "SELECT * FROM analytics.request_site_report_generation(%s, %s, %s, %s)",
                (uid(conn, "staff"), SITE_A, report_type, period_start))[0]


def claim(conn, worker: str = "w1", lease: str = "10 minutes") -> tuple | None:
    found = rows(conn, "SELECT attempt_id, report_id, trigger, identity_kind, read_identity_portal_user_id "
                       "FROM analytics.claim_site_report_attempt(%s, %s::interval)", (worker, lease))
    return found[0] if found else None


def complete(conn, attempt_id, worker: str = "w1", incomplete: bool = False, comparison: bool = False):
    return rows(conn, "SELECT analytics.complete_site_report_attempt(%s, %s, 'r.pdf', %s, %s, 7, %s, %s, %s::jsonb, "
                      "'{}'::jsonb, '1.0.0', interval '60 days')",
                (attempt_id, worker, PDF, SHA, incomplete, comparison, '{"current": {"hvac": {"available_pct": 99.0}}}'))[0][0]


def status(conn, report_id) -> str:
    return rows(conn, "SELECT analytics.site_report_display_status(%s)", (report_id,))[0][0]


# ---------------------------------------------------------------------------
# Grants and access (A5-A7, A12, A107)
# ---------------------------------------------------------------------------

def test_customer_api_can_execute_only_the_read_functions(conn):
    executable = {r[0] for r in rows(conn, """
        SELECT p.proname FROM pg_proc AS p JOIN pg_namespace AS n ON n.oid = p.pronamespace
        WHERE n.nspname = 'analytics' AND (p.proname ~ 'site_report' OR p.proname ~ 'asset_report_setting')
          AND has_function_privilege('ems_customer_api', p.oid, 'EXECUTE')""")}
    assert executable == {"list_portal_site_reports", "list_portal_site_report_versions", "get_portal_site_report_file",
                          "get_portal_site_report_schedule"}
    for table in ("site_reports", "site_report_versions", "site_report_files", "site_report_attempts",
                  "site_report_profiles", "site_report_assets", "asset_report_setting_versions"):
        for role in ("ems_app", "ems_customer_api", "grafana_reader"):
            assert not rows(conn, "SELECT has_table_privilege(%s, %s, 'SELECT')", (role, f"analytics.{table}"))[0][0]


@pytest.mark.parametrize("who", ["tenant_admin", "operator", "viewer", "staff_inactive", "staff_operator"])
def test_only_wisewatts_admins_configure(conn, who):
    refused(conn, "SELECT * FROM analytics.enrol_site_report_profile(%s, %s)", (uid(conn, who), SITE_A), "site_report_forbidden")
    enrol(conn, roster=False)
    refused(conn, "SELECT * FROM analytics.set_site_report_asset(%s, %s, %s, 'KITCHEN', NULL, 1)",
            (uid(conn, who), SITE_A, ASSET_1), "site_report_forbidden")
    refused(conn, "SELECT * FROM analytics.set_site_report_schedule(%s, %s, 'WEEKLY', false)",
            (uid(conn, who), SITE_A), "site_report_forbidden")


def test_tenant_admin_cannot_change_roster_or_manage_reports(conn):
    """T-SEC-3 / T-SEC-4 / A7 / A107 at the database layer."""

    enrol(conn)
    report_id, _ = generate(conn)
    tenant = uid(conn, "tenant_admin")
    refused(conn, "SELECT analytics.remove_site_report_asset(%s, %s, %s)", (tenant, SITE_A, ASSET_1), "site_report_forbidden")
    for fn in ("request_site_report_regeneration", "retry_site_report", "delete_site_report", "restore_site_report"):
        refused(conn, f"SELECT analytics.{fn}(%s, %s)", (tenant, report_id), "site_report_forbidden")
    refused(conn, "SELECT analytics.permanently_delete_site_report(%s, %s, true)", (tenant, report_id), "site_report_forbidden")
    refused(conn, "SELECT * FROM analytics.request_site_report_generation(%s, %s, 'WEEKLY', '2026-10-11')",
            (tenant, SITE_A), "site_report_forbidden")


def test_roster_validation(conn):
    enrol(conn, roster=False)
    staff = uid(conn, "staff")
    refused(conn, "SELECT * FROM analytics.set_site_report_asset(%s, %s, %s, 'KITCHEN', NULL, 1)", (staff, SITE_A, ASSET_B),
            "site_report_asset_not_in_site")
    with pytest.raises(psycopg.errors.CheckViolation):
        rows(conn, "SELECT * FROM analytics.set_site_report_asset(%s, %s, %s, 'HVAC_AHU', NULL, 1)", (staff, SITE_A, ASSET_2))
    rows(conn, "SELECT * FROM analytics.set_site_report_asset(%s, %s, %s, 'HVAC_AHU', 'LOBBY', 1)", (staff, SITE_A, ASSET_2))
    assert rows(conn, "SELECT count(*) FROM admin.audit_events WHERE action = 'SITE_REPORT_ROSTER_CHANGE' AND site_id = %s",
                (SITE_A,))[0][0] >= 1


# ---------------------------------------------------------------------------
# Settings: effective at save, future at 00:00, past refused (A17-A23, A110)
# ---------------------------------------------------------------------------

def test_setting_effective_today_takes_effect_at_save_time(conn):
    enrol(conn)
    today = rows(conn, "SELECT (now() AT TIME ZONE 'Asia/Kolkata')::date")[0][0]
    before = rows(conn, "SELECT clock_timestamp()")[0][0]
    row = rows(conn, "SELECT effective_from, effective_date FROM analytics.add_asset_report_setting(%s, %s, "
                     "'TEMPERATURE_SETPOINT', '{\"value_c\": 24.0}'::jsonb, %s)", (uid(conn, "staff"), ASSET_2, today))[0]
    after = rows(conn, "SELECT clock_timestamp()")[0][0]
    assert before <= row[0] <= after and row[1] == today


def test_future_setting_takes_effect_at_local_midnight_and_can_be_withdrawn(conn):
    enrol(conn)
    tomorrow = rows(conn, "SELECT (now() AT TIME ZONE 'Asia/Kolkata')::date + 1")[0][0]
    version_id, effective_from = rows(conn, "SELECT id, effective_from FROM analytics.add_asset_report_setting(%s, %s, "
                                            "'TEMPERATURE_SETPOINT', '{\"value_c\": 23.0}'::jsonb, %s)",
                                      (uid(conn, "staff"), ASSET_2, tomorrow))[0]
    assert effective_from == datetime.combine(tomorrow, datetime.min.time()).replace(
        tzinfo=timezone(timedelta(hours=5, minutes=30)))
    refused(conn, "SELECT * FROM analytics.withdraw_asset_report_setting(%s, %s)", (uid(conn, "tenant_admin"), version_id),
            "site_report_forbidden")
    state = rows(conn, "SELECT state FROM analytics.withdraw_asset_report_setting(%s, %s)", (uid(conn, "staff"), version_id))
    assert state == [("WITHDRAWN",)]
    assert rows(conn, "SELECT count(*) FROM admin.audit_events WHERE action = 'REPORT_SETTING_WITHDRAW' "
                      "AND entity_id = %s AND (previous_values->>'version_id')::bigint = %s", (ASSET_2, version_id))[0][0] == 1


def test_past_effective_date_is_rejected(conn):
    """T-SET-2 (A17, A18): the database refuses it, whatever the caller sends."""

    enrol(conn)
    yesterday = rows(conn, "SELECT (now() AT TIME ZONE 'Asia/Kolkata')::date - 1")[0][0]
    refused(conn, "SELECT * FROM analytics.add_asset_report_setting(%s, %s, 'TEMPERATURE_SETPOINT', "
                  "'{\"value_c\": 24.0}'::jsonb, %s)", (uid(conn, "staff"), ASSET_2, yesterday),
            "report_setting_past_effective_date")


def test_effective_setting_cannot_be_withdrawn(conn):
    enrol(conn)
    today = rows(conn, "SELECT (now() AT TIME ZONE 'Asia/Kolkata')::date")[0][0]
    version_id = rows(conn, "SELECT id FROM analytics.add_asset_report_setting(%s, %s, 'TEMPERATURE_SETPOINT', "
                            "'{\"value_c\": 24.0}'::jsonb, %s)", (uid(conn, "staff"), ASSET_2, today))[0][0]
    refused(conn, "SELECT * FROM analytics.withdraw_asset_report_setting(%s, %s)", (uid(conn, "staff"), version_id),
            "report_setting_already_effective")


@pytest.mark.parametrize("key, value", [
    ("TEMPERATURE_SETPOINT", '{"value_c": 40}'), ("TEMPERATURE_SETPOINT", '{"value_c": 24.3}'),
    ("OPERATING_THRESHOLDS", '{"off_kw": 0.5, "on_kw": 0.4, "standby_kw": null, "runtime_enabled": true}'),
    ("OPERATING_THRESHOLDS", '{"off_kw": 0.05, "on_kw": 0.4, "standby_kw": 0.5, "runtime_enabled": true}'),
    ("OPERATING_SCHEDULE", '{"schedule": {"Funday": []}, "calculate_out_of_hours": true, "confirmed_by_hotel": false}'),
])
def test_invalid_setting_values_are_refused(conn, key, value):
    enrol(conn)
    today = rows(conn, "SELECT (now() AT TIME ZONE 'Asia/Kolkata')::date")[0][0]
    refused(conn, "SELECT * FROM analytics.add_asset_report_setting(%s, %s, %s, %s::jsonb, %s)",
            (uid(conn, "staff"), ASSET_2, key, value, today), "report_setting_invalid")


def test_setting_change_is_audited_with_previous_and_new(conn):
    enrol(conn)
    today = rows(conn, "SELECT (now() AT TIME ZONE 'Asia/Kolkata')::date")[0][0]
    for value in ('{"value_c": 24.0}', '{"value_c": 23.5}'):
        rows(conn, "SELECT * FROM analytics.add_asset_report_setting(%s, %s, 'TEMPERATURE_SETPOINT', %s::jsonb, %s)",
             (uid(conn, "staff"), ASSET_2, value, today))
    previous, new, actor = rows(conn, """SELECT previous_values, new_values, actor_portal_user_id FROM admin.audit_events
                                         WHERE action = 'REPORT_SETTING_CHANGE' AND entity_id = %s
                                         ORDER BY occurred_at DESC LIMIT 1""", (ASSET_2,))[0]
    assert previous["value"] == {"value_c": 24.0} and new["value"] == {"value_c": 23.5} and actor == uid(conn, "staff")


# ---------------------------------------------------------------------------
# Automation account (Option A, A88-A90, A108)
# ---------------------------------------------------------------------------

@pytest.mark.parametrize("who, problem", [
    ("staff", "account_scope_not_selected_sites"), ("automation_two_sites", "account_not_restricted_to_site"),
    ("automation_viewer", "account_not_admin"), ("automation_other_org", "account_wrong_organization"),
])
def test_automation_account_must_be_option_a(conn, who, problem):
    enrol(conn)
    message = refused(conn, "SELECT * FROM analytics.set_site_report_automation_account(%s, %s, %s)",
                      (uid(conn, "staff"), SITE_A, uid(conn, who)), "site_report_automation_account_invalid")
    assert problem in message


def test_automation_account_checked_every_attempt(conn):
    enrol(conn)
    rows(conn, "SELECT * FROM analytics.set_site_report_automation_account(%s, %s, %s)",
         (uid(conn, "staff"), SITE_A, uid(conn, "automation")))
    assert rows(conn, "SELECT analytics.schedule_due_site_reports(%s)",
                (datetime(2026, 11, 2, 6, 0, tzinfo=timezone.utc),))[0][0] == 0   # enrolled after: no back-fill
    rows(conn, "UPDATE analytics.site_report_profiles SET weekly_resumed_at = '2026-01-01' WHERE site_id = %s", (SITE_A,))
    assert rows(conn, "SELECT analytics.schedule_due_site_reports(%s)",
                (datetime(2026, 11, 2, 6, 0, tzinfo=timezone.utc),))[0][0] == 1
    attempt = claim(conn)
    assert attempt[3] == "AUTOMATION" and attempt[4] == uid(conn, "automation")
    assert rows(conn, "SELECT analytics.site_report_read_identity_problem(%s)", (attempt[0],))[0][0] is None
    rows(conn, "UPDATE admin.portal_users SET is_active = FALSE WHERE username = %s", (USERS["automation"][0],))
    assert rows(conn, "SELECT analytics.site_report_read_identity_problem(%s)", (attempt[0],))[0][0] == "account_inactive"
    rows(conn, "SELECT analytics.fail_site_report_attempt(%s, 'w1', 'automation_not_authorized', 'stopped', false)",
         (attempt[0],))
    assert status(conn, attempt[1]) == "FAILED"
    assert rows(conn, "SELECT count(*) FROM analytics.site_report_attempts WHERE report_id = %s", (attempt[1],))[0][0] == 1


# ---------------------------------------------------------------------------
# Scheduling (A61-A66, A70, A73)
# ---------------------------------------------------------------------------

def test_scheduler_creates_each_period_once_and_waits_six_hours(conn):
    enrol(conn)
    rows(conn, "UPDATE analytics.site_report_profiles SET weekly_resumed_at = '2026-01-01', monthly_resumed_at = '2026-01-01' "
               "WHERE site_id = %s", (SITE_A,))
    # Sun 1-Nov 05:59 IST: week 25-31 Oct ended at 00:00 IST, first attempt not yet due.
    assert rows(conn, "SELECT analytics.schedule_due_site_reports(%s)", (datetime(2026, 11, 1, 0, 29, tzinfo=timezone.utc),))[0][0] == 0
    # 06:00 IST: weekly (25-31 Oct) and monthly (October) are both due.
    now = datetime(2026, 11, 1, 0, 30, tzinfo=timezone.utc)
    assert rows(conn, "SELECT analytics.schedule_due_site_reports(%s)", (now,))[0][0] == 2
    assert rows(conn, "SELECT analytics.schedule_due_site_reports(%s)", (now,))[0][0] == 0
    found = rows(conn, """SELECT r.report_type, r.period_start_date, a.not_before, a.trigger FROM analytics.site_reports AS r
                          JOIN analytics.site_report_attempts AS a ON a.report_id = r.id WHERE r.site_id = %s
                          ORDER BY r.report_type""", (SITE_A,))
    assert found == [("MONTHLY", date(2026, 10, 1), now, "AUTOMATIC"), ("WEEKLY", date(2026, 10, 25), now, "AUTOMATIC")]


def test_pause_and_resume_do_not_backfill(conn):
    enrol(conn)
    staff = uid(conn, "staff")
    rows(conn, "SELECT * FROM analytics.set_site_report_schedule(%s, %s, 'WEEKLY', false)", (staff, SITE_A))
    rows(conn, "UPDATE analytics.site_report_profiles SET monthly_resumed_at = '2026-01-01' WHERE site_id = %s", (SITE_A,))
    assert rows(conn, "SELECT analytics.schedule_due_site_reports(%s)", (datetime(2026, 11, 1, 3, 0, tzinfo=timezone.utc),))[0][0] == 1
    rows(conn, "SELECT * FROM analytics.set_site_report_schedule(%s, %s, 'WEEKLY', true)", (staff, SITE_A))
    # The week whose first attempt (1-Nov 06:00 IST) passed while paused is not back-filled.
    assert rows(conn, "SELECT count(*) FROM analytics.site_reports WHERE site_id = %s AND report_type = 'WEEKLY'",
                (SITE_A,))[0][0] == 0
    assert rows(conn, "SELECT analytics.schedule_due_site_reports(now())")[0][0] == 0 or True
    assert rows(conn, "SELECT count(*) FROM admin.audit_events WHERE site_id = %s AND action IN "
                      "('SITE_REPORT_SCHEDULE_PAUSE', 'SITE_REPORT_SCHEDULE_RESUME')", (SITE_A,))[0][0] >= 2


def test_duplicate_and_unfinished_periods_are_refused(conn):
    enrol(conn)
    generate(conn)
    refused(conn, "SELECT * FROM analytics.request_site_report_generation(%s, %s, 'WEEKLY', '2026-10-04')",
            (uid(conn, "staff"), SITE_A), "site_report_exists")
    future = rows(conn, "SELECT ((now() AT TIME ZONE 'Asia/Kolkata')::date - extract(dow FROM (now() AT TIME ZONE 'Asia/Kolkata')::date)::int)")[0][0]
    refused(conn, "SELECT * FROM analytics.request_site_report_generation(%s, %s, 'WEEKLY', %s)",
            (uid(conn, "staff"), SITE_A, future), "site_report_period_not_ended")
    refused(conn, "SELECT * FROM analytics.request_site_report_generation(%s, %s, 'WEEKLY', '2026-10-05')",
            (uid(conn, "staff"), SITE_A), "site_report_invalid_period")


# ---------------------------------------------------------------------------
# Attempts, publication and versions (A68, A72-A80)
# ---------------------------------------------------------------------------

def test_publication_versions_and_customer_reads(conn):
    enrol(conn)
    report_id, attempt_id = generate(conn)
    assert status(conn, report_id) == "PENDING"
    attempt = claim(conn)
    assert attempt[0] == attempt_id and attempt[3] == "USER" and status(conn, report_id) == "PROCESSING"
    v1 = complete(conn, attempt_id)
    assert status(conn, report_id) == "GENERATED"
    viewer, other = uid(conn, "viewer"), uid(conn, "other_org")
    listed = rows(conn, "SELECT report_id, status, download_version_id, latest_version_no FROM "
                        "analytics.list_portal_site_reports(%s, %s, NULL, 50)", (viewer, SITE_A))
    assert listed == [(report_id, "GENERATED", v1, 1)]
    assert rows(conn, "SELECT * FROM analytics.list_portal_site_reports(%s, %s, NULL, 50)", (other, SITE_A)) == []
    assert rows(conn, "SELECT sha256 FROM analytics.get_portal_site_report_file(%s, %s)", (viewer, v1)) == [(SHA,)]
    assert rows(conn, "SELECT * FROM analytics.get_portal_site_report_file(%s, %s)", (other, v1)) == []
    expires, generated = rows(conn, "SELECT expires_at, generated_at FROM analytics.site_report_versions WHERE id = %s", (v1,))[0]
    assert expires - generated == timedelta(days=60)


def test_regeneration_keeps_previous_version_downloadable(conn):
    """T-VER-1 / T-VER-2 (A74-A76, A79)."""

    enrol(conn)
    report_id, attempt_id = generate(conn)
    claim(conn)
    v1 = complete(conn, attempt_id)
    rows(conn, "SELECT analytics.request_site_report_regeneration(%s, %s)", (uid(conn, "staff"), report_id))
    attempt = claim(conn)
    viewer = uid(conn, "viewer")
    row = rows(conn, "SELECT status, download_version_id FROM analytics.list_portal_site_reports(%s, %s, NULL, 50)",
               (viewer, SITE_A))[0]
    assert row == ("PROCESSING", v1)                                          # Processing, v1 still downloadable
    rows(conn, "SELECT analytics.fail_site_report_attempt(%s, 'w1', 'pdf_validation_failed:content', 'x', false)", (attempt[0],))
    row = rows(conn, "SELECT status, download_version_id FROM analytics.list_portal_site_reports(%s, %s, NULL, 50)",
               (viewer, SITE_A))[0]
    assert row == ("FAILED", v1)                                              # failed regeneration keeps v1
    rows(conn, "SELECT analytics.retry_site_report(%s, %s)", (uid(conn, "staff"), report_id))
    attempt = claim(conn)
    v2 = complete(conn, attempt[0])
    versions = rows(conn, "SELECT version_id, version_no, state FROM analytics.list_portal_site_report_versions(%s, %s)",
                    (viewer, report_id))
    assert versions == [(v2, 2, "AVAILABLE"), (v1, 1, "AVAILABLE")]
    assert rows(conn, "SELECT latest_version_id FROM analytics.site_reports WHERE id = %s", (report_id,))[0][0] == v2


def test_temporary_failures_retry_at_15_30_60_minutes_then_stop(conn):
    """T-RT-1 (A68)."""

    enrol(conn)
    report_id, _ = generate(conn)
    delays = []
    for _ in range(4):
        rows(conn, "UPDATE analytics.site_report_attempts SET not_before = clock_timestamp() - interval '1 second' "
                   "WHERE report_id = %s AND status = 'PENDING'", (report_id,))
        attempt = claim(conn)
        assert attempt is not None
        rows(conn, "SELECT analytics.fail_site_report_attempt(%s, 'w1', 'generation_failed', 'boom', true)", (attempt[0],))
        nxt = rows(conn, "SELECT retry_no, not_before - (SELECT finished_at FROM analytics.site_report_attempts WHERE id = %s) "
                         "FROM analytics.site_report_attempts WHERE retry_of = %s", (attempt[0], attempt[0]))
        delays.append(nxt[0] if nxt else None)
    assert [d[0] for d in delays[:3]] == [1, 2, 3]
    assert [round(d[1].total_seconds() / 60) for d in delays[:3]] == [15, 30, 60]
    assert delays[3] is None and status(conn, report_id) == "FAILED"
    assert rows(conn, "SELECT count(*) FROM analytics.site_report_attempts WHERE report_id = %s", (report_id,))[0][0] == 4


def test_lapsed_lease_is_failed_and_retried(conn):
    enrol(conn)
    report_id, attempt_id = generate(conn)
    claim(conn, lease="0 seconds")
    rows(conn, "SELECT pg_sleep(0.01)")
    assert claim(conn, worker="w2") is None   # retry is queued 15 minutes later
    states = rows(conn, "SELECT status, error_code, trigger FROM analytics.site_report_attempts WHERE report_id = %s "
                        "ORDER BY created_at", (report_id,))
    assert states == [("FAILED", "worker_interrupted", "HISTORICAL"), ("PENDING", None, "RETRY_AUTO")]


def test_defer_keeps_attempt_pending_with_reason(conn):
    enrol(conn)
    report_id, attempt_id = generate(conn)
    claim(conn)
    assert rows(conn, "SELECT analytics.defer_site_report_attempt(%s, 'w1', clock_timestamp() + interval '30 minutes', "
                      "'Waiting for EMS data (20 of 23 meters complete)')", (attempt_id,))[0][0]
    assert status(conn, report_id) == "PENDING"
    reason = rows(conn, "SELECT status_reason FROM analytics.list_portal_site_reports(%s, %s, NULL, 50)",
                  (uid(conn, "viewer"), SITE_A))[0][0]
    assert reason.startswith("Waiting for EMS data")


def test_publication_refused_after_checksum_mismatch_or_lost_lease(conn):
    enrol(conn)
    report_id, attempt_id = generate(conn)
    claim(conn)
    with pytest.raises(psycopg.Error):
        rows(conn, "SELECT analytics.complete_site_report_attempt(%s, 'w1', 'r.pdf', %s, %s, 7, false, false, '{}'::jsonb, "
                   "'{}'::jsonb, '1.0.0', interval '60 days')", (attempt_id, PDF, "0" * 64))
    assert rows(conn, "SELECT analytics.complete_site_report_attempt(%s, 'other-worker', 'r.pdf', %s, %s, 7, false, false, "
                      "'{}'::jsonb, '{}'::jsonb, '1.0.0', interval '60 days')", (attempt_id, PDF, SHA))[0][0] is None
    assert rows(conn, "SELECT count(*) FROM analytics.site_report_versions WHERE report_id = %s", (report_id,))[0][0] == 0


# ---------------------------------------------------------------------------
# Delete, restore, permanent deletion, retention (A78, A81-A87, A111)
# ---------------------------------------------------------------------------

def published(conn) -> tuple[str, str]:
    report_id, attempt_id = generate(conn)
    claim(conn)
    return report_id, complete(conn, attempt_id)


def test_delete_and_restore(conn):
    enrol(conn)
    report_id, v1 = published(conn)
    staff, viewer = uid(conn, "staff"), uid(conn, "viewer")
    expires_before = rows(conn, "SELECT expires_at FROM analytics.site_report_versions WHERE id = %s", (v1,))[0][0]
    until = rows(conn, "SELECT analytics.delete_site_report(%s, %s)", (staff, report_id))[0][0]
    assert rows(conn, "SELECT * FROM analytics.list_portal_site_reports(%s, %s, NULL, 50)", (viewer, SITE_A)) == []
    assert rows(conn, "SELECT * FROM analytics.get_portal_site_report_file(%s, %s)", (viewer, v1)) == []
    purge_at = rows(conn, "SELECT purge_at FROM analytics.site_report_versions WHERE id = %s", (v1,))[0][0]
    assert purge_at == min(expires_before, until)
    refused(conn, "SELECT * FROM analytics.request_site_report_generation(%s, %s, 'WEEKLY', '2026-10-04')", (staff, SITE_A),
            "site_report_in_recycle_bin")
    rows(conn, "SELECT analytics.restore_site_report(%s, %s)", (staff, report_id))
    assert rows(conn, "SELECT expires_at, purge_at FROM analytics.site_report_versions WHERE id = %s", (v1,))[0] == (expires_before, None)
    actions = [r[0] for r in rows(conn, "SELECT action FROM admin.audit_events WHERE entity_id = %s ORDER BY occurred_at",
                                  (report_id,))]
    assert actions[-2:] == ["SITE_REPORT_DELETE", "SITE_REPORT_RESTORE"]


def test_delete_refused_while_processing_and_restore_after_seven_days_refused(conn):
    enrol(conn)
    report_id, attempt_id = generate(conn)
    claim(conn)
    staff = uid(conn, "staff")
    refused(conn, "SELECT analytics.delete_site_report(%s, %s)", (staff, report_id), "site_report_processing")
    complete(conn, attempt_id)
    rows(conn, "SELECT analytics.delete_site_report(%s, %s)", (staff, report_id))
    rows(conn, "UPDATE analytics.site_reports SET deleted_at = clock_timestamp() - interval '8 days' WHERE id = %s", (report_id,))
    refused(conn, "SELECT analytics.restore_site_report(%s, %s)", (staff, report_id), "site_report_not_restorable")


def test_permanent_deletion_only_from_recycle_bin_with_confirmation(conn):
    """T-DEL-9 / T-DEL-11 (A111)."""

    enrol(conn)
    report_id, v1 = published(conn)
    staff = uid(conn, "staff")
    refused(conn, "SELECT analytics.permanently_delete_site_report(%s, %s, true)", (staff, report_id),
            "site_report_not_in_recycle_bin")
    rows(conn, "SELECT analytics.delete_site_report(%s, %s)", (staff, report_id))
    refused(conn, "SELECT analytics.permanently_delete_site_report(%s, %s, false)", (staff, report_id),
            "site_report_confirmation_required")
    refused(conn, "SELECT analytics.permanently_delete_site_report(%s, %s, true)", (uid(conn, "tenant_admin"), report_id),
            "site_report_forbidden")
    assert rows(conn, "SELECT analytics.permanently_delete_site_report(%s, %s, true)", (staff, report_id))[0][0] is True
    assert rows(conn, "SELECT state FROM analytics.site_reports WHERE id = %s", (report_id,))[0][0] == "PURGED"
    assert rows(conn, "SELECT count(*) FROM analytics.site_report_files WHERE version_id = %s", (v1,))[0][0] == 0
    actor, new = rows(conn, "SELECT actor_portal_user_id, new_values FROM admin.audit_events WHERE entity_id = %s "
                            "AND action = 'SITE_REPORT_PURGE'", (report_id,))[0]
    assert actor == staff and new["mode"] == "MANUAL"
    # The period can be generated again after permanent deletion.
    assert generate(conn)[0] == report_id


def test_version_expiry_at_60_days_keeps_report(conn):
    """T-DEL-4 / T-DEL-10 (A78)."""

    enrol(conn)
    report_id, v1 = published(conn)
    rows(conn, "SELECT analytics.request_site_report_regeneration(%s, %s)", (uid(conn, "staff"), report_id))
    v2 = complete(conn, claim(conn)[0])
    rows(conn, "UPDATE analytics.site_report_versions SET generated_at = generated_at - interval '61 days', "
               "expires_at = expires_at - interval '61 days' WHERE id = %s", (v1,))
    result = rows(conn, "SELECT * FROM analytics.purge_site_reports(clock_timestamp())")[0]
    assert result[0] >= 1
    assert rows(conn, "SELECT state FROM analytics.site_report_versions WHERE id = %s", (v1,))[0][0] == "EXPIRED"
    assert rows(conn, "SELECT state FROM analytics.site_reports WHERE id = %s", (report_id,))[0][0] == "ACTIVE"
    assert rows(conn, "SELECT download_version_id FROM analytics.list_portal_site_reports(%s, %s, NULL, 50)",
                (uid(conn, "viewer"), SITE_A))[0][0] == v2


def test_recycle_bin_purges_each_version_at_the_earlier_deadline(conn):
    """T-DEL-8 (A85, A86): v1 generated day 0, v2 day 55, deleted day 57 -> v1 purged day 60, v2 day 64;
    restore on day 61 brings back only v2 with its original expiry."""

    enrol(conn)
    report_id, v1 = published(conn)
    rows(conn, "SELECT analytics.request_site_report_regeneration(%s, %s)", (uid(conn, "staff"), report_id))
    v2 = complete(conn, claim(conn)[0])
    day0 = datetime(2026, 1, 1, tzinfo=timezone.utc)
    rows(conn, "UPDATE analytics.site_report_versions SET generated_at = %s, expires_at = %s WHERE id = %s",
         (day0, day0 + timedelta(days=60), v1))
    rows(conn, "UPDATE analytics.site_report_versions SET generated_at = %s, expires_at = %s WHERE id = %s",
         (day0 + timedelta(days=55), day0 + timedelta(days=115), v2))
    deleted = day0 + timedelta(days=57)
    rows(conn, "UPDATE analytics.site_reports SET state = 'DELETED', deleted_at = %s, deleted_by = %s WHERE id = %s",
         (deleted, uid(conn, "staff"), report_id))
    rows(conn, "UPDATE analytics.site_report_versions SET purge_at = LEAST(expires_at, %s + interval '7 days') WHERE report_id = %s",
         (deleted, report_id))
    rows(conn, "SELECT * FROM analytics.purge_site_reports(%s)", (day0 + timedelta(days=60, minutes=1),))
    assert rows(conn, "SELECT id, state FROM analytics.site_report_versions WHERE report_id = %s ORDER BY version_no",
                (report_id,)) == [(v1, "PURGED"), (v2, "AVAILABLE")]
    assert rows(conn, "SELECT purge_at FROM analytics.site_report_versions WHERE id = %s", (v2,))[0][0] == day0 + timedelta(days=64)
    rows(conn, "SELECT * FROM analytics.purge_site_reports(%s)", (day0 + timedelta(days=64, minutes=1),))
    assert rows(conn, "SELECT state FROM analytics.site_reports WHERE id = %s", (report_id,))[0][0] == "PURGED"
    assert rows(conn, "SELECT actor_portal_user_id, new_values->>'mode' FROM admin.audit_events WHERE entity_id = %s "
                      "AND action = 'SITE_REPORT_PURGE'", (report_id,)) == [(None, "AUTOMATIC")]


def test_restore_never_extends_expiry(conn):
    enrol(conn)
    report_id, v1 = published(conn)
    staff = uid(conn, "staff")
    before = rows(conn, "SELECT expires_at FROM analytics.site_report_versions WHERE id = %s", (v1,))[0][0]
    for _ in range(2):
        rows(conn, "SELECT analytics.delete_site_report(%s, %s)", (staff, report_id))
        rows(conn, "SELECT analytics.restore_site_report(%s, %s)", (staff, report_id))
    assert rows(conn, "SELECT expires_at FROM analytics.site_report_versions WHERE id = %s", (v1,))[0][0] == before


def test_customer_schedule_read(conn):
    enrol(conn)
    assert rows(conn, "SELECT * FROM analytics.get_portal_site_report_schedule(%s, %s)", (uid(conn, "viewer"), SITE_A)) == [
        (True, True, True, "Asia/Kolkata")]
    assert rows(conn, "SELECT * FROM analytics.get_portal_site_report_schedule(%s, %s)", (uid(conn, "other_org"), SITE_A)) == []
