"""WhatsApp Phase 1 -- alert lifecycle regression matrix RG-1 to RG-13
(phase-1-plan §7.2; P1-AC-7, -8, -9, -14; ADR-024 Amendment 2 §2C; D6, D20).

The guarantee under test: WhatsApp saves, and rule saves that change no
operational field (whatever they send for the retired WhatsApp flag), leave
Active occurrence state, trigger and resolution timers, acknowledgements and
rule versions byte-for-byte unchanged -- while an operational edit still ends
the Active occurrence exactly as ADR-024 §8 says.

Fixture (one rolled-back transaction per case, on the ADR-024 fixtures of
test_alert_rules_db): four assets, each fed independently, each with a
SUBJECT rule and an identical CONTROL twin that no save ever touches:

    active          Active occurrence, acknowledged by a customer operator
    active_unacked  Active occurrence, not acknowledged
    qualifying      condition true for 3 minutes (needs 5 to qualify)
    resolving       Active occurrence, first clear observation 30 s ago

Snapshot = the full rows of analytics.alerts, analytics.alert_evaluation_
candidates (the timers) and analytics.alert_rules for the subject rules.
Fictional phone numbers only; nothing is sent.
"""

from __future__ import annotations

import re
from datetime import datetime, timedelta, timezone

import psycopg
import pytest
from psycopg.types.json import Jsonb

from tests.test_alert_rules_db import CONNINFO, create, evaluate, tx, update, world  # noqa: F401  (fixtures)

T0 = datetime(2026, 11, 24, 6, 0, tzinfo=timezone.utc)
SNAPSHOT_AT = T0 + timedelta(minutes=6, seconds=30)
P = [f"+1202555{n:04d}" for n in range(100, 112)]  # fictional
SCENARIOS = ("active", "active_unacked", "qualifying", "resolving")
# Occurrence fields that must match between a subject and its control twin.
TWIN_FIELDS = ("state", "triggered_at", "trigger_value", "resolved_at", "resolved_value", "ended_at",
               "ended_reason_code", "data_unavailable", "rule_version")


def _feed_value(scenario: str, minute: int) -> int:
    if scenario == "qualifying":
        return 70 if minute >= 3 else 40      # true since minute 3
    if scenario == "resolving":
        return 10 if minute >= 6 else 70      # Active at 5, first clear at 6
    return 70                                  # Active from minute 5


@pytest.fixture
def m(world):
    cur, f = world["cur"], world["f"]
    admin, operator = world["u"]["admin"], world["u"]["operator"]
    # Saves use the wording loaded by migration 332 (WA-OPTIN-1), which names
    # the customer by its legal name (R9): a fictional one here.
    cur.execute("UPDATE metadata.organizations SET legal_name = %s WHERE id = %s", (BUSINESS, world["org"]))
    # Opt-ins need Legal approval of the wording: recorded here for the
    # rolled-back test transaction only (on staging it stays PENDING).
    cur.execute(
        "UPDATE analytics.alert_whatsapp_consent_statements SET legal_review_status = 'APPROVED', "
        "legal_reviewed_by_name = 'Test Legal', legal_reviewed_at = clock_timestamp() WHERE version = 'WA-OPTIN-1'"
    )
    feeds, subjects, controls, assets = {}, {}, {}, {}
    for s in SCENARIOS:
        asset, device = f.asset(world["org"], world["site"], world["gw"], f"RG {s}")
        assets[s] = asset
        subjects[s] = create(cur, admin, world["site"], asset, name=f"RG {s} subject")[1]
        controls[s] = create(cur, admin, world["site"], asset, name=f"RG {s} control")[1]

        def feed(value, at, _device=device):
            f.live(world["org"], world["site"], world["gw"], _device, "ACTIVE_POWER_TOTAL", value, at - timedelta(seconds=5))

        feeds[s] = feed

    def step(minute: int, at: datetime | None = None):
        at = at or T0 + timedelta(minutes=minute)
        for s in SCENARIOS:
            feeds[s](_feed_value(s, minute), at)
        evaluate(cur, at)

    for minute in range(7):
        step(minute)
        if minute == 5:
            for rule in (subjects["active"], controls["active"]):
                cur.execute("SELECT alert_id FROM analytics.alerts WHERE rule_id = %s AND state = 'ACTIVE'", (rule,))
                cur.execute("SELECT result FROM analytics.acknowledge_portal_alert(%s, %s)", (operator, cur.fetchone()[0]))
                assert cur.fetchone() == ("ok",)
    ctx = dict(world, cur=cur, admin=admin, subjects=subjects, controls=controls, assets=assets, step=step)
    _sanity(ctx)
    return ctx


