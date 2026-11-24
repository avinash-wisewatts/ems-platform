# Alerts → WhatsApp notifications — decisions and review

Status: **PROPOSED.** The Product Owner agreed decisions D1–D13 and D14–D21
on 2026-11-23. The architecture decision
([ADR-026](../../../00-governance/decisions/ADR-026-whatsapp-alert-notifications.md))
stays **Proposed** until provider validation, privacy/legal review and the
infrastructure approvals are complete (D13). Phase 1 configuration behaviour
is covered by **ADR-024 Amendment 2, DECIDED 2026-11-23** (Product Owner and
Architecture approvals recorded; resolves review B1). That is not an
implementation approval. **Nothing is implemented or
authorised**: no database, API, UI, infrastructure or production change.
Owner: Product + Engineering. Last reviewed: 2026-11-23.

| Document | Purpose |
|---|---|
| [prd-draft-0.1.md](prd-draft-0.1.md) | The Product Owner's PRD, verbatim — the source record. |
| [prd-draft-0.1-addendum-2026-11-23.md](prd-draft-0.1-addendum-2026-11-23.md) | Dated clarifications: where the PRD is out of date or superseded by D1–D21. |
| This README | Decisions, assumptions, open legal/provider questions, dependencies, approval gates, the conflict review. |
| [phase-1-plan.md](phase-1-plan.md) | Phase 1 plan — staging-only configuration; sends nothing. Not authorised. |
| [phase-1-approval-package.md](phase-1-approval-package.md) | Phase 1 approval package: readiness, approval checklist, final scope, requirement IDs, effort, risks. **Not ready**: owner documentation review pending. |
| [doc-review-checklist.md](doc-review-checklist.md) | Documentation review checklist and review record for PR #186. |
| [consent-wording-register.md](consent-wording-register.md) | Register of approved opt-in wording versions (R6: in Phase 1 scope, Product Owner 2026-11-23; Legal sufficiency open, L-1). Empty: no wording is approved, so new opt-ins are refused until an approved version exists (D21). |
| [review-2026-11-23.md](review-2026-11-23.md) | PR #186 review record: findings B1–B3, R1–R12, I1–I5; status of the outstanding reviews; provider desk research. |
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
| "Operators and Viewers" | *Assumption A-1 (awaiting Product):* every role **without** `alert.configure` — customer `OPERATOR` / `VIEWER` and `GLOBAL` `OPERATOR` / `VIEWER`. |

The design keeps **three separate concepts** (D6):

1. **Alert definition and operational lifecycle**: the rule, its occurrences,
   timers and acknowledgements. This is ADR-024, unchanged.
2. **WhatsApp notification configuration**: per rule, whether WhatsApp is
   on, its recipients, and each recipient's consent. This is new in
   Phase 1.
3. **WhatsApp delivery records**: one per occurrence and recipient, with
   provider status. This is Phase 2+, and **not** in Phase 1.

## 2. Confirmed decisions (Product Owner, 2026-11-23)

### 2.1 Decisions D1–D13

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

### 2.2 Decisions D14–D21 (they close the earlier questions Q-1 to Q-7 and the opt-in wording)

