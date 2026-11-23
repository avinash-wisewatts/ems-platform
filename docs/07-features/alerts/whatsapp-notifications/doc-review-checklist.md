# PR #186 — documentation review checklist

For the documentation reviewer. The Product Owner chose an **owner review**
(2026-11-23); no independent reviewer is assigned, so this is recorded as a
known limitation. Record
the outcome in §3. A pass permits the PR to leave draft for documentation
review and merge consideration **only**. It does not authorise Phase 1
implementation, merge, deployment or test saves.

Files: `docs/07-features/alerts/whatsapp-notifications/*`; ADR-024
(Amendment 2 and the notes); ADR-026; the decision log; the decisions
index; `functional-requirements.md`; the Alerts README.

## 1. Checks

| # | Area | Check | How to verify |
|---|---|---|---|
| 1 | PRD integrity | The PRD body is word for word as received; only the record note above it differs | `git diff 1824bab -- …/prd-draft-0.1.md` shows record-note lines only |
| 2 | PRD addendum | Every PRD discrepancy (including §16) is in the dated addendum, not edited into the PRD | Read the addendum against the PRD |
| 3 | Decisions D1–D21 | The decision tables are unchanged since they were recorded | Compare README §2.1 to `a750c5f` and §2.2 to `bc7899e` |
| 4 | ADR-024 Amendment 2 | Status Decided; both approvals recorded (role, date); scope limited to 2A–2E; delivery left in ADR-026; states that it is **not** implementation permission; R5 excluded | Read the amendment and its approval table |
| 5 | ADR-026 | Status Proposed; the decision conditions match D13 | Read the ADR header and the open-items section |
| 6 | Migration safeguard | Migration 331 refuses to run if any `whatsapp_requested` is true; adds the CHECK; the flag leaves the change comparison; rollback deletes numbers and restores the 323 functions | phase-1-plan §3.3, P1-AC-11, P1-AC-13 |
| 7 | Permissions / D16 | Only `alert.configure` holders see or edit WhatsApp data; other roles see no number, count or indicator; GET/PUT/summaries checked in route **and** database | phase-1-plan §3.5, §4, §5; P1-AC-4 |
| 8 | Consent | Per-number confirmation; a recipient id must belong to the rule (B2); the wording version is recorded; D21 wording required before staging deployment | phase-1-plan §3.2, §3.5; consent-wording-register.md |
| 9 | Audit | One row per effective save; no phone number, full or masked (R12 default); refused or no-op saves write nothing | phase-1-plan §3.5; P1-AC-6 |
| 10 | Lifecycle invariants | WhatsApp saves and no-op rule saves never change occurrence state, timers, acknowledgements or versions; operational edits still end alerts (ADR-024 §8) | phase-1-plan §7.2 RG-1 to RG-13; P1-AC-7, -8, -9, -14 |
| 11 | Phase 1 scope | Sends nothing; no provider, delivery records, queue, sender, receipt endpoint, STOP handling, templates, infrastructure or production | phase-1-plan §1, §9; approval package §3 |
| 12 | Gates | Implementation, merge, staging deployment and test saves each need separate approval; Phase 2 and production gates are stated | README §5; approval package §2 |
| 13 | Proposals vs decisions | Each item carries its recorded status, with owner and date where decided, and nothing open is shown as approved. **Decided:** ADR-024 Amendment 2 (Product Owner + Architecture). **Approved, in scope:** R5 (Architecture). **In scope:** R6 (Product; wording not supplied, Legal sufficiency open). **Confirmed:** A-1 to A-9 and R7 (Product; R7/A-9 subject to Legal L-3). **Allocated:** R11, `EMS-REQ-153`–`EMS-REQ-159`. **Out of scope:** R8. **Open / proposed:** R9, R10, R12, D21 wording, L-1 to L-3, P-1 to P-4; ADR-026 Proposed. All decisions dated 2026-11-23 | README §3, §4A; review-2026-11-23.md §7; approval package §1, §2, §4; consent-wording-register.md |
| 14 | Traceability | Each decision maps to an ADR section, a plan section and an acceptance criterion or test | README §5A |
| 15 | Links | All relative links resolve | Link check |

## 2. Author's mechanical-check record (not independent)

Each run names the commit it checked. A run applies to that commit only;
any later commit needs a new run.

| Commit checked | Date | Checks | Result |
|---|---|---|---|
| `8ce5f0a` | 2026-11-23 | 1, 3, 5, 15 | Pass (superseded) |
| `05204f7` | 2026-11-23 | 1 (PRD diff vs `1824bab`), 3 (D1–D13 rows vs `a750c5f`, D14–D21 rows vs `bc7899e`), 5 (ADR-026 Proposed in ADR, log, index), 15 (171 relative links, 0 broken) | Pass. Cross-document review found six inconsistencies (review record, check 13, this record, consent register, PR description, ADR-024 index row), corrected in the next commit |

The run for the commit that made those corrections is reported in the PR
#186 description, since a commit cannot record its own SHA. The other checks
were self-reviewed in review-2026-11-23.md. **This does not replace the
reviewer's review.**

## 3. Review record

| Reviewer (role) | Date | Outcome | Findings / follow-ups |
|---|---|---|---|
| Repository owner (Product Owner) — **owner review, not independent**; GitHub cannot record an approval from the PR author's account, so the outcome is recorded here | Assigned 2026-11-23 | **Pending** | — |
