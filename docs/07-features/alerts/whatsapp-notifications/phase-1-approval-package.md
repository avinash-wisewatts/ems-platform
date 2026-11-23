# WhatsApp notifications — Phase 1 approval package (draft)

Status: **DRAFT — NOT READY FOR IMPLEMENTATION APPROVAL.** Prepared
2026-11-23 on PR #186. Design basis: ADR-024 Amendment 2 (**Decided
2026-11-23**), which is **not** implementation permission. ADR-026 remains
**Proposed**. This package collects what an implementation approval would
cover, and what is still missing before one can be asked for.

Detail: [phase-1-plan.md](phase-1-plan.md). Decisions and open items:
[README.md](README.md). Review: [review-2026-11-23.md](review-2026-11-23.md).

## 1. Readiness assessment

| Area | Ready? | What is missing | Owner |
|---|---|---|---|
| Authorising record | **Yes** | — (ADR-024 Amendment 2 Decided) | — |
| Scope | **Yes**, apart from three optional items | Decide whether R5, R6 and R8 are in scope | Architecture (R5, R8); Product + Legal (R6); Product (R8) |
| Database / migration 331 | Designed | Final shape depends on R5, R6, R8 | Architecture |
| API | Designed | — | — |
| UI | Designed | **Approved opt-in wording (D21)**, which also depends on R9 (the sending business) | Product, Legal |
| Permissions / D16 | Designed | Confirm A-1; R5 | Product; Architecture |
| Audit | Designed with the safe default (R12: no numbers) | L-2 may change the content before any production use; it does not block staging | Legal |
| Retention | Designed (A-3, A-5, R7) | Confirm A-9 / R7 | Product, Legal |
| Rollback | Designed (review B3) | — | — |
| Lifecycle regression tests | Designed (RG-1 to RG-13, P1-AC-14) | — | — |
| Test-number restriction | Procedural (P1-AC-15) | R8 decides whether it is enforced in code | Product, Architecture |
| Requirement IDs | **No** | R11: allocate IDs (proposal in §4) | Product |
| Working assumptions | **No** | A-1 to A-9 confirmed | Product |
| Legal L-1 to L-3 | Not started | Does not block staging with WiseWatts test numbers only (D17); blocks Phase 2 and production | Legal |
| Provider P-1 to P-4 | Desk research only | Not needed for Phase 1; blocks Phase 2 | Product + Engineering |

**Verdict:** not yet ready to request implementation approval. These must
be answered first:
- **Architecture:** R5.
- **Product:** A-1 to A-9, R7, R8 and R11; plus the decision to include R6
  or not.

The approved opt-in wording (D21, with R9) can follow during
implementation, but it is required **before staging deployment**.

## 2. Approval checklist

Each item is recorded with an owner, a date and evidence, in the README
or the ADR. Nothing below has been approved unless marked.

**Before requesting Phase 1 implementation approval:**
- [x] ADR-024 Amendment 2 Decided: Product Owner + Architecture, 2026-11-23
- [ ] R5: automation-account exclusion, in or out (Architecture)
- [ ] R6: consent-wording register, in or out (Product; Legal on sufficiency)
- [ ] R8: staging allow-list, in or out (Product + Architecture)
- [ ] R7 / A-9: keep numbers while disabled (Product; Legal may override)
- [ ] A-1 to A-8 confirmed (Product)
- [ ] R11: requirement IDs allocated (Product), see §4
- [ ] This package updated to the answers, and the effort re-estimated

**Phase 1 implementation approval** (explicit, separate):
- [ ] Approval to implement the final scope on a feature branch

**Before merge** (separate approval):
- [ ] All P1-AC criteria met; the full regression suite and CI green; code
      review complete; documentation updated in the same PR

**Before staging deployment** (separate approval):
- [ ] D21: the opt-in wording approved, naming the business per R9
      (Product + Legal on R9)
- [ ] If R6 is in scope, the wording is loaded into the register by
      migration
- [ ] Migration 331 applied through the normal staging deployment only

**Before any staging test save** (separate approval):
- [ ] Only WiseWatts-controlled test numbers (D17). If R8 is in scope,
      the allow-list is populated by a separately approved staging write.

