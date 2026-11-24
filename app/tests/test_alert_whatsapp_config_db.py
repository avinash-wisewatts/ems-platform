"""WhatsApp Phase 1 -- migration 331 configuration functions against the
disposable ems_test database (phase-1-plan §7.1).

Configuration only: nothing here sends anything, and every phone number is
fictional (the +1 555-01xx range reserved for fiction). Each test runs in one
rolled-back transaction on the ADR-024 fixtures of test_alert_rules_db; the
concurrency test alone needs committed data and uses its own disabled rule.

Covers: save/read round trip, replace-all and revision semantics, no-op saves,
validation (E.164, duplicates, 10 accepted / 11 refused, enabled without
recipients), per-number consent (new and changed numbers need a fresh
confirmation; unchanged keep theirs), the empty wording register refusing
new opt-ins (R6, D21), recipient identity (review B2), concurrent first saves
(review R1), automation-account refusal incl. cross-site (R5), the permission
matrix and tenant isolation (D16), audit without phone digits (R12,
P1-AC-6), soft delete (A-5), grants, and the migration's safeguard,
idempotent re-apply and rollback (P1-AC-11, P1-AC-13).
"""

from __future__ import annotations

import re
import threading
import uuid
from pathlib import Path

import psycopg
import pytest
from psycopg.types.json import Jsonb

from tests.test_alert_rules_db import CONNINFO, Fixture, create, tx, world  # noqa: F401  (fixtures)

ROOT = Path(__file__).resolve().parents[2]
MIGRATION = ROOT / "postgres" / "migrations" / "331_alert_whatsapp_configuration.sql"
ROLLBACK = ROOT / "postgres" / "maintenance" / "331_alert_whatsapp_configuration_rollback.sql"
MIGRATION_323 = ROOT / "postgres" / "migrations" / "323_alert_rule_write_functions.sql"

# Fictional numbers only (North American 555-0100..0199 is reserved for fiction).
P = [f"+1202555{n:04d}" for n in range(100, 112)]

GET = "analytics.get_portal_alert_rule_whatsapp(bigint, uuid)"
SAVE = "analytics.save_portal_alert_rule_whatsapp(bigint, uuid, boolean, jsonb, integer, text)"
SUMMARIES = "analytics.get_portal_alert_rule_whatsapp_summaries(bigint, uuid)"
INTERNAL = [
    "analytics.alert_whatsapp_actor_is_automation(bigint)",
    "analytics.alert_whatsapp_current_statement_version()",
    "analytics.alert_whatsapp_audit_recipients(uuid)",
]
TABLES = [
    "analytics.alert_whatsapp_consent_statements",
    "analytics.alert_rule_whatsapp_settings",
    "analytics.alert_rule_whatsapp_recipients",
]


# --- helpers --------------------------------------------------------------------------

def statement(cur, version: str = "TEST-1") -> str:
    """Load a TEST wording version (inside the rolled-back transaction only)."""
    cur.execute(
        "INSERT INTO analytics.alert_whatsapp_consent_statements (version, statement_text, approved_by_name, approved_at) "
        "VALUES (%s, 'Test-only wording, never shown to anyone.', 'Test Product Owner', clock_timestamp() - interval '1 minute')",
        (version,),
    )
    return version


def new(phone: str, confirmed: bool = True) -> dict:
    return {"recipient_id": None, "phone": phone, "opt_in_confirmed": confirmed}


def keep(recipient_id, phone: str) -> dict:
    return {"recipient_id": str(recipient_id), "phone": phone, "opt_in_confirmed": False}


def save(cur, user, rule, enabled, recipients, revision, version: str | None = "current") -> tuple:
    """version: the wording version the administrator was shown; "current"
    passes whatever is current now (the normal UI flow)."""
    if version == "current":
        cur.execute("SELECT analytics.alert_whatsapp_current_statement_version()")
        version = cur.fetchone()[0]
    cur.execute(
        "SELECT result, revision FROM analytics.save_portal_alert_rule_whatsapp(%s, %s, %s, %s, %s, %s)",
        (user, rule, enabled, Jsonb(recipients), revision, version),
    )
    return cur.fetchone()


def get(cur, user, rule) -> tuple:
    cur.execute("SELECT result, enabled, revision, recipients FROM analytics.get_portal_alert_rule_whatsapp(%s, %s)", (user, rule))
    return cur.fetchone()


def shown_wording(cur, user, rule):
    cur.execute("SELECT consent_statement FROM analytics.get_portal_alert_rule_whatsapp(%s, %s)", (user, rule))
    return cur.fetchone()[0]


def summaries(cur, user, site) -> list[tuple]:
    cur.execute(
        "SELECT result, rule_id, enabled, recipient_count FROM analytics.get_portal_alert_rule_whatsapp_summaries(%s, %s)",
        (user, site),
    )
    return cur.fetchall()


def wa_audit(cur, rule) -> list[tuple]:
    cur.execute(
        "SELECT action, result, actor_type, actor_portal_user_id, previous_values, new_values FROM admin.audit_events "
        "WHERE entity_id = %s AND entity_type = 'ALERT_RULE_WHATSAPP' ORDER BY occurred_at, event_id",
        (rule,),
    )
    return cur.fetchall()