def _sanity(m) -> None:
    """The fixture really is in the four intended states."""
    cur = m["cur"]
    for s, expected in (("active", "ACTIVE"), ("active_unacked", "ACTIVE"), ("resolving", "ACTIVE")):
        for rule in (m["subjects"][s], m["controls"][s]):
            assert [r[0] for r in _occurrences(cur, rule)] == [expected], s
    for rule in (m["subjects"]["qualifying"], m["controls"]["qualifying"]):
        assert _occurrences(cur, rule) == []
        cur.execute("SELECT count(*) FROM analytics.alert_evaluation_candidates WHERE rule_id = %s", (rule,))
        assert cur.fetchone()[0] >= 1  # the qualification timer is running
    cur.execute("SELECT acknowledged_at IS NOT NULL FROM analytics.alerts WHERE rule_id = %s", (m["subjects"]["active"],))
    assert cur.fetchone() == (True,)


def _occurrences(cur, rule) -> list[tuple]:
    cur.execute(f"SELECT {', '.join(TWIN_FIELDS)} FROM analytics.alerts WHERE rule_id = %s ORDER BY triggered_at", (rule,))
    return cur.fetchall()


def snapshot(cur, rules) -> dict:
    rules = list(rules)
    cur.execute("SELECT to_jsonb(a) FROM analytics.alerts a WHERE a.rule_id = ANY(%s) ORDER BY a.alert_id", (rules,))
    alerts = cur.fetchall()
    cur.execute(
        "SELECT to_jsonb(c) FROM analytics.alert_evaluation_candidates c WHERE c.rule_id = ANY(%s) "
        "ORDER BY c.rule_id, c.condition_key",
        (rules,),
    )
    candidates = cur.fetchall()
    cur.execute("SELECT to_jsonb(r) FROM analytics.alert_rules r WHERE r.rule_id = ANY(%s) ORDER BY r.rule_id", (rules,))
    return {"alerts": alerts, "candidates": candidates, "rules": cur.fetchall()}


def wa_state(cur, rules) -> list:
    cur.execute(
        "SELECT to_jsonb(s), COALESCE((SELECT jsonb_agg(to_jsonb(r) ORDER BY r.recipient_id) "
        "FROM analytics.alert_rule_whatsapp_recipients r WHERE r.rule_id = s.rule_id), '[]') "
        "FROM analytics.alert_rule_whatsapp_settings s WHERE s.rule_id = ANY(%s) ORDER BY s.rule_id",
        (list(rules),),
    )
    return cur.fetchall()


def rule_audit_count(cur, rules) -> int:
    cur.execute("SELECT count(*) FROM admin.audit_events WHERE entity_id = ANY(%s) AND entity_type = 'ALERT_RULE'",
                (list(rules),))
    return cur.fetchone()[0]


BUSINESS = "Fictional RG Hotels Pvt Ltd"


def wa_save(cur, user, rule, enabled, recipients, revision) -> tuple:
    cur.execute(
        "SELECT result, revision FROM analytics.save_portal_alert_rule_whatsapp(%s, %s, %s, %s, %s, 'WA-OPTIN-1', %s)",
        (user, rule, enabled, Jsonb(recipients), revision, BUSINESS),
    )
    return cur.fetchone()


def revision(cur, rule) -> int:
    cur.execute("SELECT revision FROM analytics.alert_rule_whatsapp_settings WHERE rule_id = %s", (rule,))
    row = cur.fetchone()
    return row[0] if row else 0


def without_ended_at(occurrences) -> list[tuple]:
    """ended_at is the wall-clock instant of the disable / delete itself, so it
    differs between a subject and its control operated milliseconds apart."""
    index = TWIN_FIELDS.index("ended_at")
    assert all(o[index] is not None for o in occurrences if o[0] == "ENDED")
    return [o[:index] + o[index + 1:] for o in occurrences]


