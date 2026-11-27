"""Migration 332: the Product-approved WhatsApp opt-in wording WA-OPTIN-1
(D21) naming the customer business (R9), against the disposable test database.

Covers: the wording is loaded, current and exactly the approved text, and
marked Legal review PENDING, which keeps new opt-ins closed; every
wording version names the business; the read renders it with the
organisation's legal name; new opt-ins stay blocked without an approved
wording, without a legal name, or when the version or business name the
administrator was shown is not the current one; each new or changed number
needs its own confirmation; the version and business name are recorded with
every consent and kept when they later change; the audit carries them but no
phone data; the six-argument caller still resolves; the migration
precondition, idempotent re-apply and the rollback (331 bodies restored
verbatim).

Fictional data only: +1 202-555-01xx numbers and invented company names.
Nothing is sent: there is no provider, queue or sender (messages_active is
always false in the API).
"""

from __future__ import annotations

import psycopg
import pytest
from psycopg.types.json import Jsonb

from tests.test_alert_rules_db import CONNINFO, Fixture, create, tx, world  # noqa: F401  (fixtures)
from tests.test_alert_whatsapp_config_db import (  # noqa: F401  (wa is a fixture)
    MIGRATION as MIGRATION_331,
    P,
    ROLLBACK_332,
    ROLLBACK_333,
    ROOT,
    _function_body,
    _sql_without_transaction_control,
    assert_no_phone_data,
    legal_approve,
    business_name,
    get,
    ids,
    keep,
    new,
    retire_current_wording,
    save,
    shown_wording,
    state,
    statement,
    wa,
    wa_audit,
)

MIGRATION = ROOT / "postgres" / "migrations" / "332_alert_whatsapp_consent_wording.sql"

APPROVED_TEXT = (
    "I confirm that this person has explicitly agreed to receive operational alert notifications from "
    "{business_name} on WhatsApp at this number. These messages are delivered by WiseWatts as "
    "{business_name}'s technology platform. No marketing messages will be sent."
)
NAME_A = "Fictional A Hotels Pvt Ltd"  # set on world["org"] by the wa fixture
SAVE_7 = "analytics.save_portal_alert_rule_whatsapp(bigint, uuid, boolean, jsonb, integer, text, text)"
SAVE_6 = "analytics.save_portal_alert_rule_whatsapp(bigint, uuid, boolean, jsonb, integer, text)"


def set_legal_name(cur, org, name) -> None:
    cur.execute("UPDATE metadata.organizations SET legal_name = %s WHERE id = %s", (name, org))


def recorded(cur, rule) -> dict[str, tuple]:
    cur.execute(
        "SELECT phone_e164, consent_statement_version, consent_business_name FROM analytics.alert_rule_whatsapp_recipients "
        "WHERE rule_id = %s",
        (rule,),
    )
    return {phone: (version, name) for phone, version, name in cur.fetchall()}


# --- the loaded wording -------------------------------------------------------------------

def test_wa_optin_1_is_loaded_current_and_exactly_the_approved_text_pending_legal():
    with psycopg.connect(CONNINFO) as c:
        row = c.execute(
            "SELECT version, statement_text, approved_by_name, approved_at = TIMESTAMPTZ '2026-11-24 00:00:00+05:30', "
            "retired_at, legal_review_status, legal_reviewed_by_name, legal_reviewed_at "
            "FROM analytics.alert_whatsapp_consent_statements WHERE version = 'WA-OPTIN-1'"
        ).fetchone()
        current = c.execute("SELECT analytics.alert_whatsapp_current_statement_version()").fetchone()[0]
    assert row == ("WA-OPTIN-1", APPROVED_TEXT, "WiseWatts Product Owner", True, None, "PENDING", None, None)
    assert current == "WA-OPTIN-1"


# --- Legal review gate: opt-ins stay closed until Legal approves (L-1) --------------------------

def _pending(cur) -> None:
    cur.execute(
        "UPDATE analytics.alert_whatsapp_consent_statements SET legal_review_status = 'PENDING', "
        "legal_reviewed_by_name = NULL, legal_reviewed_at = NULL WHERE version = 'WA-OPTIN-1'"
    )


