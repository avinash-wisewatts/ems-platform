"""WhatsApp delivery -- migration 333 against the disposable ems_test database
(ADR-026 Phase 2: A3 outbox, A4 sender functions, A5 receipts).

Every test runs in one rolled-back transaction on the ADR-024 fixtures; the
real evaluator (analytics.evaluate_alert_rules) drives occurrences. Nothing
is sent: there is no provider here. Fictional numbers only (+1 202-555-01xx).
Legal approval of WA-OPTIN-1 and the kill switch are set inside the rolled-
back transaction only -- on staging WA-OPTIN-1 stays PENDING and sending off.
"""

from __future__ import annotations

import re
from datetime import datetime, timedelta, timezone
from pathlib import Path

import psycopg
import pytest

from tests.test_alert_rules_db import CONNINFO, Fixture, create, evaluate, tx, update, world  # noqa: F401  (fixtures)
from tests.test_alert_whatsapp_config_db import (  # noqa: F401  (wa is a fixture)
    ROLLBACK_332,
    ROLLBACK_333,
    ROOT,
    _sql_without_transaction_control,
    new,
    save,
    wa,
)

MIGRATION = ROOT / "postgres" / "migrations" / "333_alert_whatsapp_delivery.sql"
T0 = datetime(2026, 11, 18, 6, 0, tzinfo=timezone.utc)
A, B, C = "+12025550101", "+12025550102", "+12025550103"  # fictional
WORKER = "test-worker"

SENDER_FUNCS = [
    "analytics.claim_whatsapp_deliveries(text, integer, interval, timestamptz)",
    "analytics.begin_whatsapp_send(uuid, text, interval, timestamptz)",
    "analytics.record_whatsapp_send_result(uuid, text, text, text, text, timestamptz, timestamptz)",
    "analytics.purge_whatsapp_deliveries(timestamptz)",
    "analytics.get_whatsapp_delivery_overview(timestamptz)",
]
RECEIPT_FUNC = "analytics.record_whatsapp_status_update(text, text, timestamptz, text)"
PORTAL_FUNC = "analytics.get_portal_alert_rule_whatsapp_deliveries(bigint, uuid, integer)"
INTERNAL_FUNCS = [
    "analytics.alert_whatsapp_enqueue(uuid)",
    "analytics.alert_whatsapp_apply_status(uuid, text, timestamptz, text)",
    "analytics.alert_whatsapp_mask_phone(text)",
]
TABLES = [
    "analytics.alert_whatsapp_delivery_control",
    "analytics.alert_whatsapp_deliveries",
    "analytics.alert_whatsapp_status_events",
    "analytics.alert_whatsapp_enqueue_errors",
]


# --- helpers --------------------------------------------------------------------------

def sending(cur, on: bool = True) -> None:
    cur.execute("UPDATE analytics.alert_whatsapp_delivery_control SET sending_enabled = %s, changed_by_name = 'test' "
                "WHERE id = 1", (on,))


def feeder(world):
    f = world["f"]

    def feed(value, at):
        f.live(world["org"], world["site"], world["gw"], world["device"], "ACTIVE_POWER_TOTAL", value,
               at - timedelta(seconds=5))
    return feed


def run(cur, feed, minutes, value) -> None:
    for m in minutes:
        feed(value, T0 + timedelta(minutes=m))
        evaluate(cur, T0 + timedelta(minutes=m))


def deliveries(cur, rule=None) -> list[dict]:
    cur.execute(
        "SELECT d.*, a.state AS alert_state FROM analytics.alert_whatsapp_deliveries d "
        "LEFT JOIN analytics.alerts a ON a.alert_id = d.alert_id "
        "WHERE (%s::uuid IS NULL OR d.rule_id = %s::uuid) ORDER BY d.created_at, d.phone_masked",
        (rule, rule),
    )
    cols = [c.name for c in cur.description]
    return [dict(zip(cols, r)) for r in cur.fetchall()]


def claim(cur, at, limit=10, lease="1 minute", worker=WORKER) -> list[tuple]:
    cur.execute("SELECT delivery_id, phone_e164, message, attempts FROM analytics.claim_whatsapp_deliveries(%s, %s, %s, %s)",
                (worker, limit, lease, at))
    return cur.fetchall()


def result(cur, delivery, outcome, at, *, message_id=None, code=None, retry_at=None, worker=WORKER):
    cur.execute("SELECT analytics.record_whatsapp_send_result(%s, %s, %s, %s, %s, %s, %s)",
                (delivery, worker, outcome, message_id, code, retry_at, at))
    return cur.fetchone()[0]


def begin(cur, delivery, at, min_remaining="15 seconds", worker=WORKER) -> bool:
    cur.execute("SELECT analytics.begin_whatsapp_send(%s, %s, %s, %s)", (delivery, worker, min_remaining, at))
    return cur.fetchone()[0]


def receipt(cur, message_id, status, at, code=None) -> str:
    cur.execute("SELECT analytics.record_whatsapp_status_update(%s, %s, %s, %s)", (message_id, status, at, code))
    return cur.fetchone()[0]


