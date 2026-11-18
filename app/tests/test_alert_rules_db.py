"""ADR-024 customer-configurable alert rules -- migrations 321-326 against the
disposable ems_test database.

Each test builds its own tenant fixtures inside one transaction that is rolled
back (so the background evaluator job, which only sees committed rules, never
touches them). Evaluator tests hold the evaluator's advisory lock for the
session so a concurrent background run can never make a direct call skip.

Covers: the ADR-024 §2 permission matrix (customer ADMIN / OPERATOR / VIEWER,
GLOBAL ADMIN / OPERATOR / VIEWER staff), tenant isolation, server-side
validation (explicit equal-to tolerance, cumulative counters excluded, the
25-active-rule limit, name reuse after soft delete), transactional audit with
actor type, configuration changes ending Active alerts, acknowledgement (not
resolution; "WiseWatts Support" for staff), and the evaluator lifecycle
(5-minute qualification, telemetry gap keeps Active + acknowledgement,
1-minute resolution on valid data, schedules incl. crossing midnight, 90-day
retention).
"""

from __future__ import annotations

import os
import re
import uuid
from datetime import datetime, time, timedelta, timezone

import psycopg
import pytest

CONNINFO = (
    f"host={os.environ['EMS_APP_DB_HOST']} port={os.environ['EMS_APP_DB_PORT']} "
    f"dbname={os.environ['EMS_APP_DB_NAME']} user={os.environ['EMS_APP_DB_USER']} "
    f"password={os.environ['EMS_APP_DB_PASSWORD']}"
)
EVALUATOR_LOCK = "SELECT pg_advisory_lock(hashtextextended('analytics.evaluate_alert_rules', 0))"
EVERY_DAY = 127


class Fixture:
    def __init__(self, cur):
        self.cur = cur
        self.tag = uuid.uuid4().hex[:8].upper()
        cur.execute("SELECT id FROM config.device_profiles WHERE profile_code = 'ENERGY_METER_ENISCOPE_V1'")
        row = cur.fetchone()
        if row is None:
            pytest.skip("ENERGY_METER_ENISCOPE_V1 profile is not seeded in this database")
        self.profile_id = row[0]
        cur.execute("SELECT id FROM config.device_categories WHERE lower(name) = 'energy meter'")
        category_id = cur.fetchone()[0]
        cur.execute(
            "INSERT INTO metadata.device_models (vendor, model, device_type, device_category_id) "
            "VALUES ('WiseWatts Test', %s, 'Energy Meter', %s) RETURNING id",
            (f"Alert Rule Meter {self.tag}", category_id),
        )
        self.model_id = cur.fetchone()[0]

    def point(self, name: str) -> str:
        self.cur.execute("SELECT id FROM metadata.logical_points WHERE name = %s", (name,))
        return self.cur.fetchone()[0]

    def org_site(self, label: str, tz: str = "Asia/Kolkata") -> tuple[str, str, str]:
        code = f"AR_{label}_{self.tag}"
        self.cur.execute("INSERT INTO metadata.organizations (name, code) VALUES (%s, %s) RETURNING id", (code, code))
        org = self.cur.fetchone()[0]
        self.cur.execute(
            "INSERT INTO metadata.sites (organization_id, name, code, timezone) VALUES (%s, %s, %s, %s) RETURNING id",
            (org, f"Alert Site {label} {self.tag}", code, tz),
        )
        site = self.cur.fetchone()[0]
        self.cur.execute(
            "INSERT INTO metadata.gateways (organization_id, site_id, name, external_id) VALUES (%s, %s, %s, %s) RETURNING id",
            (org, site, f"AR GW {label}", f"AR-GW-{label}-{self.tag}"),
        )
        return org, site, self.cur.fetchone()[0]

    def site(self, org: str, label: str, tz: str = "Asia/Kolkata") -> tuple[str, str]:
        code = f"AR_{label}_{self.tag}"
        self.cur.execute(
            "INSERT INTO metadata.sites (organization_id, name, code, timezone) VALUES (%s, %s, %s, %s) RETURNING id",
            (org, f"Alert Site {label} {self.tag}", code, tz),
        )
        site = self.cur.fetchone()[0]
        self.cur.execute(
            "INSERT INTO metadata.gateways (organization_id, site_id, name, external_id) VALUES (%s, %s, %s, %s) RETURNING id",
            (org, site, f"AR GW {label}", f"AR-GW-{label}-{self.tag}"),
        )
        return site, self.cur.fetchone()[0]

    def asset(self, org, site, gateway, name: str, points=("ACTIVE_POWER_TOTAL", "FREQUENCY", "ENERGY_IMPORT_TOTAL"),
              lifecycle: str = "ACTIVE") -> tuple[str, str]:
        slug = re.sub(r"[^A-Z0-9]+", "_", name.upper()).strip("_")
        self.cur.execute(
            "INSERT INTO metadata.devices (organization_id, gateway_id, device_model_id, profile_id, name, external_id) "
            "VALUES (%s, %s, %s, %s, %s, %s) RETURNING id",
            (org, gateway, self.model_id, self.profile_id, f"{name} meter", f"AR_DEV_{slug}_{self.tag}"),
        )
        device = self.cur.fetchone()[0]
        self.cur.execute(
            "INSERT INTO metadata.assets (organization_id, site_id, name, external_id, metering_requirement, lifecycle_status) "
            "VALUES (%s, %s, %s, %s, 'NOT_REQUIRED', %s) RETURNING id",
            (org, site, name, f"AR_ASSET_{slug}_{self.tag}", lifecycle),
        )
        asset = self.cur.fetchone()[0]
        for p in points:
            self.cur.execute(
                "INSERT INTO metadata.asset_points (asset_id, device_id, logical_point_id, organization_id, effective_from) "
                "VALUES (%s, %s, %s, %s, %s)",
                (asset, device, self.point(p), org, datetime(2026, 1, 1, tzinfo=timezone.utc)),
            )
        return asset, device

    def user(self, org, scope: str, role: str, name: str | None = None) -> int:
        self.cur.execute(
            "INSERT INTO admin.portal_users (username, display_name, password_hash, role_code, organization_id, "
            "access_scope_mode, created_by) VALUES (%s, %s, '$argon2id$placeholder', %s, %s, %s, 'alert-rules-test') "
            "RETURNING portal_user_id",
            (f"ar-{role.lower()}-{scope.lower()}-{uuid.uuid4().hex[:8]}@test", name or f"{role} {scope}", role, org, scope),
        )
        return self.cur.fetchone()[0]

    def selected(self, user: int, site: str, granted_by: int) -> None:
        self.cur.execute(
            "INSERT INTO admin.portal_user_site_access (portal_user_id, site_id, created_by_portal_user_id) VALUES (%s, %s, %s)",
            (user, site, granted_by),
        )

    def live(self, org, site, gateway, device, point: str, value, at: datetime, quality: str = "GOOD") -> None:
        self.cur.execute(
            """
            INSERT INTO telemetry.device_live_point_state
                (device_id, logical_point_id, organization_id, site_id, gateway_id, event_time, received_at,
                 numeric_value, quality_code, raw_field_name, mapping_source)
            VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, 'test', 'TEST')
            ON CONFLICT (device_id, logical_point_id) DO UPDATE
               SET event_time = EXCLUDED.event_time, received_at = EXCLUDED.received_at,
                   numeric_value = EXCLUDED.numeric_value, quality_code = EXCLUDED.quality_code
            """,
            (device, self.point(point), org, site, gateway, at, at, value, quality),
        )


