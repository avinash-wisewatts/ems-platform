# ADR-026: WhatsApp notifications for alert rules — separate notification configuration, transactional outbox and a sender worker

Status: **Proposed** (raised 2026-11-23; Product Owner decisions D1–D21
agreed 2026-11-23). **Remains Proposed** until provider validation,
privacy/legal review and the required infrastructure approvals are complete
(D13). Nothing is implemented or authorised. Phase 1 (staging-only
configuration, sends nothing) is planned in
[phase-1-plan.md](../../07-features/alerts/whatsapp-notifications/phase-1-plan.md)
and needs separate authorisation.
Date: 2026-11-23
Decision owners: Product Owner (D1–D21); Architecture (A1–A8); privacy/legal (L-1–L-3, open)
Source: [PRD Draft 0.1](../../07-features/alerts/whatsapp-notifications/prd-draft-0.1.md)
(verbatim) and its [dated addendum](../../07-features/alerts/whatsapp-notifications/prd-draft-0.1-addendum-2026-11-23.md);
decisions, assumptions, open legal/provider questions and approval gates:
[whatsapp-notifications/README.md](../../07-features/alerts/whatsapp-notifications/README.md).
Related requirements: `EMS-REQ-084`, `EMS-REQ-145`, `EMS-REQ-146`
Would amend (when Decided): [ADR-024](ADR-024-customer-configurable-alert-rules.md)
§8 (WhatsApp settings are not a configuration change), §9 (WhatsApp is no
longer "Coming Soon" once delivery is live; Email unchanged), §10 (no
WhatsApp reminders).

## Context

ADR-024 (on staging since 2026-11-18, not on production) lets customer site
administrators and WiseWatts `GLOBAL` `ADMIN` staff manage alert rules in
the EMS Web App through an audited write path, and stores Email/WhatsApp
only as "Coming Soon" preferences — nothing is sent. The Product Owner now
wants WhatsApp delivery to several individual numbers per rule.

Facts (`origin/staging` `458c179`; staging read-only 2026-11-23):

- The evaluator is a TimescaleDB job inside PostgreSQL
  (`run_alert_rule_evaluation_job` → `evaluate_alert_rules`, migrations
  325/327); timers live in `alert_evaluation_candidates`; one Active
  occurrence per rule.
- `update_portal_alert_rule` (migration 323) ends the Active occurrence
  and bumps the rule version on **any** change, including
  `whatsapp_requested`; the API's `delivery.whatsapp` input defaults to
  `false`, so a form that stops sending it would end alerts.
- `alert.configure` (`ADMIN` only) and the ADR-024 §14–§16 write pattern
  exist; `admin.audit_events` has an `actor_type` column.
- Staging: 13 rule rows, 0 with `whatsapp_requested`; production has no
  rules.
- Background-worker precedent: `ems-report-worker` (ADR-025).

## Decision

### Product decisions — agreed (Product Owner, 2026-11-23)

D1 Meta WhatsApp Business Cloud API preferred, subject to validation; no
integration commitment. D2 Individual numbers only; no groups. D3
Configured per alert rule in EMS → Alerts; multiple numbers; Site Admins
on authorised sites, WiseWatts Global Site Admins on all sites. D4
Explicit administrator opt-in confirmation per number; STOP opt-out
subject to provider capability and legal review; no OTP initially. D5 Off
by default; the "Coming Soon" checkbox never activates sending. D6
WhatsApp settings stored separately; saving them never ends an Active
occurrence, resets a timer or re-triggers. D7 One message per occurrence
and recipient; duplicates for the same occurrence/recipient suppressed
within 60 minutes; no reminders or recovery messages initially. D8
WiseWatts Product owns wording and templates. D9 Server-side tenant/site/
role enforcement; consent and configuration changes audited; numbers
masked in delivery history; full numbers only to admins managing
configuration; Operators and Viewers never see numbers. D10 Delivery
history 90 days initially; numbers kept while configured, deletion per
legal obligations. D11 No rollout before ADR-024 completes production
rollout and acceptance. D12 Queue, sender, public signature-checked
receipt endpoint, outbound internet access and provider secrets each need
separate explicit approval. D13 This ADR stays Proposed until provider
validation, legal review and infrastructure approvals are complete.

D14 60-minute quiet period per rule and recipient across separate
occurrences, in addition to D7. D15 At most 10 numbers per rule. D16
Operators and Viewers see no recipient information in Phase 1 (no numbers,
count or indicator); masked delivery history reconsidered when delivery
records exist. D17 Staging uses WiseWatts-controlled test numbers only; no
real customer numbers before sending exists. D18 Per-site message cap
deferred to Phase 2. D19 Legal sufficiency of administrator opt-in and
permitted audit content/retention stay open for legal review; compliance is
not assumed. D20 The old "Coming Soon" WhatsApp checkbox is removed in
Phase 1, behind the migration safeguard and regression tests. D21 Product
defines and approves the exact opt-in wording before it is used.

### Architecture (proposed)

