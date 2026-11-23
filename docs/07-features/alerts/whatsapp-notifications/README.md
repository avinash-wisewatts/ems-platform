# Alerts → WhatsApp notifications — PRD intake review

Status: **PROPOSED — not decided, not authorised.** Intake of the Product
Owner's PRD Draft 0.1 (received 2026-11-23). No database, API, UI,
infrastructure or production change is authorised (PRD §16). Owner: Product +
Engineering. Last reviewed: 2026-11-23.

- Source record: [prd-draft-0.1.md](prd-draft-0.1.md) (verbatim).
- Proposed architecture decision: [ADR-026](../../../00-governance/decisions/ADR-026-whatsapp-alert-notifications.md) (Proposed).
- Builds on: [ADR-024](../../../00-governance/decisions/ADR-024-customer-configurable-alert-rules.md)
  (customer alert rules — on staging since 2026-11-18, **not on production**),
  [ADR-017](../../../00-governance/decisions/ADR-017-mvp7-alert-architecture.md)
  (evaluator as a TimescaleDB job), [ADR-025](../../../00-governance/decisions/ADR-025-site-energy-performance-reports.md)
  (the report-worker precedent for a background Python worker).
- Requirements: `EMS-REQ-084` (multi-channel notification, LATER), `EMS-REQ-145`
  (reminder frequency), `EMS-REQ-146` (delivery options "Coming Soon").

Evidence for this review: repository `origin/staging` `458c179` and read-only
staging queries on 2026-11-23 (cited inline).

## 1. How the PRD maps onto what exists

| PRD term | Current model (ADR-024, migrations 320–327) |
|---|---|
| "Alert" / "individual alert" (e.g. *Maximum Demand Exceeded*) | An **alert rule** (`analytics.alert_rules`): one site, one asset, one parameter, a condition, a schedule; customer-named. At most 25 active rules per site. |
| "A triggered alert" | A rule's **occurrence** (`analytics.alerts`) becoming **Active** after 5 minutes of the condition holding. One Active occurrence per rule at a time. |
| "Alert engine" | `analytics.run_alert_rule_evaluation_job`, a TimescaleDB job running **inside PostgreSQL** once a minute (migration 325). |
| "Site Admin" | Customer `ADMIN` whose ORGANIZATION / SELECTED_SITES scope covers the site. Holds `alert.configure`. |
| "WiseWatts Global Site Admin" | `GLOBAL`-scope `ADMIN` (WiseWatts staff, ADR-023 decision 4). Holds `alert.configure` on every site. |
| "Authorised backend write path" (PRD §8.2, open decision 7) | **Already decided and built** by ADR-024 §14–§16: same-origin JSON to `/api/v1`, a route-level dedicated permission, SECURITY DEFINER write functions that re-check permission and site access, and an `admin.audit_events` row in the same transaction. |
| "Enable WhatsApp Notifications" checkbox | Today `alert_rules.whatsapp_requested` — a stored **"Coming Soon" preference only**; nothing is ever sent (ADR-024 §9). |

So the PRD's role model, location and write-path requirements are already
met by ADR-024. What is new is **real outbound delivery**, **recipient phone
numbers (personal data)**, and **delivery records**.

## 2. Conflicts and gaps found

Each item states what conflicts, where, and the proposed resolution. The
resolutions are proposals for decision ([ADR-026](../../../00-governance/decisions/ADR-026-whatsapp-alert-notifications.md)), not decisions.

**C1 — ADR-024 §9 forbids sending.** ADR-024 §9, `EMS-REQ-125` and
`EMS-REQ-146` say no email or WhatsApp message is sent, there is no outbound
integration, and the UI must show no delivery status. The rule form says
"Email, WhatsApp and reminders are not sent yet"
(`web/src/routes/alerts/AlertRuleForm.tsx`). *Proposal:* when the PRD is
approved, ADR-026 amends ADR-024 §9 for WhatsApp only. Email stays
"Coming Soon".

**C2 — Changing WhatsApp settings would end the Active alert.** Under
ADR-024 §8, `analytics.update_portal_alert_rule` (migration 323) treats
**any** change as a configuration change, including `whatsapp_requested`:
- the rule's Active occurrence is ended `CONFIGURATION_CHANGED`;
- the rule version is bumped;
- qualification restarts.

With real delivery, adding a recipient during an incident would end the
alert, and five minutes later the alert could re-trigger and send a second
message. That contradicts the PRD's FR-01 intent (disabling WhatsApp must
not affect the underlying alert) and AC-15 (no uncontrolled duplicates).
*Proposal:*
- Notification configuration becomes its own record with its own audited
  write function.
- It is **not** part of the rule's condition identity.
- Saving it never ends an occurrence or bumps the rule version.
- The WhatsApp flag is removed from the rule-edit comparison.