def create(cur, user, site, asset, *, name="High power", code="ACTIVE_POWER", qualifier="TOTAL", comparator="GT",
           threshold=50, tolerance=None, start=time(0, 0), end=time(23, 59), weekdays=EVERY_DAY, reminder=None,
           email=False, whatsapp=False, enabled=True):
    cur.execute(
        "SELECT result, rule_id, version FROM analytics.create_portal_alert_rule("
        "%s, %s, %s, %s, %s, %s, %s, %s::numeric, %s::numeric, %s, %s, %s::smallint, %s::smallint, %s, %s, %s)",
        (user, site, name, asset, code, qualifier, comparator, threshold, tolerance, start, end, weekdays, reminder,
         email, whatsapp, enabled),
    )
    return cur.fetchone()


def update(cur, user, rule, version, asset, **kw):
    a = dict(name="High power", code="ACTIVE_POWER", qualifier="TOTAL", comparator="GT", threshold=50, tolerance=None,
             start=time(0, 0), end=time(23, 59), weekdays=EVERY_DAY, reminder=None, email=False, whatsapp=False)
    a.update(kw)
    cur.execute(
        "SELECT result, rule_id, version FROM analytics.update_portal_alert_rule("
        "%s, %s, %s, %s, %s, %s, %s, %s, %s::numeric, %s::numeric, %s, %s, %s::smallint, %s::smallint, %s, %s)",
        (user, rule, version, a["name"], asset, a["code"], a["qualifier"], a["comparator"], a["threshold"],
         a["tolerance"], a["start"], a["end"], a["weekdays"], a["reminder"], a["email"], a["whatsapp"]),
    )
    return cur.fetchone()


def evaluate(cur, at: datetime) -> tuple:
    cur.execute("SELECT * FROM analytics.evaluate_alert_rules(%s)", (at,))
    row = cur.fetchone()
    assert row[5] is False, "evaluator skipped"
    return row


def alerts(cur, rule) -> list[tuple]:
    cur.execute(
        "SELECT state, triggered_at, resolved_at, ended_reason_code, data_unavailable, acknowledged_at, trigger_value "
        "FROM analytics.alerts WHERE rule_id = %s ORDER BY triggered_at",
        (rule,),
    )
    return cur.fetchall()


def audit(cur, entity) -> list[tuple]:
    cur.execute(
        "SELECT action, result, actor_type, actor_portal_user_id FROM admin.audit_events WHERE entity_id = %s "
        "ORDER BY occurred_at, event_id",
        (entity,),
    )
    return cur.fetchall()


@pytest.fixture
def tx():
    with psycopg.connect(CONNINFO) as connection:
        connection.execute(EVALUATOR_LOCK)
        connection.commit()
        yield connection
        connection.rollback()