- **A1. Three separate concepts.** (1) Alert definition and operational
  lifecycle — ADR-024, unchanged; (2) WhatsApp notification configuration
  — new tables keyed by the stable `rule_id`
  (`alert_rule_whatsapp_settings`, `alert_rule_whatsapp_recipients` with
  per-number consent), never read by the evaluator; (3) WhatsApp delivery
  records — Phase 2 (`alert_whatsapp_deliveries` + outbox). Concept 2 is
  written only by new SECURITY DEFINER functions that re-check
  `alert.configure` and site access and write one `admin.audit_events` row
  in the same transaction (ADR-024 §14–§16), holding recipient ids, not
  phone numbers (proposed R12, pending L-2). Phase 1 configuration
  behaviour is governed by the proposed ADR-024 Amendment 2.
- **A2. Neutralise the legacy flag.** `whatsapp_requested` is retired:
  forced `false` (CHECK), removed from the rule-change comparison, ignored
  on input, still reported as `COMING_SOON` for older clients (D5, D6).
- **A3. Transactional outbox (Phase 2).** When `evaluate_alert_rules`
  creates an Active occurrence for a rule with WhatsApp enabled, it inserts
  one outbox row per consented, not-opted-out recipient outside the D14
  quiet period in the same transaction, snapshotting the message values; unique (occurrence,
  recipient) gives idempotency (D7, AC-15). Needs approval (D12).
- **A4. Sender worker (Phase 2).** A separate Python service
  (report-worker pattern): leased claims, one provider request per
  recipient, retries with backoff inside the 60-minute duplicate window
  (D7), permanent failures recorded; one recipient's failure never affects
  another; heartbeat and outbox age monitored. Needs approval (D12).
- **A5. Delivery receipts (Phase 2).** Public endpoint verifying the
  provider signature; maps provider statuses to Pending / Submitted / Sent
  / Delivered / Failed / Suppressed; STOP replies set the recipient
  `OPTED_OUT` (D4, subject to P-3 and legal review). Needs approval and
  security review (D12).
- **A6. Secrets.** Provider token and receipt secret only in a server-side
  env file for the worker/endpoint; never browser, Grafana, repository or
  logs (D12).
- **A7. Customer API.** `GET`/`PUT /api/v1/alert-rules/{rule_id}/whatsapp`
  (`alert.configure`, same-origin JSON, revision-checked, at most 10
  recipients), a no-numbers summary in rule responses **for
  `alert.configure` holders only** (`null` for other roles, D16); functions granted to `ems_app` and, guarded,
  `ems_customer_api` (Phase 1 plan §3–§4).
- **A8. Environments.** WhatsApp migrations staging/test-scoped; production
  only after ADR-024 is in production and accepted (D11) and this ADR is
  Decided (D13).

## Open questions and approvals (block Decided status)

Product questions are closed (D14–D21). Still open — **not product
decisions, and not assumed**: legal L-1 (sufficiency of administrator
opt-in), L-2 (permitted audit content and retention), L-3 (deletion
obligations); provider P-1 (Meta account, templates, pricing, limits), P-2
(receipt semantics and signatures), P-3 (STOP support), P-4 (template
variable limits). Approval gates — Phase 1: implementation, then merge,
staging deployment and staging test saves, each separately, plus the
Product-approved opt-in wording (D21); Phase 2: provider validation, legal
review, and each D12 infrastructure item separately; production: ADR-024
production rollout and acceptance (D11) and this ADR Decided (D13). See the
README §4–§5.

**Review 2026-11-23** ([review record](../../07-features/alerts/whatsapp-notifications/review-2026-11-23.md)):
blocker B1 — Phase 1 changes ADR-024 §8–§9 and `EMS-REQ-146` (D6, D20) while
this ADR is Proposed, so Phase 1 needs its own authorising record:
recommended, a Decided ADR-024 Amendment 2 scoped to D5, D6, D16, D17 and D20,
leaving delivery here. Open architecture item R5: whether designated
automation accounts are excluded from the WhatsApp functions. This ADR
remains **Proposed**.

## Alternatives considered

- **Keep WhatsApp on the rule as a rule field** — rejected (D6): editing
  recipients during an incident would end and re-trigger the alert.
- **Send from the database** (HTTP extension / job) — rejected: couples
  the evaluator transaction to provider latency/outages and puts secrets in
  the database.
- **Send from the API process** — rejected: delivery must not depend on a
  user request and needs leases, retries and a heartbeat.
- **Contact directory first** — deferred (PRD §3.3); recipients are kept
  outside the rule so a directory can replace direct entry later.

## Consequences

- When Decided: ADR-024 Amendment 2 (§8, §9, §10); `EMS-REQ-084`
  (WhatsApp part) leaves LATER and new requirement IDs are allocated.
- New operational surface in Phase 2: a worker, a public endpoint, a
  third-party dependency, and personal data under retention rules.
- Staging and production definitions of the rule write functions will
  differ while migration 331 is staging/test-only; production receives
  them only with the WhatsApp production release (D11).