| ID | Was | Decision |
|---|---|---|
| D14 | Q-1 | **Repeat alerts:** a **60-minute quiet period per rule and recipient across separate occurrences**, in addition to D7's duplicate suppression within one occurrence. A send inside the quiet period is not made, and is recorded as Suppressed (Phase 2). |
| D15 | Q-2 | **Recipient limit:** at most **10** phone numbers per rule. |
| D16 | Q-3 | **Operators and Viewers:** **no recipient information** visible to these roles in Phase 1. That means no numbers, no masked numbers, no recipient count and no WhatsApp on/off indicator. Masked delivery history for them is reconsidered when delivery records are introduced (Phase 2/3). |
| D17 | Q-4 | **Staging numbers:** only WiseWatts-controlled test numbers are entered. **No real customer numbers are collected before sending exists.** |
| D18 | Q-5 | **Per-site message cap:** deferred to Phase 2 design. |
| D19 | Q-6 | **Consent and audit:** whether administrator opt-in confirmation is legally sufficient, and what the audit log may contain and for how long, stay **open for privacy/legal review**. **Compliance is not assumed.** See L-1 and L-2. |
| D20 | Q-7 | **Legacy checkbox:** the old "Coming Soon" WhatsApp checkbox is **removed in Phase 1**, subject to the migration 331 safeguard ([phase-1-plan.md §3.3](phase-1-plan.md)) and the regression tests (phase-1-plan.md §7.2). |
| D21 | Opt-in wording | WiseWatts Product **defines and approves the exact opt-in confirmation wording before it is used**. The Phase 1 UI cannot ship to staging without it. |

## 3. Assumptions

Engineering's working assumptions. Each is to be confirmed or corrected in
review.

- **A-1. "Admins managing configuration" means `alert.configure` holders.**
  Those are the customer site `ADMIN` and the `GLOBAL` `ADMIN`. Every other
  role counts as an "Operator or Viewer" for D9 and D16.
- **A-2. Editing a number is removing it and adding a new one.** A changed
  number needs fresh opt-in confirmation (D4).