@pytest.fixture
def world(tx):
    cur = tx.cursor()
    f = Fixture(cur)
    org, site, gw = f.org_site("A")
    site2, gw2 = f.site(org, "A2")
    org_b, site_b, gw_b = f.org_site("B")
    asset, device = f.asset(org, site, gw, "Chiller 1")
    asset2, _ = f.asset(org, site2, gw2, "Chiller 2")
    asset_b, _ = f.asset(org_b, site_b, gw_b, "Other Chiller")
    users = {
        "admin": f.user(org, "ORGANIZATION", "ADMIN", "Asha Admin"),
        "operator": f.user(org, "ORGANIZATION", "OPERATOR", "Omar Operator"),
        "viewer": f.user(org, "ORGANIZATION", "VIEWER"),
        "admin_b": f.user(org_b, "ORGANIZATION", "ADMIN"),
        "g_admin": f.user(None, "GLOBAL", "ADMIN", "Staff Person"),
        "g_operator": f.user(None, "GLOBAL", "OPERATOR", "Staff Operator"),
        "g_viewer": f.user(None, "GLOBAL", "VIEWER"),
    }
    users["sel_admin2"] = f.user(org, "SELECTED_SITES", "ADMIN")
    f.selected(users["sel_admin2"], site2, users["g_admin"])
    return dict(cur=cur, f=f, org=org, site=site, gw=gw, site2=site2, asset=asset, device=device, asset2=asset2,
                site_b=site_b, asset_b=asset_b, u=users)


# --- grants and function properties -------------------------------------------------

PUBLIC_FUNCS = [
    "analytics.create_portal_alert_rule(bigint, uuid, text, uuid, text, text, text, numeric, numeric, time, time, smallint, smallint, boolean, boolean, boolean)",
    "analytics.update_portal_alert_rule(bigint, uuid, integer, text, uuid, text, text, text, numeric, numeric, time, time, smallint, smallint, boolean, boolean)",
    "analytics.set_portal_alert_rule_enabled(bigint, uuid, boolean)",
    "analytics.delete_portal_alert_rule(bigint, uuid)",
    "analytics.acknowledge_portal_alert(bigint, uuid)",
    "analytics.get_portal_site_alerts(bigint, uuid, text[], timestamptz, timestamptz, integer, timestamptz)",
    "analytics.get_portal_alert_detail(bigint, uuid)",
    "analytics.list_portal_alert_rules(bigint, uuid)",
    "analytics.get_portal_alert_rule(bigint, uuid)",
    "analytics.list_portal_alert_rule_parameters(bigint, uuid, uuid)",
]
INTERNAL_FUNCS = [
    "analytics.alert_rule_parameter_binding(uuid, text, text, timestamptz)",
    "analytics.alert_rule_end_active(uuid, timestamptz)",
    "analytics.evaluate_alert_rules(timestamptz)",
]


@pytest.mark.parametrize("sig", PUBLIC_FUNCS)
def test_customer_functions_are_security_definer_and_granted_to_app_roles_only(sig):
    with psycopg.connect(CONNINFO) as c:
        row = c.execute(
            "SELECT p.prosecdef, r.rolname, p.proconfig IS NOT NULL, has_function_privilege('public', p.oid, 'EXECUTE'), "
            "has_function_privilege('ems_app', p.oid, 'EXECUTE'), has_function_privilege('ems_customer_api', p.oid, 'EXECUTE') "
            "FROM pg_proc p JOIN pg_roles r ON r.oid = p.proowner WHERE p.oid = %s::regprocedure",
            (sig,),
        ).fetchone()
    assert row == (True, "ems_admin", True, False, True, True)


@pytest.mark.parametrize("sig", INTERNAL_FUNCS)
def test_internal_functions_are_not_executable_by_application_roles(sig):
    with psycopg.connect(CONNINFO) as c:
        row = c.execute(
            "SELECT has_function_privilege('public', %s, 'EXECUTE'), has_function_privilege('ems_app', %s, 'EXECUTE'), "
            "has_function_privilege('ems_customer_api', %s, 'EXECUTE')",
            (sig, sig, sig),
        ).fetchone()
    assert row == (False, False, False)


def test_alert_configure_is_admin_only_and_operator_keeps_acknowledge():
    with psycopg.connect(CONNINFO) as c:
        rows = c.execute(
            "SELECT role_code, permission_code FROM config.portal_role_permissions "
            "WHERE permission_code IN ('alert.configure', 'alert.acknowledge') ORDER BY 1, 2"
        ).fetchall()
    assert ("ADMIN", "alert.configure") in rows and ("ADMIN", "alert.acknowledge") in rows
    assert ("OPERATOR", "alert.acknowledge") in rows
    assert ("OPERATOR", "alert.configure") not in rows
    assert not [r for r in rows if r[0] == "VIEWER"]


def test_legacy_alert_objects_are_gone():
    with psycopg.connect(CONNINFO) as c:
        assert c.execute(
            "SELECT to_regprocedure('analytics.evaluate_alerts()'), "
            "to_regprocedure('analytics.run_alert_evaluation_job(integer, jsonb)'), "
            "to_regprocedure('analytics.evaluate_energy_attention_materiality(uuid, timestamptz)')"
        ).fetchone() == (None, None, None)
        assert c.execute(
            "SELECT count(*) FROM timescaledb_information.jobs WHERE proc_schema = 'analytics' "
            "AND proc_name = 'run_alert_evaluation_job'"
        ).fetchone() == (0,)
        assert c.execute(
            "SELECT count(*) FROM timescaledb_information.jobs WHERE proc_schema = 'analytics' "
            "AND proc_name = 'run_alert_rule_evaluation_job' AND scheduled AND schedule_interval = INTERVAL '1 minute'"
        ).fetchone() == (1,)


# --- permission matrix ----------------------------------------------------------------

