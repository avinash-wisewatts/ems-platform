"""WhatsApp notifications, Phase 1 -- per-rule WhatsApp CONFIGURATION only
(ADR-024 Amendment 2; ADR-026 Proposed; migration 331).

Nothing is sent: there is no provider, queue, sender or receipt endpoint, and
``messages_active`` is always false.

Phone numbers are personal data. This module never puts a submitted or stored
number into a log line, an exception message or an error ``detail``:

* numbers are parsed with the pinned ``phonenumbers`` library and stored in
  E.164 form (the database CHECK is the backstop);
* refusals carry a code and a fixed sentence only;
* a database error is re-raised as a generic error WITHOUT its chained cause,
  because PostgreSQL error details can echo row values.

The opt-in wording (migration 332, R9 / D21) names the customer business:
the read returns it rendered with the organisation's legal name, and a save
that adds a number must send back the wording version AND the business name
the administrator was shown; both are recorded with the consent. New
opt-ins stay closed while the wording's Legal review is pending (L-1).

Permissions are enforced at the route (``alert.configure``) and again inside
the SECURITY DEFINER functions, which also refuse designated report
automation accounts of any site (R5) and re-check site access.
"""

from __future__ import annotations

import logging
from datetime import datetime
from typing import Any, Literal
from uuid import UUID

import phonenumbers
import psycopg
from psycopg.types.json import Jsonb
from pydantic import BaseModel, ConfigDict, Field

from src.alert_rules_service import WhatsAppRuleSummary

logger = logging.getLogger(__name__)

MAX_RECIPIENTS = 10

RESULT_STATUS: dict[str, int] = {
    "not_found": 404,
    "forbidden": 403,
    "whatsapp_config_stale": 409,
    "whatsapp_consent_statement_changed": 409,
}
RESULT_DETAIL: dict[str, str] = {
    "not_found": "The resource does not exist or is not accessible.",
    "forbidden": "You do not have permission to do this.",
    "whatsapp_config_stale": "These WhatsApp settings were changed by someone else. Reload them and try again.",
    "whatsapp_invalid_request": "The WhatsApp settings are malformed.",
    "whatsapp_invalid_phone": "Enter a valid mobile number with its country code, starting with + (for example +91 for India).",
    "whatsapp_duplicate_phone": "This number is already in the list.",
    "whatsapp_too_many_recipients": f"An alert rule can have at most {MAX_RECIPIENTS} WhatsApp numbers.",
    "whatsapp_recipients_required": "Add at least one number before turning WhatsApp notifications on.",
    "whatsapp_consent_required": "Confirm that the person has agreed to receive WhatsApp alert messages.",
    "whatsapp_consent_statement_missing": (
        "New WhatsApp numbers cannot be added yet: the opt-in confirmation wording has not been approved."
    ),
    "whatsapp_consent_legal_review_pending": (
        "New WhatsApp numbers cannot be added yet: the opt-in confirmation wording is awaiting Legal review."
    ),
    "whatsapp_business_name_missing": (
        "New WhatsApp numbers cannot be added yet: the customer's legal business name is not recorded."
    ),
    "whatsapp_unknown_recipient": "A recipient in the request does not belong to this alert rule. Reload and try again.",
    "whatsapp_consent_statement_changed": (
        "The opt-in confirmation wording has changed. Reload, read the current wording and confirm again."
    ),
}


class WhatsAppConfigError(Exception):
    """A refusal from validation or from a migration 331 function. Its message
    is the code only -- never a phone number."""

    def __init__(self, code: str, index: int | None = None):
        super().__init__(code)
        self.code = code
        self.index = index  # position of the offending recipient, when known
        self.status = RESULT_STATUS.get(code, 422)
        self.detail = RESULT_DETAIL.get(code, "The WhatsApp settings violate the contract.")


# ---------------------------------------------------------------------------
# Requests / responses
# ---------------------------------------------------------------------------

class RecipientIn(BaseModel):
    model_config = ConfigDict(extra="forbid")

    recipient_id: UUID | None = Field(
        default=None, description="Present for an existing recipient; omit for a new number."
    )
    phone: str = Field(max_length=32, description="Mobile number with its country code (E.164: + then the country code and number).")
    opt_in_confirmed: bool = Field(
        default=False,
        description="Required for a new or changed number: the administrator confirms the person opted in.",
    )