@pytest.fixture
def d(wa):
    """WhatsApp on for wa['rule'] with two fictional recipients, Legal-approved
    consent (test only), sending switched on (test only)."""
    cur = wa["cur"]
    assert save(cur, wa["u"]["admin"], wa["rule"], True, [new(A), new(B)], 0)[0] == "ok"
    sending(cur)
    return dict(wa, feed=feeder(wa))


def activate(d, start=0) -> None:
    """Condition true for five minutes from `start`: Active at start+5."""
    run(d["cur"], d["feed"], range(start, start + 6), 70)


def resolve(d, start) -> None:
    run(d["cur"], d["feed"], range(start, start + 2), 10)


# --- enqueue (A3) ---------------------------------------------------------------------

def test_an_active_occurrence_queues_one_message_per_recipient_in_the_same_transaction(d):
    cur = d["cur"]
    run(cur, d["feed"], range(0, 5), 70)
    assert deliveries(cur) == []                      # not Active yet: nothing queued
    run(cur, d["feed"], [5], 70)
    rows = deliveries(cur, d["rule"])
    assert [(r["status"], r["phone_e164"], r["phone_masked"], r["alert_state"]) for r in rows] == [
        ("PENDING", A, "•••• 0101", "ACTIVE"), ("PENDING", B, "•••• 0102", "ACTIVE")]
    msg = rows[0]["message"]
    assert msg["business_name"] == "Fictional A Hotels Pvt Ltd"
    assert msg["rule_name"] == "High power" and msg["asset_name"] == "Chiller 1"
    assert msg["comparator"] == "GT" and float(msg["threshold"]) == 50 and float(msg["trigger_value"]) == 70
    assert rows[0]["created_at"] == T0 + timedelta(minutes=5) == rows[0]["next_attempt_at"]
    assert rows[0]["consent_statement_version"] == "WA-OPTIN-1"
    assert {r["organization_id"] for r in rows} == {d["org"]} and {r["site_id"] for r in rows} == {d["site"]}


def test_the_kill_switch_queues_nothing(d):
    cur = d["cur"]
    sending(cur, False)
    activate(d)
    assert deliveries(cur) == []
    cur.execute("SELECT count(*) FROM analytics.alerts WHERE rule_id = %s AND state = 'ACTIVE'", (d["rule"],))
    assert cur.fetchone() == (1,)


def test_whatsapp_off_for_the_rule_queues_nothing(d):
    cur = d["cur"]
    assert save(cur, d["u"]["admin"], d["rule"], False, [new(A)], 1)[0] == "ok"
    activate(d)
    assert deliveries(cur) == []


def test_pending_legal_review_suppresses_every_recipient(d):
    """WA-OPTIN-1 is PENDING on staging: nobody is ever sent to."""
    cur = d["cur"]
    cur.execute("UPDATE analytics.alert_whatsapp_consent_statements SET legal_review_status = 'PENDING', "
                "legal_reviewed_by_name = NULL, legal_reviewed_at = NULL WHERE version = 'WA-OPTIN-1'")
    activate(d)
    rows = deliveries(cur)
    assert [(r["status"], r["status_reason"], r["phone_e164"]) for r in rows] == [
        ("SUPPRESSED", "CONSENT_NOT_APPROVED", None)] * 2
    assert claim(cur, T0 + timedelta(minutes=6)) == []


def test_resolution_and_configuration_changes_send_nothing(d):
    """No recovery messages (D7): only the opening of an occurrence queues."""
    cur = d["cur"]
    activate(d)
    resolve(d, 6)
    cur.execute("SELECT state FROM analytics.alerts WHERE rule_id = %s", (d["rule"],))
    assert cur.fetchall() == [("RESOLVED",)]
    assert len(deliveries(cur)) == 2
    activate(d, 8)
    cur.execute("SELECT version FROM analytics.alert_rules WHERE rule_id = %s", (d["rule"],))
    version = cur.fetchone()[0]
    assert update(cur, d["u"]["admin"], d["rule"], version, d["asset"], threshold=55)[0] == "ok"   # ends it
    cur.execute("SELECT count(*) FROM analytics.alerts WHERE rule_id = %s AND state = 'ENDED'", (d["rule"],))
    assert cur.fetchone() == (1,)
    assert len(deliveries(cur)) == 4                  # 2 + 2 (second occurrence, quiet period) -- nothing for the end