def test_pending_legal_review_closes_the_wording_in_the_read(wa):
    cur, admin, rule = wa["cur"], wa["u"]["admin"], wa["rule"]
    _pending(cur)
    assert shown_wording(cur, admin, rule) == {
        "version": "WA-OPTIN-1", "text": None, "business_name": None, "unavailable_reason": "legal_review_pending",
    }


def test_pending_legal_review_refuses_every_new_opt_in(wa):
    cur, admin, rule = wa["cur"], wa["u"]["admin"], wa["rule"]
    _pending(cur)
    # Even with exactly the version and business name a client could send.
    assert save(cur, admin, rule, True, [new(P[0])], 0, version="WA-OPTIN-1", business=NAME_A) == (
        "whatsapp_consent_legal_review_pending", 0)
    assert state(cur, rule) == (None, []) and wa_audit(cur, rule) == []


def test_pending_legal_review_still_allows_switching_off_and_removing(wa):
    """Only adding is closed: an administrator can always remove a number."""
    cur, admin, rule = wa["cur"], wa["u"]["admin"], wa["rule"]
    save(cur, admin, rule, True, [new(P[0]), new(P[1])], 0)
    keep_id = ids(cur, rule)[P[0]]
    _pending(cur)
    assert save(cur, admin, rule, False, [keep(keep_id, P[0])], 1, version=None, business=None) == ("ok", 2)
    assert recorded(cur, rule) == {P[0]: ("WA-OPTIN-1", NAME_A)}


def test_the_committed_wording_is_pending_so_opt_ins_are_closed(world):
    """The real state after migration 332 (no test approval): nobody can be added."""
    cur = world["cur"]
    _, rule, _ = create(cur, world["u"]["admin"], world["site"], world["asset"])
    set_legal_name(cur, world["org"], NAME_A)
    assert save(cur, world["u"]["admin"], rule, True, [new(P[0])], 0, version="WA-OPTIN-1", business=NAME_A) == (
        "whatsapp_consent_legal_review_pending", 0)


@pytest.mark.parametrize("status,by,at", [
    ("APPROVED", None, "now"), ("APPROVED", "  ", "now"), ("APPROVED", "Legal", None),
    ("PENDING", "Legal", None), ("PENDING", None, "now"), ("REJECTED", None, None),
])
def test_a_legal_approval_needs_a_reviewer_and_a_date(tx, status, by, at):
    cur = tx.cursor()
    with pytest.raises(psycopg.errors.CheckViolation, match="legal_chk"):
        cur.execute(
            "UPDATE analytics.alert_whatsapp_consent_statements SET legal_review_status = %s, legal_reviewed_by_name = %s, "
            "legal_reviewed_at = CASE WHEN %s THEN clock_timestamp() END WHERE version = 'WA-OPTIN-1'",
            (status, by, at == "now"),
        )


def test_the_approved_text_meets_the_r9_and_d21_conditions():
    # R9: names the customer business as the originator and WiseWatts as the platform.
    assert APPROVED_TEXT.count("{business_name}") == 2
    assert "from {business_name}" in APPROVED_TEXT and "delivered by WiseWatts" in APPROVED_TEXT
    # D21: explicit individual consent, operational notifications only, no marketing.
    assert "this person has explicitly agreed" in APPROVED_TEXT and "at this number" in APPROVED_TEXT
    assert "operational alert notifications" in APPROVED_TEXT
    assert "No marketing messages will be sent." in APPROVED_TEXT


def test_every_wording_version_must_name_the_business(tx):
    cur = tx.cursor()
    retire_current_wording(cur)
    with pytest.raises(psycopg.errors.CheckViolation, match="business_name_chk"):
        cur.execute(
            "INSERT INTO analytics.alert_whatsapp_consent_statements (version, statement_text, approved_by_name, approved_at) "
            "VALUES ('TEST-NO-NAME', 'I confirm this person agreed.', 'Test', clock_timestamp())"
        )


def test_a_second_current_version_is_refused_until_the_first_is_retired(tx):
    cur = tx.cursor()
    cur.execute("SAVEPOINT s")
    with pytest.raises(psycopg.errors.UniqueViolation):
        cur.execute(
            "INSERT INTO analytics.alert_whatsapp_consent_statements (version, statement_text, approved_by_name, approved_at) "
            "VALUES ('WA-OPTIN-2', 'New wording for {business_name}.', 'Test', clock_timestamp())"
        )
    cur.execute("ROLLBACK TO SAVEPOINT s")