def automation(cur, user, site, org) -> None:
    cur.execute(
        "INSERT INTO analytics.site_report_profiles (site_id, organization_id, automation_portal_user_id) VALUES (%s, %s, %s) "
        "ON CONFLICT (site_id) DO UPDATE SET automation_portal_user_id = EXCLUDED.automation_portal_user_id",
        (site, org, user),
    )


@pytest.fixture
def wa(world):
    cur = world["cur"]
    _, rule, _ = create(cur, world["u"]["admin"], world["site"], world["asset"])
    _, rule2, _ = create(cur, world["u"]["admin"], world["site"], world["asset"], name="Second rule")
    _, rule_s2, _ = create(cur, world["u"]["sel_admin2"], world["site2"], world["asset2"], name="Site two rule")
    _, rule_b, _ = create(cur, world["u"]["admin_b"], world["site_b"], world["asset_b"], name="Other tenant rule")
    return dict(world, rule=rule, rule2=rule2, rule_s2=rule_s2, rule_b=rule_b)


def ids(cur, rule) -> dict[str, uuid.UUID]:
    _, _, _, recipients = get_as_owner(cur, rule)
    return {r["phone_e164"]: uuid.UUID(r["recipient_id"]) for r in recipients}


def get_as_owner(cur, rule):
    cur.execute(
        "SELECT 'ok', s.enabled, s.revision, COALESCE((SELECT jsonb_agg(jsonb_build_object('recipient_id', r.recipient_id, "
        "'phone_e164', r.phone_e164, 'consent_statement_version', r.consent_statement_version, "
        "'consent_confirmed_by', r.consent_confirmed_by)) FROM analytics.alert_rule_whatsapp_recipients r "
        "WHERE r.rule_id = s.rule_id), '[]') FROM analytics.alert_rule_whatsapp_settings s WHERE s.rule_id = %s",
        (rule,),
    )
    return cur.fetchone() or ("ok", False, 0, [])


def state(cur, rule) -> tuple:
    """The complete stored WhatsApp configuration of a rule (for 'unchanged' checks)."""
    cur.execute(
        "SELECT to_jsonb(s) - 'updated_at' FROM analytics.alert_rule_whatsapp_settings s WHERE s.rule_id = %s", (rule,)
    )
    settings = cur.fetchone()
    cur.execute(
        "SELECT to_jsonb(r) FROM analytics.alert_rule_whatsapp_recipients r WHERE r.rule_id = %s ORDER BY r.recipient_id",
        (rule,),
    )
    return settings, cur.fetchall()


# --- grants and properties ----------------------------------------------------------

@pytest.mark.parametrize("sig", [GET, SAVE, SUMMARIES])
def test_customer_functions_are_security_definer_and_granted_to_app_roles_only(sig):
    with psycopg.connect(CONNINFO) as c:
        row = c.execute(
            "SELECT p.prosecdef, r.rolname, p.proconfig IS NOT NULL, has_function_privilege('public', p.oid, 'EXECUTE'), "
            "has_function_privilege('ems_app', p.oid, 'EXECUTE'), has_function_privilege('ems_customer_api', p.oid, 'EXECUTE') "
            "FROM pg_proc p JOIN pg_roles r ON r.oid = p.proowner WHERE p.oid = %s::regprocedure",
            (sig,),
        ).fetchone()
    assert row == (True, "ems_admin", True, False, True, True)


@pytest.mark.parametrize("sig", INTERNAL)
def test_internal_helpers_are_not_executable_by_application_roles(sig):
    with psycopg.connect(CONNINFO) as c:
        row = c.execute(
            "SELECT has_function_privilege('public', %s, 'EXECUTE'), has_function_privilege('ems_app', %s, 'EXECUTE'), "
            "has_function_privilege('ems_customer_api', %s, 'EXECUTE')",
            (sig, sig, sig),
        ).fetchone()
    assert row == (False, False, False)


@pytest.mark.parametrize("table", TABLES)
@pytest.mark.parametrize("role", ["ems_app", "ems_customer_api", "grafana_reader", "public"])
def test_no_role_reads_the_tables_directly(table, role):
    with psycopg.connect(CONNINFO) as c:
        if not c.execute("SELECT %s = 'public' OR EXISTS (SELECT 1 FROM pg_roles WHERE rolname = %s)", (role, role)).fetchone()[0]:
            pytest.skip(f"{role} does not exist here")
        row = c.execute(
            "SELECT has_table_privilege(%s, %s, 'SELECT'), has_table_privilege(%s, %s, 'INSERT'), "
            "has_table_privilege(%s, %s, 'UPDATE'), has_table_privilege(%s, %s, 'DELETE')",
            (role, table) * 4,
        ).fetchone()
    assert row == (False, False, False, False)


def test_the_wording_register_ships_empty():
    with psycopg.connect(CONNINFO) as c:
        assert c.execute("SELECT count(*) FROM analytics.alert_whatsapp_consent_statements").fetchone() == (0,)
        assert c.execute("SELECT analytics.alert_whatsapp_current_statement_version()").fetchone() == (None,)


def test_legacy_flag_is_retired_by_check():
    with psycopg.connect(CONNINFO) as c:
        assert c.execute(
            "SELECT pg_get_constraintdef(oid) FROM pg_constraint WHERE conname = 'alert_rules_whatsapp_retired_chk'"
        ).fetchone() == ("CHECK ((NOT whatsapp_requested))",)
        assert c.execute("SELECT count(*) FROM analytics.alert_rules WHERE whatsapp_requested").fetchone() == (0,)