def test_one_message_per_occurrence_and_recipient(d):
    cur = d["cur"]
    activate(d)
    cur.execute("SELECT alert_id FROM analytics.alerts WHERE rule_id = %s", (d["rule"],))
    alert_id = cur.fetchone()[0]
    cur.execute("SELECT analytics.alert_whatsapp_enqueue(%s)", (alert_id,))   # a repeat enqueue
    assert cur.fetchone() == (0,)
    assert len(deliveries(cur)) == 2
    cur.execute("SAVEPOINT dup")
    with pytest.raises(psycopg.errors.UniqueViolation, match="alert_whatsapp_deliveries_once_uq"):
        cur.execute("INSERT INTO analytics.alert_whatsapp_deliveries (alert_id, rule_id, recipient_id, organization_id, "
                    "site_id, phone_masked, consent_statement_version, message, status, created_at, updated_at) "
                    "SELECT alert_id, rule_id, recipient_id, organization_id, site_id, phone_masked, "
                    "consent_statement_version, message, 'SUPPRESSED', created_at, updated_at "
                    "FROM analytics.alert_whatsapp_deliveries LIMIT 1")
    cur.execute("ROLLBACK TO SAVEPOINT dup")


def test_sixty_minute_quiet_period_per_rule_and_recipient_across_occurrences(d):
    cur = d["cur"]
    activate(d)            # occurrence 1 at +5
    resolve(d, 6)
    activate(d, 8)         # occurrence 2 at +13: inside the quiet period
    rows = deliveries(cur)
    assert [(r["status"], r["status_reason"]) for r in rows[2:]] == [("SUPPRESSED", "QUIET_PERIOD")] * 2
    resolve(d, 14)
    activate(d, 60)        # occurrence 3 at +65: 60 minutes after occurrence 1
    rows = deliveries(cur)
    assert [r["status"] for r in rows[4:]] == ["PENDING", "PENDING"]
    # Another rule's recipients are not affected by this rule's quiet period.
    cur.execute("SELECT count(DISTINCT alert_id) FROM analytics.alert_whatsapp_deliveries")
    assert cur.fetchone() == (3,)


def test_a_failed_message_does_not_start_a_quiet_period(d):
    cur = d["cur"]
    activate(d)
    for delivery_id, *_ in claim(cur, T0 + timedelta(minutes=5)):
        assert result(cur, delivery_id, "FAILED", T0 + timedelta(minutes=5), code="META_131026") == "FAILED"
    resolve(d, 6)
    activate(d, 8)
    assert [r["status"] for r in deliveries(cur)[2:]] == ["PENDING", "PENDING"]


def _mismatch_settings(cur, rule, site_b) -> None:
    """Corrupt the settings' site (migration 331's scope guard refuses this at
    write time; disabled here, in the rolled-back transaction, to prove the
    delivery path does not rely on it alone)."""
    cur.execute("ALTER TABLE analytics.alert_rule_whatsapp_settings DISABLE TRIGGER alert_rule_whatsapp_settings_scope_guard")
    cur.execute("UPDATE analytics.alert_rule_whatsapp_settings SET site_id = %s WHERE rule_id = %s", (site_b, rule))


def test_tenant_isolation_settings_must_match_the_alert_site(d):
    cur = d["cur"]
    _mismatch_settings(cur, d["rule"], d["site_b"])
    activate(d)
    assert deliveries(cur) == []


def test_tenant_isolation_is_rechecked_when_claiming(d):
    cur = d["cur"]
    activate(d)
    _mismatch_settings(cur, d["rule"], d["site_b"])
    assert claim(cur, T0 + timedelta(minutes=5)) == []
    assert {(r["status"], r["status_reason"]) for r in deliveries(cur)} == {("SUPPRESSED", "WHATSAPP_OFF")}


def test_an_enqueue_failure_never_affects_the_alert(d):
    cur = d["cur"]
    cur.execute("ALTER TABLE analytics.alert_whatsapp_deliveries ADD CONSTRAINT test_reject CHECK (false) NOT VALID")
    activate(d)
    cur.execute("SELECT state FROM analytics.alerts WHERE rule_id = %s", (d["rule"],))
    assert cur.fetchall() == [("ACTIVE",)]
    assert deliveries(cur) == []
    cur.execute("SELECT sqlstate, rule_id FROM analytics.alert_whatsapp_enqueue_errors")
    assert cur.fetchall() == [("23514", d["rule"])]


def test_whatsapp_leaves_the_alert_lifecycle_identical_to_a_control_rule(d):
    cur = d["cur"]
    _, control, _ = create(cur, d["u"]["admin"], d["site"], d["asset"], name="Control twin")
    activate(d)
    resolve(d, 6)
    cur.execute("SELECT rule_id, state, triggered_at, trigger_value, resolved_at, resolved_value, ended_at "
                "FROM analytics.alerts WHERE rule_id IN (%s, %s)", (d["rule"], control))
    by_rule = {r[0]: r[1:] for r in cur.fetchall()}
    assert by_rule[d["rule"]] == by_rule[control]


# --- sender functions (A4) ------------------------------------------------------------

def test_claim_leases_returns_the_number_once_and_rechecks_eligibility(d):
    cur = d["cur"]
    activate(d)
    at = T0 + timedelta(minutes=5)
    claimed = claim(cur, at)
    assert sorted(p for _, p, _, _ in claimed) == [A, B] and {a for *_, a in claimed} == {1}
    assert claim(cur, at) == []                                         # leased
    assert len(claim(cur, at + timedelta(minutes=2), worker="other")) == 2   # lease lapsed: taken over
    cur.execute("SELECT DISTINCT lease_owner, attempts FROM analytics.alert_whatsapp_deliveries")
    assert cur.fetchall() == [("other", 2)]