# --- the read renders the wording with the customer business (R9) ---------------------------

def test_the_read_shows_the_wording_with_the_customers_legal_name(wa):
    cur, admin, rule = wa["cur"], wa["u"]["admin"], wa["rule"]
    assert shown_wording(cur, admin, rule) == {
        "version": "WA-OPTIN-1",
        "text": APPROVED_TEXT.replace("{business_name}", NAME_A),
        "business_name": NAME_A,
        "unavailable_reason": None,
    }
    assert "{business_name}" not in shown_wording(cur, admin, rule)["text"]


def test_each_tenant_sees_its_own_business_name(wa):
    cur = wa["cur"]
    other = shown_wording(cur, wa["u"]["admin_b"], wa["rule_b"])
    assert other["business_name"] == "Fictional B Hotels Pvt Ltd"
    assert NAME_A not in other["text"]


@pytest.mark.parametrize("name", [None, "", "   "])
def test_without_a_legal_name_the_wording_cannot_be_shown(wa, name):
    cur, admin, rule = wa["cur"], wa["u"]["admin"], wa["rule"]
    set_legal_name(cur, wa["org"], name)
    assert shown_wording(cur, admin, rule) == {
        "version": "WA-OPTIN-1", "text": None, "business_name": None, "unavailable_reason": "business_name_missing",
    }


def test_the_legal_name_is_trimmed(wa):
    cur, admin, rule = wa["cur"], wa["u"]["admin"], wa["rule"]
    set_legal_name(cur, wa["org"], "  Fictional Trim Hotels Pvt Ltd  ")
    assert shown_wording(cur, admin, rule)["business_name"] == "Fictional Trim Hotels Pvt Ltd"


# --- new opt-ins stay blocked unless the wording AND the name are shown and current ---------

def test_a_new_opt_in_with_the_shown_wording_and_name_is_recorded_with_both(wa):
    cur, admin, rule = wa["cur"], wa["u"]["admin"], wa["rule"]
    assert save(cur, admin, rule, True, [new(P[0])], 0, version="WA-OPTIN-1", business=NAME_A) == ("ok", 1)
    assert recorded(cur, rule) == {P[0]: ("WA-OPTIN-1", NAME_A)}
    [recipient] = get(cur, admin, rule)[3]
    assert recipient["consent_statement_version"] == "WA-OPTIN-1" and recipient["consent_business_name"] == NAME_A


def test_no_current_wording_blocks_new_opt_ins(wa):
    cur, admin, rule = wa["cur"], wa["u"]["admin"], wa["rule"]
    retire_current_wording(cur)
    assert save(cur, admin, rule, True, [new(P[0])], 0, version="WA-OPTIN-1", business=NAME_A) == (
        "whatsapp_consent_statement_missing", 0)
    assert state(cur, rule) == (None, []) and wa_audit(cur, rule) == []


@pytest.mark.parametrize("name", [None, "", "   "])
def test_no_legal_name_blocks_new_opt_ins(wa, name):
    cur, admin, rule = wa["cur"], wa["u"]["admin"], wa["rule"]
    set_legal_name(cur, wa["org"], name)
    for shown in (NAME_A, None):
        assert save(cur, admin, rule, True, [new(P[0])], 0, version="WA-OPTIN-1", business=shown) == (
            "whatsapp_business_name_missing", 0)
    assert state(cur, rule) == (None, []) and wa_audit(cur, rule) == []


@pytest.mark.parametrize("version,business", [
    ("WA-OPTIN-1", None),                          # an older client that sends no name
    ("WA-OPTIN-1", "Fictional Other Hotels Ltd"),  # a different business than the rule's
    ("WA-OPTIN-1", NAME_A.lower()),                # not exactly the shown text
    (None, NAME_A),
    ("WA-OPTIN-0", NAME_A),
])
def test_new_consent_needs_exactly_the_shown_version_and_name(wa, version, business):
    cur, admin, rule = wa["cur"], wa["u"]["admin"], wa["rule"]
    assert save(cur, admin, rule, True, [new(P[0])], 0, version=version, business=business) == (
        "whatsapp_consent_statement_changed", 0)
    assert state(cur, rule) == (None, []) and wa_audit(cur, rule) == []