# --- save and read --------------------------------------------------------------------

def test_unconfigured_rule_reads_off_at_revision_zero(wa):
    assert get(wa["cur"], wa["u"]["admin"], wa["rule"]) == ("ok", False, 0, [])


def test_round_trip_and_replace_all(wa):
    cur, admin, rule = wa["cur"], wa["u"]["admin"], wa["rule"]
    statement(cur)
    assert save(cur, admin, rule, True, [new(P[0]), new(P[1])], 0) == ("ok", 1)
    result, enabled, revision, recipients = get(cur, admin, rule)
    assert (result, enabled, revision) == ("ok", True, 1)
    assert [r["phone_e164"] for r in recipients] == [P[0], P[1]]
    assert {r["consent_state"] for r in recipients} == {"CONFIRMED"}
    assert {r["consent_statement_version"] for r in recipients} == {"TEST-1"}
    assert {r["consent_confirmed_by_name"] for r in recipients} == {"Asha Admin"}
    # Replace-all: keep P[0], drop P[1], add P[2].
    by_phone = {r["phone_e164"]: r["recipient_id"] for r in recipients}
    assert save(cur, admin, rule, True, [keep(by_phone[P[0]], P[0]), new(P[2])], 1) == ("ok", 2)
    _, _, revision, recipients = get(cur, admin, rule)
    assert revision == 2 and sorted(r["phone_e164"] for r in recipients) == [P[0], P[2]]
    kept = next(r for r in recipients if r["phone_e164"] == P[0])
    assert kept["recipient_id"] == by_phone[P[0]]  # same recipient, same consent


def test_each_rule_is_independent(wa):
    cur, admin = wa["cur"], wa["u"]["admin"]
    statement(cur)
    assert save(cur, admin, wa["rule"], True, [new(P[0])], 0)[0] == "ok"
    assert get(cur, admin, wa["rule2"]) == ("ok", False, 0, [])
    assert save(cur, admin, wa["rule2"], True, [new(P[0])], 0) == ("ok", 1)  # same number, other rule: fine
    assert state(cur, wa["rule"])[1] != state(cur, wa["rule2"])[1]


def test_disable_keeps_numbers(wa):
    """R7 / A-9: switching WhatsApp off keeps the configured numbers."""
    cur, admin, rule = wa["cur"], wa["u"]["admin"], wa["rule"]
    statement(cur)
    save(cur, admin, rule, True, [new(P[0])], 0)
    recipient = ids(cur, rule)[P[0]]
    assert save(cur, admin, rule, False, [keep(recipient, P[0])], 1) == ("ok", 2)
    assert get(cur, admin, rule)[1:3] == (False, 2) and len(get(cur, admin, rule)[3]) == 1


def test_no_op_saves_write_nothing(wa):
    cur, admin, rule = wa["cur"], wa["u"]["admin"], wa["rule"]
    assert save(cur, admin, rule, False, [], 0) == ("ok", 0)  # never configured, still off
    assert state(cur, rule) == (None, [])
    statement(cur)
    save(cur, admin, rule, True, [new(P[0])], 0)
    before = state(cur, rule)
    recipient = ids(cur, rule)[P[0]]
    assert save(cur, admin, rule, True, [keep(recipient, P[0])], 1) == ("ok", 1)
    assert state(cur, rule) == before
    assert len(wa_audit(cur, rule)) == 1


# --- validation -----------------------------------------------------------------------

@pytest.mark.parametrize("recipients,enabled,code", [
    ([new("0202555 0100")], True, "whatsapp_invalid_phone"),
    ([new("+0202555010")], True, "whatsapp_invalid_phone"),
    ([new("+1202")], True, "whatsapp_invalid_phone"),
    ([new(P[0]), new(P[0])], True, "whatsapp_duplicate_phone"),
    ([new(p) for p in P[:11]], True, "whatsapp_too_many_recipients"),
    ([], True, "whatsapp_recipients_required"),
    ([new(P[0], confirmed=False)], True, "whatsapp_consent_required"),
    ([{"phone": 12025550100}], True, "whatsapp_invalid_request"),
    (["+12025550100"], True, "whatsapp_invalid_request"),
])
def test_refused_saves_change_nothing_and_write_no_audit(wa, recipients, enabled, code):
    cur, admin, rule = wa["cur"], wa["u"]["admin"], wa["rule"]
    statement(cur)
    save(cur, admin, rule, True, [new(P[11])], 0)
    before = state(cur, rule)
    assert save(cur, admin, rule, enabled, recipients, 1) == (code, 1)
    assert state(cur, rule) == before
    assert len(wa_audit(cur, rule)) == 1  # only the first, effective save


def test_ten_recipients_are_accepted(wa):
    cur, admin, rule = wa["cur"], wa["u"]["admin"], wa["rule"]
    statement(cur)
    assert save(cur, admin, rule, True, [new(p) for p in P[:10]], 0) == ("ok", 1)
    assert len(get(cur, admin, rule)[3]) == 10


def test_non_array_payload_is_refused(wa):
    cur, admin, rule = wa["cur"], wa["u"]["admin"], wa["rule"]
    cur.execute(
        "SELECT result FROM analytics.save_portal_alert_rule_whatsapp(%s, %s, TRUE, %s, 0, NULL)",
        (admin, rule, Jsonb({"phone": P[0]})),
    )
    assert cur.fetchone() == ("whatsapp_invalid_request",)