# --- at most once: the in-flight marker -------------------------------------------------

def test_begin_send_needs_the_lease_with_the_request_time_left_and_the_switch_on(d):
    cur = d["cur"]
    activate(d)
    at = T0 + timedelta(minutes=5)
    (first, *_), (second, *_) = claim(cur, at, lease="1 minute")
    assert begin(cur, first, at, worker="other") is False                          # not the lease holder
    assert begin(cur, first, at + timedelta(seconds=50)) is False                   # 10 s left < 15 s needed
    sending(cur, False)
    assert begin(cur, first, at) is False                                           # kill switch off
    sending(cur, True)
    assert begin(cur, first, at) is True
    assert begin(cur, first, at) is False                                           # already in flight
    assert _row(cur, first)["send_started_at"] == at and _row(cur, second)["send_started_at"] is None
    with pytest.raises(psycopg.errors.InvalidParameterValue):
        begin(cur, first, at, min_remaining="-1 second")


def test_a_lapsed_lease_is_taken_over_only_if_the_send_never_started(d):
    cur = d["cur"]
    activate(d)
    at = T0 + timedelta(minutes=5)
    (started, *_), (unstarted, *_) = claim(cur, at, lease="1 minute")
    assert begin(cur, started, at) is True                    # the request may have reached the provider
    later = at + timedelta(minutes=2)                           # ... and then the worker stalled
    taken = claim(cur, later, worker="other")
    assert [t[0] for t in taken] == [unstarted]                 # never-started row: retried normally
    row = _row(cur, started)
    assert (row["status"], row["status_reason"], row["last_error_code"], row["phone_e164"], row["lease_owner"],
            row["send_started_at"]) == ("FAILED", "SEND_UNCONFIRMED", "LEASE_EXPIRED", None, None, None)
    assert started not in [t[0] for t in claim(cur, later + timedelta(minutes=5), worker="third")]  # never twice
    # the stalled worker's own late outcome for it: a refusal or retry changes nothing ...
    assert result(cur, started, "RETRY", later, code="HTTP_503", retry_at=later + timedelta(minutes=1)) is None
    assert result(cur, started, "FAILED", later, code="META_131026") is None
    assert _row(cur, started)["status"] == "FAILED"


def test_a_late_acceptance_after_the_lease_lapsed_is_still_recorded(d):
    cur = d["cur"]
    activate(d)
    at = T0 + timedelta(minutes=5)
    delivery_id = claim(cur, at, limit=1, lease="1 minute")[0][0]
    assert begin(cur, delivery_id, at) is True
    later = at + timedelta(minutes=2)
    claim(cur, later, worker="other")                                           # marks it SEND_UNCONFIRMED
    assert receipt(cur, "wamid.LATE", "delivered", later) == "buffered"           # receipt overtakes it
    assert result(cur, delivery_id, "SUBMITTED", later, message_id="wamid.LATE") == "DELIVERED"
    row = _row(cur, delivery_id)
    assert (row["status_reason"], row["failed_at"], row["provider_message_id"]) == (None, None, "wamid.LATE")
    assert result(cur, delivery_id, "SUBMITTED", later, message_id="wamid.OTHER") is None


def test_a_retry_after_a_started_send_clears_the_marker(d):
    cur = d["cur"]
    activate(d)
    at = T0 + timedelta(minutes=5)
    delivery_id = claim(cur, at, limit=1)[0][0]
    assert begin(cur, delivery_id, at) is True
    assert result(cur, delivery_id, "RETRY", at, code="CONNECT_ERROR", retry_at=at + timedelta(seconds=30)) == "PENDING"
    assert _row(cur, delivery_id)["send_started_at"] is None
    again = claim(cur, at + timedelta(seconds=30))
    assert delivery_id in [c[0] for c in again]


@pytest.mark.parametrize("change,reason,status", [
    ("kill", "SENDING_DISABLED", "SUPPRESSED"),
    ("resolve", "ALERT_NOT_ACTIVE", "SUPPRESSED"),
    ("off", "WHATSAPP_OFF", "SUPPRESSED"),
    ("pending_legal", "RECIPIENT_NOT_ELIGIBLE", "SUPPRESSED"),
    ("late", "EXPIRED", "FAILED"),
])
def test_claim_suppresses_what_no_longer_qualifies(d, change, reason, status):
    cur = d["cur"]
    activate(d)
    at = T0 + timedelta(minutes=8)
    if change == "kill":
        sending(cur, False)
    elif change == "resolve":
        resolve(d, 6)
    elif change == "off":
        cur.execute("UPDATE analytics.alert_rule_whatsapp_settings SET enabled = FALSE WHERE rule_id = %s", (d["rule"],))
    elif change == "pending_legal":
        cur.execute("UPDATE analytics.alert_whatsapp_consent_statements SET legal_review_status = 'PENDING', "
                    "legal_reviewed_by_name = NULL, legal_reviewed_at = NULL WHERE version = 'WA-OPTIN-1'")
    else:
        at = T0 + timedelta(minutes=5, hours=1, seconds=1)
    assert claim(cur, at) == []
    assert {(r["status"], r["status_reason"], r["phone_e164"]) for r in deliveries(cur)} == {(status, reason, None)}


