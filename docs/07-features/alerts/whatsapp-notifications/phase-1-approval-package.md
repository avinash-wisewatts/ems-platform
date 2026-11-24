# WhatsApp notifications — Phase 1 approval package

Status: **READY FOR AN IMPLEMENTATION APPROVAL REQUEST — not approved.** The
last prerequisite, the owner documentation review of PR #186, was recorded as
Approved on 2026-11-24 ([doc-review-checklist.md](doc-review-checklist.md)
§3; documentation only, not independent, not Legal). Updated 2026-11-23 with
the Architecture and Product answers. Design basis:
ADR-024 Amendment 2 (**Decided 2026-11-23**), which is **not**
implementation permission. ADR-026 remains **Proposed**.

Detail: [phase-1-plan.md](phase-1-plan.md). Decisions and open items:
[README.md](README.md). Review: [review-2026-11-23.md](review-2026-11-23.md).

## 1. Readiness assessment

| Area | Ready? | Basis / what is missing | Owner |
|---|---|---|---|
| Authorising record | **Yes** | ADR-024 Amendment 2 Decided (2026-11-23) | — |
| Scope | **Yes** | R5 in, R6 in, R8 out (2026-11-23) | — |
| Database / migration 331 | **Yes** (designed) | Includes the R5 check and the R6 register | — |
| API | **Yes** (designed) | — | — |
| UI | Designed; **staging deployment blocked** | Approved opt-in wording (D21), which depends on R9 (the sending business) | Product + Legal |
| Permissions / D16 / R5 | **Yes** | A-1 confirmed; R5 approved | — |
| Audit | **Yes** for staging (R12 default: no numbers) | L-2 may change the content before Phase 2 or production | Legal |
| Retention | **Yes** | A-9 / R7 confirmed; Legal may override (L-3) | Legal |
| Rollback | **Yes** (designed) | — | — |
| Lifecycle regression tests | **Yes** (designed) | RG-1 to RG-13; P1-AC-14 | — |
| Test-number restriction | **Procedural only** | R8 out of scope: D17 relies on process (P1-AC-15) | Product (accepted) |
| Requirement IDs | **Yes** | `EMS-REQ-153`–`EMS-REQ-159` allocated (2026-11-23) | — |
| Working assumptions | **Yes** | A-1 to A-9 confirmed (2026-11-23) | — |
| Documentation review | **Yes** | Owner review Approved 2026-11-24 at `3d00c20` (documentation only; not independent, not Legal) | Product Owner |
| Legal L-1 to L-3 | Not started | Does not block staging with test numbers; blocks Phase 2 and production | Legal |
| Provider P-1 to P-4 | Desk research only | Not needed for Phase 1; blocks Phase 2 | Product + Engineering |

**Verdict:** the owner documentation review was recorded on 2026-11-24, so
Phase 1 is ready for its **implementation approval request**. That request
is not yet made or granted. The opt-in wording (D21,
with R9) is required before **staging deployment**, not before
implementation. Without it, the R6 register is empty, and the save refuses
new consent (`whatsapp_consent_statement_missing`).

## 2. Approval checklist

**Before requesting Phase 1 implementation approval:**
- [x] ADR-024 Amendment 2 Decided: Product Owner + Architecture, 2026-11-23
- [x] R5 approved, in scope: Architecture, 2026-11-23
- [x] R6 in scope: Product Owner, 2026-11-23 (Legal sufficiency still open)
- [x] R8 out of scope: Product Owner, 2026-11-23
- [x] R7 / A-9 confirmed: Product Owner, 2026-11-23 (Legal may override)
- [x] A-1 to A-8 confirmed: Product Owner, 2026-11-23
- [x] R11: `EMS-REQ-153`–`EMS-REQ-159` allocated, Product Owner, 2026-11-23
- [x] Package updated and re-estimated (§5)
- [x] Owner documentation review of PR #186 recorded: Approved, repository owner as Product Owner, 2026-11-24, at `3d00c20` (documentation only)

**Phase 1 implementation approval** (explicit, separate):
- [ ] Approval to implement this scope on a feature branch from fresh
      `origin/staging`

**Before merge** (separate approval):
- [ ] All P1-AC criteria met (P1-AC-18 does not apply); full regression
      and CI green; code review complete; docs updated in the same PR

**Before staging deployment** (separate approval):
- [ ] D21 opt-in wording approved by Product, naming the business per R9
      (Product + Legal)
- [ ] The wording loaded into the R6 register by migration
- [ ] Migration 331 applied through the normal staging deployment only