class WhatsAppConfigIn(BaseModel):
    model_config = ConfigDict(extra="forbid")

    enabled: bool
    revision: int = Field(ge=0, description="The revision being edited; 0 for a rule never configured.")
    # A generous bound on the payload; the 10-recipient rule is a named refusal.
    recipients: list[RecipientIn] = Field(default_factory=list, max_length=50)
    consent_statement_version: str | None = Field(
        default=None,
        max_length=40,
        description="The opt-in wording version shown to the administrator (from the GET); required to add a "
        "new or changed number, and must still be the current approved version.",
    )
    consent_business_name: str | None = Field(
        default=None,
        max_length=300,
        description="The business name in the opt-in wording shown to the administrator (from the GET); required "
        "with consent_statement_version, and must still be the customer's recorded legal name.",
    )


class ConsentOut(BaseModel):
    state: Literal["CONFIRMED", "OPTED_OUT"]
    confirmed_at: datetime
    confirmed_by_name: str = Field(description='Display name, or "WiseWatts Support" for WiseWatts staff.')
    statement_version: str
    business_name: str | None = Field(default=None, description="The business named in the confirmed wording (R9).")


class RecipientOut(BaseModel):
    recipient_id: UUID
    phone_e164: str
    phone_masked: str
    consent: ConsentOut


class ConsentStatementOut(BaseModel):
    version: str
    text: str = Field(description="The approved wording, with the customer business named (R9).")
    business_name: str


class WhatsAppConfigOut(BaseModel):
    rule_id: UUID
    enabled: bool
    revision: int
    messages_active: Literal[False] = Field(
        default=False, description="Always false in Phase 1: WhatsApp messages are not sent yet."
    )
    max_recipients: int = MAX_RECIPIENTS
    recipients: list[RecipientOut]
    consent_statement: ConsentStatementOut | None = Field(
        default=None,
        description="The Product-approved opt-in wording to show for a new number; null when it cannot be shown "
        "(new numbers cannot be added; see consent_unavailable_reason).",
    )
    consent_unavailable_reason: Literal["statement_missing", "legal_review_pending", "business_name_missing"] | None = Field(
        default=None,
        description="Why consent_statement is null: no approved wording, Legal review of the wording pending, or no "
        "legal business name recorded.",
    )


# ---------------------------------------------------------------------------
# Phone numbers
# ---------------------------------------------------------------------------

def normalize_phone(raw: str, index: int | None = None) -> str:
    """Parse a number entered with its country code and return E.164.

    Raises WhatsAppConfigError('whatsapp_invalid_phone') -- with no number in
    it -- for anything that is not a valid number."""

    text = (raw or "").strip()
    if not text.startswith("+"):
        raise WhatsAppConfigError("whatsapp_invalid_phone", index)
    try:
        parsed = phonenumbers.parse(text, None)
    except phonenumbers.NumberParseException:
        raise WhatsAppConfigError("whatsapp_invalid_phone", index) from None
    if not phonenumbers.is_valid_number(parsed):
        raise WhatsAppConfigError("whatsapp_invalid_phone", index)
    return phonenumbers.format_number(parsed, phonenumbers.PhoneNumberFormat.E164)


def mask_phone(e164: str) -> str:
    """Country code plus the last four digits, e.g. "+1 ••••••0100". Shown only
    to configurers; never written to the audit log (R12)."""

    try:
        parsed = phonenumbers.parse(e164, None)
        country = str(parsed.country_code)
    except phonenumbers.NumberParseException:
        country = ""
    digits = e164.lstrip("+")
    national = digits[len(country):] if country and digits.startswith(country) else digits
    hidden = max(len(national) - 4, 0)
    return f"+{country} {'•' * hidden}{national[-4:]}" if country else f"{'•' * hidden}{national[-4:]}"


def prepare_recipients(body: WhatsAppConfigIn) -> list[dict[str, Any]]:
    """Validate and normalise a save request before the database sees it.

    The database repeats every check; this gives the field-level position of
    the first bad number to the UI."""

    if len(body.recipients) > MAX_RECIPIENTS:
        raise WhatsAppConfigError("whatsapp_too_many_recipients")
    prepared: list[dict[str, Any]] = []
    seen: set[str] = set()
    for index, recipient in enumerate(body.recipients):
        phone = normalize_phone(recipient.phone, index)
        if phone in seen:
            raise WhatsAppConfigError("whatsapp_duplicate_phone", index)
        seen.add(phone)
        prepared.append(
            {
                "recipient_id": str(recipient.recipient_id) if recipient.recipient_id else None,
                "phone": phone,
                "opt_in_confirmed": recipient.opt_in_confirmed,
            }
        )
    if body.enabled and not prepared:
        raise WhatsAppConfigError("whatsapp_recipients_required")
    return prepared