def test_removing_a_recipient_removes_its_number_and_suppresses_its_message(d):
    cur = d["cur"]
    activate(d)
    cur.execute("DELETE FROM analytics.alert_rule_whatsapp_recipients WHERE phone_e164 = %s", (A,))
    rows = {r["phone_masked"]: r for r in deliveries(cur)}
    assert (rows["•••• 0101"]["status"], rows["•••• 0101"]["status_reason"], rows["•••• 0101"]["phone_e164"]) == (
        "SUPPRESSED", "RECIPIENT_REMOVED", None)
    assert rows["•••• 0102"]["status"] == "PENDING"


def test_submitted_clears_the_number_and_records_the_provider_id(d):
    cur = d["cur"]
    activate(d)
    at = T0 + timedelta(minutes=5)
    (delivery_id, *_), _ = claim(cur, at)
    assert result(cur, delivery_id, "SUBMITTED", at, message_id="wamid.TEST1") == "SUBMITTED"
    row = next(r for r in deliveries(cur) if r["delivery_id"] == delivery_id)
    assert (row["phone_e164"], row["provider_message_id"], row["submitted_at"], row["lease_owner"]) == (
        None, "wamid.TEST1", at, None)
    assert result(cur, delivery_id, "SUBMITTED", at, message_id="wamid.TEST2") is None   # no longer leased


def test_retry_backs_off_inside_the_sixty_minute_window_then_fails(d):
    cur = d["cur"]
    activate(d)
    at = T0 + timedelta(minutes=5)
    (delivery_id, *_), _ = claim(cur, at)
    assert result(cur, delivery_id, "RETRY", at, code="META_130429", retry_at=at + timedelta(seconds=30)) == "PENDING"
    assert all(c[0] != delivery_id for c in claim(cur, at + timedelta(seconds=10)))   # not due yet
    again = [c for c in claim(cur, at + timedelta(seconds=31)) if c[0] == delivery_id]
    assert again and again[0][3] == 2
    # A retry that would land past the window fails instead.
    assert result(cur, delivery_id, "RETRY", at, code="HTTP_503", retry_at=at + timedelta(minutes=61)) == "FAILED"
    row = next(r for r in deliveries(cur) if r["delivery_id"] == delivery_id)
    assert (row["status_reason"], row["last_error_code"], row["phone_e164"]) == ("RETRIES_EXHAUSTED", "HTTP_503", None)


def test_retries_stop_after_six_attempts(d):
    cur = d["cur"]
    activate(d)
    at = T0 + timedelta(minutes=5)
    delivery_id = claim(cur, at, limit=1)[0][0]
    status = None
    for i in range(6):
        if i:
            assert [c[0] for c in claim(cur, at + timedelta(minutes=i), limit=10) if c[0] == delivery_id] == [delivery_id]
        status = result(cur, delivery_id, "RETRY", at + timedelta(minutes=i), code="HTTP_500",
                        retry_at=at + timedelta(minutes=i + 1) - timedelta(seconds=1))
    assert status == "FAILED"


def test_permanent_failure_and_allowlist_refusal(d):
    cur = d["cur"]
    activate(d)
    at = T0 + timedelta(minutes=5)
    (first, *_), (second, *_) = claim(cur, at)
    assert result(cur, first, "FAILED", at, code="META_131026") == "FAILED"
    assert result(cur, second, "FAILED", at, code="NOT_ALLOWLISTED") == "FAILED"
    reasons = {r["delivery_id"]: (r["status_reason"], r["phone_e164"]) for r in deliveries(cur)}
    assert reasons == {first: ("PROVIDER_REJECTED", None), second: ("NOT_ALLOWLISTED", None)}


def test_result_arguments_are_validated(d):
    cur = d["cur"]
    activate(d)
    (delivery_id, *_), _ = claim(cur, T0 + timedelta(minutes=5))
    for outcome, mid, code, retry in (("SUBMITTED", None, None, None), ("RETRY", None, None, None),
                                      ("NOPE", None, None, None), ("FAILED", None, "has spaces", None)):
        cur.execute("SAVEPOINT bad")
        with pytest.raises(psycopg.errors.InvalidParameterValue):
            result(cur, delivery_id, outcome, T0, message_id=mid, code=code, retry_at=retry)
        cur.execute("ROLLBACK TO SAVEPOINT bad")


# --- receipts (A5) --------------------------------------------------------------------

def _submitted(d, message_id="wamid.R1"):
    cur = d["cur"]
    activate(d)
    at = T0 + timedelta(minutes=5)
    delivery_id = claim(cur, at, limit=1)[0][0]
    result(cur, delivery_id, "SUBMITTED", at, message_id=message_id)
    return cur, delivery_id, at