# --- consent --------------------------------------------------------------------------

def test_new_opt_ins_are_refused_while_no_wording_is_approved(wa):
    """R6 / D21 / R9: the register ships empty, so nobody can be added yet."""
    cur, admin, rule = wa["cur"], wa["u"]["admin"], wa["rule"]
    assert save(cur, admin, rule, True, [new(P[0])], 0) == ("whatsapp_consent_statement_missing", 0)
    assert state(cur, rule) == (None, [])
    assert wa_audit(cur, rule) == []


def test_the_read_returns_the_approved_wording_to_show_or_none(wa):
    cur, admin, rule = wa["cur"], wa["u"]["admin"], wa["rule"]
    assert shown_wording(cur, admin, rule) is None
    statement(cur, "TEST-1")
    assert shown_wording(cur, admin, rule) == {"version": "TEST-1", "text": "Test-only wording, never shown to anyone."}


@pytest.mark.parametrize("shown", [None, "TEST-0", "test-1"])
def test_new_consent_is_refused_unless_the_shown_wording_is_the_current_one(wa, shown):
    """The recorded version is always the text the administrator confirmed."""
    cur, admin, rule = wa["cur"], wa["u"]["admin"], wa["rule"]
    statement(cur, "TEST-1")
    assert save(cur, admin, rule, True, [new(P[0])], 0, version=shown) == ("whatsapp_consent_statement_changed", 0)
    assert state(cur, rule) == (None, []) and wa_audit(cur, rule) == []


def test_unchanged_recipients_need_no_wording_version(wa):
    cur, admin, rule = wa["cur"], wa["u"]["admin"], wa["rule"]
    statement(cur)
    save(cur, admin, rule, True, [new(P[0])], 0)
    recipient = ids(cur, rule)[P[0]]
    assert save(cur, admin, rule, False, [keep(recipient, P[0])], 1, version=None) == ("ok", 2)


def test_a_retired_version_cannot_be_used_and_existing_consents_keep_theirs(wa):
    cur, admin, rule = wa["cur"], wa["u"]["admin"], wa["rule"]
    statement(cur, "TEST-1")
    save(cur, admin, rule, True, [new(P[0])], 0)
    cur.execute("UPDATE analytics.alert_whatsapp_consent_statements SET retired_at = clock_timestamp() WHERE version = 'TEST-1'")
    recipient = ids(cur, rule)[P[0]]
    assert save(cur, admin, rule, True, [keep(recipient, P[0]), new(P[1])], 1) == ("whatsapp_consent_statement_missing", 1)
    statement(cur, "TEST-2")
    assert save(cur, admin, rule, True, [keep(recipient, P[0]), new(P[1])], 1) == ("ok", 2)
    versions = {r["phone_e164"]: r["consent_statement_version"] for r in get(cur, admin, rule)[3]}
    assert versions == {P[0]: "TEST-1", P[1]: "TEST-2"}


def test_only_one_current_wording_version_can_exist(wa):
    cur = wa["cur"]
    statement(cur, "TEST-1")
    with pytest.raises(psycopg.errors.UniqueViolation):
        statement(cur, "TEST-2")


def test_a_changed_number_needs_fresh_consent_and_is_a_new_recipient(wa):
    """A-2: editing a number is removing it and adding a new one."""
    cur, admin, rule = wa["cur"], wa["u"]["admin"], wa["rule"]
    statement(cur)
    save(cur, admin, rule, True, [new(P[0])], 0)
    old = ids(cur, rule)[P[0]]
    edited = {"recipient_id": str(old), "phone": P[1], "opt_in_confirmed": False}
    assert save(cur, admin, rule, True, [edited], 1) == ("whatsapp_consent_required", 1)
    edited["opt_in_confirmed"] = True
    assert save(cur, admin, rule, True, [edited], 1) == ("ok", 2)
    now = ids(cur, rule)
    assert list(now) == [P[1]] and now[P[1]] != old
    new_values = wa_audit(cur, rule)[-1][5]
    assert new_values["removed_recipient_ids"] == [str(old)]
    assert new_values["added_recipient_ids"] == [str(now[P[1]])]


def test_unchanged_recipients_keep_their_consent_even_unconfirmed(wa):
    cur, admin, rule = wa["cur"], wa["u"]["admin"], wa["rule"]
    statement(cur)
    save(cur, admin, rule, True, [new(P[0])], 0)
    recipient = ids(cur, rule)[P[0]]
    cur.execute("SELECT consent_confirmed_at FROM analytics.alert_rule_whatsapp_recipients WHERE recipient_id = %s", (recipient,))
    confirmed_at = cur.fetchone()[0]
    assert save(cur, admin, rule, True, [keep(recipient, P[0]), new(P[1])], 1) == ("ok", 2)
    cur.execute("SELECT consent_confirmed_at FROM analytics.alert_rule_whatsapp_recipients WHERE recipient_id = %s", (recipient,))
    assert cur.fetchone() == (confirmed_at,)


# --- recipient identity (review B2) --------------------------------------------------