- **A-3. Removing a recipient deletes its stored number** (D10: kept "while
  configured"). Phase 1 has no delivery records.
- **A-4. The audit log stores masked numbers plus the recipient id, never a
  full number.** This is the privacy-protective default. Whether consent
  evidence needs more is open (L-1, L-2), so the Phase 1 design must not
  depend on this answer. *Superseded by the proposed review item R12:*
  the recommended default is now **no phone number, full or masked, in the
  audit log**, only recipient ids, until Legal approves otherwise.
- **A-5. Soft-deleting a rule deletes its WhatsApp settings and recipients**
  in the same audited transaction.
- **A-6. Enabling WhatsApp never sends about an already-Active
  occurrence.** This applies from Phase 2.
- **A-7. An "alert save" means any write through the migration 323
  functions:** create, update, enable/disable, delete, and acknowledge
  (`acknowledge_portal_alert`). ADR-024 §8 still applies. An update that
  changes an operational field (name, asset, parameter, condition,
  threshold, tolerance, schedule, reminder) **intentionally** ends the
  Active occurrence and bumps the version. The regression guarantee is that
  WhatsApp saves, and rule saves whose only difference is the legacy
  WhatsApp field, change none of these.
- **A-8. Phone numbers are stored in E.164 form** and validated server-side
  with a pinned library, with a database format check as a backstop.
- **A-9. A rule with WhatsApp switched off still counts as "configured"**
  (D10), so its numbers are kept until they are removed or the rule is
  deleted (review R7). Needs Product and legal confirmation.

**Status:** A-1 to A-9 **confirmed as written by the Product Owner on
2026-11-23** (recorded in this session; A-4 is read with its R12 supersession
note; A-9/R7 may still be overridden by Legal, L-3). See [review-2026-11-23.md](review-2026-11-23.md) §2.

## 4. Open questions — legal and provider (not product decisions)

| ID | Question | Owner | Blocks |
|---|---|---|---|
| L-1 | Is administrator attestation of opt-in legally sufficient consent evidence under the DPDP Act 2023 and Meta policy? Does the recipient need notice, and what records must be kept? | Privacy/legal | Phase 2; ADR-026 Decided (D13) |
| L-2 | What may the audit log contain about recipients (masked number, keyed hash, full number), and for how long, given `admin.audit_events` is permanent today? | Privacy/legal | Phase 2; may require a Phase 1 audit-content change before production |
| L-3 | Deletion obligations for removed recipients and opted-out numbers (D10). | Privacy/legal | Phase 2 |
| P-1 | Meta Cloud API: business verification, sender number, utility-template approval and categories, India pricing, throughput, data handling. | Product + Engineering | Phase 2 |
| P-2 | Provider delivery-receipt semantics and signature scheme; mapping to Pending / Submitted / Sent / Delivered / Failed / Suppressed. | Engineering | Phase 2 |
| P-3 | STOP / opt-out support and how it is reported (D4). | Engineering | Phase 2 |
| P-4 | Template variable limits (length, characters) for customer-entered names (C13). | Engineering + Product (D8) | Phase 2 |

L-1 to L-3 are **not started**. P-1 to P-4 have **desk research only**
(public documentation, unverified against an account) in
[review-2026-11-23.md §3](review-2026-11-23.md#3-provider-desk-research-p-1-to-p-4-unverified-public-sources-only).
That research adds questions for Product and legal: which business the
opt-in names (R9); whether to store `read` receipts; and inbound message
content under STOP handling (R10).

## 4A. Review items R5–R12: owner decisions and open items

Owner answers recorded 2026-11-23 for R5, R6, R7, R8 and R11. R9, R10 and
R12 are **still open**; they are proposals, not decisions.
The details are in [phase-1-plan.md §3.6](phase-1-plan.md) and
[review-2026-11-23.md](review-2026-11-23.md).

| Item | Proposal | Owner(s) | Status | Question for the owner |
|---|---|---|---|---|
| R5 | Exclude designated report automation accounts of **any** site from all WhatsApp read/write functions, following migration 330; access-control tests | Architecture | **Approved 2026-11-23** (repository owner acting for Architecture); **in Phase 1** | — |
| R6 | A versioned register of approved opt-in wording; each consent records its version | Product (wording), Legal (sufficiency) | **In Phase 1 scope** (Product Owner, 2026-11-23); Legal review of sufficiency open | Supply version 1 of the wording (D21) |
| R7 | Keep configured numbers when WhatsApp is disabled; disabling stops sending; deletion is a separate, explicit action | Product, Legal | **Confirmed by Product 2026-11-23** (A-9); Legal may override (L-3) | Does Legal require deletion after a period of being disabled? |
| R8 | Server-side, staging-only allow-list of WiseWatts test numbers | Product, Architecture | **Out of Phase 1 scope** (Product Owner, 2026-11-23); D17 stays procedural (P1-AC-15) | — |
| R9 | Name the sending business in the opt-in wording | Product, Legal | **Open question** | WiseWatts or the customer site? |
| R10 | Phase 2 STOP handling keyword-only; no retention of message text beyond what is needed | Engineering design; Provider (P-3); Legal | Proposed (Phase 2) | Confirm minimal retention of inbound content |
| R11 | Formal requirement IDs for the Phase 1 acceptance criteria | Product | **Allocated 2026-11-23**: `EMS-REQ-153`–`EMS-REQ-159` (Product Owner) | — |
| R12 | No phone numbers, full or masked, in the permanent audit log until Legal approves; recipient ids instead | Legal | Proposed; reflected in the plan as the default | What may the audit log hold, and for how long (L-2)? |

## 5. Approval gates and dependencies

**B1 resolved:** ADR-024 Amendment 2 is **Decided** (2026-11-23). The
approvals of the Product Owner (2A, 2D, 2E) and Architecture (2B, 2C, the 2D
enforcement) are recorded in its approval table. PR #186 stays in draft
until the documentation review is complete. Leaving draft means
documentation review only, not implementation.

**Before Phase 1 implementation:**
- ~~the authorising record for Phase 1 (review B1)~~ — **done**: ADR-024
  Amendment 2 Decided 2026-11-23;
- ~~an Architecture decision on automation accounts (review R5)~~ — **done**:
  approved 2026-11-23;
- an owner documentation review of PR #186 recorded
  ([doc-review-checklist.md](doc-review-checklist.md));
- explicit approval to implement Phase 1;
- D21: the opt-in wording approved by Product, before the UI ships to
  staging;
- a new pinned code dependency, `phonenumbers`.

**Within Phase 1, each separately approved:**
- merging the PR;
- applying migration 331 and deploying to staging;
- any staging test save, using WiseWatts test numbers only (D17).

**Before Phase 2:**
- Meta provider validation (P-1 to P-4) completed;
- privacy/legal review completed, and consent evidence and audit retention
  resolved (L-1 to L-3);
- separate approval for **each** infrastructure item (D12): the DB-backed
  delivery queue, the background sender service (a new container on the
  1.9 GB staging host), the public signature-checked receipt endpoint (with
  a security review), outbound internet access from the servers (the
  security-group and network-ACL rules have never been read), and the
  provider secrets in a server-side env file;
- WhatsApp templates written and approved by Product (D8);
- Phase 2 design of the per-site cap (D18) and of masked delivery history
  for Operators and Viewers (D16).

**Before production:**
- ADR-024 has completed its production rollout and acceptance (D11). It is
  currently blocked on backup, precheck, bundle and approval;
- ADR-026 is Decided (D13);
- a separate production approval.

## 5A. Traceability

Every decision D1–D21 appears exactly once below, in one of three tables:
Phase 1 behaviour (§5A.1), legal and governance (§5A.2), and Phase 2 or
production (§5A.3). Requirement IDs and the review items R5, R6 and R12
follow in §5A.4.

How to read the columns:
- **Decision record.** "ADR-024 Am. 2 §2x" is a section of the **Decided**
  ADR-024 Amendment 2, the Phase 1 design basis. "ADR-026 Dn" is the decision
  text recorded under ADR-026 → *Decision → Product decisions*; "ADR-026 An"
  is ADR-026 → *Decision → Architecture (proposed)*; "ADR-026 OQ" is
  ADR-026 → *Open questions and approvals*. ADR-026 is **Proposed**: citing
  it records where a decision is written down, and authorises nothing.
- **Phase 1 plan** sections are in [phase-1-plan.md](phase-1-plan.md).
  P1-AC-n is plan §6, RG-n is plan §7.2. "AC-n" is a whole-feature criterion
  in §8 below, not a Phase 1 criterion.
- **"None"** means no such entry exists. It is stated rather than invented.
- **A later-phase row is a tracking reference only.** It does not authorise
  any Phase 2 or production design, implementation or deployment; the gates
  in §5 still apply.

### 5A.1 Phase 1 behaviour (configuration, staging only)

| Decision | Decision record | Phase 1 plan | Phase 1 acceptance / tests | Open dependency or later gate |
|---|---|---|---|---|
| D2 (individual numbers only; no groups) | ADR-026 D2. None in ADR-024 Am. 2 | §3.2 (one E.164 number per recipient row), §9 (groups out of scope) | No dedicated group test: a group cannot be stored, because every recipient must pass the E.164 CHECK (§3.2). P1-AC-1, P1-AC-5; §7.1 validation (E.164 format) | Groups are excluded from the initial release; any change needs a new Product decision |
| D3 (per rule; several numbers; Site Admins on authorised sites, Global Site Admins on all sites) | ADR-024 Am. 2 §2B (per rule, keyed by `rule_id`), §2D (who may edit); ADR-026 D3, A7 | §3.1, §3.5, §4, §5 | P1-AC-1 (site `ADMIN`, authorised site), P1-AC-2 (rules independent), P1-AC-3 (`GLOBAL` `ADMIN`, any site), P1-AC-4 (404 for unauthorised sites); §7.1 permissions; §7.3. `EMS-REQ-153`, `EMS-REQ-155` | — |
| D4 (explicit per-number admin opt-in; no OTP; STOP opt-out later) | ADR-024 Am. 2 §2B (per-number opt-in confirmation); ADR-026 D4; STOP: ADR-026 A5 (Phase 2) | §1 item 4, §3.2 (no verification column, so no OTP; `OPTED_OUT` reserved for Phase 2), §3.5 consent and recipient identity (B2), §9 (OTP and STOP out of scope) | P1-AC-5 (new or changed number without opt-in refused); §7.1 validation (fresh consent for a changed number, A-2) and recipient identity (B2); §7.4 opt-in checkbox required. "No OTP" has no test: Phase 1 adds no verification step to test. `EMS-REQ-154` | Legal sufficiency of the opt-in: D19 / L-1 (§5A.2). STOP handling: Phase 2, P-3, R10 |
| D5 (off by default; the flag never sends) | ADR-024 Am. 2 §2A; ADR-026 D5, A2 | §3.1, §3.3 | P1-AC-10, P1-AC-11; RG-6, RG-13. `EMS-REQ-157` | — |
| D6 (separate store; not an operational edit) | ADR-024 Am. 2 §2B, §2C; ADR-026 D6, A1 | §2, §3.1–§3.4 | P1-AC-7–9, P1-AC-14; RG-1–RG-12. `EMS-REQ-156` | — |
| D9 / D16 (server-side permissions; audited changes; visibility) | ADR-024 Am. 2 §2D; ADR-026 D9, D16, A7 | §3.5, §4, §5 | P1-AC-4, P1-AC-6 (audit); §7.1 permissions and audit, §7.3, §7.4. `EMS-REQ-155`, `EMS-REQ-158` | D9 masked delivery history and the D16 reconsideration: Phase 2/3 (§5 "Before Phase 2"; §7) |
| D10 / R7 (retention of numbers) | ADR-026 D10 | §3.2, §3.4; §3.6 R7 | P1-AC-12; RG-11 | 90-day delivery-history retention: Phase 3 (§7). Deletion obligations: L-3 (Legal may override R7) |
| D15 (10 recipients) | ADR-026 D15, A7. None in ADR-024 Am. 2 | §1 item 3, §3.2, §3.5 | P1-AC-1, P1-AC-5; RG-2, RG-4; §7.1 (10 accepted, 11 refused); §7.4. `EMS-REQ-153` | — |
| D17 (test numbers only on staging) | ADR-024 Am. 2 §2E; ADR-026 D17 | §1, §7.6 (R8 out of scope) | P1-AC-15 (procedural). `EMS-REQ-159` | Each staging test save needs separate approval (§5); no real customer numbers on any environment (plan §9) |
| D20 (remove the legacy checkbox) | ADR-024 Am. 2 §2A; ADR-026 D20 | §3.3, §5 | P1-AC-9, P1-AC-11; §7.2; §7.4; §7.5 test changes. `EMS-REQ-157` | — |
| D21 (Product approves the exact opt-in wording before use) | ADR-026 D21 and ADR-026 OQ (a Phase 1 gate). No ADR-024 Am. 2 section | §3.2, §3.6 R6, §5 (placeholder wording only), §8 Product | P1-AC-17; §7.1 R6 tests. `EMS-REQ-154`. **Product approval requirement:** an approval (approver and date) recorded in [consent-wording-register.md](consent-wording-register.md), and the [approval package](phase-1-approval-package.md) §2 "Before staging deployment" item. No wording is approved | Blocks staging deployment of the UI (§5). Depends on R9 (which business is named: Product + Legal). Product approval is not Legal sign-off (L-1) |

### 5A.2 Legal and governance

| Decision | Decision record | Phase 1 plan | Acceptance / tests | Open dependency or later gate |
|---|---|---|---|---|
| D19 (legal sufficiency of the opt-in, and audit content and retention, stay open; compliance is not assumed) | ADR-026 D19 and OQ (L-1, L-2); ADR-024 Am. 2 *Not amended* note (audit content pending L-2) | §1 item 4, §3.5 audit, §8 Legal | **No acceptance criterion can close D19**; only Legal can. P1-AC-6 tests the R12 default (no phone number in audit) and P1-AC-17 tests the wording-version record. Neither establishes legal sufficiency | L-1, L-2 (§4); R12 (§4A, proposed). Before Phase 2: L-1 to L-3 resolved (§5). L-2 may require a Phase 1 audit-content change before production |
| D13 (ADR-026 stays Proposed until provider validation, legal review and infrastructure approvals) | ADR-026 status header and OQ | Plan header (ADR-026 Proposed) | No Phase 1 acceptance criterion. Documentation check: checklist check 5 (ADR-026 Proposed in the ADR, the decision log and the index) | Production gate: ADR-026 Decided (§5 "Before production") |

### 5A.3 Phase 2, production and infrastructure gates (not Phase 1 scope)

No decision here has a Phase 1 acceptance criterion, because none is built
in Phase 1. Where a Phase 1 criterion is cited, it only proves the thing
is **absent**.

| Decision | Decision record | Phase 1 plan | Phase 1 evidence | Later-phase tracking reference |
|---|---|---|---|---|
| D1 (Meta Cloud API preferred; no integration commitment) | ADR-026 D1 | §9 (provider accounts, SDKs and HTTP calls out of scope) | P1-AC-10 (no outbound call exists) | P-1 to P-4 (§4); §5 "Before Phase 2" (provider validation) |
| D7 (one message per occurrence and recipient; 60-minute duplicate suppression; no reminders or recovery messages) | ADR-026 D7, A3, A4 | §9 (outbox, worker, reminders and recovery messages out of scope) | P1-AC-10 (nothing can send) | §7 Phase 2; whole-feature AC-15, AC-19 (§8) |
| D8 (Product owns message wording and templates) | ADR-026 D8 | §9 (templates out of scope) | None | §5 "Before Phase 2" (templates written and approved by Product); P-4. Separate from the D21 opt-in wording |
| D11 (no rollout before ADR-024 completes production rollout and acceptance) | ADR-026 D11, A8; ADR-024 Am. 2 §2E (production not covered) | §3 (migration 331 scoped `staging\|test`), §8 Platform, §9 (production out of scope) | None | §5 "Before production" |
| D12 (queue, sender, receipt endpoint, outbound access and secrets each need separate approval) | ADR-026 D12, A3–A6 | §9 (all excluded) | P1-AC-10 (no outbox, worker or callback route) | §5 "Before Phase 2" (one approval per item); whole-feature AC-18 (§8, receipt endpoint) |
| D14 (60-minute quiet period per rule and recipient across occurrences) | ADR-026 D14, A3 | None (delivery behaviour; §9 excludes the outbox) | None | §7 Phase 2; whole-feature AC-9, AC-15, AC-20 (§8) |
| D18 (per-site message cap deferred) | ADR-026 D18 | §9 (per-site cap out of scope) | None | §5 "Before Phase 2" (Phase 2 design of the cap); §7 Phase 2 |

### 5A.4 Requirements and review items

| Item | Decision record | Phase 1 plan | Acceptance / tests | Open dependency |
|---|---|---|---|---|
| `EMS-REQ-153`–`EMS-REQ-159` | `functional-requirements.md` (allocated 2026-11-23, R11) | §6 | Mapped to P1-AC in the approval package §4 | — |
| R5 (automation accounts; approved) | ADR-024 Am. 2 approval notes (dated note on §2D) | §3.5, §3.6 | P1-AC-16; §7.1 R5 tests. `EMS-REQ-155` | — |
| R6 (versioned wording register; in Phase 1 scope) | No ADR section; recorded in §4A and review §7 | §3.2, §3.6 | P1-AC-17; §7.1 R6 tests. `EMS-REQ-154` | Wording unapproved (D21); Legal sufficiency open (L-1) |
| R12 (audit content; proposed) | ADR-024 Am. 2 *Not amended* note | §3.4, §3.5 | P1-AC-6, P1-AC-12; §7.1 audit. `EMS-REQ-158` | L-2 (Legal). Still a proposal: the plan uses it as the default |

## 6. Conflict review — resolution status

From the intake review of 2026-11-23 (`1824bab`); that commit's version of
this file has the full text.

| ID | Conflict | Status |
|---|---|---|
| C1 | ADR-024 §9 forbids sending | Stands until ADR-026 is Decided; then a further ADR-024 amendment (Amendment 3) allows WhatsApp sending only; Email stays Coming Soon. Amendment 2 (Decided) covers configuration only and sends nothing. |
| C2 | Changing any rule field, including `whatsapp_requested`, ends the Active occurrence | **Resolved by D6/D20 and ADR-024 Amendment 2 §2C (Decided).** Phase 1 §3.3 safeguard and §7.2 regression tests. |
| C3 | Existing "requested" flags must not start sending | **Resolved by D5.** Staging: 13 rule rows, 0 with WhatsApp requested. |
| C4 | PRD §16 describes an outdated baseline | Recorded in the [addendum](prd-draft-0.1-addendum-2026-11-23.md). |
| C5 | Stored reminder frequency would imply repeat messages | **Resolved by D7.** |
| C6 | Retention of delivery records and numbers | D10 decided; legal detail open (L-2, L-3). |
| C7 | Visibility by role | **Resolved by D9/D16.** |
| C8 | Evaluator can't call HTTP (outbox + worker) | ADR-026 A3–A4; approval required (D12). Phase 2. |
| C9 | New infrastructure | Approval required per item (D12). Phase 2. |
| C10 | Production depends on the ADR-024 rollout | **Resolved by D11.** |
| C11 | `last_value` is not the value at trigger | Phase 2 design (outbox snapshot). |
| C12 | No deep link to an occurrence | Phase 2 design. |
| C13 | Free-text names inside template variables | Phase 2 design (P-4, D8). |
| C14 | Resolved / Ended / data-unavailable / flapping | **Resolved:** D7 (only Active is sent; no recovery or reminders) and D14 (quiet period across occurrences). |
| C15 | Caps | **Resolved:** 10 recipients per rule (D15); per-site cap deferred (D18). |
| C16 | Phone validation | Phase 1 design (A-8). |

## 7. Delivery phases

1. **Phase 1: configuration, staging only, sends nothing.** See
   [phase-1-plan.md](phase-1-plan.md).
2. **Phase 2: delivery.** Covers:
   - the outbox, the sender worker and the signed receipt endpoint;
   - templates and delivery records;
   - the D7 duplicate suppression and the D14 quiet period;
   - the per-site cap (D18);
   - STOP handling;
   - test numbers first.
3. **Phase 3: operational readiness.** Covers:
   - delivery-history UI (with the D16 reconsideration), retries and
     monitoring;
   - 90-day retention, and the security tests.
4. **Production.** Behind the gates in §5.

## 8. Acceptance criteria — whole feature

PRD §11 AC-1 to AC-15 are adopted, with these refinements:
- **AC-3:** 1–10 numbers per rule (D15).
- **AC-8:** disabling WhatsApp or editing recipients never ends an Active
  occurrence, resets a timer, or changes an acknowledgement or version (D6).
- **AC-9:** applies to occurrences that become Active after WhatsApp was
  enabled (A-6), and only to consented, not-opted-out recipients outside
  the D14 quiet period.
- **AC-15:** a unique (occurrence, recipient) key plus the D14 quiet period,
  proven by replay tests.

Additions:
- **AC-16:** the "Coming Soon" flag never sends (D5).
- **AC-17:** Operators and Viewers see no recipient information (D16).
- **AC-18:** a forged or unsigned delivery receipt is rejected.
- **AC-19:** no message is sent for Resolved, Ended or data-unavailable
  states, and no reminders are sent (D7).
- **AC-20:** a second occurrence of the same rule within 60 minutes of a
  message to a recipient is recorded as Suppressed for that recipient
  (D14).

Phase 1 has its own criteria in [phase-1-plan.md](phase-1-plan.md) §6.
