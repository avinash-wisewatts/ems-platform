# WiseWatts EMS — Product Documentation

> **Status:** WORKING DRAFT  ·  **Version:** 0.1  ·  **Owner:** Product  ·  **Last updated:** 2026-09-10
>
> **Source basis:** the authoritative DDS documents (below), the product-owner brief that commissioned this set, PR #44, and the ZeroWatt EMS video + `Zerowatt-Technical-Overview.pdf` (**reference / inspiration only**, not committed to this repo, not a specification to copy).

This directory defines **what WiseWatts is building for the customer** — the customer-facing **EMS Web Application**, distinct from the existing **Administration App**. It is a **v0.1 working product definition**: not final, subject to product-owner review, and deliberately explicit about what is a decision vs. an inference vs. an open question.

**It does not implement anything.** No UI, no backend, no schema. It is the shared reference the product owner and engineering use before Phase 9 implementation begins.

---

## Which document answers which question

| # | Document | Answers | Read it when you want to know… |
|---|---|---|---|
| A | [`ems-product-definition.md`](ems-product-definition.md) | *What are we building for the customer, and why?* | the vision, the four-stage experience (MONITOR→INVESTIGATE→IMPROVE→MEASURE), target users, the Administration-App vs EMS-Web-App boundary, the customer journey, product principles, terminology, goals, non-goals, and the product owner's five key questions. |
| B | [`ems-customer-requirements.md`](ems-customer-requirements.md) | *What specific capabilities, at what priority, from where?* | the requirements catalogue (`EMS-REQ-001…`), each with customer question, priority (`MUST/SHOULD/COULD/LATER/NOT-IN-SCOPE`), source, status, dependencies, phase; the NOT-IN-SCOPE list; the ZeroWatt 25-capability cross-reference. |
| C | [`ems-information-architecture.md`](ems-information-architecture.md) | *What screens, what does each show, how do they connect?* | the navigation hypothesis, cross-cutting UX rules, and ~21 screen breakdowns (purpose · customer question · primary/secondary info · filters · time context · drill-down · empty/no-data/error states · future considerations · API-dependency status). |
| D | [`ems-product-architecture.md`](ems-product-architecture.md) | *How does the product sit on top of the frozen platform?* | the layering, application boundaries, the Analytics API boundary, customer-vs-admin responsibilities, semantic-exposure rules, auth principles, `/app` as a routing detail, the independent-deployment principle, Grafana's OPS role, and the relationship to the authoritative DDS. **Does not replace the DDS.** |
| E | [`ems-product-roadmap.md`](ems-product-roadmap.md) | *What customer outcome does each technical phase deliver?* | a customer-outcome view of technical Phases 7–17 (phase objectives quoted verbatim; the authoritative roadmap is unchanged), a capability→phase map, and the proposed Phase 9 starting point. |
| F | [`ems-requirements-traceability.md`](ems-requirements-traceability.md) | *Does every UI idea have the semantic/API support to build it?* | the control matrix `requirement → screen → API capability → semantic/data capability → phase → status`; the buildable-now set; the blocked-by-decision register; anti-pattern guardrails. |
| G | `README.md` (this) | *Where do I start?* | this table, the reading paths, and the labelling scheme. |

### Reading paths

- **Product owner:** A → C → B (§15 priority summary) → A §13 (your five questions) → F §4 (what's blocked on you).
- **Engineer / architect:** D → F → E → B. Then: *"where does requirement X fit in the architecture and roadmap?"* is answered by F's matrix row for X.
- **New joiner:** A, then this README's table.

---

## Authoritative technical architecture — the DDS

These remain **authoritative for platform architecture**. Nothing in `docs/product/` overrides them.

| Document | Role |
|---|---|
| [`../DDS/analytics-platform-future-state-architecture.md`](../DDS/analytics-platform-future-state-architecture.md) | **CONCEPTUALLY FROZEN** conceptual data architecture — entities, relationships, rules. §F.0 (added by PR #44) defines the Administration-App / EMS-Web-App boundary. |
| [`../DDS/analytics-platform-future-state-architecture-implementation-roadmap.md`](../DDS/analytics-platform-future-state-architecture-implementation-roadmap.md) | The phased technical implementation plan (Phases 0–17). Implements the frozen architecture; does not redefine it. |
| [`../DDS/analytics-platform-future-state-architecture-review.md`](../DDS/analytics-platform-future-state-architecture-review.md) | Red-team review — evidentiary record of corrections. |
| [`../DDS/analytics-platform-future-state-architecture-stress-test.md`](../DDS/analytics-platform-future-state-architecture-stress-test.md) | Ten-scenario practical validation — evidentiary record. |

Related operational docs: [`../operations/PHASE8_FRONTEND_DEPLOYMENT.md`](../operations/PHASE8_FRONTEND_DEPLOYMENT.md) (how the EMS Web App is delivered to staging today), [`../operations/CICD_PIPELINE.md`](../operations/CICD_PIPELINE.md) (build-once → promote-the-same-artifact), [`../platform-manual/12-grafana.md`](../platform-manual/12-grafana.md) (Grafana's current role).

---

## Evidence labelling (used throughout this set)

Every non-trivial statement is tagged so a reader can see its provenance:

| Tag | Meaning |
|---|---|
| `[ZEROWATT-OBSERVED]` | Seen in the ZeroWatt demo / technical overview. Reference only — **not** automatically a WiseWatts requirement. |
| `[INFERRED]` | A reasonable deduction by the author. **Not fact.** Needs confirmation. |
| `[WISEWATTS-DECISION]` | A deliberate WiseWatts product choice recorded here (still a v0.1 draft choice). |
| `[ARCH-CONSTRAINT]` | Imposed by the frozen DDS / existing platform. Not negotiable at the product layer. |
| `[OPEN]` | `OPEN — PRODUCT DECISION REQUIRED`. No answer yet; not invented. |

Requirement **sources** (doc B): `PRODUCT_OWNER` · `ARCHITECTURE` · `ROADMAP` · `ZEROWATT_DEMO` · `ZEROWATT_TECHNICAL_REFERENCE` · `INFERENCE`.

---

## Status of this set

- **v0.1 — working draft.** Every priority and hypothesis is provisional. Items marked `PO-REVIEW` / `OPEN — PRODUCT DECISION REQUIRED` need the product owner.
- **No architecture change.** The only DDS edit connected to this effort is the already-merged **PR #44** (new §F.0 + Phase 8 wording), which made the application/deployment boundary explicit without changing the frozen model. Product requirements that would need an architecture change are recorded as explicit dependencies (doc F §4), not adopted.
- **No implementation.** Producing this set changed **documentation only**.

## Version history

| Version | Date | Change |
|---|---|---|
| 0.1 | 2026-09-10 | Initial product documentation set (A–G) created together. |