**C3 — Existing "requested" flags must not start sending.**
`whatsapp_requested = true` today only records interest. It has no
recipients, and nobody consented on the basis of it. *Proposal:*
- These flags never activate delivery; WhatsApp starts disabled for every rule
  (PRD FR-01 default).
- The flag is retired or migrated to "disabled", with the count recorded.
- *Staging (read-only, 2026-11-23):* 2 live rules on 2 sites, **0** with
  WhatsApp requested, 0 with Email requested. Production has no rules
  (ADR-024 is not on production).

**C4 — The PRD's baseline statement is out of date.** PRD §16 says the
customer EMS "primarily consumes configured information" and that alert MVP
delivery includes email. Both are out of date:
- **Alert configuration:** ADR-024 (2026-11-18) moved it into the EMS and
  superseded Q67 for alerts.
- **Email:** removed from MVP by ADR-016 (2026-09-14 note on `EMS-REQ-084`).

*Proposal:* record this in ADR-026. PRD open decision 7 reduces to the API
contract for the new endpoints, using the ADR-024 pattern.

**C5 — Reminders already have a policy.** ADR-024 §10 / `EMS-REQ-145`:
- Rules store a reminder frequency (15 or 30 minutes).
- Reminders repeat while an occurrence is Active and unacknowledged, and stop
  on acknowledgement.
- Today nothing is delivered.

Once WhatsApp exists, the stored reminder values would imply repeat
WhatsApp messages every 15–30 minutes. The PRD lists repeat notifications
as open (open decision 5) and escalation as out of scope. *Proposal:*
- Release 1 sends **one** message per occurrence and **no reminders**.
- The form keeps saying reminders are not sent.
- WhatsApp reminders are a separate later decision.

**C6 — Retention of delivery records and phone numbers.**
- Occurrences are purged 90 days after Resolved/Ended (migration 325). A
  delivery record that references an occurrence must be purged with it, or
  keep its own snapshot.
- Phone numbers are personal data. India's Digital Personal Data Protection
  Act, 2023 requires a purpose, consent and erasure.
- Removing a recipient must stop future sends, but history needs a decision:
  keep a masked number, or delete it.

*Proposal:*
- Delivery records follow the occurrence's 90-day retention.
- History shows masked numbers (last 4 digits).
- Removed recipients are soft-deactivated; their full number is erased when
  the last delivery record referencing them ages out.

To confirm with the PO, and legal review if required.

**C7 — Who may see recipients and delivery history.** The PRD defines only
the two configuring roles. Under ADR-024, Operators and Viewers (customer
and GLOBAL) can see alerts and rules. *Proposal:*
- Full recipient numbers are visible only to holders of `alert.configure`.
- Other roles see "WhatsApp on · N recipients" and a delivery summary with
  masked numbers.
- Needs a PO decision.

**C8 — The evaluator cannot call WhatsApp.** The evaluator runs inside
PostgreSQL (ADR-017), which must not make outbound HTTP calls. *Proposal:*
- **Outbox:** when the evaluator creates an Active occurrence for a rule with
  WhatsApp enabled, it writes one outbox row per active recipient in the
  **same transaction**.
- **Idempotency:** a unique key (occurrence, recipient, event) makes repeat
  processing harmless (PRD AC-15).
- **Notification worker:** a separate Python service claims rows with a
  lease, calls the provider, records the outcome, and retries transient
  failures with a cap. This is the `ems-report-worker` pattern (ADR-025).
- **Callbacks:** a signed webhook endpoint updates delivered/failed status.

**C9 — Infrastructure that doesn't exist yet.** Each of these is a
separate, authorised operational change:
- a new container on a staging host with little headroom (1.9 GB RAM);
- outbound HTTPS from the host to the provider, which is unverified — the
  security-group and network-ACL rules have never been read;
- a **public inbound webhook** for delivery callbacks, a new
  internet-facing endpoint with signature verification;
- a new server-side secret: the provider token and the webhook verify
  secret, in their own env file, never in the browser.

**C10 — Production depends on the ADR-024 release.** ADR-024 is not on
production. Its production release is blocked on backup, precheck, bundle
and approval. Production has no `ems_customer_api` role and no current
database backup. WhatsApp cannot reach production before ADR-024 does.

**C11 — Which value the message shows.** `analytics.alerts.last_value` is
the **latest** value and changes as the occurrence runs; it is not the
value at trigger. *Proposal:* the outbox row snapshots the values at
creation, so a retried message always says the same thing:
- trigger value and unit;
- threshold and tolerance;
- rule name, site name and asset name;
- triggered time in the site timezone.

**C12 — The "Secure EMS Link".** The Alerts area is one route
(`/features/alerts`), and an individual occurrence has no URL yet.
*Proposal:*
- The link is a plain deep link to the occurrence on the customer host. It
  requires normal sign-in and carries no token, session or internal
  database id beyond the occurrence UUID already used by the API.
- The deep link needs a small UI routing change.