@pytest.mark.parametrize("source", ["rule2", "rule_s2", "rule_b"])
def test_another_rules_recipient_id_is_refused_and_no_consent_is_copied(wa, source):
    cur = wa["cur"]
    statement(cur)
    owner = {"rule2": "admin", "rule_s2": "sel_admin2", "rule_b": "admin_b"}[source]
    assert save(cur, wa["u"][owner], wa[source], True, [new(P[0])], 0)[0] == "ok"
    foreign = ids(cur, wa[source])[P[0]]
    assert save(cur, wa["u"]["g_admin"], wa["rule"], True, [keep(foreign, P[0])], 0) == ("whatsapp_unknown_recipient", 0)
    assert state(cur, wa["rule"]) == (None, [])


@pytest.mark.parametrize("bad", [str(uuid.uuid4()), "not-a-uuid"])
def test_unknown_or_malformed_recipient_id_is_refused(wa, bad):
    cur = wa["cur"]
    statement(cur)
    item = {"recipient_id": bad, "phone": P[0], "opt_in_confirmed": True}
    assert save(cur, wa["u"]["admin"], wa["rule"], True, [item], 0) == ("whatsapp_unknown_recipient", 0)


def test_the_same_recipient_id_twice_is_refused(wa):
    cur, admin, rule = wa["cur"], wa["u"]["admin"], wa["rule"]
    statement(cur)
    save(cur, admin, rule, True, [new(P[0])], 0)
    recipient = ids(cur, rule)[P[0]]
    twice = [keep(recipient, P[0]), {"recipient_id": str(recipient), "phone": P[1], "opt_in_confirmed": True}]
    assert save(cur, admin, rule, True, twice, 1) == ("whatsapp_unknown_recipient", 1)


# --- revisions and concurrency (review R1) ------------------------------------------

def test_stale_revision_is_refused(wa):
    cur, admin, rule = wa["cur"], wa["u"]["admin"], wa["rule"]
    statement(cur)
    assert save(cur, admin, rule, True, [new(P[0])], 1) == ("whatsapp_config_stale", 0)
    assert save(cur, admin, rule, True, [new(P[0])], 0) == ("ok", 1)
    assert save(cur, admin, rule, False, [], 0) == ("whatsapp_config_stale", 1)


@pytest.fixture
def committed_rule():
    """A committed, DISABLED rule (the background evaluator ignores it) for the
    two-connection test. Soft-deleted afterwards; the tenant rows stay in the
    disposable database, as for test_customer_api_role_db."""
    with psycopg.connect(CONNINFO) as c:
        cur = c.cursor()
        f = Fixture(cur)
        org, site, gw = f.org_site("WAC")
        asset, _ = f.asset(org, site, gw, "Concurrency Chiller")
        admin = f.user(org, "ORGANIZATION", "ADMIN")
        _, rule, _ = create(cur, admin, site, asset, enabled=False)
        cur.execute(
            "INSERT INTO analytics.alert_whatsapp_consent_statements (version, statement_text, approved_by_name, approved_at) "
            "VALUES ('TEST-CONCURRENCY', 'Test-only wording.', 'Test', clock_timestamp() - interval '1 minute')"
        )
        c.commit()
    yield admin, rule
    with psycopg.connect(CONNINFO) as c:
        c.execute("SELECT analytics.delete_portal_alert_rule(%s, %s)", (admin, rule))
        c.execute("DELETE FROM analytics.alert_whatsapp_consent_statements WHERE version = 'TEST-CONCURRENCY'")
        c.commit()


def test_two_concurrent_first_saves_one_wins_one_is_stale(committed_rule):
    admin, rule = committed_rule
    first = psycopg.connect(CONNINFO)
    second = psycopg.connect(CONNINFO)
    try:
        # The first save holds its lock (not yet committed) ...
        assert save(first.cursor(), admin, rule, True, [new(P[0])], 0) == ("ok", 1)
        results: list = []
        t = threading.Thread(target=lambda: results.append(save(second.cursor(), admin, rule, True, [new(P[1])], 0)))
        t.start()
        t.join(1.0)
        assert t.is_alive(), "the second save must wait for the first"
        first.commit()
        t.join(10)
        second.commit()
        # ... and the second sees revision 1: a clean 409, never a 500.
        assert results == [("whatsapp_config_stale", 1)]
        with psycopg.connect(CONNINFO) as c:
            assert c.execute(
                "SELECT revision, (SELECT array_agg(phone_e164) FROM analytics.alert_rule_whatsapp_recipients WHERE rule_id = %s) "
                "FROM analytics.alert_rule_whatsapp_settings WHERE rule_id = %s",
                (rule, rule),
            ).fetchone() == (1, [P[0]])
    finally:
        first.close()
        second.close()


# --- permissions and tenant isolation (D16, P1-AC-4) ---------------------------------

@pytest.mark.parametrize("who,expected", [
    ("admin", "ok"), ("g_admin", "ok"),
    ("operator", "forbidden"), ("viewer", "forbidden"),
    ("g_operator", "forbidden"), ("g_viewer", "forbidden"),
    ("admin_b", "not_found"), ("sel_admin2", "not_found"),
])
def test_permission_matrix_for_read_save_and_summaries(wa, who, expected):
    cur, user = wa["cur"], wa["u"][who]
    statement(cur)
    assert get(cur, user, wa["rule"])[0] == expected
    assert save(cur, user, wa["rule"], False, [], 0)[0] == expected
    rows = summaries(cur, user, wa["site"])
    if expected == "ok":
        assert {r[0] for r in rows} == {"ok"} and {r[1] for r in rows} == {wa["rule"], wa["rule2"]}
    else:
        assert rows == [(expected, None, None, None)]
    # Refusals reveal nothing and write nothing (P1-AC-6).
    assert wa_audit(cur, wa["rule"]) == []