def test_a_legal_name_change_after_the_read_refuses_the_save(wa):
    """The name shown is the name confirmed: a rename in between needs a reload."""
    cur, admin, rule = wa["cur"], wa["u"]["admin"], wa["rule"]
    shown = shown_wording(cur, admin, rule)
    set_legal_name(cur, wa["org"], "Fictional Renamed Hotels Pvt Ltd")
    assert save(cur, admin, rule, True, [new(P[0])], 0, version=shown["version"], business=shown["business_name"]) == (
        "whatsapp_consent_statement_changed", 0)


def test_each_new_number_needs_its_own_confirmation(wa):
    """D21: explicit individual consent -- one confirmed number does not cover another."""
    cur, admin, rule = wa["cur"], wa["u"]["admin"], wa["rule"]
    assert save(cur, admin, rule, True, [new(P[0]), new(P[1], confirmed=False)], 0) == ("whatsapp_consent_required", 0)
    assert state(cur, rule) == (None, []) and wa_audit(cur, rule) == []


def test_a_changed_number_needs_fresh_confirmation_under_the_current_wording(wa):
    cur, admin, rule = wa["cur"], wa["u"]["admin"], wa["rule"]
    save(cur, admin, rule, True, [new(P[0])], 0)
    recipient = ids(cur, rule)[P[0]]
    assert save(cur, admin, rule, True, [{"recipient_id": str(recipient), "phone": P[1], "opt_in_confirmed": False}], 1) == (
        "whatsapp_consent_required", 1)
    assert save(cur, admin, rule, True, [{"recipient_id": str(recipient), "phone": P[1], "opt_in_confirmed": True}], 1) == (
        "ok", 2)
    assert recorded(cur, rule) == {P[1]: ("WA-OPTIN-1", NAME_A)}


# --- existing consents keep what was confirmed -------------------------------------------------

def test_existing_consents_keep_their_recorded_name_after_a_rename(wa):
    cur, admin, rule = wa["cur"], wa["u"]["admin"], wa["rule"]
    save(cur, admin, rule, True, [new(P[0])], 0)
    first = ids(cur, rule)[P[0]]
    set_legal_name(cur, wa["org"], "Fictional Renamed Hotels Pvt Ltd")
    # Unchanged numbers need no wording at all; a new one records the new name.
    assert save(cur, admin, rule, True, [keep(first, P[0])], 1, version=None, business=None) == ("ok", 1)  # no-op
    assert save(cur, admin, rule, True, [keep(first, P[0]), new(P[1])], 1) == ("ok", 2)
    assert recorded(cur, rule) == {P[0]: ("WA-OPTIN-1", NAME_A), P[1]: ("WA-OPTIN-1", "Fictional Renamed Hotels Pvt Ltd")}


def test_a_new_wording_version_applies_to_new_consents_only(wa):
    cur, admin, rule = wa["cur"], wa["u"]["admin"], wa["rule"]
    save(cur, admin, rule, True, [new(P[0])], 0)
    first = ids(cur, rule)[P[0]]
    statement(cur, "TEST-2")  # retires WA-OPTIN-1 and makes TEST-2 current (rolled back)
    assert save(cur, admin, rule, True, [keep(first, P[0]), new(P[1])], 1, version="WA-OPTIN-1") == (
        "whatsapp_consent_statement_changed", 1)
    assert save(cur, admin, rule, True, [keep(first, P[0]), new(P[1])], 1) == ("ok", 2)
    assert recorded(cur, rule) == {P[0]: ("WA-OPTIN-1", NAME_A), P[1]: ("TEST-2", NAME_A)}


def test_the_audit_records_version_and_business_name_but_no_phone_data(wa):
    cur, admin, rule = wa["cur"], wa["u"]["admin"], wa["rule"]
    save(cur, admin, rule, True, [new(P[0]), new(P[1])], 0)
    [row] = wa_audit(cur, rule)
    consents = row[5]["recipients"]
    assert {(r["consent_statement_version"], r["consent_business_name"]) for r in consents} == {("WA-OPTIN-1", NAME_A)}
    assert_no_phone_data(row[4], P[:2])
    assert_no_phone_data(row[5], P[:2])