def _row(cur, delivery_id):
    return next(r for r in deliveries(cur) if r["delivery_id"] == delivery_id)


def test_receipts_move_forward_only(d):
    cur, delivery_id, at = _submitted(d)
    assert receipt(cur, "wamid.R1", "sent", at + timedelta(seconds=1)) == "applied"
    assert _row(cur, delivery_id)["status"] == "SENT"
    assert receipt(cur, "wamid.R1", "read", at + timedelta(seconds=9)) == "applied"
    row = _row(cur, delivery_id)
    assert (row["status"], row["delivered_at"], row["read_at"]) == ("DELIVERED", at + timedelta(seconds=9), at + timedelta(seconds=9))
    assert receipt(cur, "wamid.R1", "delivered", at + timedelta(seconds=5)) == "applied"   # keeps the first delivered_at
    assert _row(cur, delivery_id)["delivered_at"] == at + timedelta(seconds=9)
    assert receipt(cur, "wamid.R1", "sent", at + timedelta(seconds=2)) == "ignored"
    assert receipt(cur, "wamid.R1", "failed", at + timedelta(seconds=20), "META_131026") == "ignored"
    assert _row(cur, delivery_id)["status"] == "DELIVERED"


def test_a_failed_receipt_fails_an_undelivered_message(d):
    cur, delivery_id, at = _submitted(d)
    assert receipt(cur, "wamid.R1", "failed", at + timedelta(seconds=3), "META_131047") == "applied"
    row = _row(cur, delivery_id)
    assert (row["status"], row["status_reason"], row["last_error_code"]) == ("FAILED", "PROVIDER_FAILED", "META_131047")


def test_a_receipt_that_overtakes_the_send_result_is_applied_later(d):
    cur = d["cur"]
    activate(d)
    at = T0 + timedelta(minutes=5)
    delivery_id = claim(cur, at, limit=1)[0][0]
    assert receipt(cur, "wamid.EARLY", "delivered", at + timedelta(seconds=1)) == "buffered"
    # The buffered receipt is applied as part of recording the submission.
    assert result(cur, delivery_id, "SUBMITTED", at, message_id="wamid.EARLY") == "DELIVERED"
    assert _row(cur, delivery_id)["status"] == "DELIVERED"
    cur.execute("SELECT count(*) FROM analytics.alert_whatsapp_status_events")
    assert cur.fetchone() == (0,)


def test_receipt_arguments_are_validated(d):
    cur = d["cur"]
    for args in (("bad id with spaces", "sent", T0, None), ("wamid.X", "opened", T0, None), ("wamid.X", "sent", None, None)):
        cur.execute("SAVEPOINT bad")
        with pytest.raises(psycopg.errors.InvalidParameterValue):
            receipt(cur, *args)
        cur.execute("ROLLBACK TO SAVEPOINT bad")


# --- visibility, privacy and retention -----------------------------------------------

def test_portal_history_is_masked_and_for_configurers_of_that_site_only(d):
    cur = d["cur"]
    activate(d)
    q = "SELECT result, phone_masked, status FROM analytics.get_portal_alert_rule_whatsapp_deliveries(%s, %s, %s)"
    cur.execute(q, (d["u"]["admin"], d["rule"], 50))
    rows = cur.fetchall()
    assert sorted(rows) == [("ok", "•••• 0101", "PENDING"), ("ok", "•••• 0102", "PENDING")]
    for who, expected in (("operator", "forbidden"), ("viewer", "forbidden"), ("admin_b", "not_found")):
        cur.execute(q, (d["u"][who], d["rule"], 50))
        assert [r[0] for r in cur.fetchall()] == [expected], who
    cur.execute("SELECT * FROM analytics.get_portal_alert_rule_whatsapp_deliveries(%s, %s, %s)", (d["u"]["admin"], d["rule"], 50))
    assert not any(isinstance(v, str) and ("2025550101" in v or "2025550102" in v) for row in cur.fetchall() for v in row)


def test_no_full_number_survives_outside_pending_deliveries(d):
    cur = d["cur"]
    activate(d)
    at = T0 + timedelta(minutes=5)
    first, second = (c[0] for c in claim(cur, at))
    result(cur, first, "SUBMITTED", at, message_id="wamid.P1")
    result(cur, second, "FAILED", at, code="META_100")
    receipt(cur, "wamid.P1", "delivered", at + timedelta(seconds=2))
    cur.execute("SELECT row_to_json(d)::text FROM analytics.alert_whatsapp_deliveries d")
    dumped = " ".join(r[0] for r in cur.fetchall())
    assert not re.search(r"2025550?10[12]", dumped)


def test_overview_counts_without_numbers(d):
    cur = d["cur"]
    activate(d)
    cur.execute("SELECT * FROM analytics.get_whatsapp_delivery_overview(%s)", (T0 + timedelta(minutes=10),))
    row = cur.fetchone()
    assert row[0] is True and row[1] == 2 and row[2] == 300


