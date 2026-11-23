# Alerts → WhatsApp notifications — decisions and review

Status: **PROPOSED.** The Product Owner agreed decisions D1–D13 on
2026-11-23; the architecture decision
([ADR-026](../../../00-governance/decisions/ADR-026-whatsapp-alert-notifications.md))
stays **Proposed** until provider validation, privacy/legal review and the
infrastructure approvals are complete (D13). **Nothing is implemented or
authorised**: no database, API, UI, infrastructure or production change.
Owner: Product + Engineering. Last reviewed: 2026-11-23.

| Document | Purpose |
|---|---|
| [prd-draft-0.1.md](prd-draft-0.1.md) | The Product Owner's PRD, verbatim — the source record. |
| [prd-draft-0.1-addendum-2026-11-23.md](prd-draft-0.1-addendum-2026-11-23.md) | Dated clarifications: where the PRD is out of date or superseded by D1–D13. |
| This README | Decisions, assumptions, open questions, dependencies, approvals, the conflict review. |
| [phase-1-plan.md](phase-1-plan.md) | Phase 1 plan — staging-only configuration; sends nothing. Not authorised. |
| [ADR-026](../../../00-governance/decisions/ADR-026-whatsapp-alert-notifications.md) | Proposed architecture decision. |

Builds on [ADR-024](../../../00-governance/decisions/ADR-024-customer-configurable-alert-rules.md)
(customer alert rules — on staging since 2026-11-18, **not on production**),
[ADR-017](../../../00-governance/decisions/ADR-017-mvp7-alert-architecture.md)
(evaluator = TimescaleDB job) and [ADR-025](../../../00-governance/decisions/ADR-025-site-energy-performance-reports.md)
(background-worker precedent). Requirements: `EMS-REQ-084`, `-145`, `-146`.
Evidence: `origin/staging` `458c179`; read-only staging queries 2026-11-23.

## 1. Terms

| PRD term | Model term (ADR-024, migrations 320–327) |
|---|---|
| "Alert" (e.g. *Maximum Demand Exceeded*) | **Alert rule** — `analytics.alert_rules`, one row per rule (`rule_id` stable; `version` bumps on every edit). |
| "A triggered alert" | A rule's **occurrence** (`analytics.alerts`) becoming **Active** after 5 minutes. |
| "Alert engine" | `analytics.run_alert_rule_evaluation_job` → `analytics.evaluate_alert_rules`, a TimescaleDB job **inside PostgreSQL**, once a minute; qualification timers in `analytics.alert_evaluation_candidates`. |
| "Site Admin" | Customer `ADMIN` (ORGANIZATION / SELECTED_SITES scope covering the site), holds `alert.configure`. |
| "WiseWatts Global Site Admin" | `GLOBAL` `ADMIN` (WiseWatts staff), holds `alert.configure` on every site. |

The design keeps **three separate concepts** (D6):

1. **Alert definition and operational lifecycle**: the rule, its occurrences
   and their timers. This is ADR-024, unchanged.
2. **WhatsApp notification configuration**: per rule, whether WhatsApp is
   on, its recipients, and each recipient's consent. This is new in
   Phase 1.
3. **WhatsApp delivery records**: one per occurrence and recipient, with
   provider status. This is Phase 2+, and not in Phase 1.

## 2. Confirmed decisions (Product Owner, 2026-11-23)

| ID | Decision |
|---|---|
| D1 | **Provider:** Meta WhatsApp Business Cloud API preferred, subject to validation of account requirements, templates, callbacks, pricing and operational suitability. No commitment to integrate yet. |
| D2 | **Recipients:** individual phone numbers only; no WhatsApp groups in the initial release. |
| D3 | **Configuration:** independently per alert rule in EMS → Alerts; multiple numbers per rule; Site Admins only on authorised sites; WiseWatts Global Site Admins on all sites. |
| D4 | **Consent:** explicit administrator confirmation of opt-in for each number. STOP-based opt-out, subject to provider capability and legal review. No OTP verification initially. |
| D5 | **Defaults:** WhatsApp off for every rule by default. The existing "Coming Soon" interest checkbox (`whatsapp_requested`) **never** activates sending. |
| D6 | **Lifecycle isolation:** WhatsApp settings and recipients are stored separately from the operational rule. Saving them never ends an Active occurrence, never resets a trigger timer and never re-triggers an alert. |
| D7 | **Delivery:** one message per occurrence and recipient; duplicate sends for the same occurrence/recipient suppressed within 60 minutes; no WhatsApp reminders and no recovery messages in the initial release. |
| D8 | **Templates:** WiseWatts Product owns message wording and templates. |
| D9 | **Security and privacy:** tenant, site and role permissions enforced server-side. Consent and configuration changes are audited. Phone numbers are masked in delivery history. Full numbers are shown only to authorised admins managing configuration. Operators and Viewers never see recipient numbers. |
| D10 | **Retention:** delivery history kept 90 days initially. Recipient numbers kept while configured; deletion handled according to applicable legal obligations. |
| D11 | **Production dependency:** no WhatsApp rollout until the existing Alerts feature (ADR-024) has completed its production rollout and acceptance. |
| D12 | **Infrastructure:** each of these needs separate explicit approval: the DB-backed queue, the background sender, the public signature-checked delivery-receipt endpoint, outbound server internet access and the provider secrets. They are documented only, not provisioned. |
| D13 | **Governance:** ADR-026 stays Proposed until provider validation, privacy/legal review and the required infrastructure approvals are complete. |