def test_refused_roles_receive_no_recipient_information(wa):
    cur = wa["cur"]
    statement(cur)
    save(cur, wa["u"]["admin"], wa["rule"], True, [new(P[0])], 0)
    for who in ("operator", "viewer", "g_operator", "g_viewer"):
        assert get(cur, wa["u"][who], wa["rule"]) == ("forbidden", None, None, None)
        assert summaries(cur, wa["u"][who], wa["site"]) == [("forbidden", None, None, None)]


def test_selected_sites_admin_reaches_only_its_site(wa):
    cur, user = wa["cur"], wa["u"]["sel_admin2"]
    assert get(cur, user, wa["rule_s2"])[0] == "ok"
    assert get(cur, user, wa["rule"])[0] == "not_found"


def test_summaries_carry_no_numbers(wa):
    cur, admin = wa["cur"], wa["u"]["admin"]
    statement(cur)
    save(cur, admin, wa["rule"], True, [new(P[0]), new(P[1])], 0)
    rows = summaries(cur, admin, wa["site"])
    assert (("ok", wa["rule"], True, 2) in rows) and (("ok", wa["rule2"], False, 0) in rows)
    assert not any("555" in str(v) for row in rows for v in row)


def test_inactive_admin_is_refused(wa):
    cur = wa["cur"]
    cur.execute("UPDATE admin.portal_users SET is_active = FALSE WHERE portal_user_id = %s", (wa["u"]["admin"],))
    assert get(cur, wa["u"]["admin"], wa["rule"])[0] in {"forbidden", "not_found"}
    assert save(cur, wa["u"]["admin"], wa["rule"], False, [], 0)[0] in {"forbidden", "not_found"}


def test_a_soft_deleted_rule_is_not_found(wa):
    cur, admin = wa["cur"], wa["u"]["admin"]
    cur.execute("SELECT result FROM analytics.delete_portal_alert_rule(%s, %s)", (admin, wa["rule2"]))
    assert get(cur, admin, wa["rule2"])[0] == "not_found"
    assert save(cur, admin, wa["rule2"], False, [], 0)[0] == "not_found"
    assert wa["rule2"] not in {r[1] for r in summaries(cur, admin, wa["site"])}


# --- R5: report automation accounts ---------------------------------------------------

def test_automation_account_is_refused_everywhere_even_with_admin_and_site_access(wa):
    cur, f = wa["cur"], wa["f"]
    bot = f.user(wa["org"], "ORGANIZATION", "ADMIN", "Report Automation")
    statement(cur)
    assert get(cur, bot, wa["rule"])[0] == "ok"  # an ordinary ADMIN until designated
    automation(cur, bot, wa["site"], wa["org"])
    assert get(cur, bot, wa["rule"]) == ("forbidden", None, None, None)
    assert save(cur, bot, wa["rule"], True, [new(P[0])], 0) == ("forbidden", None)
    assert summaries(cur, bot, wa["site"]) == [("forbidden", None, None, None)]
    assert wa_audit(cur, wa["rule"]) == []
    # Removing the designation restores access.
    cur.execute("UPDATE analytics.site_report_profiles SET automation_portal_user_id = NULL WHERE site_id = %s", (wa["site"],))
    assert get(cur, bot, wa["rule"])[0] == "ok"


def test_automation_account_of_another_site_is_refused_here_too(wa):
    """Designated for site A2, ADMIN on site A as well: refused on site A."""
    cur, f = wa["cur"], wa["f"]
    bot = f.user(wa["org"], "ORGANIZATION", "ADMIN", "Report Automation")
    automation(cur, bot, wa["site2"], wa["org"])
    assert get(cur, bot, wa["rule"]) == ("forbidden", None, None, None)
    assert summaries(cur, bot, wa["site"]) == [("forbidden", None, None, None)]
    # An ordinary ADMIN of the same site is unaffected.
    assert get(cur, wa["u"]["admin"], wa["rule"])[0] == "ok"


def test_automation_refusal_comes_before_the_existence_check(wa):
    """R5: an automation account cannot even probe whether a rule exists."""
    cur, f = wa["cur"], wa["f"]
    bot = f.user(wa["org"], "ORGANIZATION", "ADMIN")
    automation(cur, bot, wa["site"], wa["org"])
    assert get(cur, bot, uuid.uuid4())[0] == "forbidden"
    assert get(cur, bot, wa["rule_b"])[0] == "forbidden"


# --- audit (P1-AC-6, R12) -------------------------------------------------------------

def _digits(value) -> str:
    return re.sub(r"\D", "", str(value))


# Recipient/rule ids and timestamps are not phone data, but their digits can
# contain any 4-digit run (a save at 17:01:00 contains "0100"), so they are
# removed before a value is searched for phone digits.
_ID_OR_TIMESTAMP = re.compile(
    r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}"
    r"|\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}(?::?\d{2})?)?",
    re.IGNORECASE,
)


def _leaves(value):
    if isinstance(value, dict):
        for key, item in value.items():
            yield key
            yield from _leaves(item)
    elif isinstance(value, (list, tuple)):
        for item in value:
            yield from _leaves(item)
    else:
        yield value


