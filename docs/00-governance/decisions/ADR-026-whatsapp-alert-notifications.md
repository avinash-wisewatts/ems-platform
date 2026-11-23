# ADR-026: WhatsApp notifications for alert rules — per-rule recipients, transactional outbox and a notification worker

Status: **Proposed** (2026-11-23). Not decided, not implemented, nothing
authorised. Raised from the Product Owner's PRD Draft 0.1
([prd-draft-0.1.md](../../07-features/alerts/whatsapp-notifications/prd-draft-0.1.md));
the intake review with the conflicts C1–C16 is
[whatsapp-notifications/README.md](../../07-features/alerts/whatsapp-notifications/README.md).
Becomes Decided only after the Product Owner answers the open decisions
listed below and a provider is selected.
Date: 2026-11-23
Decision owners: Product Owner (product decisions P1–P8); Architecture (A1–A8)
Related requirements: `EMS-REQ-084`, `EMS-REQ-145`, `EMS-REQ-146`
Would amend: [ADR-024](ADR-024-customer-configurable-alert-rules.md) §8
(notification settings are not a configuration change), §9 (WhatsApp is no
longer "Coming Soon" once delivery is live), §10 (no WhatsApp reminders in
release 1).

## Context

ADR-024 (on staging since 2026-11-18, not on production) gave customer site
administrators and WiseWatts `GLOBAL` `ADMIN` staff an audited write path for
alert rules in the EMS Web App, and stored Email/WhatsApp only as
"Coming Soon" preferences (`alert_rules.whatsapp_requested`) — nothing is
sent. The Product Owner now wants real WhatsApp delivery to several
individual phone numbers per rule (PRD Draft 0.1).

Facts this proposal builds on (`origin/staging` `458c179`, 2026-11-23):

- The evaluator is a TimescaleDB job, `analytics.run_alert_rule_evaluation_job`
  → `analytics.evaluate_alert_rules` (migration 325), inside PostgreSQL;
  one Active occurrence per rule (`analytics.alerts`).
- `analytics.update_portal_alert_rule` (migration 323) ends the Active
  occurrence (`CONFIGURATION_CHANGED`) and bumps the rule version on any
  field change, including `whatsapp_requested`.
- `alert.configure` exists (`ADMIN` only); writes follow ADR-024 §14–§16.
- Precedent for a background Python worker with leased claims, retries and
  a heartbeat: `ems-report-worker` (ADR-025).
- No portal-user phone field exists; no phone library is pinned;
  `httpx` is available.
- Staging (read-only): 2 live rules, 0 with WhatsApp requested.

## Proposed decision

### Product (for Product Owner decision)

- **P1. Scope.** Every alert rule may enable WhatsApp, per rule, default
  off. Email remains "Coming Soon".
- **P2. Recipients.** 1–10 E.164 phone numbers per rule when enabled, no
  duplicates; entered directly (no contact directory in release 1).
- **P3. Who.** `alert.configure` holders (customer site `ADMIN`, `GLOBAL`
  `ADMIN`) configure and see full numbers; other roles see only whether
  WhatsApp is on, the recipient count and masked delivery history.
- **P4. Consent.** The configuring administrator confirms, per number,
  that the recipient opted in (recorded who/when, audited); a recipient's
  opt-out (STOP) deactivates that number. Legal review of DPDP Act 2023
  obligations before Phase 2.
- **P5. Events.** One message when an occurrence becomes Active. No
  message for Resolved (revisit), Ended, or data-unavailable. No reminders
  in release 1; the stored reminder frequency stays labelled as not sent.
- **P6. Repeats.** A re-trigger of the same rule within 60 minutes of its
  previous message is recorded as suppressed, not sent; per-site hourly
  cap, exceeded sends recorded as suppressed.
- **P7. Content.** Utility template: rule name, site, asset, parameter,
  value at trigger and threshold (with unit; ± tolerance for "equal to"),
  triggered time in the site timezone, link to the occurrence (sign-in
  required, no token).
- **P8. Retention.** Delivery records live as long as their occurrence
  (90 days after Resolved/Ended); history shows masked numbers; full
  numbers of removed recipients are erased once unreferenced.

### Architecture (proposed)

- **A1. Notification settings are separate from the rule's condition.**
  New tables for per-rule WhatsApp settings and recipients, written only by
  new SECURITY DEFINER functions that re-check `alert.configure` and site
  access and write `admin.audit_events` in the same transaction (ADR-024
  §14–§16; numbers redacted to masked form in audit values). Saving them
  never ends an occurrence or bumps the rule version (amends ADR-024 §8
  for these fields). `whatsapp_requested` is retired; no existing value
  activates delivery.
- **A2. Transactional outbox.** When `evaluate_alert_rules` creates an
  Active occurrence for a rule with WhatsApp enabled, it inserts one outbox
  row per active recipient in the same transaction, snapshotting the
  message values. Unique (occurrence, recipient, event) makes reprocessing
  idempotent.
- **A3. Notification worker.** A separate Python service (report-worker
  pattern) claims due rows with a lease, sends one provider request per
  recipient, records provider message id/status, retries transient failures
  with backoff up to a cap, and marks permanent failures; one recipient's
  failure never affects another. Heartbeat and outbox age are checked by
  the deployment verification suite.
- **A4. Delivery callbacks.** A webhook endpoint verifies the provider
  signature, maps provider statuses to Pending / Submitted / Sent /
  Delivered / Failed (and Suppressed), and handles opt-out replies. It is a
  new internet-facing endpoint and needs its own security review.
- **A5. Secrets.** Provider token and webhook secret live only in a
  server-side env file read by the worker and webhook; never in the
  browser, Grafana, the repository or logs.
- **A6. Customer API.** Endpoints for reading and saving a rule's
  notification settings and reading an occurrence's delivery history, under
  `/api/v1`, same-origin JSON, `alert.configure` for writes and reads of
  full numbers; functions granted to `ems_app` and (guarded) to
  `ems_customer_api`.
- **A7. Environment.** Migrations staging/test-scoped until production is
  approved; production only after ADR-024 is on production.
- **A8. Infrastructure.** Outbound HTTPS to the provider, the worker
  container and the public webhook route are each separately authorised
  operational changes.

## Open decisions (block Decided status)

PRD §15 items 1–8 and this review's C2, C3, C6, C7, C14, C15 — see the
intake review §3. Provider selection is the critical path.

## Alternatives considered

- **Keep the flag on the rule and treat changes as rule edits** — rejected:
  editing recipients during an incident would end and re-trigger the alert
  (duplicate messages).
- **Send from the database (HTTP extension / job)** — rejected: outbound
  calls inside the evaluator transaction couple alerting to provider
  latency and outages and put secrets in the database.
- **Send from the API process** — rejected: delivery must not depend on a
  user request and needs leases, retries and a heartbeat.
- **Contact directory first** — deferred by the PRD; the recipient table is
  kept separate from the rule so a directory can replace direct entry later.

## Consequences

- ADR-024 gets Amendment 2 when this is decided (§8, §9, §10 as above).
- `EMS-REQ-084` moves from LATER (WhatsApp part) when decided; new
  requirements are added then.
- New operational surface: a worker, a public webhook, a third-party
  dependency and personal data (phone numbers) under retention rules.