## 3. Assumptions

Engineering's working assumptions. Each is to be confirmed or corrected.

- **A-1. "Admins managing configuration" means `alert.configure` holders.**
  Those are the customer site `ADMIN` and the `GLOBAL` `ADMIN`. Everyone else
  counts as "Operators and Viewers" for D9, including `GLOBAL` `OPERATOR` and
  `GLOBAL` `VIEWER`.
- **A-2. Editing a number is removing it and adding a new one.** A changed
  number needs fresh opt-in confirmation (D4); consent never carries over
  to a different number.
- **A-3. Removing a recipient deletes its stored number** (D10: kept "while
  configured"). Phase 1 has no delivery records, so nothing else refers to
  the number. From Phase 2, delivery records keep only a masked copy.
- **A-4. The audit log holds masked numbers only, plus the recipient id**,
  so the permanent audit log keeps no full phone numbers. Whether consent
  evidence needs more (for example, a keyed hash of the number) is a
  question for the legal review (Q-6).
- **A-5. Soft-deleting a rule deletes its WhatsApp settings and recipients
  in the same audited transaction** (D10), because the numbers are no longer
  configured.
- **A-6. Enabling WhatsApp never sends about an occurrence that is already
  Active.** Only occurrences that become Active afterwards are eligible.
  This applies from Phase 2.
- **A-7. The Phase 1 UI is staging-only and labelled "messages are not sent
  yet"**, and only WiseWatts-controlled test numbers are entered on staging
  (Q-4).
- **A-8. Phone numbers are stored in E.164 form** and validated server-side
  with a pinned library, with a database format check as a backstop.

## 4. Open questions (need Product Owner input)

| ID | Question | Why it matters | Engineering suggestion |
|---|---|---|---|
| Q-1 | **Repeated occurrences of the same rule.** D7 limits sends per *occurrence*/recipient. A rule that keeps resolving and re-triggering creates new occurrences: it can resolve after 1 minute and re-qualify after 5 (ADR-024 timing). Should each new occurrence send again? | D7's 60-minute window only covers retries of one occurrence. A flapping rule could message a recipient about every 6 minutes. This was PRD open decision 5. | Add a per-rule/recipient cooldown of 60 minutes across occurrences; sends inside it are recorded as Suppressed. |
| Q-2 | **Maximum recipients per rule.** | Bounds cost, abuse and UI size. | 10. |
| Q-3 | **Can Operators and Viewers see masked delivery history**, or no recipient information at all? | D9 says they must not see recipient numbers; masked history may or may not be acceptable. | Masked history plus an "N recipients" summary; no full numbers. |
| Q-4 | **Should Phase 1 collect real customer numbers** before sending exists? | Holding personal data for a purpose that isn't live yet runs against data minimisation. | Staging only, WiseWatts test numbers only, until Phase 2 is approved. |
| Q-5 | **Per-site message cap** (storm protection, PRD §8.4). | Not covered by D1–D13. | Decide in Phase 2 design; not needed for Phase 1. |
| Q-6 | **Legal review scope** (D4, D10): is administrator attestation enough consent evidence; what the audit log may hold; deletion obligations. | Blocks Phase 2 and D13. | Raise with legal before Phase 2. |
| Q-7 | **Retiring the "Coming Soon" WhatsApp checkbox.** | When the new WhatsApp section appears, the old checkbox would duplicate it. | Remove it from the rule form in Phase 1 and keep Email "Coming Soon". |

## 5. Dependencies and approvals still required

| Item | Needed for | Status |
|---|---|---|
| Provider validation (Meta Cloud API): business verification, sender number, utility-template approval, callbacks, India pricing, limits, data handling | Phase 2; D13 | Not started |
| Privacy/legal review (DPDP Act 2023): consent evidence, retention, deletion, audit content | Phase 2; D13 | Not started |
| Phase 1 implementation authorisation (staging only) | Phase 1 | **Required: not authorised** |
| Phase 1 staging migration and deployment authorisation | Phase 1 deploy | Required separately |
| DB-backed delivery queue (outbox) | Phase 2 | Approval required (D12) |
| Background sender service (new container on the 1.9 GB staging host) | Phase 2 | Approval required (D12) |
| Public, signature-checked delivery-receipt endpoint | Phase 2 | Approval required (D12); security review |
| Outbound HTTPS from the servers to the provider (security-group and network-ACL rules never read) | Phase 2 | Approval required (D12) |
| Provider secrets (token, webhook secret) in a server-side env file | Phase 2 | Approval required (D12) |
| WhatsApp templates written and approved | Phase 2 | WiseWatts Product (D8) |
| ADR-024 production rollout and acceptance (blocked on backup, precheck, bundle, approval) | Any production WhatsApp | Not done (D11) |

## 6. Conflict review — resolution status

From the intake review of 2026-11-23 (`1824bab`). The full text of C1–C16 is
in that commit's version of this file; summarised here with what D1–D13
settled.

| ID | Conflict | Status |
|---|---|---|
| C1 | ADR-024 §9 forbids sending | Stands until ADR-026 is Decided; then ADR-024 Amendment 2 (WhatsApp only; Email stays Coming Soon). |
| C2 | Changing any rule field, including `whatsapp_requested`, ends the Active occurrence (`update_portal_alert_rule`, migration 323) | **Resolved by D6.** Phase 1 design in [phase-1-plan.md](phase-1-plan.md) §3, including neutralising `whatsapp_requested` so new-form saves can't end alerts. |
| C3 | Existing "requested" flags must not start sending | **Resolved by D5.** Staging: 2 live rules, 0 with WhatsApp requested. |
| C4 | PRD §16 describes an outdated baseline | Recorded in the [addendum](prd-draft-0.1-addendum-2026-11-23.md). |
| C5 | Stored reminder frequency would imply repeat messages | **Resolved by D7** (no WhatsApp reminders); the form keeps saying reminders are not sent. |
| C6 | Retention of delivery records and numbers | **Mostly resolved by D10**; deletion detail and audit content in Q-6, A-3, A-4. |
| C7 | Visibility by role | **Resolved by D9**; masked history for Operators/Viewers in Q-3. |
| C8 | The evaluator can't call HTTP (needs outbox + worker) | Architecture proposal in ADR-026 A2–A3; approval required (D12). Phase 2. |
| C9 | New infrastructure (worker, egress, public webhook, secrets) | Approval required (D12). Phase 2. |
| C10 | Production depends on the ADR-024 rollout | **Resolved by D11.** |
| C11 | `last_value` is not the value at trigger | Phase 2 design: the outbox row snapshots the message values. |
| C12 | No deep link to an occurrence | Phase 2 design (small UI routing change). |
| C13 | Free-text names inside template variables | Phase 2 design (sanitise and truncate); templates owned by Product (D8). |
| C14 | Resolved / Ended / data-unavailable / flapping | Resolved and reminders settled by D7 (no messages). Ended and data-unavailable: no message (follows from D7: only Active is sent). Flapping is open as Q-1. |
| C15 | Caps | Recipients per rule (Q-2), per-site cap (Q-5). |
| C16 | Phone validation | Phase 1 design (A-8). |

## 7. Delivery phases

1. **Phase 1: configuration, staging only, sends nothing.** See
   [phase-1-plan.md](phase-1-plan.md). Needs implementation authorisation.
2. **Phase 2: delivery.** Covers:
   - the outbox written by the evaluator, the sender worker and the signed
     delivery-receipt endpoint;
   - approved templates and delivery records;
   - test numbers first.

   Needs D12 approvals, provider validation and legal review.
3. **Phase 3: operational readiness.** Covers:
   - delivery-history UI, retries, cooldown and caps;
   - monitoring (worker heartbeat, outbox age);
   - 90-day retention, and the security tests.
4. **Production.** Only after ADR-024 is in production and accepted (D11),
   ADR-026 is Decided (D13), and a separate approval is given.

## 8. Acceptance criteria — whole feature

PRD §11 AC-1 to AC-15 are adopted, with these refinements:
- **AC-8:** disabling WhatsApp or editing recipients never ends an Active
  occurrence or resets a timer (D6).
- **AC-9:** applies to occurrences that become Active after WhatsApp was
  enabled (A-6), and only to recipients whose consent is confirmed and who
  have not opted out.
- **AC-15:** proven by a unique (occurrence, recipient) key, and by a test
  that replays the same occurrence.

Additions:
- **AC-16:** the "Coming Soon" flag never sends (D5).
- **AC-17:** Operators and Viewers never see full numbers (D9).
- **AC-18:** a forged or unsigned delivery receipt is rejected.
- **AC-19:** no message is sent for Resolved, Ended or data-unavailable
  states, and no reminders are sent (D7).

Phase 1 has its own criteria in [phase-1-plan.md](phase-1-plan.md) §6.