def assert_no_phone_data(blob, phones) -> None:
    """R12: no audit value holds a number -- full, E.164, digits only, or its
    last four digits -- once ids and timestamps are set aside. Each value is
    checked on its own, so digits are never joined across fields."""

    text = str(blob)
    assert "phone" not in text and "•" not in text
    for phone in phones:
        assert phone not in text
    for leaf in _leaves(blob):
        if leaf is None or isinstance(leaf, bool):
            continue
        if isinstance(leaf, int):
            assert len(str(abs(leaf))) < 8, "an integer shaped like a phone number"
            continue
        digits = _digits(_ID_OR_TIMESTAMP.sub(" ", str(leaf)))
        for phone in phones:
            assert phone[-4:] not in digits and _digits(phone) not in digits


def test_the_phone_data_check_catches_leaks_and_ignores_ids_and_timestamps() -> None:
    phone = "+12025550100"
    clean = {"saved_at": "2026-11-24T17:01:00.598925+05:30", "recipient_id": "0100aaaa-0100-4100-8100-000000000100",
             "revision": 101, "consent_confirmed_by": 10100}
    assert_no_phone_data(clean, [phone])  # the CI false positive of 2026-11-24
    for leak in ({"n": phone}, {"n": "202 555 0100"}, {"n": "ends 0100"}, {"n": 12025550100},
                 {"n": ["x", {"y": "2025550100"}]}, {"phone_masked": "x"}, {"n": "+1 ••••••0100"}):
        with pytest.raises(AssertionError):
            assert_no_phone_data(leak, [phone])


def test_one_audit_row_per_effective_save_with_actor_type_and_no_phone_digits(wa):
    cur, rule = wa["cur"], wa["rule"]
    statement(cur)
    assert save(cur, wa["u"]["admin"], rule, True, [new(P[0]), new(P[1])], 0)[0] == "ok"
    recipients = ids(cur, rule)
    assert save(cur, wa["u"]["g_admin"], rule, False, [keep(recipients[P[0]], P[0])], 1)[0] == "ok"
    rows = wa_audit(cur, rule)
    assert [(r[0], r[1], r[2], r[3]) for r in rows] == [
        ("ALERT_RULE_WHATSAPP_UPDATED", "SUCCEEDED", "CUSTOMER", wa["u"]["admin"]),
        ("ALERT_RULE_WHATSAPP_UPDATED", "SUCCEEDED", "WISEWATTS_STAFF", wa["u"]["g_admin"]),
    ]
    first_new = rows[0][5]
    assert first_new["enabled"] is True and first_new["revision"] == 1
    assert sorted(first_new["added_recipient_ids"]) == sorted(str(v) for v in recipients.values())
    assert first_new["consent_confirmed_recipient_ids"] == first_new["added_recipient_ids"]
    assert {r["consent_statement_version"] for r in first_new["recipients"]} == {"TEST-1"}
    assert {r["consent_confirmed_by"] for r in first_new["recipients"]} == {wa["u"]["admin"]}
    assert rows[1][5]["removed_recipient_ids"] == [str(recipients[P[1]])]
    for row in rows:
        for blob in (row[4], row[5]):
            assert_no_phone_data(blob, P[:2])


def test_audit_and_change_are_atomic(wa):
    """A failure after the audit row rolls back both (one transaction)."""
    cur, admin, rule = wa["cur"], wa["u"]["admin"], wa["rule"]
    statement(cur)
    cur.execute("SAVEPOINT before_save")
    assert save(cur, admin, rule, True, [new(P[0])], 0)[0] == "ok"
    cur.execute("ROLLBACK TO SAVEPOINT before_save")
    assert state(cur, rule) == (None, []) and wa_audit(cur, rule) == []


# --- soft delete (A-5, P1-AC-12) ------------------------------------------------------

def test_soft_delete_removes_the_configuration_and_audits_ids_only(wa):
    cur, admin, rule = wa["cur"], wa["u"]["admin"], wa["rule"]
    statement(cur)
    save(cur, admin, rule, True, [new(P[0]), new(P[1])], 0)
    recipient_ids = sorted(str(v) for v in ids(cur, rule).values())
    cur.execute("SELECT result FROM analytics.delete_portal_alert_rule(%s, %s)", (admin, rule))
    assert cur.fetchone() == ("ok",)
    assert state(cur, rule) == (None, [])
    cur.execute(
        "SELECT new_values FROM admin.audit_events WHERE entity_id = %s AND action = 'ALERT_RULE_DELETED'", (rule,)
    )
    [(new_values,)] = cur.fetchall()
    assert new_values["whatsapp_removed_recipient_ids"] == recipient_ids
    assert P[0] not in str(new_values) and P[1] not in str(new_values)


def test_soft_delete_of_an_unconfigured_rule_is_unchanged(wa):
    cur, admin, rule = wa["cur"], wa["u"]["admin"], wa["rule2"]
    cur.execute("SELECT result FROM analytics.delete_portal_alert_rule(%s, %s)", (admin, rule))
    assert cur.fetchone() == ("ok",)
    cur.execute("SELECT new_values -> 'whatsapp_removed_recipient_ids' FROM admin.audit_events "
                "WHERE entity_id = %s AND action = 'ALERT_RULE_DELETED'", (rule,))
    assert cur.fetchone() == ([],)