@pytest.mark.parametrize("who,expected", [
    ("admin", "ok"), ("g_admin", "ok"),
    ("operator", "forbidden"), ("viewer", "forbidden"), ("g_operator", "forbidden"), ("g_viewer", "forbidden"),
    ("admin_b", "not_found"),
])
def test_create_permission_matrix(world, who, expected):
    cur = world["cur"]
    result = create(cur, world["u"][who], world["site"], world["asset"])
    assert result[0] == expected
    if expected == "forbidden":
        cur.execute(
            "SELECT action, result, failure_reason FROM admin.audit_events WHERE actor_portal_user_id = %s "
            "AND action = 'ALERT_RULE_CREATED'",
            (world["u"][who],),
        )
        assert cur.fetchall() == [("ALERT_RULE_CREATED", "REJECTED", "Missing permission alert.configure.")]
    if expected == "not_found":
        cur.execute("SELECT count(*) FROM admin.audit_events WHERE actor_portal_user_id = %s", (world["u"][who],))
        assert cur.fetchone() == (0,)


def test_selected_sites_admin_reaches_only_its_selected_site(world):
    cur = world["cur"]
    assert create(cur, world["u"]["sel_admin2"], world["site"], world["asset"])[0] == "not_found"
    assert create(cur, world["u"]["sel_admin2"], world["site2"], world["asset2"])[0] == "ok"


def test_asset_of_another_site_is_refused(world):
    cur = world["cur"]
    assert create(cur, world["u"]["admin"], world["site"], world["asset2"])[0] == "asset_not_found"
    assert create(cur, world["u"]["admin"], world["site"], world["asset_b"])[0] == "asset_not_found"


@pytest.mark.parametrize("who", ["admin", "operator", "viewer", "g_admin", "g_operator", "g_viewer"])
def test_everyone_with_site_access_can_read_rules_and_alerts(world, who):
    cur = world["cur"]
    create(cur, world["u"]["admin"], world["site"], world["asset"])
    cur.execute("SELECT count(*) FROM analytics.list_portal_alert_rules(%s, %s)", (world["u"][who], world["site"]))
    assert cur.fetchone() == (1,)


def test_other_tenant_reads_nothing(world):
    cur = world["cur"]
    _, rule, _ = create(cur, world["u"]["admin"], world["site"], world["asset"])
    other = world["u"]["admin_b"]
    for sql, args in (
        ("SELECT count(*) FROM analytics.list_portal_alert_rules(%s, %s)", (other, world["site"])),
        ("SELECT count(*) FROM analytics.get_portal_alert_rule(%s, %s)", (other, rule)),
        ("SELECT count(*) FROM analytics.get_portal_site_alerts(%s, %s)", (other, world["site"])),
        ("SELECT count(*) FROM analytics.list_portal_alert_rule_parameters(%s, %s)", (other, world["site"])),
    ):
        cur.execute(sql, args)
        assert cur.fetchone() == (0,), sql
    assert update(cur, other, rule, 1, world["asset"])[0] == "not_found"
    cur.execute("SELECT result FROM analytics.delete_portal_alert_rule(%s, %s)", (other, rule))
    assert cur.fetchone() == ("not_found",)


# --- validation ------------------------------------------------------------------------

@pytest.mark.parametrize("kw,code", [
    (dict(name="  "), "invalid_name"),
    (dict(name="x" * 121), "invalid_name"),
    (dict(comparator="NE"), "invalid_comparator"),
    (dict(comparator="EQ", code="FREQUENCY", qualifier=None, threshold=50), "tolerance_required"),
    (dict(comparator="EQ", code="FREQUENCY", qualifier=None, threshold=50, tolerance=-1), "invalid_tolerance"),
    (dict(comparator="GT", tolerance=1), "tolerance_not_allowed"),
    (dict(code="ENERGY_IMPORT"), "counter_not_allowed"),
    (dict(code="VOLTAGE_LINE_NEUTRAL", qualifier="AVG"), "parameter_not_available"),
    (dict(start=time(8), end=time(8)), "invalid_schedule"),
    (dict(weekdays=0), "invalid_weekdays"),
    (dict(weekdays=128), "invalid_weekdays"),
    (dict(reminder=60), "invalid_reminder"),
])
def test_validation(world, kw, code):
    assert create(world["cur"], world["u"]["admin"], world["site"], world["asset"], **kw)[0] == code


def test_equal_to_with_explicit_tolerance_and_reminder_choices_are_accepted(world):
    cur = world["cur"]
    ok = create(cur, world["u"]["admin"], world["site"], world["asset"], name="Grid frequency", code="FREQUENCY",
                qualifier=None, comparator="EQ", threshold=50, tolerance=0.1, reminder=15, email=True, whatsapp=True)
    assert ok[0] == "ok"
    for minutes, name in ((30, "r30"), (None, "none")):
        assert create(cur, world["u"]["admin"], world["site"], world["asset"], name=name, reminder=minutes)[0] == "ok"


def test_names_are_unique_per_site_case_insensitive_and_reusable_after_delete(world):
    cur = world["cur"]
    _, rule, _ = create(cur, world["u"]["admin"], world["site"], world["asset"], name="Pump watch")
    assert create(cur, world["u"]["admin"], world["site"], world["asset"], name="pump WATCH")[0] == "name_taken"
    assert create(cur, world["u"]["admin"], world["site2"], world["asset2"], name="Pump watch")[0] == "ok"
    cur.execute("SELECT result FROM analytics.delete_portal_alert_rule(%s, %s)", (world["u"]["admin"], rule))
    assert cur.fetchone() == ("ok",)
    assert create(cur, world["u"]["admin"], world["site"], world["asset"], name="Pump watch")[0] == "ok"