def new(phone):
    return {"recipient_id": None, "phone": phone, "opt_in_confirmed": True}


def recipient_ids(cur, rule) -> dict[str, str]:
    cur.execute("SELECT phone_e164, recipient_id::text FROM analytics.alert_rule_whatsapp_recipients WHERE rule_id = %s",
                (rule,))
    return dict(cur.fetchall())


def unchanged_update(cur, user, rule, asset, whatsapp):
    """A rule save that changes no operational field (the fixture's defaults)."""
    cur.execute("SELECT version, name FROM analytics.alert_rules WHERE rule_id = %s", (rule,))
    version, name = cur.fetchone()
    return update(cur, user, rule, version, asset, name=name, whatsapp=whatsapp)


# --- RG-1 .. RG-7: saves that must leave the lifecycle untouched ------------------------

def _rg1(m, rule, asset):
    r = revision(m["cur"], rule)
    assert wa_save(m["cur"], m["admin"], rule, True, [new(P[0])], r) == ("ok", r + 1)


def _rg2(m, rule, asset):
    cur, admin = m["cur"], m["admin"]
    assert wa_save(cur, admin, rule, True, [new(P[0]), new(P[1])], revision(cur, rule))[0] == "ok"  # add
    ids = recipient_ids(cur, rule)
    edited = [{"recipient_id": ids[P[0]], "phone": P[2], "opt_in_confirmed": True}]  # edit P0 -> P2, remove P1
    assert wa_save(cur, admin, rule, True, edited, revision(cur, rule))[0] == "ok"
    kept = {"recipient_id": recipient_ids(cur, rule)[P[2]], "phone": P[2], "opt_in_confirmed": False}
    assert wa_save(cur, admin, rule, True, [kept] + [new(p) for p in P[3:12]], revision(cur, rule))[0] == "ok"  # 10
    assert len(recipient_ids(cur, rule)) == 10


def _rg3(m, rule, asset):
    cur, admin = m["cur"], m["admin"]
    assert wa_save(cur, admin, rule, True, [new(P[0])], revision(cur, rule))[0] == "ok"
    keep = [{"recipient_id": recipient_ids(cur, rule)[P[0]], "phone": P[0], "opt_in_confirmed": False}]
    r = revision(cur, rule)
    assert wa_save(cur, admin, rule, False, keep, r) == ("ok", r + 1)


def _rg4(m, rule, asset):
    cur, admin = m["cur"], m["admin"]
    r = revision(cur, rule)
    assert wa_save(cur, admin, rule, True, [new("12345")], r)[0] == "whatsapp_invalid_phone"
    assert wa_save(cur, admin, rule, True, [new(p) for p in P[:11]], r)[0] == "whatsapp_too_many_recipients"
    assert wa_save(cur, admin, rule, True, [new(P[0])], r + 7)[0] == "whatsapp_config_stale"


def _rg5(m, rule, asset):
    for whatsapp in (False, None):  # the new form omits the field: API default False; NULL for direct callers
        assert unchanged_update(m["cur"], m["admin"], rule, asset, whatsapp)[0] == "ok"


def _rg6(m, rule, asset):
    assert unchanged_update(m["cur"], m["admin"], rule, asset, True)[0] == "ok"


def _rg7(m, rule, asset):
    assert unchanged_update(m["cur"], m["admin"], rule, asset, False)[0] == "ok"


UNTOUCHED = {"RG-1": _rg1, "RG-2": _rg2, "RG-3": _rg3, "RG-4": _rg4, "RG-5": _rg5, "RG-6": _rg6, "RG-7": _rg7}


@pytest.mark.parametrize("case", list(UNTOUCHED))
def test_saves_leave_occurrences_timers_acknowledgements_and_versions_unchanged(m, case):
    cur, subjects = m["cur"], m["subjects"]
    before = snapshot(cur, subjects.values())
    audits_before = rule_audit_count(cur, subjects.values())
    wa_before = wa_state(cur, subjects.values())
    for s in SCENARIOS:
        UNTOUCHED[case](m, subjects[s], m["assets"][s])
    assert snapshot(cur, subjects.values()) == before
    # No rule save is audited when nothing operational changed (RG-5..RG-7).
    assert rule_audit_count(cur, subjects.values()) == audits_before
    if case == "RG-4":
        assert wa_state(cur, subjects.values()) == wa_before == []
    cur.execute("SELECT count(*) FROM analytics.alert_rules WHERE rule_id = ANY(%s) AND whatsapp_requested",
                (list(subjects.values()),))
    assert cur.fetchone() == (0,)