def test_settings_scope_must_match_the_rule(wa):
    cur = wa["cur"]
    with pytest.raises(psycopg.errors.CheckViolation):
        cur.execute(
            "INSERT INTO analytics.alert_rule_whatsapp_settings (rule_id, organization_id, site_id, created_by, updated_by) "
            "VALUES (%s, %s, %s, %s, %s)",
            (wa["rule"], wa["org"], wa["site2"], wa["u"]["admin"], wa["u"]["admin"]),
        )


# --- migration 331: safeguard, re-apply, rollback (P1-AC-11, P1-AC-13) ---------------

def _sql_without_transaction_control(path: Path) -> str:
    text = path.read_text(encoding="utf-8")
    return re.sub(r"^(BEGIN|COMMIT);\s*$", "", text, flags=re.MULTILINE)


def test_migration_reapplies_idempotently(tx):
    cur = tx.cursor()
    cur.execute(MIGRATION.read_text(encoding="utf-8"))
    cur.execute(MIGRATION.read_text(encoding="utf-8"))
    cur.execute("SELECT count(*) FROM pg_constraint WHERE conname = 'alert_rules_whatsapp_retired_chk'")
    assert cur.fetchone() == (1,)


def test_migration_refuses_to_run_while_a_rule_has_the_legacy_flag(world):
    cur = world["cur"]
    _, rule, _ = create(cur, world["u"]["admin"], world["site"], world["asset"])
    cur.execute("ALTER TABLE analytics.alert_rules DROP CONSTRAINT alert_rules_whatsapp_retired_chk")
    cur.execute("UPDATE analytics.alert_rules SET whatsapp_requested = TRUE WHERE rule_id = %s", (rule,))
    with pytest.raises(psycopg.errors.RaiseException, match="whatsapp_requested = true"):
        cur.execute(MIGRATION.read_text(encoding="utf-8"))


def _function_body(cur, signature: str) -> str:
    cur.execute("SELECT prosrc FROM pg_proc WHERE oid = %s::regprocedure", (signature,))
    return cur.fetchone()[0]


def _323_body(name: str) -> str:
    text = MIGRATION_323.read_text(encoding="utf-8")
    start = text.index(f"CREATE OR REPLACE FUNCTION analytics.{name}(")
    body_start = text.index("AS $function$", start) + len("AS $function$")
    return text[body_start:text.index("$function$;", body_start)]


SIG_CREATE = ("analytics.create_portal_alert_rule(bigint, uuid, text, uuid, text, text, text, numeric, numeric, time, time, "
              "smallint, smallint, boolean, boolean, boolean)")
SIG_UPDATE = ("analytics.update_portal_alert_rule(bigint, uuid, integer, text, uuid, text, text, text, numeric, numeric, time, "
              "time, smallint, smallint, boolean, boolean)")
SIG_DELETE = "analytics.delete_portal_alert_rule(bigint, uuid)"


def test_rollback_deletes_all_numbers_and_restores_the_323_functions(world):
    cur = world["cur"]
    _, rule, _ = create(cur, world["u"]["admin"], world["site"], world["asset"])
    statement(cur)
    assert save(cur, world["u"]["admin"], rule, True, [new(P[0])], 0)[0] == "ok"
    notices: list[str] = []
    cur.connection.add_notice_handler(lambda d: notices.append(d.message_primary))
    cur.execute(_sql_without_transaction_control(ROLLBACK))
    assert any("1 WhatsApp settings row(s), 1 recipient number(s)" in n for n in notices), notices
    for table in TABLES:
        cur.execute("SELECT to_regclass(%s)", (table,))
        assert cur.fetchone() == (None,)
    for sig in (GET, SAVE, SUMMARIES, *INTERNAL):
        cur.execute("SELECT to_regprocedure(%s)", (sig,))
        assert cur.fetchone() == (None,)
    cur.execute("SELECT count(*) FROM pg_constraint WHERE conname = 'alert_rules_whatsapp_retired_chk'")
    assert cur.fetchone() == (0,)
    for sig, name in ((SIG_CREATE, "create_portal_alert_rule"), (SIG_UPDATE, "update_portal_alert_rule"),
                      (SIG_DELETE, "delete_portal_alert_rule")):
        assert _function_body(cur, sig) == _323_body(name), name
        cur.execute(
            "SELECT p.prosecdef, has_function_privilege('ems_app', p.oid, 'EXECUTE'), "
            "has_function_privilege('ems_customer_api', p.oid, 'EXECUTE') FROM pg_proc p WHERE p.oid = %s::regprocedure",
            (sig,),
        )
        assert cur.fetchone() == (True, True, True)
    cur.execute("SELECT count(*) FROM admin.schema_migrations WHERE migration_id = '331_alert_whatsapp_configuration'")
    assert cur.fetchone() == (0,)
    # Prior behaviour is back: the flag is stored and compared again (323).
    _, rule2, _ = create(cur, world["u"]["admin"], world["site"], world["asset"], name="After rollback", whatsapp=True)
    cur.execute("SELECT whatsapp_requested FROM analytics.alert_rules WHERE rule_id = %s", (rule2,))
    assert cur.fetchone() == (True,)
    # ... and re-applying 331 after a rollback is refused by the safeguard.
    with pytest.raises(psycopg.errors.RaiseException, match="whatsapp_requested = true"):
        cur.execute(MIGRATION.read_text(encoding="utf-8"))