def test_history_is_purged_after_ninety_days(d):
    cur = d["cur"]
    activate(d)
    at = T0 + timedelta(minutes=5)
    for delivery_id, *_ in claim(cur, at):
        result(cur, delivery_id, "FAILED", at, code="META_100")
    cur.execute("SELECT * FROM analytics.purge_whatsapp_deliveries(%s)", (at + timedelta(days=89),))
    assert cur.fetchone()[0] == 0
    cur.execute("SELECT * FROM analytics.purge_whatsapp_deliveries(%s)", (at + timedelta(days=91),))
    assert cur.fetchone()[0] == 2


# --- grants, migration and rollback ---------------------------------------------------

def _can(role, sig):
    with psycopg.connect(CONNINFO) as c:
        if not c.execute("SELECT 1 FROM pg_roles WHERE rolname = %s", (role,)).fetchone():
            pytest.skip(f"role {role} not present")
        return c.execute("SELECT has_function_privilege(%s, %s, 'EXECUTE')", (role, sig)).fetchone()[0]


@pytest.mark.parametrize("sig", SENDER_FUNCS + [RECEIPT_FUNC, PORTAL_FUNC])
def test_the_sender_role_can_execute_its_functions(sig):
    assert _can("ems_app", sig)


@pytest.mark.parametrize("sig,allowed", [(s, False) for s in SENDER_FUNCS] + [(RECEIPT_FUNC, True), (PORTAL_FUNC, True)])
def test_the_customer_api_gets_receipts_and_masked_history_only(sig, allowed):
    assert _can("ems_customer_api", sig) is allowed


@pytest.mark.parametrize("sig", INTERNAL_FUNCS)
def test_internal_functions_are_not_executable_by_application_roles(sig):
    for role in ("ems_app", "ems_customer_api"):
        assert not _can(role, sig), role


def test_no_application_role_reads_the_tables_directly():
    with psycopg.connect(CONNINFO) as c:
        for table in TABLES:
            for role in ("ems_app", "ems_customer_api"):
                if c.execute("SELECT 1 FROM pg_roles WHERE rolname = %s", (role,)).fetchone():
                    assert not c.execute("SELECT has_table_privilege(%s, %s, 'SELECT')", (role, table)).fetchone()[0]


def test_sending_is_off_after_the_migration():
    with psycopg.connect(CONNINFO) as c:
        assert c.execute("SELECT sending_enabled FROM analytics.alert_whatsapp_delivery_control").fetchall() == [(False,)]


def test_migration_reapplies_idempotently(tx):
    cur = tx.cursor()
    cur.execute(MIGRATION.read_text(encoding="utf-8"))
    cur.execute(MIGRATION.read_text(encoding="utf-8"))
    cur.execute("SELECT count(*) FROM pg_trigger WHERE tgname = 'alert_whatsapp_enqueue' AND NOT tgisinternal")
    assert cur.fetchone() == (1,)


def test_rollback_order_and_rollback(d):
    cur = d["cur"]
    activate(d)
    cur.execute("SAVEPOINT order_check")
    with pytest.raises(psycopg.errors.RaiseException, match="migration 333 is applied"):
        cur.execute(_sql_without_transaction_control(ROLLBACK_332))
    cur.execute("ROLLBACK TO SAVEPOINT order_check")
    notices: list[str] = []
    cur.connection.add_notice_handler(lambda n: notices.append(n.message_primary))
    cur.execute(_sql_without_transaction_control(ROLLBACK_333))
    assert any("deleting 2 WhatsApp delivery record(s) (2 pending)" in n for n in notices), notices
    for table in TABLES:
        cur.execute("SELECT to_regclass(%s)", (table,))
        assert cur.fetchone() == (None,)
    cur.execute("SELECT count(*) FROM pg_trigger WHERE tgname IN ('alert_whatsapp_enqueue', 'alert_whatsapp_recipient_removed')")
    assert cur.fetchone() == (0,)
    cur.execute("SELECT count(*) FROM admin.schema_migrations WHERE migration_id = '333_alert_whatsapp_delivery'")
    assert cur.fetchone() == (0,)
    cur.execute("SELECT count(*) FROM analytics.alert_rule_whatsapp_recipients WHERE rule_id = %s", (d["rule"],))
    assert cur.fetchone() == (2,)                     # configuration untouched
    activate(d, 10)                                   # the evaluator still works without the trigger


# --- end to end: Active alert -> queue -> sender -> provider (mock) -> webhook -------------