def test_twenty_five_active_rules_per_site(world):
    cur = world["cur"]
    for i in range(25):
        assert create(cur, world["u"]["admin"], world["site"], world["asset"], name=f"Rule {i}")[0] == "ok"
    assert create(cur, world["u"]["admin"], world["site"], world["asset"], name="Rule 26")[0] == "rule_limit_reached"
    # A disabled rule does not count, but cannot be enabled past the limit.
    _, disabled, _ = create(cur, world["u"]["admin"], world["site"], world["asset"], name="Off", enabled=False)
    cur.execute("SELECT result FROM analytics.set_portal_alert_rule_enabled(%s, %s, TRUE)", (world["u"]["admin"], disabled))
    assert cur.fetchone() == ("rule_limit_reached",)


def test_parameters_list_excludes_cumulative_counters_and_other_tenants(world):
    cur = world["cur"]
    cur.execute(
        "SELECT asset_name, parameter_code, qualifier, unit_symbol FROM analytics.list_portal_alert_rule_parameters(%s, %s, %s) "
        "ORDER BY parameter_code",
        (world["u"]["viewer"], world["site"], world["asset"]),
    )
    assert cur.fetchall() == [("Chiller 1", "ACTIVE_POWER", "TOTAL", "kW"), ("Chiller 1", "FREQUENCY", None, "Hz")]


# --- audit -----------------------------------------------------------------------------

def test_every_write_is_audited_with_actor_and_actor_type(world):
    cur = world["cur"]
    _, rule, _ = create(cur, world["u"]["admin"], world["site"], world["asset"])
    assert update(cur, world["u"]["g_admin"], rule, 1, world["asset"], threshold=60)[:1] == ("ok",)
    cur.execute("SELECT result FROM analytics.set_portal_alert_rule_enabled(%s, %s, FALSE)", (world["u"]["admin"], rule))
    cur.execute("SELECT result FROM analytics.set_portal_alert_rule_enabled(%s, %s, TRUE)", (world["u"]["admin"], rule))
    cur.execute("SELECT result FROM analytics.delete_portal_alert_rule(%s, %s)", (world["u"]["g_admin"], rule))
    assert audit(cur, rule) == [
        ("ALERT_RULE_CREATED", "SUCCEEDED", "CUSTOMER", world["u"]["admin"]),
        ("ALERT_RULE_UPDATED", "SUCCEEDED", "WISEWATTS_STAFF", world["u"]["g_admin"]),
        ("ALERT_RULE_DISABLED", "SUCCEEDED", "CUSTOMER", world["u"]["admin"]),
        ("ALERT_RULE_ENABLED", "SUCCEEDED", "CUSTOMER", world["u"]["admin"]),
        ("ALERT_RULE_DELETED", "SUCCEEDED", "WISEWATTS_STAFF", world["u"]["g_admin"]),
    ]


def test_actor_type_cannot_be_supplied_by_a_caller(world):
    cur = world["cur"]
    cur.execute(
        "INSERT INTO admin.audit_events (transaction_id, actor_portal_user_id, actor_role, action, entity_type, result, actor_type) "
        "VALUES (gen_random_uuid(), %s, 'ADMIN', 'X', 'Y', 'SUCCEEDED', 'CUSTOMER') RETURNING actor_type",
        (world["u"]["g_admin"],),
    )
    assert cur.fetchone() == ("WISEWATTS_STAFF",)


def test_unchanged_update_and_repeated_toggle_write_nothing(world):
    cur = world["cur"]
    _, rule, _ = create(cur, world["u"]["admin"], world["site"], world["asset"])
    assert update(cur, world["u"]["admin"], rule, 1, world["asset"]) == ("ok", rule, 1)
    cur.execute("SELECT result, version FROM analytics.set_portal_alert_rule_enabled(%s, %s, TRUE)", (world["u"]["admin"], rule))
    assert cur.fetchone() == ("ok", 1)
    assert [a[0] for a in audit(cur, rule)] == ["ALERT_RULE_CREATED"]


def test_stale_version_is_a_conflict(world):
    cur = world["cur"]
    _, rule, _ = create(cur, world["u"]["admin"], world["site"], world["asset"])
    assert update(cur, world["u"]["admin"], rule, 1, world["asset"], threshold=70)[0] == "ok"
    assert update(cur, world["u"]["admin"], rule, 1, world["asset"], threshold=80)[0] == "version_conflict"


# --- evaluator lifecycle ---------------------------------------------------------------

def _rule_and_feed(world, **kw):
    cur, f = world["cur"], world["f"]
    _, rule, _ = create(cur, world["u"]["admin"], world["site"], world["asset"], **kw)

    def feed(value, at, quality="GOOD"):
        f.live(world["org"], world["site"], world["gw"], world["device"], "ACTIVE_POWER_TOTAL", value, at - timedelta(seconds=5),
               quality)

    return cur, rule, feed