# --- RG-8: an operational edit still ends the occurrence (ADR-024 §8) -------------------

def test_rg8_threshold_change_ends_the_occurrence_and_keeps_the_whatsapp_configuration(m):
    cur, admin, rule = m["cur"], m["admin"], m["subjects"]["active"]
    wa_save(cur, admin, rule, True, [new(P[0])], 0)
    wa_before = wa_state(cur, [rule])
    assert update(cur, admin, rule, 1, m["assets"]["active"], name="RG active subject", threshold=55) == ("ok", rule, 2)
    [(state, *_rest, ended_reason, _unavailable, rule_version)] = _occurrences(cur, rule)
    assert (state, ended_reason, rule_version) == ("ENDED", "CONFIGURATION_CHANGED", 1)
    assert wa_state(cur, [rule]) == wa_before


# --- RG-9: disable / enable behave as before; WhatsApp configuration unchanged ----------

def test_rg9_disable_and_enable_match_the_control_and_keep_the_whatsapp_configuration(m):
    cur, admin = m["cur"], m["admin"]
    subject, control = m["subjects"]["active_unacked"], m["controls"]["active_unacked"]
    wa_save(cur, admin, subject, True, [new(P[0])], 0)
    wa_before = wa_state(cur, [subject])
    results = {}
    for rule in (subject, control):
        cur.execute("SELECT result, version FROM analytics.set_portal_alert_rule_enabled(%s, %s, FALSE)", (admin, rule))
        disabled = cur.fetchone()
        cur.execute("SELECT result, version FROM analytics.set_portal_alert_rule_enabled(%s, %s, TRUE)", (admin, rule))
        results[rule] = (disabled, cur.fetchone(), without_ended_at(_occurrences(cur, rule)))
    assert results[subject] == results[control]
    assert results[subject][0] == ("ok", 1) and results[subject][1] == ("ok", 2)
    [(state, *_middle, reason, _unavailable, _version)] = results[subject][2]
    assert (state, reason) == ("ENDED", "CONFIGURATION_CHANGED")
    assert wa_state(cur, [subject]) == wa_before


# --- RG-10: a WhatsApp save never changes an acknowledgement ----------------------------

def test_rg10_acknowledge_then_whatsapp_save_keeps_who_and_when(m):
    cur, rule = m["cur"], m["subjects"]["active_unacked"]
    cur.execute("SELECT alert_id FROM analytics.alerts WHERE rule_id = %s AND state = 'ACTIVE'", (rule,))
    alert_id = cur.fetchone()[0]
    cur.execute("SELECT result FROM analytics.acknowledge_portal_alert(%s, %s)", (m["u"]["operator"], alert_id))
    assert cur.fetchone() == ("ok",)
    cur.execute("SELECT to_jsonb(a) FROM analytics.alerts a WHERE alert_id = %s", (alert_id,))
    acknowledged = cur.fetchone()
    assert wa_save(cur, m["u"]["g_admin"], rule, True, [new(P[0])], 0)[0] == "ok"
    cur.execute("SELECT to_jsonb(a) FROM analytics.alerts a WHERE alert_id = %s", (alert_id,))
    assert cur.fetchone() == acknowledged


# --- RG-11: soft delete -------------------------------------------------------------------

def test_rg11_soft_delete_matches_the_control_and_removes_the_whatsapp_configuration(m):
    cur, admin = m["cur"], m["admin"]
    subject, control = m["subjects"]["active"], m["controls"]["active"]
    wa_save(cur, admin, subject, True, [new(P[0]), new(P[1])], 0)
    for rule in (subject, control):
        cur.execute("SELECT result FROM analytics.delete_portal_alert_rule(%s, %s)", (admin, rule))
        assert cur.fetchone() == ("ok",)
    assert without_ended_at(_occurrences(cur, subject)) == without_ended_at(_occurrences(cur, control))
    assert [o[0] for o in _occurrences(cur, subject)] == ["ENDED"]
    assert wa_state(cur, [subject]) == []
    cur.execute("SELECT count(*) FROM analytics.alert_rule_whatsapp_recipients WHERE rule_id = %s", (subject,))
    assert cur.fetchone() == (0,)