def test_end_to_end_an_active_alert_is_delivered_once_and_its_receipts_recorded(d, monkeypatch):
    """The whole path on one rolled-back transaction: the real evaluator makes
    the alert Active, the trigger queues it, the real sender (real service
    module, real Meta client over httpx.MockTransport) claims, marks in flight
    and submits it, and a signed callback through the real customer app marks
    it DELIVERED. Only the HTTP transport to Meta is simulated."""
    import asyncio
    import hashlib
    import hmac
    import json

    import httpx
    from fastapi.testclient import TestClient

    import src.config as config
    import src.customer_main as customer_main
    import src.routers.whatsapp_webhook as wh
    from src import whatsapp_delivery_service
    from src.whatsapp_config import WhatsAppSettings
    from src.whatsapp_provider import MetaWhatsAppClient
    from src.whatsapp_sender import WhatsAppSender

    cur = d["cur"]

    async def on_test_transaction(sql, params):
        cur.execute(sql, params)
        if cur.description is None:
            return []
        cols = [c.name for c in cur.description]
        return [dict(zip(cols, r)) for r in cur.fetchall()]

    monkeypatch.setattr(whatsapp_delivery_service, "_call", on_test_transaction)

    # Real clock: the sender's functions use clock_timestamp(), so the alert must be recent.
    base = datetime.now(timezone.utc).replace(microsecond=0) - timedelta(minutes=10)
    for m in range(0, 6):
        d["feed"](70, base + timedelta(minutes=m))
        evaluate(cur, base + timedelta(minutes=m))
    queued = deliveries(cur, d["rule"])
    assert [(r["status"], r["alert_state"]) for r in queued] == [("PENDING", "ACTIVE")] * 2

    secret, verify = "e2e-app-secret-not-real", "e2e-verify-not-real"
    settings = WhatsAppSettings(
        EMS_WHATSAPP_SENDING_ENABLED=True, EMS_WHATSAPP_ACCESS_TOKEN="e2e-token-not-real",
        EMS_WHATSAPP_PHONE_NUMBER_ID="1234567890", EMS_WHATSAPP_TEMPLATE_NAME="ems_alert_v1",
        EMS_WHATSAPP_RECIPIENT_ALLOWLIST=A,                    # B is configured but not allowlisted
        EMS_WHATSAPP_APP_SECRET=secret, EMS_WHATSAPP_WEBHOOK_VERIFY_TOKEN=verify)
    requests: list[dict] = []

    def meta(request: httpx.Request) -> httpx.Response:
        requests.append(json.loads(request.content))
        return httpx.Response(200, json={"messaging_product": "whatsapp", "contacts": [{"wa_id": "12025550101"}],
                                         "messages": [{"id": "wamid.E2E1"}]})

    client = MetaWhatsAppClient(settings, httpx.AsyncClient(transport=httpx.MockTransport(meta)))
    sender = WhatsAppSender(settings, client, worker_id="e2e-worker")
    asyncio.run(sender.run_once())
    asyncio.run(sender.run_once())                         # nothing left to send: never twice

    assert len(requests) == 1 and requests[0]["to"] == "12025550101"
    body = requests[0]["template"]["components"][0]["parameters"]
    assert [p["text"] for p in body][:3] == ["Fictional A Hotels Pvt Ltd", "High power", "Chiller 1"]
    rows = {r["phone_masked"]: r for r in deliveries(cur, d["rule"])}
    assert (rows["•••• 0101"]["status"], rows["•••• 0101"]["provider_message_id"], rows["•••• 0101"]["phone_e164"]) == (
        "SUBMITTED", "wamid.E2E1", None)
    assert (rows["•••• 0102"]["status"], rows["•••• 0102"]["status_reason"]) == ("FAILED", "NOT_ALLOWLISTED")

    config.use_core_settings(customer_main.settings)
    monkeypatch.setattr(wh, "_settings", lambda: settings)
    try:
        web = TestClient(customer_main.app, follow_redirects=False)
        challenge = web.get(wh.WEBHOOK_PATH, params={"hub.mode": "subscribe", "hub.verify_token": verify,
                                                     "hub.challenge": "42"})
        assert (challenge.status_code, challenge.text) == (200, "42")
        ts = int(datetime.now(timezone.utc).timestamp())
        for status, offset in (("sent", 1), ("delivered", 2)):
            raw = json.dumps({"object": "whatsapp_business_account", "entry": [{"id": "1", "changes": [{
                "field": "messages", "value": {"statuses": [
                    {"id": "wamid.E2E1", "status": status, "timestamp": str(ts + offset),
                     "recipient_id": "12025550101"}]}}]}]}).encode()
            signature = "sha256=" + hmac.new(secret.encode(), raw, hashlib.sha256).hexdigest()
            response = web.post(wh.WEBHOOK_PATH, content=raw,
                                headers={"X-Hub-Signature-256": signature, "Content-Type": "application/json"})
            assert response.status_code == 200 and response.json()["applied"] == 1
        forged = web.post(wh.WEBHOOK_PATH, content=b'{"entry": []}',
                          headers={"X-Hub-Signature-256": "sha256=" + "0" * 64, "Content-Type": "application/json"})
        assert forged.status_code == 401
    finally:
        config._core_settings = None

    final = next(r for r in deliveries(cur, d["rule"]) if r["phone_masked"] == "•••• 0101")
    assert (final["status"], final["sent_at"], final["delivered_at"]) == (
        "DELIVERED", datetime.fromtimestamp(ts + 1, timezone.utc), datetime.fromtimestamp(ts + 2, timezone.utc))