# --- signatures and grants -------------------------------------------------------------------

def test_the_six_argument_save_is_replaced_and_still_resolves(wa):
    cur, admin, rule = wa["cur"], wa["u"]["admin"], wa["rule"]
    cur.execute("SELECT to_regprocedure(%s), to_regprocedure(%s) IS NOT NULL", (SAVE_6, SAVE_7))
    assert cur.fetchone() == (None, True)
    # A caller still passing six arguments (an image older than 332) reaches
    # the new function: it can keep and remove numbers, never add one.
    save(cur, admin, rule, True, [new(P[0])], 0)
    recipient = ids(cur, rule)[P[0]]
    six = "SELECT result, revision FROM analytics.save_portal_alert_rule_whatsapp(%s, %s, %s, %s, %s, %s)"
    cur.execute(six, (admin, rule, True, Jsonb([keep(recipient, P[0]), new(P[1])]), 1, "WA-OPTIN-1"))
    assert cur.fetchone() == ("whatsapp_consent_statement_changed", 1)
    cur.execute(six, (admin, rule, False, Jsonb([keep(recipient, P[0])]), 1, None))
    assert cur.fetchone() == ("ok", 2)


def test_the_business_name_helper_is_internal():
    with psycopg.connect(CONNINFO) as c:
        row = c.execute(
            "SELECT p.prosecdef, has_function_privilege('public', p.oid, 'EXECUTE'), "
            "has_function_privilege('ems_app', p.oid, 'EXECUTE'), has_function_privilege('ems_customer_api', p.oid, 'EXECUTE') "
            "FROM pg_proc p WHERE p.oid = 'analytics.alert_whatsapp_business_name(uuid)'::regprocedure"
        ).fetchone()
    assert row == (True, False, False, False)


def test_the_consent_business_name_column_is_required():
    with psycopg.connect(CONNINFO) as c:
        assert c.execute(
            "SELECT is_nullable FROM information_schema.columns WHERE table_schema = 'analytics' "
            "AND table_name = 'alert_rule_whatsapp_recipients' AND column_name = 'consent_business_name'"
        ).fetchone() == ("NO",)


# --- migration: re-apply, precondition, rollback ------------------------------------------------

def test_migration_reapplies_idempotently(tx):
    cur = tx.cursor()
    cur.execute(MIGRATION.read_text(encoding="utf-8"))
    cur.execute(MIGRATION.read_text(encoding="utf-8"))
    cur.execute("SELECT count(*) FROM analytics.alert_whatsapp_consent_statements WHERE version = 'WA-OPTIN-1'")
    assert cur.fetchone() == (1,)


def _331_body(name: str) -> str:
    text = MIGRATION_331.read_text(encoding="utf-8")
    start = text.index(f"CREATE OR REPLACE FUNCTION analytics.{name}(")
    body_start = text.index("AS $function$", start) + len("AS $function$")
    return text[body_start:text.index("$function$;", body_start)]