# --- RG-12: the evaluator treats every saved subject exactly like its control -----------

def test_rg12_after_rg1_to_rg7_every_subject_transitions_like_its_control(m):
    cur, subjects, controls = m["cur"], m["subjects"], m["controls"]
    for case in UNTOUCHED.values():
        for s in SCENARIOS:
            cur.execute("SAVEPOINT rg")
            case(m, subjects[s], m["assets"][s])
            cur.execute("RELEASE SAVEPOINT rg")
    # Fixed instants: the 1-minute resolution of "resolving" (minute 7), the
    # 5-minute qualification of "qualifying" (minute 8, inside the 2 s grace),
    # and further runs while the Active ones stay Active.
    m["step"](7)
    m["step"](8, T0 + timedelta(minutes=8) - timedelta(seconds=1, milliseconds=500))
    m["step"](9)
    for s in SCENARIOS:
        assert _occurrences(cur, subjects[s]) == _occurrences(cur, controls[s]), s
    assert [o[0] for o in _occurrences(cur, subjects["resolving"])] == ["RESOLVED"]
    assert [o[0] for o in _occurrences(cur, subjects["qualifying"])] == ["ACTIVE"]
    assert [o[0] for o in _occurrences(cur, subjects["active"])] == ["ACTIVE"]


# --- RG-13: the retired flag cannot be stored -------------------------------------------

def test_rg13_create_with_the_legacy_flag_stores_false_and_the_check_holds(world):
    cur = world["cur"]
    result, rule, _ = create(cur, world["u"]["admin"], world["site"], world["asset"], whatsapp=True)
    assert result == "ok"
    cur.execute("SELECT whatsapp_requested FROM analytics.alert_rules WHERE rule_id = %s", (rule,))
    assert cur.fetchone() == (False,)
    cur.execute("SAVEPOINT direct")
    with pytest.raises(psycopg.errors.CheckViolation):
        cur.execute("UPDATE analytics.alert_rules SET whatsapp_requested = TRUE WHERE rule_id = %s", (rule,))
    cur.execute("ROLLBACK TO SAVEPOINT direct")


# --- whole-file check: the WhatsApp functions never write the lifecycle tables ---------

WHATSAPP_FUNCTIONS = [
    "analytics.get_portal_alert_rule_whatsapp(bigint, uuid)",
    "analytics.get_portal_alert_rule_whatsapp_summaries(bigint, uuid)",
    "analytics.save_portal_alert_rule_whatsapp(bigint, uuid, boolean, jsonb, integer, text, text)",
    "analytics.alert_whatsapp_actor_is_automation(bigint)",
    "analytics.alert_whatsapp_business_name(uuid)",
    "analytics.alert_whatsapp_current_statement_version()",
    "analytics.alert_whatsapp_audit_recipients(uuid)",
    "analytics.alert_rule_whatsapp_settings_scope_guard()",
]


@pytest.mark.parametrize("sig", WHATSAPP_FUNCTIONS)
def test_whatsapp_functions_never_write_rules_occurrences_or_timers(sig):
    with psycopg.connect(CONNINFO) as c:
        source = c.execute("SELECT prosrc FROM pg_proc WHERE oid = %s::regprocedure", (sig,)).fetchone()[0]
    # Occurrences and timers are not referenced at all.
    assert not re.search(r"\balert_evaluation_candidates\b", source)
    assert not re.search(r"analytics\.alerts\b", source)
    # The rule is only ever read (FOR KEY SHARE at most), never written.
    assert not re.search(r"(?i)\b(update|insert\s+into|delete\s+from)\s+analytics\.alert_rules\b", source)
    # Any row lock on the rule is FOR KEY SHARE, never FOR (NO KEY) UPDATE.
    for statement in source.split(";"):
        if re.search(r"analytics\.alert_rules\b", statement):
            assert not re.search(r"(?i)\bfor\s+(no\s+key\s+)?update\b", statement), statement
    assert "alert_rule_end_active" not in source