def test_qualifies_after_five_continuous_minutes_and_resolves_after_one_minute_clear(world):
    cur, rule, feed = _rule_and_feed(world)
    t0 = datetime(2026, 11, 18, 6, 0, tzinfo=timezone.utc)
    for m in range(5):
        feed(60 + m, t0 + timedelta(minutes=m))
        evaluate(cur, t0 + timedelta(minutes=m))
        assert alerts(cur, rule) == [], m
    feed(65, t0 + timedelta(minutes=5))
    evaluate(cur, t0 + timedelta(minutes=5))
    [(state, triggered, *_rest, trigger_value)] = alerts(cur, rule)
    assert state == "ACTIVE" and triggered == t0 and trigger_value == 60
    # First clear observation, then one continuous minute clear -> RESOLVED at the first clear.
    feed(40, t0 + timedelta(minutes=6))
    evaluate(cur, t0 + timedelta(minutes=6))
    assert alerts(cur, rule)[0][0] == "ACTIVE"
    feed(41, t0 + timedelta(minutes=7))
    evaluate(cur, t0 + timedelta(minutes=7))
    state, _, resolved_at, *_ = alerts(cur, rule)[0]
    assert state == "RESOLVED" and resolved_at == t0 + timedelta(minutes=6)


def test_a_false_observation_resets_qualification(world):
    cur, rule, feed = _rule_and_feed(world)
    t0 = datetime(2026, 11, 18, 6, 0, tzinfo=timezone.utc)
    for m, v in enumerate([60, 60, 60, 40, 60, 60, 60, 60, 60]):
        feed(v, t0 + timedelta(minutes=m))
        evaluate(cur, t0 + timedelta(minutes=m))
    assert alerts(cur, rule) == []  # restarted at minute 4, needs minute 9
    feed(60, t0 + timedelta(minutes=9))
    evaluate(cur, t0 + timedelta(minutes=9))
    assert alerts(cur, rule)[0][1] == t0 + timedelta(minutes=4)


def test_telemetry_gap_keeps_the_alert_active_and_acknowledged_and_resolves_only_when_clear(world):
    cur, rule, feed = _rule_and_feed(world)
    t0 = datetime(2026, 11, 18, 6, 0, tzinfo=timezone.utc)
    for m in range(6):
        feed(70, t0 + timedelta(minutes=m))
        evaluate(cur, t0 + timedelta(minutes=m))
    cur.execute("SELECT alert_id FROM analytics.alerts WHERE rule_id = %s", (rule,))
    alert_id = cur.fetchone()[0]
    cur.execute("SELECT result FROM analytics.acknowledge_portal_alert(%s, %s)", (world["u"]["operator"], alert_id))
    assert cur.fetchone() == ("ok",)
    # The last sample stops at minute 5; by minute 11 it is older than 5 minutes -> unavailable.
    for m in range(6, 15):
        evaluate(cur, t0 + timedelta(minutes=m))
    state, _, _, ended, unavailable, acked, _ = alerts(cur, rule)[0]
    assert (state, ended, unavailable) == ("ACTIVE", None, True) and acked is not None
    # Valid data returns, still breaching -> same occurrence continues.
    feed(75, t0 + timedelta(minutes=15))
    evaluate(cur, t0 + timedelta(minutes=15))
    rows = alerts(cur, rule)
    assert len(rows) == 1 and rows[0][0] == "ACTIVE" and rows[0][4] is False and rows[0][5] is not None
    # Clear on valid data for one minute -> RESOLVED, acknowledgement retained.
    feed(10, t0 + timedelta(minutes=16))
    evaluate(cur, t0 + timedelta(minutes=16))
    feed(10, t0 + timedelta(minutes=17))
    evaluate(cur, t0 + timedelta(minutes=17))
    state, _, resolved, ended, _, acked, _ = alerts(cur, rule)[0]
    assert state == "RESOLVED" and ended is None and acked is not None


def test_gap_during_resolution_resets_it(world):
    cur, rule, feed = _rule_and_feed(world)
    t0 = datetime(2026, 11, 18, 6, 0, tzinfo=timezone.utc)
    for m in range(6):
        feed(70, t0 + timedelta(minutes=m))
        evaluate(cur, t0 + timedelta(minutes=m))
    feed(10, t0 + timedelta(minutes=6))
    evaluate(cur, t0 + timedelta(minutes=6))
    feed(10, t0 + timedelta(minutes=6), quality="GAP")  # no valid sample any more
    evaluate(cur, t0 + timedelta(minutes=12))
    assert alerts(cur, rule)[0][0] == "ACTIVE"


def test_schedule_close_keeps_active_and_outside_schedule_does_not_qualify(world):
    # 06:00-06:10 UTC == 11:30-11:40 Asia/Kolkata, every day.
    cur, rule, feed = _rule_and_feed(world, start=time(11, 30), end=time(11, 40))
    t0 = datetime(2026, 11, 18, 6, 0, tzinfo=timezone.utc)
    for m in range(6):
        feed(70, t0 + timedelta(minutes=m))
        evaluate(cur, t0 + timedelta(minutes=m))
    assert alerts(cur, rule)[0][0] == "ACTIVE"
    # Window closes at 11:40 local; still breaching -> stays ACTIVE.
    for m in range(6, 20):
        feed(70, t0 + timedelta(minutes=m))
        evaluate(cur, t0 + timedelta(minutes=m))
    assert alerts(cur, rule)[0][0] == "ACTIVE"
    # Clear outside the window still resolves.
    feed(10, t0 + timedelta(minutes=20))
    evaluate(cur, t0 + timedelta(minutes=20))
    feed(10, t0 + timedelta(minutes=21))
    evaluate(cur, t0 + timedelta(minutes=21))
    assert alerts(cur, rule)[0][0] == "RESOLVED"
    # Breaching again outside the window never qualifies.
    for m in range(22, 30):
        feed(70, t0 + timedelta(minutes=m))
        evaluate(cur, t0 + timedelta(minutes=m))
    assert len(alerts(cur, rule)) == 1