# ---------------------------------------------------------------------------
# Data access
# ---------------------------------------------------------------------------

async def _execute(sql: str, params: tuple[Any, ...], *, commit: bool) -> list[dict[str, Any]]:
    from src.database import database_connection

    try:
        async with database_connection() as connection:
            try:
                async with connection.cursor() as cursor:
                    await cursor.execute(sql, params)
                    rows = await cursor.fetchall() if cursor.description else []
                if commit:
                    await connection.commit()
                else:
                    await connection.rollback()
            except BaseException:
                await connection.rollback()
                raise
    except psycopg.Error as exc:
        # PostgreSQL details can echo row values (numbers): log the SQLSTATE
        # only and drop the cause from the traceback.
        logger.error("WhatsApp configuration database call failed (sqlstate=%s)", exc.sqlstate)
        raise RuntimeError(f"WhatsApp configuration database call failed (sqlstate={exc.sqlstate})") from None
    return rows


def _build(rule_id: UUID, row: dict[str, Any]) -> WhatsAppConfigOut:
    recipients = []
    for item in row["recipients"] or []:
        recipients.append(
            RecipientOut(
                recipient_id=item["recipient_id"],
                phone_e164=item["phone_e164"],
                phone_masked=mask_phone(item["phone_e164"]),
                consent=ConsentOut(
                    state=item["consent_state"],
                    confirmed_at=item["consent_confirmed_at"],
                    confirmed_by_name=item["consent_confirmed_by_name"],
                    statement_version=item["consent_statement_version"],
                    business_name=item.get("consent_business_name"),
                ),
            )
        )
    statement = row.get("consent_statement")
    shown: ConsentStatementOut | None = None
    reason: str | None = None
    if not statement:
        reason = "statement_missing"
    elif statement.get("unavailable_reason") or not statement.get("text"):
        reason = statement.get("unavailable_reason") or "business_name_missing"
    else:
        shown = ConsentStatementOut(
            version=statement["version"], text=statement["text"], business_name=statement["business_name"]
        )
    return WhatsAppConfigOut(
        rule_id=rule_id, enabled=bool(row["enabled"]), revision=int(row["revision"]), recipients=recipients,
        consent_statement=shown, consent_unavailable_reason=reason,
    )


async def fetch_config(portal_user_id: int, rule_id: UUID) -> WhatsAppConfigOut:
    rows = await _execute(
        "SELECT result, enabled, revision, recipients, consent_statement "
        "FROM analytics.get_portal_alert_rule_whatsapp(%s, %s)",
        (portal_user_id, rule_id),
        commit=False,
    )
    row = rows[0] if rows else {"result": "not_found"}
    if row["result"] != "ok":
        raise WhatsAppConfigError(row["result"])
    return _build(rule_id, row)


async def save_config(portal_user_id: int, rule_id: UUID, body: WhatsAppConfigIn) -> int:
    recipients = prepare_recipients(body)
    rows = await _execute(
        "SELECT result, revision FROM analytics.save_portal_alert_rule_whatsapp(%s, %s, %s, %s, %s, %s, %s)",
        (portal_user_id, rule_id, body.enabled, Jsonb(recipients), body.revision, body.consent_statement_version,
         body.consent_business_name),
        commit=True,
    )
    row = rows[0] if rows else {"result": "not_found"}
    if row["result"] != "ok":
        raise WhatsAppConfigError(row["result"])
    return int(row["revision"])


async def fetch_summaries(portal_user_id: int, site_id: UUID) -> dict[UUID, WhatsAppRuleSummary] | None:
    """Per-rule summaries for a site, or None when the caller may not see them
    (not a configurer, an automation account, or no site access) -- D16."""

    rows = await _execute(
        "SELECT result, rule_id, enabled, recipient_count "
        "FROM analytics.get_portal_alert_rule_whatsapp_summaries(%s, %s)",
        (portal_user_id, site_id),
        commit=False,
    )
    if any(r["result"] != "ok" for r in rows):
        return None
    return {
        r["rule_id"]: WhatsAppRuleSummary(enabled=bool(r["enabled"]), recipient_count=int(r["recipient_count"]))
        for r in rows
    }
