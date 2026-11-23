# PRD Draft 0.1 — dated clarifications (addendum, 2026-11-23)

The PRD ([prd-draft-0.1.md](prd-draft-0.1.md)) is preserved word for word as
the source record. This addendum records, without rewriting it, where it is
out of date, superseded by the Product Owner's decisions D1–D21 of
2026-11-23 ([README.md §2](README.md#2-confirmed-decisions-product-owner-2026-11-23)),
or needs a terminology mapping. Where this addendum and the PRD differ, the
addendum and D1–D21 apply. Legal and provider questions (L-1 – L-3, P-1 –
P-4 in the README) are **not** decided by anything here.

| PRD section | PRD text (summary) | Clarification (2026-11-23) |
|---|---|---|
| Throughout | "Alert", "individual alert", "triggered alert" | An "alert" is an **alert rule** (ADR-024); "a triggered alert" is a rule's **occurrence** becoming Active. |
| §16 ¶1 | Workshop baseline: MVP alert delivery is in-product **and email**, WhatsApp deferred | **Out of date.** Email was removed from MVP scope by ADR-016 (note on `EMS-REQ-084`, 2026-09-14). Today alerts are in-product only; Email and WhatsApp are "Coming Soon" placeholders (ADR-024 §9). |
| §16 ¶2 | Admin Portal owns facility configuration; the customer EMS "primarily consumes configured information" | **Superseded for alerts.** ADR-024 (2026-11-18) moved alert-rule configuration into the customer EMS (superseding Workshop Q67 for alerts only). It still holds for every other kind of configuration. |
| §8.2; §15 item 7 | An explicit architecture decision is required for a customer write path | **Already decided** by ADR-024 §14–§16: same-origin JSON to `/api/v1`, a dedicated permission (`alert.configure`), SECURITY DEFINER write functions that re-check access, and an audit row in the same transaction. WhatsApp configuration reuses it (ADR-026). |
| §9; §15 item 1 | Provider not decided | **D1:** Meta WhatsApp Business Cloud API preferred, subject to validation; no integration commitment. |
| §15 items 2–3 | Verification and consent open | **D4:** explicit administrator opt-in confirmation per number; STOP opt-out subject to provider capability and legal review; no OTP initially. **D21:** the exact confirmation wording is defined and approved by Product before use. **D19:** legal sufficiency is open (L-1); compliance is not assumed. |
| §15 item 4 | Alert scope open | **D3/D5:** any rule may enable WhatsApp; off by default. |
| §15 item 5 | Repeat notifications open | **D7:** one message per occurrence and recipient; duplicates for the same occurrence/recipient suppressed within 60 minutes; no reminders. **D14:** plus a 60-minute quiet period per rule and recipient across separate occurrences. |
| §15 item 6 | Recovery messages open | **D7:** none in the initial release. |
| §15 item 8 | Template governance open | **D8:** WiseWatts Product owns wording and templates. |
| §4 | Two configuring roles; delivery history visible to them | **D9:** full numbers only to admins managing configuration; delivery history masked. **D16:** Operators and Viewers see no recipient information in Phase 1 (masked history reconsidered when delivery records exist). |
| FR-01 | "Disabling WhatsApp must not disable the underlying alert" | **D6 strengthens this:** saving any WhatsApp setting never ends an Active occurrence, resets a timer or re-triggers. |
| FR-01 / existing UI | — | **D5:** the existing "Coming Soon" WhatsApp checkbox never activates sending. **D20:** it is removed in Phase 1, behind the migration 331 safeguard and regression tests. |
| FR-02 | Multiple numbers, no stated limit | **D15:** at most 10 per rule. |
| FR-06; §8.4 | Delivery records; storm protection | **D18:** per-site message cap deferred to Phase 2. |
| §14 Phase 1 | Configuration | **D17:** WiseWatts-controlled test numbers only on staging; no real customer numbers before sending exists. |
| §8.3 | Verification/consent status "if implemented" | Consent state is **required** (D4). No verification status (no OTP). |
| FR-06; §10 Auditability | Delivery records | **D10:** 90-day retention initially; masked numbers (D9). Delivery records are Phase 2+. |
| §14 | Phase 1 – configuration; Phase 2 – integration; Phase 3 – readiness | Phase 1 is staging-only and sends nothing ([phase-1-plan.md](phase-1-plan.md)). Queue, sender, receipt endpoint, egress and secrets each need separate approval (D12). No production rollout before ADR-024 is in production and accepted (D11). |
| §11 | AC-1 – AC-15 | Adopted with refinements and AC-16 – AC-20 ([README.md §8](README.md#8-acceptance-criteria--whole-feature)). |
