# ADR-026: WhatsApp notifications for alert rules — separate notification configuration, transactional outbox and a sender worker

Status: **Proposed** (raised 2026-11-23; Product Owner decisions D1–D13
agreed 2026-11-23). **Remains Proposed** until provider validation,
privacy/legal review and the required infrastructure approvals are complete
(D13). Nothing is implemented or authorised. Phase 1 (staging-only
configuration, sends nothing) is planned in
[phase-1-plan.md](../../07-features/alerts/whatsapp-notifications/phase-1-plan.md)
and needs separate authorisation.
Date: 2026-11-23
Decision owners: Product Owner (D1–D13); Architecture (A1–A8)
Source: [PRD Draft 0.1](../../07-features/alerts/whatsapp-notifications/prd-draft-0.1.md)
(verbatim) and its [dated addendum](../../07-features/alerts/whatsapp-notifications/prd-draft-0.1-addendum-2026-11-23.md);
decisions, assumptions, open questions and approvals:
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

### Architecture (proposed)

- **A1. Three separate concepts.** (1) Alert definition and operational
  lifecycle — ADR-024, unchanged; (2) WhatsApp notification configuration
  — new tables keyed by the stable `rule_id`
  (`alert_rule_whatsapp_settings`, `alert_rule_whatsapp_recipients` with
  per-number consent), never read by the evaluator; (3) WhatsApp delivery
  records — Phase 2 (`alert_whatsapp_deliveries` + outbox). Concept 2 is
  written only by new SECURITY DEFINER functions that re-check
  `alert.configure` and site access and write one `admin.audit_events` row
  (masked numbers only) in the same transaction (ADR-024 §14–§16).
- **A2. Neutralise the legacy flag.** `whatsapp_requested` is retired:
  forced `false` (CHECK), removed from the rule-change comparison, ignored
  on input, still reported as `COMING_SOON` for older clients (D5, D6).
- **A3. Transactional outbox (Phase 2).** When `evaluate_alert_rules`
  creates an Active occurrence for a rule with WhatsApp enabled, it inserts
  one outbox row per consented, not-opted-out recipient in the same
  transaction, snapshotting the message values; unique (occurrence,
  recipient) gives idempotency (D7, AC-15). Needs approval (D12).
- **A4. Sender worker (Phase 2).** A separate Python service
  (report-worker pattern): leased claims, one provider request per
  recipient, retries with backoff inside the 60-minute duplicate window
  (D7), permanent failures recorded; one recipient's failure never affects
  another; heartbeat and outbox age monitored. Needs approval (D12).
- **A5. Delivery receipts (Phase 2).** Public endpoint verifying the
  provider signature; maps provider statuses to Pending / Submitted / Sent
  / Delivered / Failed / Suppressed; STOP replies set the recipient
  `OPTED_OUT` (D4). Needs approval and security review (D12).
- **A6. Secrets.** Provider token and receipt secret only in a server-side
  env file for the worker/endpoint; never browser, Grafana, repository or
  logs (D12).
- **A7. Customer API.** `GET`/`PUT /api/v1/alert-rules/{rule_id}/whatsapp`
  (`alert.configure`, same-origin JSON, revision-checked), a no-numbers
  summary in rule responses; functions granted to `ems_app` and, guarded,
  `ems_customer_api` (Phase 1 plan §3–§4).
- **A8. Environments.** WhatsApp migrations staging/test-scoped; production
  only after ADR-024 is in production and accepted (D11) and this ADR is
  Decided (D13).

## Open questions and approvals (block Decided status)

Open questions Q-1 (repeat occurrences of a flapping rule — D7 covers only
the same occurrence), Q-2 (recipient cap), Q-3 (masked history for
Operators/Viewers), Q-4 (real numbers before Phase 2), Q-5 (per-site cap),
Q-6 (legal review scope), Q-7 (retire the old checkbox). Approvals: provider
validation, legal review, the D12 infrastructure items, and per-phase
implementation and deployment authorisations — see the README §4–§5.

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