**Not part of Phase 1:** Phase 2 gates (provider validation, legal
review, and per-item infrastructure approvals) and production gates
(ADR-024 production rollout and acceptance; ADR-026 Decided).

## 3. Final scope (for approval once §2 is answered)

**In scope** (staging and test only):
- **Migration 331:** two configuration tables, three new functions plus
  the mask helper, re-created `create_portal_alert_rule`,
  `update_portal_alert_rule` and `delete_portal_alert_rule`, the
  `whatsapp_requested` safeguard and CHECK, guarded grants,
  postconditions, and a rollback that deletes the stored numbers.
- **API:** `GET` and `PUT /api/v1/alert-rules/{rule_id}/whatsapp`, a
  configurer-only summary in rule responses, and the permission map entry.
- **UI:** the WhatsApp panel on rule edit, the configurer-only list badge,
  and removal of the Coming Soon WhatsApp checkbox.
- **Tests:** §7 of the plan, including RG-1 to RG-13.

**Optional, if approved:** R5 (+P1-AC-16), R6 (+P1-AC-17), R8 (+P1-AC-18).

**Out of scope:** phase-1-plan §9 — no message, provider, delivery
record, queue, sender, receipt endpoint, STOP handling, templates,
infrastructure or production.

## 4. Proposed requirement IDs (R11): for Product to confirm

Proposed only; not allocated until Product confirms. Next free ID after
`EMS-REQ-152`.

| Proposed ID | Requirement | Acceptance |
|---|---|---|
| EMS-REQ-153 | Per-rule WhatsApp configuration (on/off, 1–10 recipients), stored separately from the rule | P1-AC-1, -2, -3, -5 |
| EMS-REQ-154 | Per-number opt-in confirmation with the confirmer, the time and the wording version | P1-AC-5; P1-AC-17 if R6 |
| EMS-REQ-155 | WhatsApp configuration visible and editable only by `alert.configure` holders | P1-AC-4; P1-AC-16 if R5 |
| EMS-REQ-156 | WhatsApp saves never alter alert occurrences, timers, acknowledgements or rule versions | P1-AC-7, -8, -9, -14 |
| EMS-REQ-157 | The legacy Coming Soon WhatsApp preference is retired and never sends | P1-AC-9, -11 |
| EMS-REQ-158 | Every configuration and consent change is audited, without phone numbers (subject to L-2) | P1-AC-6, -12 |
| EMS-REQ-159 | No messages in Phase 1; staging uses WiseWatts test numbers only | P1-AC-10, -15; P1-AC-18 if R8 |

## 5. Effort estimate (rough, for planning)

| Work | Engineering days |
|---|---|
| Migration 331: tables, functions, three re-created functions, safeguard, grants, postconditions, registration, rollback | 2 |
| API routes, models, permission map, service | 1 |
| UI panel, rule-list badge, checkbox removal | 1.5 |
| Database tests (configuration, permissions, audit, concurrency) and regression matrix RG-1 to RG-13 | 2.5 |
| Route and web tests; intentional existing-test changes | 1 |
| Documentation updates, CI, review fixes | 0.5 |
| **Core total** | **≈ 8.5** |
| Optional: R5 / R6 / R8 | +0.5 each |
| Staging verification after an approved deployment | 0.5 |

Estimates assume the existing ADR-024 and migration 330 patterns are
reused, and exclude review waiting time.

## 6. Risks

| Risk | Mitigation |
|---|---|
| Re-creating three ADR-024 write functions could regress rule behaviour | RG-1 to RG-13 against control twins; the full `test_alert_rules_db.py`; the rollback restores the migration 323 definitions |
| Personal data collected before its purpose is live | D17 test numbers only; R8 optional enforcement; the rollback deletes the numbers |
| Legal outcome changes the audit or consent design | R12 safe default (no numbers in audit); R6 versioned wording; changes are additive |
| Staging and production function drift (331 is staging/test only) | Recorded; production receives it only with the WhatsApp production release (D11) |
| Deploy-window UX (old web, new API) | Customer API then web, back to back (R4); the ignored flag never sends |
| Small staging host | Phase 1 adds no service and no job; the load is configuration reads and writes only |