**Before any staging test save** (separate approval):
- [ ] Only WiseWatts-controlled test numbers (D17). This is a procedural
      check recorded in the staging verification record, since R8 is out.

**Not part of Phase 1:** Phase 2 gates (provider validation, legal review,
per-item infrastructure approvals) and production gates (ADR-024 production
rollout and acceptance; ADR-026 Decided).

## 3. Final scope

**In scope** (staging and test only):
- **Migration 331:**
  - two configuration tables, plus the R6 consent-wording register;
  - three new functions plus the mask helper, each with the R5
    automation-account refusal;
  - re-created `create_portal_alert_rule`, `update_portal_alert_rule` and
    `delete_portal_alert_rule`;
  - the `whatsapp_requested` safeguard and CHECK;
  - guarded grants, postconditions, and a rollback that deletes the stored
    numbers.
- **API:** `GET` and `PUT /api/v1/alert-rules/{rule_id}/whatsapp`, a
  configurer-only summary in rule responses, and the permission map entry.
- **UI:** the WhatsApp panel on rule edit, the configurer-only list badge,
  and removal of the Coming Soon WhatsApp checkbox.
- **Tests:** plan §7, including RG-1 to RG-13 and the R5 and R6 tests.

**Out of scope:**
- R8 (the allow-list);
- phase-1-plan §9: no message, provider, delivery record, queue, sender,
  receipt endpoint, STOP handling, templates, infrastructure or production.

## 4. Requirement traceability (allocated 2026-11-23)

| ID | Requirement | Acceptance |
|---|---|---|
| EMS-REQ-153 | Per-rule WhatsApp configuration (on/off, 1–10 recipients), stored separately from the rule | P1-AC-1, -2, -3, -5 |
| EMS-REQ-154 | Per-number opt-in confirmation with the confirmer, the time and the approved wording version (R6) | P1-AC-5, -17 |
| EMS-REQ-155 | Configurer-only visibility; automation accounts refused (R5) | P1-AC-4, -16 |
| EMS-REQ-156 | WhatsApp saves never alter occurrences, timers, acknowledgements or versions | P1-AC-7, -8, -9, -14 |
| EMS-REQ-157 | The legacy Coming Soon WhatsApp option is retired and never sends | P1-AC-9, -11 |
| EMS-REQ-158 | Audited configuration and consent changes, without phone numbers (subject to L-2) | P1-AC-6, -12 |
| EMS-REQ-159 | No sending in Phase 1; staging test numbers only (procedural) | P1-AC-10, -15 |

P1-AC-13 (migration, grants, rollback) supports all of them. P1-AC-18 is
not used (R8 out).

## 5. Effort estimate (rough, re-estimated 2026-11-23)

| Work | Engineering days |
|---|---|
| Migration 331: tables, R6 register, functions with the R5 check, three re-created functions, safeguard, grants, postconditions, registration, rollback | 2.5 |
| API routes, models, permission map, service | 1 |
| UI panel, rule-list badge, checkbox removal, wording-version handling | 1.5 |
| Database tests (configuration, permissions incl. R5, consent and R6, audit, concurrency) and regression matrix RG-1 to RG-13 | 3 |
| Route and web tests; intentional existing-test changes | 1 |
| Documentation updates, CI, review fixes | 0.5 |
| **Total** | **≈ 9.5** (was 8.5 core + optional; R5 and R6 now included, R8 dropped) |
| Staging verification after an approved deployment | 0.5 |

## 6. Risks

| Risk | Mitigation |
|---|---|
| Re-creating three ADR-024 write functions regresses rule behaviour | RG-1 to RG-13 against control twins; the full `test_alert_rules_db.py`; the rollback restores the migration 323 definitions |
| **A real customer number is entered on staging** (R8 out, so D17 is procedural only) | Only WiseWatts staff test accounts configure WhatsApp on staging. Each test save needs separate approval and a record in the staging verification. The rollback deletes all numbers. *Residual risk accepted by Product with R8 out.* |
| The opt-in wording or R9 is late | Implementation can proceed; with the register empty, consent is refused; staging deployment is blocked until the wording is approved |
| Legal outcome changes the consent or audit design | R12 safe default; the versioned wording (R6); changes are additive |
| Staging and production function drift | Recorded; production only with the WhatsApp production release (D11) |
| Deploy-window UX (old web, new API) | Customer API then web, back to back (R4) |
| Owner review instead of an independent review | Recorded as a known limitation in the checklist; the mechanical checks (PRD diff, decision hashes, links) are reproducible |