def test_rollback_deletes_the_numbers_and_restores_the_331_functions(wa):
    cur, admin, rule = wa["cur"], wa["u"]["admin"], wa["rule"]
    assert save(cur, admin, rule, True, [new(P[0]), new(P[1])], 0) == ("ok", 1)
    notices: list[str] = []
    cur.connection.add_notice_handler(lambda d: notices.append(d.message_primary))
    cur.execute(_sql_without_transaction_control(ROLLBACK_333))  # 333 builds on 332
    cur.execute(_sql_without_transaction_control(ROLLBACK_332))
    assert any("deleting 2 recipient number(s); switching off WhatsApp on 1 rule(s)" in n for n in notices), notices

    cur.execute("SELECT count(*) FROM analytics.alert_rule_whatsapp_recipients")
    assert cur.fetchone() == (0,)
    cur.execute("SELECT enabled, revision FROM analytics.alert_rule_whatsapp_settings WHERE rule_id = %s", (rule,))
    assert cur.fetchone() == (False, 2)
    cur.execute("SELECT count(*) FROM analytics.alert_whatsapp_consent_statements")
    assert cur.fetchone() == (0,)
    cur.execute(
        "SELECT count(*) FROM information_schema.columns WHERE table_schema = 'analytics' "
        "AND table_name = 'alert_rule_whatsapp_recipients' AND column_name = 'consent_business_name'"
    )
    assert cur.fetchone() == (0,)
    cur.execute(
        "SELECT count(*) FROM pg_constraint WHERE conname IN ('alert_whatsapp_consent_statements_business_name_chk', "
        "'alert_whatsapp_consent_statements_legal_chk')"
    )
    assert cur.fetchone() == (0,)
    cur.execute(
        "SELECT count(*) FROM information_schema.columns WHERE table_schema = 'analytics' "
        "AND table_name = 'alert_whatsapp_consent_statements' AND column_name LIKE 'legal_review%%'"
    )
    assert cur.fetchone() == (0,)
    cur.execute("SELECT to_regprocedure(%s), to_regprocedure('analytics.alert_whatsapp_business_name(uuid)')", (SAVE_7,))
    assert cur.fetchone() == (None, None)

    # The migration 331 definitions are back, verbatim, with their grants.
    for sig, name in ((SAVE_6, "save_portal_alert_rule_whatsapp"),
                      ("analytics.get_portal_alert_rule_whatsapp(bigint, uuid)", "get_portal_alert_rule_whatsapp"),
                      ("analytics.alert_whatsapp_audit_recipients(uuid)", "alert_whatsapp_audit_recipients")):
        assert _function_body(cur, sig) == _331_body(name), name
    for sig in (SAVE_6, "analytics.get_portal_alert_rule_whatsapp(bigint, uuid)"):
        cur.execute(
            "SELECT p.prosecdef, has_function_privilege('public', p.oid, 'EXECUTE'), "
            "has_function_privilege('ems_app', p.oid, 'EXECUTE'), has_function_privilege('ems_customer_api', p.oid, 'EXECUTE') "
            "FROM pg_proc p WHERE p.oid = %s::regprocedure",
            (sig,),
        )
        assert cur.fetchone() == (True, False, True, True)
    cur.execute("SELECT count(*) FROM admin.schema_migrations WHERE migration_id = '332_alert_whatsapp_consent_wording'")
    assert cur.fetchone() == (0,)

    # Back to the 331 state: no wording, so new opt-ins are refused again.
    cur.execute(
        "SELECT result FROM analytics.save_portal_alert_rule_whatsapp(%s, %s, %s, %s, %s, %s)",
        (admin, rule, True, Jsonb([new(P[0])]), 2, None),
    )
    assert cur.fetchone() == ("whatsapp_consent_statement_missing",)

    # ... and 332 applies again on top, Legal review PENDING again.
    cur.execute(MIGRATION.read_text(encoding="utf-8"))
    cur.execute("SELECT version, legal_review_status FROM analytics.alert_whatsapp_consent_statements WHERE retired_at IS NULL")
    assert cur.fetchone() == ("WA-OPTIN-1", "PENDING")


def test_migration_refuses_recipients_recorded_without_a_business_name(wa):
    """Only reachable if a recipient were stored under 331 rules: refuse, never invent a name."""
    cur, admin, rule = wa["cur"], wa["u"]["admin"], wa["rule"]
    cur.execute(_sql_without_transaction_control(ROLLBACK_333))  # 333 builds on 332
    cur.execute(_sql_without_transaction_control(ROLLBACK_332))
    cur.execute(
        "INSERT INTO analytics.alert_whatsapp_consent_statements (version, statement_text, approved_by_name, approved_at) "
        "VALUES ('TEST-331', 'Test-only 331 wording.', 'Test', clock_timestamp() - interval '1 minute')"
    )
    cur.execute(
        "SELECT result FROM analytics.save_portal_alert_rule_whatsapp(%s, %s, %s, %s, %s, %s)",
        (admin, rule, True, Jsonb([new(P[0])]), 0, "TEST-331"),
    )
    assert cur.fetchone() == ("ok",)
    with pytest.raises(psycopg.errors.RaiseException, match="without a recorded business name"):
        cur.execute(MIGRATION.read_text(encoding="utf-8"))
