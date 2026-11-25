# WhatsApp alert notifications — Legal review package

Prepared 2026-11-24 for privacy/legal review. Status: **review requested;
nothing here is Legal advice or a Legal decision.** It records what the
system does today, what the Product Owner has decided, and the questions
only Legal can answer (L-1 to L-3, R10, R12, and the R9/D21 conditions).

## 1. What Legal is asked to do

1. Review the approved opt-in wording `WA-OPTIN-1` for sufficiency (L-1),
   and either sign it off or return the required changes. A change becomes
   a new wording version; approved text is never edited.
2. Answer the questions in §5 (consent), §6 (privacy and audit) and §7
   (retention and deletion).
3. Record the outcome in the Legal column of
   [consent-wording-register.md](consent-wording-register.md), and in the
   L-1 to L-3 rows of [README.md §4](README.md). An approval of the wording
   is then recorded in the database by a separately approved migration
   (`legal_review_status = 'APPROVED'`, with reviewer and date). **Until
   then, no administrator can add a number on staging.**

**Timing.** None of these answers blocks the current staging configuration,
which uses WiseWatts-controlled test numbers only and sends nothing. They do
block Phase 2 (sending), ADR-026 becoming Decided, and any production
release (README §5).

## 2. Decisions already made (Product Owner, 2026-11-24)

| ID | Decision | Legal input still needed |
|---|---|---|
| R9 | The **customer business is the alert originator**; WiseWatts is the technology and delivery platform. The wording names the customer by its approved legal or trading name. | Whether this matches the parties' roles under the DPDP Act 2023 (who is the Data Fiduciary and who the Data Processor), and the contract terms that follow (§5, Q-C7) |
| D21 | Wording `WA-OPTIN-1` approved, **subject to Legal review**. Explicit individual recipient consent is mandatory. Operational notifications only; no marketing. | Sufficiency of the wording and of administrator attestation (§5) |
| D17 | On staging, only WiseWatts-controlled test numbers are entered. No real customer numbers are collected before sending exists. | None (procedural control) |
| D19 | Legal sufficiency of consent, audit content and retention stay open. Compliance is not assumed. | All of §5 to §7 |

The approved wording, as stored (`{business_name}` is filled in per customer):

> I confirm that this person has explicitly agreed to receive operational
> alert notifications from {business_name} on WhatsApp at this number. These
> messages are delivered by WiseWatts as {business_name}'s technology
> platform. No marketing messages will be sent.

## 3. What the system does today (facts for the review)

**Phase 1 is configuration only.** No WhatsApp message can be sent: there is
no provider account, sender, queue or delivery-receipt endpoint, and the API
always reports `messages_active: false`. It runs on staging only.

| Topic | As built (migrations 331 and 332) |
|---|---|
| Who adds numbers | Customer site administrators and WiseWatts admin staff (`alert.configure`), per alert rule, up to 10 numbers per rule |
| How consent is captured | **Administrator attestation**: for each new or changed number, the administrator ticks a confirmation showing the full wording with the customer's name. The recipient is not contacted, and receives no notice or confirmation message in Phase 1 |
| Consent record per number | Wording version, the exact business name shown, the confirming user and the time. Staff confirmers are shown to customers as "WiseWatts Support" |
| No wording, no legal name, or Legal review pending | New numbers are refused. Nothing is saved without the full wording having been shown, and none is saved before Legal approves the wording. That is the state after migration 332: opt-ins are closed |
| Who can see numbers | Only `alert.configure` holders for that site. Operators and Viewers see nothing about WhatsApp (D16). No database role can read the tables directly |
| Opt-out | **None in Phase 1.** Recipients cannot opt out themselves until STOP handling exists (Phase 2, R10). An administrator can remove a number at any time |
| Audit log | One `admin.audit_events` row per effective change, holding recipient ids, consent metadata and the business name, **never a phone number, full or masked** (R12 default). The audit log is permanent today |
| Retention while switched off | Numbers are kept while WhatsApp is switched off for a rule (R7 / A-9), until they are removed or the rule is deleted |
| Removal | Removing a number, or deleting the rule, deletes the stored number immediately (hard delete). Audit rows remain, with ids only |
| Rollback | The documented rollback scripts delete every stored number |
| Data location | Application database on WiseWatts-managed servers. Phase 2 would send numbers and message content to Meta's WhatsApp Cloud API (P-1) |