**C13 — Template content.** Rule, site and asset names are free text typed
by customers. WhatsApp template variables have length and character limits
(for example, no new lines). *Proposal:* sanitise and truncate variables in
the worker, and use one approved utility template per event type.

**C14 — Events that need explicit decisions:**
- **Resolved:** recovery message? This is PRD open decision 6.
- **Ended `CONFIGURATION_CHANGED`:** proposal — no message.
- **"Unable to evaluate — data unavailable"** (ADR-024 §4A): the occurrence
  stays Active. Proposal — no message.
- **Flapping:** under ADR-024 timing a rule can resolve after 1 minute and
  re-trigger after 5, so a flapping rule could message about every
  6 minutes. That needs a cooldown decision (PRD open decision 5).

**C15 — Limits.** There is no recipients-per-rule cap and no per-site
message cap. *Proposal:* at most 10 recipients per rule, and a per-site
hourly send cap with an operator-visible "suppressed" status. To confirm.

**C16 — Phone validation.** No phone-number library is in
`app/requirements.txt`. *Proposal:*
- Store numbers in E.164.
- Validate server-side with a pinned library, enforced again by a database
  CHECK on the format.
- Allow no duplicates per rule.

## 3. What the PRD needs decided before implementation

PRD §15 open decisions, with this review's recommendation for each (all for
Product Owner decision):

| # | Decision | Recommendation |
|---|---|---|
| 1 | Provider | Choose between the Meta WhatsApp Cloud API direct and an Indian BSP. Validate business verification, the sender number, utility-template approval, India pricing, callbacks and data residency first. **Pick before Phase 2.** |
| 2 | Number verification | Release 1: none in-product. The administrator attests that recipients have opted in (see 3). |
| 3 | Consent | WhatsApp policy requires the business to hold opt-in. Proposal: the administrator records the opt-in confirmation per number (who, when), audited, and the recipient can opt out by replying STOP, which deactivates that number everywhere. Legal review advised (DPDP Act). |
| 4 | Alert scope | Every rule (all are customer-defined); WhatsApp is per-rule opt-in. |
| 5 | Repeat notifications | One message per occurrence; no reminders in release 1; a re-trigger within a cooldown (proposed 60 min) of the previous message for the same rule is recorded as suppressed. |
| 6 | Recovery messages | Release 1: no recovery message (fewer template approvals); revisit. |
| 7 | Write path | Settled by ADR-024 §14–§16 (C4). Only the endpoint contract remains — see ADR-026. |
| 8 | Template governance | WiseWatts Product owns the template text; changes go through ADR-026 amendments; Operations submits the templates to the provider. |

Plus decisions this review adds: C2 (notification config separate from rule
identity), C3 (requested flags never activate), C6 (retention and
masking), C7 (visibility by role), C14 (Ended / unavailable / flapping),
C15 (caps).

## 4. Proposed delivery plan (once decided)

The PRD's phases, adjusted so nothing visible promises delivery before
delivery exists:

1. **Phase 0: decisions.**
   - PO answers §3; the provider is selected; legal/consent review is done.
   - ADR-026 moves to Decided, with ADR-024 Amendment 2 for C1/C2/C5.
2. **Phase 1: configuration.** Staging only.
   - Migration: the notification-config and recipient tables, the audited
     write functions, the read functions, guarded grants, and retiring
     `whatsapp_requested` (C3).
   - API endpoints and the rule-form recipient editor.
   - Saving configuration sends nothing. The UI says delivery is not active
     yet until Phase 2 is live.
3. **Phase 2: delivery.** Staging only, to WiseWatts-owned test numbers
   first.
   - Outbox written by the evaluator, the notification worker, approved
     templates, and the signed webhook.
   - Needs the infrastructure authorisations in C9.
4. **Phase 3: operational readiness.**
   - Delivery history UI, retries, cooldown and caps.
   - Monitoring: worker heartbeat and outbox age in the deployment
     verification suite.
   - Retention, and security tests: tenant isolation, PII masking, webhook
     signature.
5. **Production.** Only after ADR-024 is on production, and with a
   separate approval.

## 5. Acceptance-criteria notes

PRD §11 AC-1 to AC-15 are adopted as written, with these refinements:
- **AC-8:** disabling WhatsApp or editing recipients never ends an Active
  occurrence (C2).
- **AC-9:** applies to occurrences that become Active after WhatsApp was
  enabled; enabling WhatsApp does not message about an alert that is
  already Active.
- **AC-15:** proven by the outbox unique key and a test that replays the
  same occurrence.

Proposed additions:
- **AC-16:** pre-existing "requested" flags send nothing (C3).
- **AC-17:** delivery history shows masked numbers to non-configuring roles (C7).
- **AC-18:** a forged or unsigned callback is rejected (C9).
- **AC-19:** no message is sent for Ended or data-unavailable states (C14).