def test_schedule_window_crossing_midnight_uses_the_starting_weekday():
    with psycopg.connect(CONNINFO) as c:
        monday_only = 1  # ISO Monday bit
        def ins(ts: str) -> bool:
            return c.execute(
                "SELECT analytics.alert_rule_in_schedule(%s::timestamp, '22:00', '06:00', %s::smallint)", (ts, monday_only)
            ).fetchone()[0]
        assert ins("2026-11-16 23:00") is True    # Monday night
        assert ins("2026-11-17 02:00") is True    # Tuesday early, Monday's window
        assert ins("2026-11-17 23:00") is False   # Tuesday night
        assert ins("2026-11-16 02:00") is False   # Monday early belongs to Sunday's window
        assert ins("2026-11-17 06:00") is False   # end is exclusive


def test_equal_to_uses_the_tolerance(world):
    cur, f = world["cur"], world["f"]
    _, rule, _ = create(cur, world["u"]["admin"], world["site"], world["asset"], name="Freq", code="FREQUENCY",
                        qualifier=None, comparator="EQ", threshold=50, tolerance=0.1)
    t0 = datetime(2026, 11, 18, 6, 0, tzinfo=timezone.utc)
    for m in range(6):
        f.live(world["org"], world["site"], world["gw"], world["device"], "FREQUENCY", 50.08, t0 + timedelta(minutes=m))
        evaluate(cur, t0 + timedelta(minutes=m))
    assert alerts(cur, rule)[0][0] == "ACTIVE"
    f.live(world["org"], world["site"], world["gw"], world["device"], "FREQUENCY", 50.2, t0 + timedelta(minutes=6))
    evaluate(cur, t0 + timedelta(minutes=6))
    f.live(world["org"], world["site"], world["gw"], world["device"], "FREQUENCY", 50.2, t0 + timedelta(minutes=7))
    evaluate(cur, t0 + timedelta(minutes=7))
    assert alerts(cur, rule)[0][0] == "RESOLVED"


@pytest.mark.parametrize("change", ["edit", "disable", "delete"])
def test_configuration_change_ends_the_active_alert_and_keeps_history(world, change):
    cur, rule, feed = _rule_and_feed(world)
    t0 = datetime(2026, 11, 18, 6, 0, tzinfo=timezone.utc)
    for m in range(6):
        feed(70, t0 + timedelta(minutes=m))
        evaluate(cur, t0 + timedelta(minutes=m))
    admin = world["u"]["admin"]
    if change == "edit":
        assert update(cur, admin, rule, 1, world["asset"], threshold=55)[0] == "ok"
    elif change == "disable":
        cur.execute("SELECT result FROM analytics.set_portal_alert_rule_enabled(%s, %s, FALSE)", (admin, rule))
    else:
        cur.execute("SELECT result FROM analytics.delete_portal_alert_rule(%s, %s)", (admin, rule))
    [(state, _, resolved, reason, unavailable, _, _)] = alerts(cur, rule)
    assert (state, resolved, reason, unavailable) == ("ENDED", None, "CONFIGURATION_CHANGED", False)
    cur.execute("SELECT count(*) FROM analytics.alert_evaluation_candidates WHERE rule_id = %s", (rule,))
    assert cur.fetchone() == (0,)
    # History stays readable, also after a soft delete.
    cur.execute(
        "SELECT state, rule_name, rule_deleted FROM analytics.get_portal_site_alerts(%s, %s, ARRAY['RESOLVED','ENDED'])",
        (world["u"]["viewer"], world["site"]),
    )
    assert cur.fetchall() == [("ENDED", "High power", change == "delete")]
    expected_action = {"edit": "ALERT_RULE_UPDATED", "disable": "ALERT_RULE_DISABLED", "delete": "ALERT_RULE_DELETED"}[change]
    cur.execute(
        "SELECT action, new_values -> 'ended_alert_ids' FROM admin.audit_events WHERE entity_id = %s "
        "ORDER BY occurred_at DESC, event_id DESC LIMIT 1",
        (rule,),
    )
    action, ended_ids = cur.fetchone()
    cur.execute("SELECT alert_id::text FROM analytics.alerts WHERE rule_id = %s", (rule,))
    assert action == expected_action and ended_ids == [cur.fetchone()[0]]
    if change == "edit":
        # After an edit, qualification restarts under the new identity.
        for m in range(6, 12):
            feed(70, t0 + timedelta(minutes=m))
            evaluate(cur, t0 + timedelta(minutes=m))
        assert [a[0] for a in alerts(cur, rule)] == ["ENDED", "ACTIVE"]