## 4. Facts Legal should know about Phase 2 (not built)

Phase 2 would add a delivery queue, a sender, delivery receipts from the
provider, and **inbound STOP handling**. Receiving STOP means receiving
recipients' message text (R10; the plan proposes keyword-only processing,
with the text discarded). Delivery records (number, status, time) would be
new personal data with their own retention. Each infrastructure item needs
separate approval.

## 5. Consent sufficiency (L-1)

- **Q-C1. Administrator attestation.** Is attestation by the customer's
  administrator ("this person has explicitly agreed") sufficient evidence of
  the recipient's consent under the DPDP Act 2023 and Meta's WhatsApp
  Business opt-in policy? Or must the recipient opt in directly, for example
  by replying to a confirmation message, before the first alert?
- **Q-C2. Wording.** Does `WA-OPTIN-1` meet the requirements for the consent
  it evidences: naming the business, the WhatsApp channel, the purpose
  (operational alerts) and the absence of marketing? Must it also cover
  withdrawal, message frequency or charges?
- **Q-C3. Notice to the recipient.** Must the recipient receive a notice, at
  or before the first message, covering the purpose, the data held, how to
  withdraw and how to complain? Who gives it, the customer or WiseWatts, and
  in what form and language?
- **Q-C4. Withdrawal before STOP exists.** Phase 1 has no self-service
  opt-out. Is removal by an administrator on request enough until Phase 2,
  given that nothing is sent in Phase 1?
- **Q-C5. Records.** Are the stored consent records (version, business
  name, confirming user, time) sufficient? Must we also keep evidence of the
  recipient's own agreement, for example a document or message reference?
- **Q-C6. Business name.** R9 uses the customer's recorded legal name. Is a
  trading name acceptable where it differs, and who confirms that the
  recorded name is the "approved" one?
- **Q-C7. Roles and contracts.** With the customer as originator (R9), is
  the customer the Data Fiduciary and WiseWatts its Data Processor? Do the
  customer agreements need data-processing terms covering WhatsApp numbers,
  and Meta as a sub-processor?
- **Q-C8. Transfer.** Phase 2 sends numbers and alert content to Meta. Are
  there restrictions or conditions on that transfer?

## 6. Privacy and audit content (L-2, R12)

- **Q-P1.** May the permanent audit log hold recipient ids, consent
  metadata and the business name (today's content)? Is a recipient id
  personal data when the number it pointed to has been deleted?
- **Q-P2.** May the audit log hold a masked number (country code plus last
  four digits), a keyed hash, or the full number? R12 keeps all of these out
  until Legal decides. The masked format may still be personal data.
- **Q-P3.** Should `admin.audit_events` entries about recipients have a
  retention limit, given that the log is permanent today?
- **Q-P4.** Phase 2 (R10): may inbound message text be processed for the
  STOP keyword only and then discarded, keeping only the opt-out record?

## 7. Retention and deletion (L-3, R7 / A-9)

- **Q-R1.** May numbers be kept while WhatsApp is switched off for a rule
  (R7 / A-9, confirmed by Product), or must they be deleted after a period
  of inactivity?
- **Q-R2.** After an opt-out (Phase 2), must the number be deleted, or kept
  on a suppression list so that it is not messaged again? For how long?
- **Q-R3.** What is the retention period for Phase 2 delivery records?
- **Q-R4.** When a customer relationship ends, must its recipients' numbers
  be deleted, and within what time?
- **Q-R5.** Database backups can retain deleted numbers until the backups
  expire. Is a statement of backup retention enough, or is more required?
- **Q-R6.** How are a recipient's own requests (access, correction,
  erasure) to be received and handled, given that WiseWatts holds the
  number for the customer?

## 8. Engineering commitments while Legal reviews

- Nothing is sent, and `messages_active` stays false.
- Only WiseWatts-controlled test numbers are used on staging (D17).
- No phone number appears in the audit log, application logs or error
  messages (R12 default; tested).
- A Legal change to the wording becomes a new version through a separately
  approved migration. Existing consents keep their recorded version.
- Phase 2 and production releases wait for Legal's answers (README §5).