def test_acknowledgement_rules_and_staff_display(world):
    cur, rule, feed = _rule_and_feed(world)
    t0 = datetime(2026, 11, 18, 6, 0, tzinfo=timezone.utc)
    for m in range(6):
        feed(70, t0 + timedelta(minutes=m))
        evaluate(cur, t0 + timedelta(minutes=m))
    cur.execute("SELECT alert_id FROM analytics.alerts WHERE rule_id = %s", (rule,))
    alert_id = cur.fetchone()[0]
    for who in ("viewer", "g_viewer"):
        cur.execute("SELECT result FROM analytics.acknowledge_portal_alert(%s, %s)", (world["u"][who], alert_id))
        assert cur.fetchone() == ("forbidden",)
    cur.execute("SELECT result FROM analytics.acknowledge_portal_alert(%s, %s)", (world["u"]["admin_b"], alert_id))
    assert cur.fetchone() == ("not_found",)
    cur.execute("SELECT result FROM analytics.acknowledge_portal_alert(%s, %s)", (world["u"]["g_operator"], alert_id))
    assert cur.fetchone() == ("ok",)
    cur.execute("SELECT result FROM analytics.acknowledge_portal_alert(%s, %s)", (world["u"]["operator"], alert_id))
    assert cur.fetchone() == ("already_acknowledged",)
    cur.execute(
        "SELECT state, acknowledged_by_name, acknowledged_by_type FROM analytics.get_portal_alert_detail(%s, %s)",
        (world["u"]["viewer"], alert_id),
    )
    assert cur.fetchone() == ("ACTIVE", "WiseWatts Support", "WISEWATTS_STAFF")
    assert audit(cur, alert_id)[-1] == ("ALERT_ACKNOWLEDGED", "SUCCEEDED", "WISEWATTS_STAFF", world["u"]["g_operator"])
    # Acknowledgement is not resolution: the evaluator keeps it ACTIVE while breaching.
    feed(70, t0 + timedelta(minutes=6))
    evaluate(cur, t0 + timedelta(minutes=6))
    assert alerts(cur, rule)[0][0] == "ACTIVE"


def test_customer_acknowledger_is_shown_by_name_and_resolved_alerts_cannot_be_acknowledged(world):
    cur, rule, feed = _rule_and_feed(world)
    t0 = datetime(2026, 11, 18, 6, 0, tzinfo=timezone.utc)
    for m in range(6):
        feed(70, t0 + timedelta(minutes=m))
        evaluate(cur, t0 + timedelta(minutes=m))
    cur.execute("SELECT alert_id FROM analytics.alerts WHERE rule_id = %s", (rule,))
    alert_id = cur.fetchone()[0]
    cur.execute("SELECT result FROM analytics.acknowledge_portal_alert(%s, %s)", (world["u"]["operator"], alert_id))
    cur.execute("SELECT acknowledged_by_name FROM analytics.get_portal_alert_detail(%s, %s)", (world["u"]["viewer"], alert_id))
    assert cur.fetchone() == ("Omar Operator",)
    for m in (6, 7):
        feed(10, t0 + timedelta(minutes=m))
        evaluate(cur, t0 + timedelta(minutes=m))
    _, rule2, _ = create(cur, world["u"]["admin"], world["site"], world["asset"], name="Other")
    cur.execute("SELECT result FROM analytics.acknowledge_portal_alert(%s, %s)", (world["u"]["admin"], alert_id))
    assert cur.fetchone() == ("alert_not_active",)


def test_history_retention_is_ninety_days(world):
    cur, rule, feed = _rule_and_feed(world)
    t0 = datetime(2026, 8, 1, 6, 0, tzinfo=timezone.utc)
    for m in range(6):
        feed(70, t0 + timedelta(minutes=m))
        evaluate(cur, t0 + timedelta(minutes=m))
    for m in (6, 7):
        feed(10, t0 + timedelta(minutes=m))
        evaluate(cur, t0 + timedelta(minutes=m))
    assert alerts(cur, rule)[0][0] == "RESOLVED"
    evaluate(cur, t0 + timedelta(days=89))
    assert len(alerts(cur, rule)) == 1
    evaluate(cur, t0 + timedelta(days=91))
    assert alerts(cur, rule) == []


def test_history_and_active_reads_are_ordered_and_filtered(world):
    cur, rule, feed = _rule_and_feed(world)
    t0 = datetime(2026, 11, 18, 6, 0, tzinfo=timezone.utc)
    for m in range(6):
        feed(70, t0 + timedelta(minutes=m))
        evaluate(cur, t0 + timedelta(minutes=m))
    for m in (6, 7):
        feed(10, t0 + timedelta(minutes=m))
        evaluate(cur, t0 + timedelta(minutes=m))
    for m in range(8, 14):
        feed(70, t0 + timedelta(minutes=m))
        evaluate(cur, t0 + timedelta(minutes=m))
    cur.execute("SELECT state FROM analytics.get_portal_site_alerts(%s, %s, ARRAY['ACTIVE'])", (world["u"]["viewer"], world["site"]))
    assert cur.fetchall() == [("ACTIVE",)]
    cur.execute(
        "SELECT state, previous_occurrence_count FROM analytics.get_portal_site_alerts(%s, %s, ARRAY['RESOLVED','ENDED'])",
        (world["u"]["viewer"], world["site"]),
    )
    assert cur.fetchall() == [("RESOLVED", 0)]
    cur.execute("SELECT state, previous_occurrence_count FROM analytics.get_portal_site_alerts(%s, %s)", (world["u"]["viewer"], world["site"]))
    assert cur.fetchall() == [("ACTIVE", 1), ("RESOLVED", 0)]
