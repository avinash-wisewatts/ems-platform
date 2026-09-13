# WiseWatts EMS — Product Owner Workshop Baseline (Decision Record)

> **Status:** WORKSHOP BASELINE — IN PROGRESS · **Version:** 0.1 (workshop record, not a product document version) · **Owner:** Product · **Last updated:** 2026-09-11 (Session 2 addendum appended — see §17 onward and Document History)
>
> **This document does not modify, supersede, or formally update** `ems-product-definition.md`, `ems-customer-requirements.md`, `ems-information-architecture.md`, `ems-product-architecture.md`, `ems-product-roadmap.md`, `ems-requirements-traceability.md`, or `README.md`. Those remain the current **v0.1** documented product baseline, unchanged by this record.

---

## 1. Title

**WiseWatts EMS — Product Owner Workshop Baseline: Decisions Captured Before Continuing the Workshop**

---

## 2. Purpose

The Product Owner Workshop has been underway and has produced a set of explicit product-direction decisions. This document exists **only** to capture and preserve those decisions in durable, written form **before** the workshop continues and partner feedback is collected — so that nothing agreed so far is lost, re-litigated by accident, or misremembered between sessions.

This is a **decision record**, not a product specification and not a revision of the existing documentation set.

---

## 3. Status / Scope

- The workshop is **in progress**, not complete.
- This document reflects decisions made **as of 2026-09-11**. Further workshop sessions and partner feedback may add to, refine, or (rarely) revisit items marked DECIDED here — if that happens, it should be recorded as a new dated decision, not a silent edit of this record.
- **No v0.2 product documentation has been created.** This record will be one input to a future v0.2 update.
- **No requirements, IA, roadmap, or architecture changes are made by this document.**
- **Phase 9 has not started and is not scoped here.**
- **No code, database, API, or infrastructure changes are made or implied by this document.** This is a documentation-only artifact, consistent with `docs/operations/LOCAL_DEVELOPMENT_BOUNDARIES.md` and the project's production/staging safety rules.

---

## 4. Relationship to v0.1 Product Documentation

- The existing seven documents under `docs/product/` (`README.md`, `ems-product-definition.md`, `ems-customer-requirements.md`, `ems-information-architecture.md`, `ems-product-architecture.md`, `ems-product-roadmap.md`, `ems-requirements-traceability.md`) remain the **current, unaltered, authoritative v0.1 working product documentation**.
- This document does **not** rewrite, correct, or reinterpret those documents. Where this record's direction appears to differ from current v0.1 wording (see §15), that difference is noted explicitly and left for the product owner to resolve when v0.2 is prepared — it is **not** resolved here.
- Workshop decisions captured here are **additional product-owner direction**, layered on top of v0.1, to be used as an input when `ems-product-definition.md` and related documents are eventually revised to **v0.2**.
- The frozen platform architecture / DDS (`docs/DDS/analytics-platform-future-state-architecture*.md`) remains fully authoritative and is not touched or reinterpreted by this document. The customer-facing EMS does not override platform architecture.

---

## 5. Product Owner Workshop Decisions (Summary)

The following have been **explicitly agreed** during the Product Owner Workshop. Full detail is in §6–§11; a consolidated table is in §14.

1. **Product identity:** WiseWatts is an *Energy Management System that happens to contain dashboards* — not a dashboards/analytics/charting product.
2. **Product north star:** the **Energy Management Cycle** is the higher-level product/business framework the EMS should support.
3. **Customer job:** provide visibility into energy use and performance that helps drive optimisation and ultimately enables WiseWatts to provide recommendations. Visibility is the immediate job, not the destination.
4. **Initial product promise:** Visibility + Basic Alerting + Reporting — an initial scope, not the final capability ceiling.
5. **Primary customer:** Facility Manager / Energy Manager. Homeowners are a possible future segment — experience model OPEN.
6. **Business outcomes:** track, manage, optimise energy use; reduce cost; progress sustainability goals — sustainability is secondary to core energy-management/optimisation.
7. **Long-term vision (3–5 years):** WiseWatts as an **Energy Intelligence Platform with AI**.
8. **Product maturity/evolution:** a question-driven progression from "What is happening?" through to "Can WiseWatts help optimise/manage this automatically?"
9. **Energy Management Cycle vs. MONITOR→INVESTIGATE→IMPROVE→MEASURE:** the two coexist — the Cycle is the business framework; MONITOR/INVESTIGATE/IMPROVE/MEASURE is the digital/product experience model that progressively supports it.
10. **Product principle:** design around customer energy-management outcomes and questions, not around screens, chart types, database/telemetry structures, or Grafana concepts.
11. **Initial product boundary:** establish trustworthy visibility (see, understand, notice via basic alerts, obtain useful reports) — explicitly **not** automated optimisation, AI recommendations, autonomous control, or predictive optimisation yet.
12. **Long-term product direction:** SEE → UNDERSTAND → DECIDE → ACT → VERIFY → OPTIMISE → AUTOMATE, recorded as conceptual direction, not a committed roadmap.

---

## 6. Energy Management Cycle as Product North Star

**WORKSHOP DECISION.** The **Energy Management Cycle**, introduced and discussed in the Product Owner Workshop, is the overarching product/business framework for WiseWatts EMS. The product should be organised around supporting a customer's progress through this cycle, rather than being organised primarily as a collection of screens.

This is a higher-level framework than — and sits above — the existing four-stage digital experience model (MONITOR → INVESTIGATE → IMPROVE → MEASURE) documented in `ems-product-definition.md`. See §9 for how the two relate.

`INFERENCE / HYPOTHESIS`: no specific stage names, boundaries, or artifacts of the "Energy Management Cycle" beyond what is stated in this document have been formally defined yet. Do not assume a specific published cycle diagram is canonical until the product owner confirms one.

---

## 7. Product Maturity / Evolution

**WORKSHOP DECISION.** The intended customer-facing product progression, framed as the question the product answers at each stage:

| Stage | Customer question | Product concept |
|---|---|---|
| Today / initial | "What is happening?" | VISIBILITY |
| Next | "Why is it happening?" | UNDERSTANDING / INVESTIGATION |
| Then | "Where should I focus?" | OPTIMISATION / PRIORITISATION |
| Then | "What should I do?" | RECOMMENDATIONS |
| Then | "Did it work?" | VERIFICATION / MEASUREMENT |
| Longer term | "What will happen and what should I do?" | ENERGY INTELLIGENCE |
| Eventually | "Can WiseWatts help optimise/manage this automatically?" | AI / AUTOMATION |

A parallel, complementary framing of the same long-term direction was also agreed:

**SEE → UNDERSTAND → DECIDE → ACT → VERIFY → OPTIMISE → AUTOMATE**

`WORKSHOP DECISION`: both framings represent **product direction**, not a committed implementation roadmap and not Phase 9 requirements. Neither framing should be converted into phase scope without further product owner work.

---

## 8. Primary Customer

**WORKSHOP DECISION.** The primary customer/user for the initial EMS experience is the **Facility Manager / Energy Manager**.

**OPEN.** Homeowners are a potential future customer segment. It has **not** been decided whether homeowners will:
- use the same EMS experience with simplified presentation, or
- require a distinct experience, or
- require a separate product.

No solution to the homeowner question is proposed or implied by this document.

---

## 9. Initial Product Promise

**WORKSHOP DECISION.** The initial product promise/scope is:

**Visibility + Basic Alerting + Reporting.**

This is explicitly an **initial** scope, not a ceiling. The product is expected to mature beyond this over time (see §7, §11).

**Customer job (WORKSHOP DECISION):** "Provide visibility into their energy use and performance that helps drive optimisation and ultimately enables WiseWatts to provide recommendations." Visibility is the immediate job; it is the foundation for understanding, optimisation, recommendations, and eventually AI-assisted optimisation — it is **not** the final destination and must not be simplified to "we provide dashboards."

**Business outcomes (WORKSHOP DECISION):** the product ultimately exists to help customers track, manage, and optimise energy use; reduce energy bills/cost; and progress toward green/sustainability goals. Sustainability/green goals are **secondary** to the core energy-management/optimisation objective. The initial product must not be positioned as already delivering automated optimisation or guaranteed savings.

**Initial product boundary (WORKSHOP DECISION):** the first meaningful experience should help a facility/energy manager see what is happening with energy, understand important performance information, notice important problems through basic alerts, and obtain useful reports. It must **not** be presented as already providing automated optimisation, AI recommendations, autonomous control, full energy intelligence, or predictive optimisation — those are future directions.

---

## 10. Long-Term Energy Intelligence / AI Vision

**WORKSHOP DECISION.** The 3–5 year ambition is: **WiseWatts as an Energy Intelligence Platform with AI.**

The product should progressively evolve from visibility toward increasingly intelligent energy management, following the progression in §7.

This is a **strategic direction**, not a request to implement AI now, and must not be introduced into Phase 9 scope.

---

## 11. Product Principles

**WORKSHOP DECISION — Product identity.** WiseWatts is an *"Energy Management System that happens to contain dashboards,"* not a dashboard product that happens to support energy management, not a collection of Grafana-style dashboards, and not a generic analytics/charting product. Dashboards, charts, KPIs, and visualisations are **mechanisms inside** the EMS, in service of the customer's energy-management work — not the product itself.

**WORKSHOP DECISION — Design principle.** The EMS should be designed around **customer energy-management outcomes and questions**, rather than around screens, chart types, database structures, telemetry structures, Grafana dashboards, raw tags, or other technical implementation concepts. The customer should be able to move from visibility to the next useful energy-management question. A KPI or chart is a means of supporting the energy-management journey, not the end product.

---

## 12. Explicit Open Decisions

The following are **NOT YET DECIDED**. No answer is proposed here; they remain for further Product Owner discussion, partner feedback, and customer feedback.

| # | Topic | Notes |
|---|---|---|
| 1 | **Product differentiation** | What WiseWatts should do substantially better than conventional Grafana/dashboard systems, existing EMS products, or other competitors is **not known**. A hypothesis exists that differentiation may eventually come from energy intelligence and optimisation — this is explicitly a hypothesis, **not** a decided differentiation statement. |
| 2 | **Homeowner experience** | Same product with simplified UX vs. distinct experience vs. separate product — undetermined (see §8). |
| 3 | **Remaining v0.1 open decisions** | The existing v0.1 documents already carry additional open items not resolved by this workshop record, including: first landing page; portfolio-first vs. site-first; Site Overview headline metrics; multi-site selection; customer roles; alert appearance/configuration; energy cost capabilities; initial target industries; asset detail depth; report formats; Space as navigation vs. drill-down; functional categories; definition of "normal"/expected performance; correlations; customer write capabilities; portfolio aggregation; performance budgets; and other items identified in the existing documents (see in particular `ems-product-definition.md` §13 "Product owner's five key questions" and the `OPEN — PRODUCT DECISION REQUIRED` items across docs B, C, and F). This workshop record does not resolve any of them. |

---

## 13. Partner Feedback Still to Be Collected

The workshop is intentionally paused at this baseline so that partner feedback can be gathered before continuing. Feedback is expected to inform, at minimum:

- Reaction to the product identity framing ("EMS that happens to contain dashboards").
- Validation or challenge of the Energy Management Cycle as the north-star framework.
- Input on product differentiation (§12, item 1) — currently unanswered.
- Input on the homeowner segment question (§12, item 2).
- Reaction to the initial promise (Visibility + Basic Alerting + Reporting) as a credible first release scope.
- Any additional priorities, constraints, or concerns partners raise that are not yet reflected in v0.1 documentation or in this record.

No partner feedback has been incorporated into this document yet — this section is a placeholder describing what is still owed, not a record of feedback received.

---

## 14. Workshop Decision Log / Table

| Topic | Status | Decision |
|---|---|---|
| Product identity | DECIDED | Energy Management System that happens to contain dashboards |
| Product north star | DECIDED | Energy Management Cycle |
| Relationship to MONITOR→INVESTIGATE→IMPROVE→MEASURE | DECIDED | Coexist: Cycle = business framework; MONITOR/INVESTIGATE/IMPROVE/MEASURE = digital experience model supporting it |
| Customer job | DECIDED | Visibility that helps drive optimisation and enables recommendations |
| Initial product | DECIDED | Visibility + Basic Alerting + Reporting |
| Primary customer | DECIDED | Facility Manager / Energy Manager |
| Homeowners | OPEN | Customer segment/experience still to determine |
| Business outcomes | DECIDED | Track/manage/optimise energy, reduce cost, progress sustainability — sustainability secondary to core optimisation objective |
| Initial product boundary | DECIDED | Trustworthy visibility, basic alerts, useful reports — not automation/AI/autonomous control yet |
| Product maturity progression | DECIDED (direction only) | Visibility → Understanding → Optimisation → Recommendations → Energy Intelligence → AI/Automation |
| Alternate maturity framing | DECIDED (direction only) | See → Understand → Decide → Act → Verify → Optimise → Automate |
| Long-term vision | DECIDED | Energy Intelligence Platform with AI in 3–5 years |
| Design principle | DECIDED | Organise around customer outcomes/questions, not screens/charts/technical structures |
| Differentiation | OPEN | To be determined through further discussion/feedback |
| Remaining v0.1 open items | OPEN | Carried forward unchanged from existing docs; not resolved here |

---

## 15. What This Document Does NOT Decide

- It does **not** create, approve, or imply EMS Product Definition **v0.2**. v0.1 remains current.
- It does **not** change `ems-customer-requirements.md`, `ems-information-architecture.md`, `ems-product-architecture.md`, `ems-product-roadmap.md`, `ems-requirements-traceability.md`, or `README.md`.
- It does **not** define, scope, or start **Phase 9**.
- It does **not** define UI, wireframes, or implementation requirements.
- It does **not** change platform/database/architecture — the frozen DDS remains authoritative.
- It does **not** resolve product differentiation, the homeowner experience question, or any of the other OPEN items in §12.
- It does **not** claim the Product Owner Workshop is complete.
- It does **not** assert that the existing v0.1 documents have been reconciled with this direction — see note below.

**Note on potential contradiction:** `ems-product-definition.md` §1 currently frames the product primarily around the MONITOR→INVESTIGATE→IMPROVE→MEASURE four-stage experience without an explicit higher-level "Energy Management Cycle" framing above it, and does not yet state the product-identity line ("EMS that happens to contain dashboards") verbatim. This is **not** a contradiction to be fixed in this task — it is flagged here as something to reconcile when v0.2 is prepared, per §4.

---

## 16. Next-Step Process

1. Circulate this baseline to Product Owner Workshop participants for review before the next session.
2. Continue the Product Owner Workshop and collect partner feedback per §13.
3. Resolve or further refine the OPEN items in §12 as feedback arrives, recording new decisions with a dated entry (do not silently edit history in this document — append/update with clear dating).
4. Once the workshop concludes (or reaches a stable enough state), use this record, together with partner feedback, as an input to prepare **EMS Product Definition v0.2**, which would then formally update the v0.1 document set.
5. Only after v0.2 is agreed should Phase 9 scoping begin, following the existing `ems-product-roadmap.md` process.

---

# WORKSHOP SESSION 2 ADDENDUM (2026-09-11)

> Everything above this line (§1–§16, including the original §14 decision table and §12 open-items table) is the **Session 1 baseline** and is preserved unchanged. This addendum records additional Product Owner decisions (Q1–Q15) agreed in a subsequent workshop session on the same date. Where a Session 2 item restates or elaborates a Session 1 decision, that is noted explicitly rather than silently merged — Session 1 wording is not edited.

---

## 17. Session 2 — Purpose and Scope

This addendum captures decisions Q1–Q15 discussed in the second Product Owner Workshop session. It does **not** alter §1–§16 above. It does not create Product Definition v0.2, does not start Phase 9, and does not change any of the seven existing v0.1 product documents. The workshop remains **in progress**.

---

## 18. Q1 — Customer Job (reaffirmed)

**DECIDED (reaffirms Session 1 §9, no change in substance).** "Provide visibility into their energy use and performance that helps drive optimisation and ultimately enables WiseWatts to provide recommendations."

Interpretation reaffirmed and made explicit in this session:
- Visibility is the **immediate** job.
- Visibility is the **foundation** for optimisation.
- Visibility enables increasingly intelligent recommendations over time.
- The initial product must **not** claim to already provide automated optimisation.

This does not change the Session 1 decision; it is recorded here to keep Q1–Q15 as a complete, traceable set for this session.

---

## 19. Q2 — Customer Outcome

**DECIDED.** The customer outcome is expressed as three **progressive and complementary** stages — not competing alternatives:

| Stage | Customer-facing statement |
|---|---|
| A. SEE & UNDERSTAND | "I can see and understand how my facility is performing." |
| B. IDENTIFY & PRIORITISE | "I can identify where energy is being wasted or where performance needs attention." |
| C. IMPROVE & OPTIMISE | "I can continuously improve the energy performance of my facility." |

**The primary long-term customer outcome is continuous improvement of energy performance** (stage C). The progression is:

**SEE & UNDERSTAND → IDENTIFY & PRIORITISE → IMPROVE & OPTIMISE**

`WORKSHOP DECISION`: this must **not** be reduced to "visibility only." Visibility is the starting point; optimisation is the ultimate customer outcome. This refines (does not contradict) the Session 1 §7 maturity table by naming the three-stage customer-outcome framing explicitly.

---

## 20. Q3 — Immediate Post-Login Experience

**DECIDED AT PRINCIPLE LEVEL.** The immediate post-login experience should provide **instant financial and operational visibility**.

For primary B2B users, the EMS should immediately communicate:
- overall performance/health
- financial impact
- operational/electrical risks
- things requiring attention

Core question: **"How am I doing, and is there anything I need to pay attention to?"**

The experience should connect: **energy performance → operational condition → financial impact → potential action.**

**Candidate B2B hero concepts discussed (`HYPOTHESIS / CANDIDATE — NOT COMMITTED MVP REQUIREMENTS` unless separately marked decided):**
- Realized Savings This Month
- Pending Leakage Alert
- Maximum Demand Risk Gauge
- Power Quality Widget
- PF financial/incentive/penalty interpretation
- THD
- Contract Demand exposure
- ToD / Dynamic Tariff Calendar
- Financial impact of operational inefficiencies

`IMPORTANT`: these are product hypotheses / candidate capabilities, not a committed MVP list. Do not convert any individual example into a committed requirement without a separate decision. Financial calculations (actual savings, tariff impact, PF incentives/penalties, etc.) must eventually be based on defensible data and methodology (see §29, Q15). Tariff rules must **not** be assumed to apply universally across all Indian DISCOMs — DISCOM/state scope is OPEN.

---

## 21. B2B India Product Principle

**DECIDED.** For Indian B2B customers, the financial and operational consequences of energy performance should be highly visible. The EMS should translate technical energy/electrical metrics into business meaning **where the necessary data and methodology are available**.

Example: instead of merely showing `PF = 0.92`, the product should eventually communicate the relevant financial implication where it can be reliably calculated. Similarly, Maximum Demand should be understood in the context of Contract Demand and financial exposure.

---

## 22. Maximum Demand and Power Quality

**DECIDED PRODUCT DIRECTION.** To deliver maximum financial/operational value to Indian B2B clients, the first B2B snapshot must include:
- **Maximum Demand monitoring** — presented in terms of operational and financial risk.
- **Power Quality** — including relevant measures such as Power Factor and Total Harmonic Distortion.

PF should ultimately be framed in terms of its financial/operational significance rather than simply presented as an electrical engineering metric.

`OPEN`: the exact financial formulas, tariff rules, incentive/penalty calculations, and supported DISCOM/state scope remain open and require validation.

---

## 23. B2C Residential Experience

**DECIDED PRODUCT DIRECTION.** For B2C residential users, technical B2B terminology should be abstracted away. The residential experience should be simpler and action-oriented.

Example discussed: instead of exposing "Maximum Demand" terminology, the customer could receive a simple appliance-overload warning. Another candidate concept discussed: a **"Billing Slab Progress Bar"** showing how many kWh remain before crossing into the next electricity billing slab.

`IMPORTANT — OPEN`: the exact B2C product/UX strategy remains open. Do not assume B2C is already committed to the same product experience as B2B.

---

## 24. Q4 — Context-Aware Experience

**DECIDED.** WiseWatts should provide a **context-aware** experience. The customer hierarchy is:

**Organisation / Portfolio → Site → Space → Asset**

The product should understand the customer's scope — e.g., a single-site user primarily sees site context, a multi-site user primarily sees organisation/portfolio context, and users should be able to move naturally between levels. The customer should always understand what organisational level they are currently viewing.

`WORKSHOP DECISION`: context is not merely navigation — it **changes the meaning of performance metrics**. Examples:
- Organisation/Portfolio: "Which sites need attention?"
- Site: "How is this facility performing?"
- Space: "Where is the problem occurring?"
- Asset: "What equipment/system may be contributing?"

Single-site customers must not be forced through unnecessary portfolio ceremony.

---

## 25. Q5 — First Question the EMS Should Answer

**DECIDED.** The first experience should answer a combination of:
- How am I doing?
- Am I performing well?
- Am I spending more than expected?
- Is there financial leakage or risk?
- Is there an operational issue?
- Where should I look next?

Concise customer-facing formulation: **"How am I doing, and is there anything I need to pay attention to?"**

The product should provide an overall performance/health answer first, then surface important financial and operational exceptions. This must **not** be treated as five unrelated KPI cards. Desired conceptual flow:

**Overall status → important signals → financial/operational impact → investigation**

---

## 26. Q6 — Definition of Normal / Healthy / Expected

**DECIDED PRINCIPLE.** There is **no single definition** of "normal" or "healthy" across the EMS. Different metrics require different forms of comparison, context, and thresholds. Examples:

| Metric | Comparison basis |
|---|---|
| Energy consumption | historical performance / expected consumption |
| Maximum Demand | contract demand / configured limits |
| Power Factor | applicable operational/financial threshold |
| THD | electrical quality threshold |
| Temperature | appropriate operating/comfort range |
| Energy cost | tariff/billing context |
| Equipment performance | expected operating behaviour |
| Site performance | combination of relevant indicators |
| Future AI | modelled expected performance |

`WORKSHOP DECISION`: WiseWatts should explain what a performance assessment is being compared against, e.g. "Energy use is 14% above expected," "MD Risk: 91% of contracted demand," "PF: below configured target." **Do not create one universal baseline definition.** The specific methodology for each metric remains a future (OPEN) product decision.

---

## 27. Q7 — Response When Something Needs Attention

**DECIDED.** WiseWatts should progressively: **ALERT → EXPLAIN → RECOMMEND**, eventually progressing to **ACT / AUTOMATE**.

- Alert: "Something needs your attention."
- Explain: "Here is what is happening, where, when and why it appears significant."
- Recommend: "Here is what you could do about it."

Example conceptual journey: MD Risk: High → Why is MD increasing? → Which equipment/operation is driving the peak? → What can I change? → What financial impact could that have? → Did the change reduce MD?

`WORKSHOP DECISION`: alerts and analytics should be considered parts of the customer journey, not merely isolated product sections.

---

## 28. Q8 — What the Customer Can Do With Recommendations

**DECIDED.** Long-term, WiseWatts should progressively support: **INFORM → MANAGE → VERIFY → AUTOMATE** — but these capabilities must be **phased**.

| Stage | Description | MVP? |
|---|---|---|
| INFORM | WiseWatts identifies an issue/opportunity and informs the customer; the customer acts outside WiseWatts. | **MVP** |
| MANAGE | WiseWatts helps customers acknowledge, assign, record, and track actions/interventions. | Next — **not MVP** |
| VERIFY | WiseWatts measures whether the intervention improved performance. | Next — **not MVP** |
| AUTOMATE | WiseWatts increasingly supports authorised optimisation/automation. | Later — **not MVP** |

`IMPORTANT`: do **not** treat Manage, Verify, or Automate as MVP requirements.

---

## 29. Q9 — Verification

**DECIDED.** Verification of improvement is a **fundamental responsibility** of WiseWatts. The long-term EMS should close the loop:

**Identify → Recommend → Act → Measure → Verify → Learn → Optimise**

WiseWatts should eventually answer "Did that action actually improve energy performance?" — e.g., did consumption reduce, did Maximum Demand reduce, did financial cost reduce, was the improvement sustained. The EMS must not stop at identifying problems or opportunities.

---

## 30. Q10 — Configured + Adaptive Intelligence

**DECIDED.** WiseWatts should use **both**:

1. **Configured/authoritative intelligence** — e.g. Contract Demand, tariff information, customer targets, operating limits, known schedules, equipment configuration, customer-defined thresholds.
2. **Adaptive/learned intelligence** — e.g. normal consumption patterns, demand patterns, equipment behaviour, seasonal behaviour, recurring anomalies, relationships between conditions and energy performance, effectiveness of interventions.

Core principle: **"Authoritative facts are configured; contextual intelligence is learned."** Do not assume AI should override authoritative customer/system information.

---

## 31. Q11 — Progressive Configuration

**DECIDED.** WiseWatts should use **progressive configuration**: start with the minimum information needed to provide useful value, and request additional configuration only when it materially improves a capability or enables a new level of intelligence.

Conceptual progression: **Connect → See → Learn → Ask for context → Improve intelligence**

Examples:
- Initial: telemetry, site identity, basic energy visibility.
- Later, when needed: Contract Demand → MD Risk; tariff → financial optimisation; operating schedule → better expected-performance analysis; asset relationships → attribution; targets → target-based assessment.

Core principle: **"Don't make the customer configure the EMS before they can get value from it."**

---

## 32. Q12 — Proactivity / Intelligence Maturity

**DECIDED.** WiseWatts should progressively move from reactive visibility to proactive, predictive, and eventually automated energy management. Maturity levels: **1. Customer asks → 2. Alert → 3. Insight → 4. Recommendation → 5. Prediction → 6. Automation.**

**MVP:** customer asks + basic alerting.

`WORKSHOP DECISION`: before productised insight/recommendation capabilities exist, the WiseWatts team can **manually** analyse customer data and provide insights, identification of opportunities, recommendations, and interpretation of unusual behaviour. This is **intentional human-in-the-loop product maturation**, not something that needs to be hidden.

Progression:

Data → WiseWatts team analysis → Insight → Recommendation → Customer action → Result
*(then progressively)*
Data → EMS insight → EMS recommendation → Customer action → Verification
*(eventually)*
Data → AI Energy Intelligence → Recommendation → Action → Verification → Continuous optimisation

---

## 33. Q13 — Reporting

**DECIDED.** Reporting has **two complementary purposes**, which must **not** be collapsed into one capability:

1. **Communication** — concise, decision-oriented reports for direct operational and management reviews. Answers: "What happened, what matters, and what should we discuss?"
2. **Data export** — detailed underlying data for customers who need extensive analysis outside WiseWatts. Answers: "Give me the underlying information so I can analyse it myself."

The EMS should provide opinionated intelligence while still allowing sophisticated users to access appropriate underlying data.

---

## 34. Q14 — Trust / Explainability

**DECIDED.** Transparency and explainability are **fundamental EMS principles**. Whenever WiseWatts makes a material assessment, alert, recommendation, or prediction, the customer should be able to understand: the basis for it, relevant data/context, the comparison being used, methodology where appropriate, and uncertainty/confidence where applicable.

This is particularly important for financial claims and the Indian B2B market. A customer should not have to simply trust "You saved ₹85,000" — they should eventually be able to understand what changed, compared with what, how the saving was calculated, what action caused it, when the improvement occurred, and whether it is sustained.

Core principle: **"Trust through evidence."**

---

## 35. Q15 — Uncertainty / Evidence Classification

**DECIDED.** WiseWatts must distinguish between:

| Class | Meaning | Example |
|---|---|---|
| **MEASURED** | Directly supported by available telemetry/data. | "Consumption increased 14%." |
| **ESTIMATED** | Calculated from available information using a stated methodology. | "This represents approximately ₹42,000 additional cost based on the configured tariff." |
| **INFERRED** | Derived from observed patterns/context. | "The increase appears associated with extended HVAC operation." |
| **PREDICTED** | Forward-looking, model-based assessment. | "If the current pattern continues, next month's cost may increase by approximately ₹X." |

`WORKSHOP DECISION`: WiseWatts must **never** present uncertain conclusions as established facts. This evidence discipline applies to: savings, avoided demand penalties, tariff optimisation, efficiency improvements, recommendations, predictions, and AI outputs.

**Product principle: "No material savings claim without an explainable basis and a path to verification."**

`NOTE`: the labels MEASURED / ESTIMATED / INFERRED / PREDICTED introduced here are a workshop-specific evidence-classification vocabulary. This is distinct from, and must not be confused with, the Session 1 baseline's document-evidence tags (`[ZEROWATT-OBSERVED]`, `[INFERRED]`, `[WISEWATTS-DECISION]`, `[ARCH-CONSTRAINT]`, `[OPEN]`) used in the existing v0.1 documentation set per `README.md` §"Evidence labelling." The two vocabularies serve different purposes (product-output evidence vs. documentation-provenance) and reconciling terminology, if needed, is left for v0.2.

---

## 36. Overall Product Direction — Session 2 Synthesis

`WORKSHOP DIRECTION` (a synthesis of decisions above; **not** a rewrite of the v0.1 product definition):

WiseWatts is an **"Energy Management System that happens to contain dashboards."** It exists to support the Energy Management Cycle.

The initial customer job is: **"Provide visibility into energy use and performance that helps drive optimisation and ultimately enables WiseWatts to provide recommendations."**

The primary customer outcome progresses through: **SEE & UNDERSTAND → IDENTIFY & PRIORITISE → IMPROVE & OPTIMISE**

The initial product promise is: **VISIBILITY + BASIC ALERTING + REPORTING**

The immediate B2B experience should connect: **FINANCIAL PERFORMANCE + OPERATIONAL/ELECTRICAL HEALTH + ENERGY PERFORMANCE → ATTENTION / INVESTIGATION**

The broader maturity path is: **SEE → UNDERSTAND → IDENTIFY → INFORM → RECOMMEND → ACT → VERIFY → OPTIMISE → AUTOMATE**

The 3–5 year destination is: **ENERGY INTELLIGENCE PLATFORM WITH AI**

The system should combine **CONFIGURED AUTHORITATIVE KNOWLEDGE** + **ADAPTIVE LEARNED CONTEXT**, using **PROGRESSIVE CONFIGURATION**, and maintain **TRUST THROUGH EVIDENCE, EXPLAINABILITY AND VERIFICATION**.

---

## 37. Distinctions to Preserve (Session 2)

The following distinctions must **not** be lost or blurred in future work:

1. Energy Management Cycle = overarching product/business framework (Session 1 §6).
2. MONITOR → INVESTIGATE → IMPROVE → MEASURE = existing digital/product experience model — **not deleted**, coexists per Session 1 §6/§9.
3. Visibility = initial job/value.
4. Continuous optimisation = ultimate customer outcome (§19).
5. AI = long-term 3–5 year destination, **NOT** an MVP requirement.
6. The WiseWatts team can initially provide **manual** intelligence/recommendations before those capabilities are productised (§32).
7. B2B and B2C are different experience considerations; B2C is **not yet fully defined** (§23).
8. Financial claims must be explainable and verifiable (§34, §35).
9. "Normal" is metric/context-dependent — no single baseline definition (§26).
10. Configuration should be progressive (§31).
11. Customer scope is context-aware: Organisation/Portfolio → Site → Space → Asset (§24).
12. Reporting includes **both** communication and detailed data export (§33).

---

## 38. Open Items — Updated (Session 2)

All OPEN items from Session 1 (§12) remain OPEN and are **not resolved** by this addendum. The following additional/refined OPEN items are recorded from Session 2, without resolving any of them:

| # | Topic | Status |
|---|---|---|
| 1 | WiseWatts differentiation | OPEN (carried from Session 1 §12) |
| 2 | Exact B2B hero metrics / first-screen widget set | OPEN — candidates listed in §20 are hypotheses only |
| 3 | Exact first-screen layout | OPEN |
| 4 | Financial/savings calculation methodology | OPEN |
| 5 | Tariff / DISCOM support and rules (which states/DISCOMs, which rule sets) | OPEN |
| 6 | B2C product strategy | OPEN |
| 7 | Homeowner experience | OPEN (carried from Session 1 §8/§12) |
| 8 | Specific normal/baseline methodologies per metric | OPEN |
| 9 | Exact alert model/configuration | OPEN |
| 10 | Customer roles | OPEN |
| 11 | Portfolio depth | OPEN |
| 12 | Landing page details | OPEN |
| 13 | Space navigation vs. drill-down | OPEN |
| 14 | Functional categories | OPEN |
| 15 | Asset detail depth | OPEN |
| 16 | Reporting formats | OPEN |
| 17 | Customer write / action-management model | OPEN |
| 18 | Correlations | OPEN |
| 19 | Other unresolved v0.1 product decisions (Session 1 §12 item 3) | OPEN |

---

## 39. Session 2 Decision Table

| Topic | Status | Decision |
|---|---|---|
| Customer job (Q1) | DECIDED (reaffirmed) | Visibility that drives optimisation and enables recommendations |
| Customer outcome (Q2) | DECIDED | SEE & UNDERSTAND → IDENTIFY & PRIORITISE → IMPROVE & OPTIMISE; continuous optimisation is the primary long-term outcome |
| Post-login experience (Q3) | DECIDED (principle level) | Instant financial + operational visibility; "How am I doing, and is there anything I need to pay attention to?" |
| B2B hero concepts (Q3) | HYPOTHESIS / CANDIDATE | Realized Savings, Leakage Alert, MD Risk Gauge, Power Quality, PF interpretation, THD, Contract Demand exposure, ToD/Dynamic Tariff, inefficiency financial impact — none committed as MVP |
| B2B India principle | DECIDED | Translate technical metrics into business/financial meaning where data + methodology allow |
| MD + Power Quality in first B2B snapshot | DECIDED (product direction) | Must include Maximum Demand (risk-framed) and Power Quality (PF, THD) |
| MD/PF/tariff formulas & DISCOM scope | OPEN | Requires validation; not universal across DISCOMs |
| B2C residential experience | DECIDED (product direction) | Abstract away B2B terminology; simpler, action-oriented (e.g., appliance-overload warning, billing-slab progress bar) |
| B2C exact strategy | OPEN | Not committed to same experience as B2B |
| Context-aware experience (Q4) | DECIDED | Org/Portfolio → Site → Space → Asset; context changes metric meaning, not just navigation |
| First question (Q5) | DECIDED | "How am I doing, and is there anything I need to pay attention to?"; flow = overall status → signals → impact → investigation |
| Definition of normal (Q6) | DECIDED (principle) | No single baseline; each metric has its own comparison basis; methodology per metric OPEN |
| Response model (Q7) | DECIDED | ALERT → EXPLAIN → RECOMMEND → (eventually) ACT/AUTOMATE |
| Recommendation capability phasing (Q8) | DECIDED | INFORM (MVP) → MANAGE → VERIFY → AUTOMATE (none of the latter three are MVP) |
| Verification (Q9) | DECIDED | Fundamental responsibility; close the loop Identify→Recommend→Act→Measure→Verify→Learn→Optimise |
| Configured + adaptive intelligence (Q10) | DECIDED | Authoritative facts configured; contextual intelligence learned; AI must not override authoritative data |
| Progressive configuration (Q11) | DECIDED | Minimum info first; request more only when it materially improves a capability |
| Proactivity maturity (Q12) | DECIDED | Ask→Alert→Insight→Recommendation→Prediction→Automation; MVP = ask + basic alerting; manual WiseWatts-team analysis is an intentional interim step |
| Reporting (Q13) | DECIDED | Two purposes — Communication and Data Export — must not be collapsed |
| Trust/explainability (Q14) | DECIDED | Fundamental principle: "Trust through evidence" |
| Evidence classification (Q15) | DECIDED | MEASURED / ESTIMATED / INFERRED / PREDICTED; no uncertain conclusion presented as fact |

---

# WORKSHOP SESSION 2 — CONTINUATION (Q16–Q26)

> This is a continuation of the same Session 2 workshop discussion recorded in §17–§39 above. §1–§39 are preserved unchanged. Nothing below revises, restructures, or reinterprets Q1–Q15 or the Session 1 baseline — it is additive only.

---

## 40. Q16 — Understanding Energy Use

DECIDED — PRODUCT DIRECTION

The customer needs four types of understanding before they can make a meaningful decision:

1. Financial / penalty exposure
   "Am I approaching a costly boundary or penalty?"
   Examples: Maximum Demand vs contract demand, PF/PQ exposure, tariff context.

2. Energy performance relative to operational output
   "Is my energy use justified by what the facility is actually doing?"
   The product should eventually contextualise energy against production, occupancy, throughput, or other appropriate operational denominators.

3. Time-dependent energy cost
   "Is now a good time to be using this much energy?"
   Examples: ToD/tariff context and operational rescheduling.

4. Controllable vs structural
   "Where can I actually make a difference?"
   Examples: baseline/always-on load versus discretionary/controllable load.

Together:

"What is happening, why does it matter, and what can I influence?"

OPEN PRODUCT DECISION:
Sector-specific operational denominators and their data sources are not yet decided/available for all target sectors.

---

## 41. Q17 — Prioritisation

DECIDED — PRINCIPLE LEVEL

WiseWatts should help customers prioritise rather than simply rank alerts using a fixed formula.

Prioritisation should progressively consider a combination of:
- financial impact
- energy impact
- operational risk
- urgency
- actionability / ease of action
- customer-defined priorities
- evidence quality / confidence

The prioritisation itself should evolve with intelligence.

The progression is:

"What is abnormal?"
→ "What matters most?"
→ "What should I do first?"
→ "What action is likely to produce the best outcome?"

Do not define a fixed scoring formula yet.

OPEN PRODUCT DECISION:
Exact weighting/model for prioritisation.

---

## 42. Q18 — Act / Execution Boundary

DECIDED

WiseWatts should primarily remain the intelligence and decision-support layer, not the operational execution layer.

The long-term journey remains:

Alert → Explain → Recommend → Act → Verify → Optimise → Automate

However, "Act" does NOT mean WiseWatts directly controls site equipment.

WiseWatts should:
- identify opportunities
- explain why they matter
- recommend actions
- measure results
- verify outcomes
- learn from outcomes

The customer/site operational team or a separate execution/control system performs the actual operational action.

Reason:
Execution is highly dependent on industry, site, equipment, controls architecture, operating procedures, and customer risk tolerance.

Core boundary:

"WiseWatts recommends and verifies; execution remains with the customer or a separate execution/control system."

Future automation may automate intelligence/workflow or trigger an external execution system without WiseWatts itself becoming an equipment-control platform.

---

## 43. Q19 — Action Logging, Action Detection and Verification

DECIDED — PRINCIPLE LEVEL

When execution happens outside WiseWatts' direct control, the platform should use:

Data-Driven Inference (Closed-Loop Analytics) + Lightweight Human Validation.

The facility's data should act as the primary "sensor" confirming whether an operational recommendation appears to have been acted upon.

### Layer 1 — Energy Signature Change / Automated Verification

After a recommendation, WiseWatts should look for the expected behavioural change in telemetry within an appropriate time window.

Example:
- Recommendation: shift a heavy process outside a high-tariff ToD window.
- Observed: the expected peak disappears or moves to an off-peak period.
- Result: "Inferred Action Taken."

This must be labelled INFERRED, not presented as confirmed fact.

### Layer 2 — Micro-Feedback / Lightweight Human Validation

For actions that cannot be reliably deduced from telemetry, provide a friction-free confirmation mechanism.

Examples:
- Done
- Not Applicable
- Snooze

The customer should also be able to log an action manually.

Capture the action timestamp and relevant action details.

The timestamp creates an intervention boundary against which subsequent telemetry can be evaluated.

Example:
Customer marks an action Done at 14:30 → WiseWatts evaluates the telemetry after 14:30 to determine whether the expected effect occurred.

### Layer 3 — Baseline / Measurement & Verification

For larger structural interventions, use appropriate baseline and measurement/verification methods where the data supports them.

Evaluate:
- expected vs actual consumption
- demand
- cost
- operating conditions
- duration/sustainability of improvement
- relevant contextual variables

Distinguish observed improvement from attributed savings.

Do not claim that a measured improvement was necessarily caused by the recommendation unless the evidence supports that conclusion.

### Layer 4 — Value Realised

Eventually the product should connect:

Recommended → Acted → Verified → Value Realised

Possible summary measures:
- opportunities identified
- actions recorded/inferred
- verified improvements
- estimated financial impact

Financial claims must remain subject to the evidence model.

Important extension:
Customers should eventually be able to log actions even when WiseWatts did not recommend them.

This creates a learning path:

Customer intervention → observed change → possible learning opportunity.

OPEN PRODUCT DECISION:
- exact action-log fields
- inference algorithms
- baseline/M&V methodology
- confidence thresholds
- action-log UX

---

## 44. Q20 — Recommendation Experience

DECIDED

The recommendation experience should evolve progressively.

### Level 1 — Concise Action

Example:
"Shift HVAC load from 6–8 PM."

### Level 2 — Explainable Recommendation

Explain:
- what is happening
- why it matters
- likely cause
- recommended action
- expected impact
- evidence/confidence

### Level 3 — Guided Decision

Eventually present 2–3 possible actions with:
- expected impact
- effort/risk
- evidence

and allow the customer to choose.

Progression:

Concise → Explainable → Guided Decision

The sophistication of the recommendation must follow the quality of the underlying intelligence.

Core principle:

"Recommendation quality must not exceed underlying understanding and data quality."

OPEN PRODUCT DECISION:
Exact recommendation UX, alternative scoring, effort estimation, confidence thresholds, and when the product is sufficiently intelligent to move between levels.

---

## 45. Q21 — Role / Context-Aware Recommendations

DECIDED — PRINCIPLE LEVEL

The same opportunity may eventually be presented differently depending on who needs to make the decision or act.

Potential examples:
- Facility / Energy Manager → operational action
- Plant / Operations → process change
- Maintenance / Engineering → equipment/system cause
- Finance → financial exposure
- Senior Management → business significance/outcome
- Sustainability → environmental/compliance context

Do not assume every customer has all these roles.

Do not require customers to configure their organisational roles before receiving value.

This follows the progressive configuration principle.

OPEN PRODUCT DECISION:
- exact role model
- permissions
- assignment model
- personalisation depth

---

## 46. Q22 — Multiple Simultaneous Opportunities

DECIDED

Initially, WiseWatts should show the relevant issues/opportunities rather than prematurely deciding what the customer must address first.

The product should progressively evolve:

Show → Organise → Prioritise → Recommend What to Focus On → Optimise

Early product:
- broad visibility
- context
- explanation
- customer choice

Later product:
- intelligent prioritisation
- customer/site-specific learning
- increasingly opinionated focus recommendations

This is an extension of Q17 and should not become a competing prioritisation framework.

---

## 47. Q23 — Customer Priorities

DECIDED

Customer priorities should progressively become an input into WiseWatts intelligence.

Examples:
- cost reduction
- demand management
- operational reliability
- sustainability
- target achievement

Do not require customers to configure priorities before receiving value.

Customer priorities should influence prioritisation but should not override objective evidence or hide serious operational issues.

Progression:

Observe → Learn → Ask → Personalise → Optimise

OPEN PRODUCT DECISION:
How priorities are captured, granularity, duration, and weighting.

---

## 48. Q24 — Customer Goals and Targets

DECIDED

Customer-defined goals and targets are a later capability and are explicitly far from MVP.

Potential examples:
- reduce energy cost
- reduce MD
- improve PF
- reduce consumption intensity
- achieve sustainability targets

Do not make formal goal/target configuration part of onboarding or MVP.

Goals become more valuable after WiseWatts has established reliable understanding of the facility.

MVP:
No formal customer goal/target configuration requirement.

OPEN PRODUCT DECISION:
- goal types
- methodology
- target-setting UX
- time horizons
- influence on prioritisation/intelligence

---

## 49. Q25 — Insufficient Information

DECIDED

When WiseWatts does not have enough information to confidently explain or recommend something, it should:

1. Explain what it knows.
2. Clearly disclose what it does not know.
3. Avoid presenting uncertain conclusions as facts.
4. Ask for additional context only when it materially improves the answer.
5. Become progressively more useful as context is provided.

Core experience:

"Here's what we know. Here's what we're seeing. Here's what we can't determine yet. Here's what would help us answer it better."

This reinforces progressive configuration and trust through evidence.

OPEN PRODUCT DECISION:
Exactly when EMS asks for information, how uncertainty is communicated, and confidence thresholds for different assessments/recommendations.

---

## 50. Q26 — How Opinionated Should WiseWatts Become?

DECIDED

WiseWatts should evolve from a customer-led monitoring and understanding tool into an increasingly opinionated energy advisor as its evidence, context and intelligence improve.

Progression:

Show → Explain → Suggest → Recommend → Prioritise → Advise → Optimise

The customer remains in control.

The stronger the recommendation, the stronger the evidence and explanation must be.

Core principle:

"WiseWatts should earn its authority through evidence and verified outcomes."

OPEN PRODUCT DECISION:
Precise thresholds for moving from observation to recommendation and eventually to highly confident prioritisation.

---

## 51. Consolidated Direction Emerging From Q16–Q26

Preserve these as synthesis, not as new decisions.

### Customer understanding

Financial exposure + operational/electrical health + energy performance + time-dependent cost + controllable vs structural.

Core customer question:

"What is happening, why does it matter, and what can I influence?"

### Intelligence journey

Alert → Explain → Recommend → Act → Verify → Optimise → Automate

### Recommendation maturity

Concise → Explainable → Guided Decision

### Prioritisation maturity

Show → Organise → Prioritise → Recommend What to Focus On → Optimise

### Customer-context maturity

Observe → Learn → Ask → Personalise → Optimise

### Closed-loop learning

Identify → Recommend → Customer Action / Inferred Action → Measure → Verify → Learn → Optimise

### Execution boundary

WiseWatts recommends and verifies.
Customer/site systems or a separate execution/control system executes.

### Product authority principle

WiseWatts earns the right to become more opinionated as evidence, context and verified outcomes improve.

### Evidence principle

Do not make material claims without an explainable basis and a path to verification.

---

## 52. Important Reconciliation Notes for Later v0.2

Do NOT resolve these now. Record them as reconciliation items:

1. Existing v0.1 uses MONITOR → INVESTIGATE → IMPROVE → MEASURE.
2. Workshop introduces SEE & UNDERSTAND → IDENTIFY & PRIORITISE → IMPROVE & OPTIMISE.
3. Workshop also uses Alert → Explain → Recommend → Act → Verify → Optimise → Automate.
4. These are related but describe different dimensions and should not simply replace one another without product-owner reconciliation.

Also note:

5. Existing v0.1 provenance/evidence tags and the workshop MEASURED / ESTIMATED / INFERRED / PREDICTED vocabulary need reconciliation in v0.2.
6. The three-stage outcome model, seven-stage customer journey, and six-stage intelligence maturity model should remain distinct unless explicitly reconciled later.

---

## 53. Workshop Status After This Discussion

Q1–Q26 are decided at principle level unless an explicit OPEN PRODUCT DECISION is recorded.

This remains a workshop record only.

No implementation is authorised by these decisions.
No Phase 9 work is authorised.
No UI/API/schema/architecture changes are authorised.
No production changes are authorised.

---

# WORKSHOP SESSION 2 — CONTINUATION (Q27–Q48)

> This is a further continuation of the same Session 2 workshop discussion recorded in §17–§53 above. §1–§53 are preserved unchanged. Nothing below revises, restructures, or reinterprets Q1–Q26 or the Session 1 baseline — it is additive only.

---

## 54. Q27 — Customer Success

DECIDED

Customer success should be a combination that evolves across:
- Financial
- Energy performance
- Operational
- Action / behaviour
- Management confidence

Core principle:

"WiseWatts should ultimately measure value through real-world improvement, not engagement with the software."

Weak measures such as dashboard visits, alerts viewed, reports generated, or time spent in EMS should not define success.

Stronger measures include:
- costs reduced
- MD exposure reduced
- energy performance improved
- operational/PQ issues improved
- recommendations acted upon
- improvements verified
- improvements sustained
- better decisions made with greater confidence

Ultimately:

"Did WiseWatts help the customer make better decisions that resulted in measurable, sustained improvement?"

OPEN PRODUCT DECISION:
Actual customer-value metrics, attribution methodology, and presentation.

---

## 55. Q28 — Customer Value

DECIDED

WiseWatts should NEVER reduce customer value to a single metric or score.

Value should be represented across multiple dimensions, including:
- Finance
- Asset health & maintenance
- Energy performance
- Power / energy quality
- Production / operations
- Sustainability / environmental
- Other customer-specific dimensions as the product evolves

These are different value dimensions and should not necessarily be mathematically combined.

Example manufacturing view:
Finance → financial opportunity
Asset Health → abnormal compressor behaviour
Quality → PF deterioration
Production → energy intensity change

Core principle:
"Energy is the common thread connecting these domains."

Energy Performance should not be treated as merely one isolated module alongside Finance, Asset Health, Quality and Production.

OPEN PRODUCT DECISION:
Exact dimensions and presentation depend on sector, available data, and product maturity.

---

## 56. Q29 — Universal Foundation + Specialisation

DECIDED

Adopt:
"Common EMS foundation + progressively specialised experiences."

One WiseWatts EMS should have a common foundation, while metrics, terminology, comparisons, workflows and recommendations adapt based on:
- sector
- site characteristics
- assets
- operational context
- available data
- customer priorities
- product maturity

Directional examples:

Manufacturing:
Energy ↔ production ↔ assets ↔ maintenance ↔ demand ↔ cost

Hospitality:
Energy ↔ occupancy ↔ HVAC ↔ comfort ↔ demand ↔ cost

Commercial building:
Energy ↔ occupancy ↔ HVAC ↔ comfort ↔ demand ↔ cost

Pharma:
Energy ↔ production/process ↔ critical equipment ↔ quality/compliance ↔ cost

These are directional examples, not yet defined sector requirements.

Core principle:
"Standardise the intelligence foundation; specialise the customer experience."

OPEN PRODUCT DECISION:
Exact sector models, terminology, metrics, workflows and specialisations.

MVP implication:
No requirement to build sector-specific products.

---

## 57. Q30 — Intelligence Transparency

DECIDED

Adopt layered transparency.

Simple answer first, progressively deeper evidence and analytical detail underneath.

Experience:
What happened?
→ Why does it matter?
→ What is the evidence?
→ How was it determined?
→ What are the assumptions / uncertainty?

Example:
High MD Risk
Demand reached 94% of contract demand.

Why?
Evening demand increased 11% over four weeks.

Evidence:
Measured demand + configured contract demand + historical comparison.

Analysis details:
Baseline, contributing loads, confidence, assumptions, etc.

Core principle:
"Simple on the surface, explainable underneath."

OPEN PRODUCT DECISION:
Exact depth, terminology, visualisation and access to analytical details.

---

## 58. Q31 — Customer Challenge & Feedback

DECIDED

Customers should be able to challenge, reject, defer or contextualise WiseWatts recommendations.

Possible responses:
- Done / Implemented
- Already addressed
- Not applicable
- Cannot implement
- Not relevant / incorrect
- Snooze / revisit later
- Provide context

The product should not treat its own recommendation as automatically correct.

Long-term loop:
Recommend → Customer response → Act / Reject / Defer → Measure → Verify → Learn

Customer feedback becomes another source of intelligence alongside telemetry.

OPEN PRODUCT DECISION:
Exact feedback taxonomy, workflow, editability and influence on future recommendations.

---

## 59. Q32 — Action Status & Customer Intent

DECIDED

Recommendation/action lifecycle must distinguish what actually happened rather than treating everything as "not acted".

Potential states:
- Not viewed
- Viewed / pending
- Implemented — customer confirmed
- Implemented — inferred from data
- Already addressed
- Deferred / snoozed
- Rejected — not applicable
- Rejected — operational constraint
- Rejected — recommendation incorrect
- Unable to implement

These distinctions are valuable both for the customer and for intelligence learning.

OPEN PRODUCT DECISION:
Exact lifecycle/state taxonomy and transitions.

---

## 60. Q33 — Persistent Customer / Site Context

DECIDED — LONG-TERM

WiseWatts should eventually retain relevant operational context provided by the customer and use it in future analysis, recommendations and verification.

Examples:
- operating constraints
- production schedules
- equipment relationships
- known exceptions
- maintenance events
- customer priorities
- operational rules

This allows WiseWatts to evolve from generic energy analytics toward energy intelligence that understands the particular facility.

This is FAR FROM MVP.

Do not create a large configuration exercise.

Core principle:
Connect → See → Learn → Ask for context → Improve intelligence.

OPEN PRODUCT DECISION:
Context model, persistence, customer controls, review/edit experience, expiry, and influence on intelligence.

---

## 61. Q34 — Learning From Failed / Rejected Recommendations

DECIDED — LONG-TERM

WiseWatts should learn from recommendations that were rejected, deferred or found inappropriate.

Customer feedback is contextual evidence, not automatically universal truth.

Example:
"This compressor cannot be switched off because it supports a critical process."

This should influence recommendations for the relevant asset/context without teaching the entire system that compressors should never be switched off.

Core principle:
"Don't just learn what happened. Learn why the customer did or did not act."

FAR FROM MVP.

---

## 62. Q35 — Product Boundary

DECIDED

Adopt:
"Start as an energy intelligence platform, but deliberately evolve toward broader facility/industrial intelligence where customer use case and available data justify it."

Progression:
Energy Intelligence → Contextual Business Intelligence → Broader Facility/Industrial Intelligence

Energy remains the entry point and core identity.

Other domains can be used as context when they improve energy/performance decisions.

Examples:
Energy ↔ Finance ↔ Assets ↔ Maintenance ↔ Quality ↔ Production ↔ Operations

MVP implication:
Do not build a broad facility/industrial intelligence platform.

OPEN PRODUCT DECISION:
Which adjacent domains to introduce first and precise future boundary.

---

## 63. Q36 — Optimisation Scope

DECIDED

Focus on ENERGY first.

Near-term progression:
Energy visibility → Energy understanding → Energy opportunities → Energy improvement → Energy optimisation

Finance, assets, maintenance, quality and production can provide contextual inputs when they help explain or improve energy performance.

They are not initially separate optimisation products.

Core principle:
"Energy is the product focus. Other domains are contextual inputs initially; they may become product domains later if customer value justifies it."

MVP implication:
Focus on energy.

---

## 64. Q37 — Energy Analytics → Energy Management

DECIDED

Core distinction:

"Analytics tells the customer what happened.
Energy Management helps the customer understand what to do about it and whether it worked."

Product evolution:
Energy Analytics → Energy Management → Intelligent Energy Management

Analytics remains the foundation.

EMS is not merely reporting/analytics; it helps customers understand, decide, act and verify within the energy-management domain.

MVP implication:
Does not require mature intelligence, but must establish the visibility/understanding foundation.

---

## 65. Q38 — Energy-Management Opportunity

DECIDED

The primary unit of the EMS experience should be the customer's problem or opportunity, not a metric, location or asset.

Example:
"Evening peak-demand exposure is increasing."

Supporting context:
- metric
- where
- when
- evidence
- impact
- contributors
- recommendation
- action
- verification

Core principle:
"The metric is evidence. The opportunity is the customer-facing object."

OPEN PRODUCT DECISION:
Exact opportunity model, lifecycle and UX.

---

## 66. Q39 — Hierarchy-Aware Opportunities

DECIDED

Opportunities can originate at any level:
Organisation / Portfolio → Site → Space → Asset

WiseWatts should show the highest-level explanation that is useful and allow progressive drill-down.

Example:
Site: Peak demand risk increasing.
→ Space: Kitchen and HVAC contributing most.
→ Asset: Chiller #2 largest contributor.
→ Evidence: supporting measurements/comparison/methodology.

Core principle:
Problem/opportunity → location/context → contributing asset/system → evidence.

OPEN PRODUCT DECISION:
Exact opportunity lifecycle and navigation.

---

## 67. Q40 — Opportunity Lifecycle

DECIDED — PRINCIPLE LEVEL

Do not force the opportunity into one linear status.

Maintain at least two dimensions:

Opportunity state:
Detected → Active → Improving → Resolved → Recurring

Customer/action state:
New → Viewed → Accepted / Rejected / Deferred → Action Logged → Verified

These are independent.

Example:
Opportunity = Active
Customer = Action Logged

Or:
Opportunity = Recurring
Customer = Previously Verified

OPEN PRODUCT DECISION:
Exact states, transitions and lifecycle UX.

---

## 68. Q41 — Resolved Opportunities & Value History

DECIDED

Resolved opportunities should not disappear.

Active opportunities remain prominent.

Resolved opportunities move into a historical "Verified / Value Realised" history showing:
- what was identified
- why it mattered
- what action was taken
- when
- confirmed vs inferred
- what changed
- whether improvement was verified
- value realised
- sustainability
- recurrence

Core memory:
Problems found → Actions taken → Results achieved

A recurring issue should retain its relationship to the previous opportunity/intervention.

OPEN PRODUCT DECISION:
History UX, retention, recurrence logic and value-realisation calculations.

---

## 69. Q42 — Energy Themes

DECIDED — LONG-TERM

WiseWatts should eventually group related opportunities into persistent energy-management themes.

Examples:
Peak Demand Management
HVAC Efficiency

Theme relationship:
Theme → Opportunities → Events / measurements → Actions → Verification → Value

Themes must not replace underlying evidence or individual opportunities.

MVP implication:
Not required.

OPEN PRODUCT DECISION:
Theme taxonomy, grouping logic, relationship rules and UX.

---

## 70. Q43 — Site-Specific Intelligence

DECIDED — LONG-TERM

WiseWatts should progressively learn what is normal, important, actionable and effective for each individual site.

Learn from:
- site behaviour
- recurring opportunities
- customer actions
- rejected/deferred recommendations
- verified outcomes
- persistent operational context
- customer priorities

Generic knowledge should become site-specific understanding over time.

MVP implication:
Mature adaptive intelligence not required; MVP should establish the foundation.

---

## 71. Q44 — Cross-Customer Learning

DECIDED — LONG-TERM

WiseWatts should eventually learn from the broader customer base in addition to site-specific learning.

Two layers:
Site-specific learning
+
Aggregated / anonymised cross-customer learning

Potential uses:
- common energy behaviours
- recurring opportunities
- sector/context patterns
- intervention patterns
- relationships between characteristics and energy performance

Customer confidentiality is fundamental.

One customer's identifiable operational data must never be visible to another customer.

FAR FROM MVP.

OPEN PRODUCT DECISION:
Privacy, consent, anonymisation, aggregation methodology, governance and statistical validity.

---

## 72. Q45 — Expose Learned Context

DECIDED — LONG-TERM

WiseWatts should eventually expose meaningful things it has learned about a customer's facility.

Examples:
"We've learned that your site's peak demand is typically driven by production changeovers between 17:30–19:00."

"Over the last six months, HVAC scheduling interventions have produced the most consistent demand reductions at this site."

Learned context should be:
- explainable
- evidence-backed
- distinguishable from configured facts
- open to customer correction
- progressively introduced as confidence increases

Core loop:
WiseWatts learns → shows customer → customer confirms/corrects → intelligence improves.

MVP implication:
Not required.

---

## 73. Q46 — Facts, Interpretations, Recommendations & Predictions

DECIDED

Customer experience should distinguish levels of intelligence.

Example:
FACT — Demand reached 94% of contract demand.
INTERPRETATION — Evening operations appear to be contributing.
RECOMMENDATION — Consider shifting selected loads.
PREDICTION — If effective, peak demand may reduce by approximately X.

This is the customer-facing expression of:
MEASURED / ESTIMATED / INFERRED / PREDICTED

Core principle:
"Be clear about what we know, what we infer, what we recommend, and what we predict."

---

## 74. Q47 — Self-Correction & Transparency

DECIDED — LONG-TERM

WiseWatts should eventually acknowledge when a previous assessment was wrong or superseded by better evidence.

Example:
Previous assessment: HVAC was primary contributor.
Updated assessment: production schedule was primary contributor.

Core principle:
"Trust does not come from always being right; it comes from being transparent, evidence-based and willing to correct itself."

FAR FROM MVP.

OPEN PRODUCT DECISION:
Correction history, visibility, model/version handling and effect on future intelligence.

---

## 75. Q48 — Why One Recommendation Was Prioritised Over Another

DECIDED — LONG-TERM

As prioritisation becomes sophisticated, customers should eventually understand why one opportunity/recommendation was prioritised over another.

Potential factors:
- higher confidence
- lower operational risk
- easier implementation
- stronger evidence
- better historical results at that site

Customer should eventually be able to see:
"We recommend this first because…"

Prioritisation itself should be explainable.

FAR FROM MVP.

OPEN PRODUCT DECISION:
Exact prioritisation explanation, factors exposed and UX.

---

## 76. Q16–Q48 Consolidated Workshop Synthesis

Preserve this as synthesis, not as new decisions.

The workshop has established a long-term product direction in which WiseWatts evolves from trusted energy visibility and analytics into increasingly intelligent energy management.

Core outcome:
See & Understand → Identify & Prioritise → Improve & Optimise

Core intelligence journey:
Alert → Explain → Recommend → Act → Verify → Optimise → Automate

Core recommendation maturity:
Concise → Explainable → Guided Decision

Core prioritisation maturity:
Show → Organise → Prioritise → Recommend What to Focus On → Optimise

Core customer-context maturity:
Observe → Learn → Ask → Personalise → Optimise

Core closed-loop:
Identify → Recommend → Customer Action / Inferred Action → Measure → Verify → Learn → Optimise

Core evidence model:
MEASURED / ESTIMATED / INFERRED / PREDICTED

Core product authority principle:
WiseWatts earns the right to become more opinionated as evidence, context and verified outcomes improve.

Core execution boundary:
WiseWatts recommends and verifies; customer/site systems or a separate execution/control system executes.

Core product boundary:
Energy first. Other domains provide contextual inputs initially and may become broader product domains later.

Core opportunity model:
The customer's problem/opportunity is the primary unit; metric, location, asset, evidence, action and verification provide context.

Core value model:
Never reduce customer value to one metric. Value can exist across finance, energy performance, asset health/maintenance, quality, production/operations, sustainability and other customer-specific dimensions.

Core trust principle:
Simple on the surface, explainable underneath.

Core learning principle:
Customer feedback is contextual evidence, and facility data is a primary sensor for closed-loop verification.

---

## 77. Workshop Direction Change

At this point, future workshop questions should focus primarily on:

1. MVP product definition and customer experience.
2. Decisions that directly determine MVP scope.
3. Foundations that MVP must establish to support the longer-term intelligence direction.

Avoid further detailed questions about long-term AI/intelligence behaviour unless the decision materially affects the MVP foundation.

Long-term capabilities already captured should be treated as product-direction principles and parked for later.

Do not convert the above long-term capabilities into MVP requirements.

---

## 78. Workshop Status After Q27–Q48

Q1–Q48 are decided at their stated level (DECIDED / DECIDED AT PRINCIPLE LEVEL / DECIDED — LONG-TERM) unless an explicit OPEN PRODUCT DECISION or FAR FROM MVP qualifier is recorded alongside them.

This remains a workshop record only.

No implementation is authorised by these decisions.
No Phase 9 work is authorised.
No UI/API/schema/architecture changes are authorised.
No production changes are authorised.

---

# WORKSHOP SESSION 2 — CONTINUATION (Q49–Q60, MVP FOCUS)

> This is a further continuation of the same Session 2 workshop discussion recorded in §17–§78 above. §1–§78 are preserved unchanged. Per §77 (Workshop Direction Change), this continuation focuses on MVP product definition and MVP-determining decisions rather than further long-term intelligence detail. Nothing below revises, restructures, or reinterprets Q1–Q48 or the Session 1 baseline — it is additive only.

---

## 79. Q49 — MVP Boundary

DECISION

We chose **C — Hybrid**.

The MVP customer experience is defined by customer value, not by the capabilities currently available in the Analytics API.

MVP must deliver a coherent B2B first/site-level snapshot covering:

- Energy
- Maximum Demand (MD)
- Power Quality (PQ)
- Attention/exception visibility
- Financial interpretation where sufficiently configured and supported

Separately, the platform prerequisites required to make this customer experience possible should be identified as implementation/platform dependencies.

The product remains an **Energy Analytics platform for MVP**, evolving later toward Energy Management and ultimately Intelligent Energy Management.

---

## 80. Q50 — MVP Analytical Job

DECISION

The MVP should answer four core questions:

1. How much energy are we using?
2. How are we performing relative to what is normal/expected?
3. Where are the significant energy/electrical issues or exposures?
4. Where should I investigate further?

This is the core analytical foundation of the MVP.

---

## 81. Q51 — MVP Hierarchy/Drill-Down

DECISION

The MVP must support:

**Site → Space → Asset**

This is the progressive investigation path:

- Site: How is the facility performing?
- Space: Where is the issue?
- Asset: What is contributing?

The MVP does not need mature recommendation/action/verification intelligence, but it must establish the analytical foundation for this future evolution.

---

## 82. Q52 — MVP Analytical Scope

DECISION

MVP analytical areas:

- **Energy Consumption** — usage and trends
- **Maximum Demand** — demand level, peaks and contract/exposure context
- **Power Quality** — primarily PF and THD
- **Energy Performance** — comparison against historical/expected performance
- **Issues / Attention** — areas requiring investigation
- **Space / Asset drill-down** — tracing the above into the facility hierarchy

These form the core MVP analytical scope.

---

## 83. Q53 — Shared Time Context

DECISION

MVP must have a shared time-range experience across the analytical views.

The selected time context should consistently apply across:

- Energy Consumption
- Maximum Demand
- Power Quality
- Energy Performance
- Issues / Attention
- Space and Asset drill-down

The purpose is to maintain consistent analytical context while moving through the product.

---

## 84. Q54 — Comparison Baseline

DECISION

MVP supports both:

**A. Historical baselines**
- previous period
- same period previously
- rolling historical average

**B. Configured expectations**
- where the customer has supplied the necessary information

Historical comparison is the default starting point; configured expectations are used where available.

This follows the principle:

**Useful value first → configuration when it materially improves the analysis.**

The comparison basis must be clear to the customer.

---

## 85. Q55 — Expected Performance

DECISION

For MVP, "expected performance" is a **comparison** concept, not a **prediction** concept.

Example:

"Your energy consumption is 12% higher than the comparison baseline."

Not:

"We predicted you should have used 12% less."

Sophisticated adaptive baselines, predictive models and AI-generated expectations are explicitly deferred to the later intelligence layer.

---

## 86. Q56 — Historical Comparison Types

DECISION

MVP uses simple, transparent comparison approaches:

- Previous period
- Same period previously
- Rolling historical average
- Configured expectation, where available

MVP does not initially attempt sophisticated normalisation based on:

- weather
- occupancy
- production
- operating schedules
- or similar contextual variables

Those are candidates for the later intelligence layer.

---

## 87. Q57 — Issues / Attention

DECISION

MVP Issues / Attention is **analytical, not intelligent**.

Attention can be surfaced using:

- clear analytical conditions
- measurable deviations
- configured thresholds/limits
- other transparent rules supported by available data

Examples:

- Consumption materially above comparison baseline
- Maximum Demand approaching/exceeding contract demand
- Poor Power Factor
- Elevated THD
- Significant measurable changes requiring investigation

MVP does not attempt to:

- intelligently rank opportunities
- explain root causes
- recommend actions
- predict future problems
- learn site-specific behaviour
- determine what the customer should do

These belong to the later Energy Management/intelligence evolution.

Core principle:

**"MVP identifies and helps investigate. It does not prescribe."**

---

## 88. Q58 — MVP Investigation

DECISION

MVP investigation follows:

**Site → Space → Asset → Evidence**

The customer can progressively drill down from a site-level observation to the relevant space and asset and inspect the underlying trends/data supporting the observation.

MVP helps answer:

**"What is happening, where is it happening, and what does the evidence show?"**

It deliberately does not yet attempt to answer:

**"Why did it happen?" or "What should I do?"**

Those belong to the future Energy Management/intelligence layer.

---

## 89. Q59 — Evidence and Trust

DECISION

Evidence and transparency are **MVP foundations, not future intelligence**.

Every material analytical observation should make its basis understandable.

Example:

Energy consumption: +15% vs comparison baseline
- Comparison: 1–31 Aug vs 1–31 Jul
- Basis: measured energy data

The customer should understand:

- what was observed
- what it was compared against
- how the conclusion was reached

Evidence terminology remains:

- **MEASURED** — directly supported by data
- **ESTIMATED** — calculated using a stated methodology
- **INFERRED** — derived from patterns/context
- **PREDICTED** — future/model-based

For MVP, emphasis is on measured and transparent estimated/comparative results. Inference and prediction belong to later intelligence.

---

## 90. Q60 — Data Quality and Analytical Trust

DECISION

MVP must explicitly surface data quality / data availability alongside analytics.

Relevant states include:

- Data available / healthy
- Partial data
- Missing data
- Stale data
- Insufficient data for comparison

MVP must avoid presenting a misleading comparison or conclusion when the underlying data is insufficient.

This is a direct extension of the MVP trust principle and does not require intelligent analysis.

---

## 91. Workshop Status After Q49–Q60

Q49–Q60 are DECIDED at the MVP-scope level recorded above. No OPEN PRODUCT DECISION or FAR FROM MVP items were introduced in this continuation — all twelve items are explicit MVP-boundary decisions, consistent with the workshop-direction change recorded in §77.

Q49–Q60 are deliberately scoped to what MVP does and does not attempt. They do not expand into, replace, or contradict the long-term intelligence direction captured in Q1–Q48 (§18–§75) — they define the MVP-level boundary that the longer-term direction will later evolve beyond, per §35 (Product Boundary), §57 (Q30 — layered transparency), and §77 (Workshop Direction Change).

This remains a workshop record only.

No implementation is authorised by these decisions.
No Phase 9 work is authorised.
No UI/API/schema/architecture changes are authorised.
No production changes are authorised.

---

# WORKSHOP SESSION 2 — CONTINUATION (Q61–Q72, MVP FOCUS)

> This is a further continuation of the same Session 2 workshop discussion recorded in §17–§91 above. §1–§91 are preserved unchanged. Consistent with §77 (Workshop Direction Change) and §91, this continuation stays MVP-focused. Nothing below revises, restructures, or reinterprets Q1–Q60 or the Session 1 baseline — it is additive only.

---

## 92. Q61 — MVP Landing Experience

DECISION

The MVP landing experience should be a **Site Overview / Energy Health** view bringing the core signals together into one coherent experience:

- Overall Site Status
- Energy Consumption
- Energy Performance vs baseline
- Maximum Demand
- Power Quality
- Issues / Attention
- Paths into Space → Asset investigation

The customer should not have to choose between separate analytical dashboards just to understand how the facility is doing.

This directly answers:

**"How am I doing, and is there anything I need to pay attention to?"**

The MVP remains an Energy Analytics experience, not yet an intelligent Energy Management system.

---

## 93. Q62 — MVP Site Scope

DECISION

Site is the primary customer context in the MVP.

- Single-site customer → lands directly on Site Overview.
- Multi-site customer → selects/enters the relevant site from organisation/portfolio context.
- Once inside, the experience remains anchored to that site.
- Space → Asset are investigative levels beneath the site.
- Sophisticated portfolio analytics are not the primary MVP focus.

---

## 94. Q63 — Portfolio Experience

DECISION

The MVP will **include** a portfolio experience, rather than excluding it.

However, portfolio is **lower priority** than the core site-level experience.

Portfolio primarily answers:

**"Which facility/site should I look at?"**

while Site answers:

**"How am I doing, and what needs attention?"**

---

## 95. Q64 — Portfolio MVP Depth

DECISION

The full portfolio experience is included in MVP, including advanced portfolio capabilities, but it is the **lowest-priority experience** within the MVP.

Portfolio capabilities may include:

- Portfolio/site overview
- Cross-site comparison
- Aggregated consumption/performance
- Site ranking and benchmarking
- Sites requiring attention
- Portfolio-level trends
- Drill-down Portfolio → Site
- More advanced comparative/analytical views

Important distinction:

**Scope inclusion ≠ implementation priority.**

Priority order:

1. Site Overview / Energy Health
2. Space investigation
3. Asset investigation
4. Portfolio analytics

---

## 96. Q65 — MVP Customer Roles

DECISION

MVP is primarily designed around the **Facility / Energy Manager**.

Other B2B personas can use the same underlying analytics:

- Portfolio Lead
- Operations Engineer
- Sustainability
- Executive

Role/context-aware presentation can evolve progressively.

Do not create separate role-specific MVP products or dashboards.

---

## 97. Q66 — MVP Customer Actions

DECISION

MVP customer actions are limited to **analysis and investigation**:

- Change time range
- Change Site / Space / Asset context
- Drill down
- Compare periods/baselines
- Inspect supporting evidence
- View data-quality information
- Export underlying data
- Navigate between analytical views

MVP does **not** include:

- Acknowledging recommendations
- Assigning work
- Adding action comments
- Logging interventions
- Verification workflows
- Recommendation management

These belong to the later Energy Management evolution.

---

## 98. Q67 — MVP Configuration Boundary

DECISION

At this point, all EMS/facility configuration is performed through the **WiseWatts Admin Portal**.

The customer-facing EMS does not become a configuration/admin application.

WiseWatts administrators configure things such as:

- Site/facility structure
- Asset relationships
- Meter/telemetry relationships
- Contract demand
- Tariff information
- Analytical thresholds/limits
- Other required system configuration

The customer EMS consumes this configured information for analytics.

This reinforces:

**WiseWatts Admin Portal = configuration and administration**
**Customer EMS = analytics and investigation**

---

## 99. Q68 — MVP Customer Administration

DECISION

Customer-side administration is limited to **User & Role Management**.

Customers can:

- Add user → Assign role → Manage access

Customers **cannot** configure:

- Sites / Spaces / Assets
- Meters or telemetry relationships
- Contract demand
- Tariffs
- Analytical thresholds
- Baselines / expectations
- System configuration

Those remain WiseWatts Admin Portal responsibilities.

---

## 100. Q69 — MVP Information Architecture

DECISION

The foundational MVP information architecture has two dimensions.

**Where?**

Portfolio → Site → Space → Asset

**What?**

Overview → Energy → Demand → Power Quality → Performance → Attention

Site Overview / Energy Health is the primary MVP destination.

The hierarchy provides context and progressive drill-down rather than forcing the customer through every level.

Customer-facing navigation should reflect customer/facility concepts rather than technical implementation concepts such as:

- Gateways
- Devices
- Meters
- Telemetry
- Raw parameters
- Grafana

The underlying analytical journey is:

**See → Compare → Investigate → Understand**

---

## 101. Q70 — MVP Site Overview Information Hierarchy

DECISION

The Site Overview / Energy Health information hierarchy is:

1. **Overall Site Health / Status** — How am I doing?
2. **Attention / Exceptions** — Is there anything I need to pay attention to?
3. **Energy Performance** — current consumption and comparison against selected baseline
4. **Maximum Demand** — demand/peak and contract-demand exposure where configured
5. **Power Quality** — PF and THD status/trends
6. **Investigation paths** — drill into Space → Asset and supporting evidence

Principle:

**Tell the customer the story first; provide analytical depth afterwards.**

---

## 102. Q71 — Overall Site Health

DECISION

Overall Site Health / Status is **not** a proprietary composite score or 0–100 Energy Health Score.

It is a concise summary of the underlying analytical conditions.

Example:

**Needs Attention**
2 significant issues detected.

The underlying Energy, MD, PQ, Performance and Attention signals remain visible.

The status should be transparent and traceable to the underlying analytical conditions.

---

## 103. Q72 — Significant Issues / Attention

DECISION

MVP Attention / Exceptions should surface meaningful, predefined analytical conditions rather than every small deviation.

Examples:

- Material deviation from the comparison baseline
- Maximum Demand approaching/exceeding configured contract demand
- Power Factor outside applicable threshold
- THD outside applicable threshold
- Significant data-quality problem affecting interpretation

Core principle:

**"Attention = things worth looking at, not everything that changed."**

Attention remains analytical and transparent. It is not intelligent opportunity ranking or recommendation.

---

## 104. Workshop Status After Q61–Q72

Q61–Q72 are DECIDED at the MVP-scope level recorded above. No OPEN PRODUCT DECISION or FAR FROM MVP items were introduced in this continuation — all twelve items are explicit MVP-boundary decisions, consistent with the workshop-direction change recorded in §77 and continued in §91.

Q61–Q72 refine the MVP landing/navigation experience (Site Overview / Energy Health as the primary destination), the site-vs-portfolio priority ordering, MVP customer roles and permitted actions, the WiseWatts Admin Portal vs. customer EMS configuration boundary, and the MVP information architecture and Site Overview hierarchy. They do not expand into, replace, or contradict the long-term intelligence direction captured in Q1–Q48 (§18–§75) or the MVP analytical scope captured in Q49–Q60 (§79–§90) — they add MVP experience/navigation/administration boundaries alongside the existing MVP analytical-scope decisions.

This remains a workshop record only.

No implementation is authorised by these decisions.
No Phase 9 work is authorised.
No UI/API/schema/architecture changes are authorised.
No production changes are authorised.

---

# WORKSHOP SESSION 2 — CONTINUATION (Q73–Q87, MVP FOCUS)

> This is a further continuation of the same Session 2 workshop discussion recorded in §17–§104 above. §1–§104 are preserved unchanged. Consistent with §77 (Workshop Direction Change) and §91/§104, this continuation stays MVP-focused. Nothing below revises, restructures, or reinterprets Q1–Q72 or the Session 1 baseline — it is additive only.

---

## 105. Q73 — MVP Financial Visibility

DECISION

The MVP will provide financial metrics wherever the underlying information is accurate and sufficiently configured.

Examples:

- Energy cost / spend
- Maximum Demand financial exposure
- Power-factor financial impact
- Time-of-Day / tariff-related cost context

Governing principle:

**Show financial meaning when we can substantiate it. If we cannot, do not manufacture or imply financial precision — show the underlying energy/electrical metrics instead.**

Financial analytics are part of MVP, but are data/configuration-dependent, not mandatory for every site.

---

## 106. Q74 — MVP Financial Language

DECISION

Financial information must distinguish between:

- **Measured financial values** — actual billed/charged amounts where source data is available.
- **Estimated/calculated financial values** — derived from measured energy data and configured tariff information.

An estimated tariff calculation must never be presented in a way that could be mistaken for an actual electricity bill.

This reinforces:

**Be precise about what we know and how we know it.**

---

## 107. Q75 — MVP Export

DECISION

MVP includes export of underlying analytical data and relevant context for further analysis outside WiseWatts.

Exports may include:

- Portfolio / Site / Space / Asset context
- Selected time range
- Relevant energy/demand/PQ measurements
- Comparison period/baseline
- Applicable calculated metrics
- Data-quality indicators

Export is not a general-purpose BI/query-builder or report-building tool.

The export should preserve enough context for the customer to understand what the exported numbers represent.

---

## 108. Q76 — MVP Reporting

DECISION

MVP includes a deliberately simple customer-facing reporting capability.

Its purpose is communication:

**What happened → What matters → What needs attention**

Reports should be derived from the core Site Overview / Energy Analytics experience and remain concise and opinionated.

MVP does **not** include:

- Sophisticated scheduled reporting
- Management report packs
- Custom report builders
- Complex report configuration
- Automated intelligent narratives

Keep the distinction:

**Report = communicate the important story**
**Export = provide the underlying data**

---

## 109. Q77 — MVP Alerts

DECISION

MVP supports basic customer alerts/notifications based on clear, measurable analytical conditions.

Examples:

- Maximum Demand exceeding configured contract-demand threshold
- Power Factor below configured threshold
- THD exceeding configured threshold
- Other clearly defined conditions supported by available data

An alert should communicate:

**What happened → Where → When → Relevant analytical context**

and link the customer back to the relevant analytical experience.

MVP alerts do **not** include:

- Intelligent prioritisation
- Root-cause analysis
- Recommendations
- Predictive alerts
- Adaptive/learned alerting

---

## 110. Q78 — MVP Alert Delivery

DECISION

MVP alert delivery includes:

**In-product**
- Attention/Alerts
- Contextual alert indicators

**Email**
- Email notifications for significant alerts

Email notifications are turned on for MVP.

Keep MVP email alerting deliberately simple.

Defer:

- Complex routing
- Escalation rules
- SMS/WhatsApp
- Advanced notification preferences
- Acknowledgement workflows
- Intelligent notification management

The exact rules, thresholds, templates and recipient configuration can be defined later.

---

## 111. Q79 — Healthy-State Experience

DECISION

MVP should actively communicate when a site is healthy rather than simply showing the absence of alerts.

Example:

**Healthy**
No significant issues detected for the selected period.

Basic site states:

- **Healthy** — no significant analytical conditions requiring attention.
- **Needs Attention** — one or more significant conditions detected.
- **Insufficient Data** — available data is insufficient for a reliable assessment.

Healthy does not mean "nothing to see"; underlying Energy, Performance, MD and PQ analytics remain available.

---

## 112. Q80 — Empty / Insufficient Data Experience

DECISION

MVP must explicitly handle:

- No data
- Partial data
- Stale data
- Insufficient comparison history

It must explain:

- What is missing
- Why it matters
- What analysis remains available, where applicable

Example:

**Insufficient data for comparison**
We have 12 days of energy data, but not enough historical data to establish the selected comparison.

Insufficient data must **not** be interpreted as Healthy.

---

## 113. Q81 — MVP Data Freshness

DECISION

MVP makes data freshness visible, particularly where freshness materially affects interpretation.

Examples:

Data updated: 10 minutes ago

or:

Data last received: 4 hours ago
Some current-period analytics may be incomplete.

This is especially relevant for:

- Current Maximum Demand
- Power Quality
- Attention conditions

The customer should be able to distinguish:

**Healthy because the data shows healthy**

from:

**We cannot confidently assess the current state because the data is stale.**

---

## 114. Q82 — MVP Data Granularity

DECISION

MVP allows customers to inspect underlying analytical time-series data at useful granularity, based on available telemetry.

Possible resolutions include:

- Daily
- Hourly
- 15-minute
- Other appropriate available measurement intervals

MVP does not expose raw telemetry structures.

Customers see analytical time series using customer-facing concepts.

---

## 115. Q83 — MVP Metric Consistency

DECISION

MVP establishes a common analytical grammar across metrics.

Where appropriate:

**Current value → Comparison → Trend → Status → Evidence / Data Quality**

This applies conceptually across Energy, MD, PQ and Performance, while allowing the exact presentation to differ by metric.

This is an MVP consistency principle, not a permanent constraint on future product evolution.

---

## 116. Q84 — MVP Comparison Periods

DECISION

Comparison periods are automatic by default, based on the selected primary time range.

Example:

Selected: 1–30 September
Comparison: 1–31 August

The comparison basis must be clearly shown.

Where useful, customers can change the comparison period.

This keeps the default experience simple while preserving analytical flexibility.

---

## 117. Q85 — MVP Metric Definitions

DECISION

MVP provides concise, accessible definitions/explanations for key metrics, particularly:

- Energy Consumption
- Maximum Demand
- Power Factor
- THD
- Energy Performance / comparison

The purpose is to support:

**See → Understand**

without becoming a technical manual.

Where applicable, explanations should appear alongside the metric's:

- Meaning
- Current value
- Status
- Comparison basis

---

## 118. Q86 — MVP Units and Terminology

DECISION

MVP consistently uses customer/business-facing terminology and units, rather than internal engineering/platform terminology.

Examples:

- Energy → kWh / MWh
- Demand → kW / kVA
- Power Factor → PF
- Power Quality → PF / THD
- Cost → ₹, where applicable

Technical concepts should have concise plain-language explanations where necessary.

Principle:

**Customer vocabulary, not platform vocabulary.**

---

## 119. Q87 — MVP Metric Context

DECISION

Key metrics should show their relevant contextual qualifier rather than presenting a number in isolation.

Examples:

Maximum Demand
842 kVA
vs Contract Demand: 900 kVA
Status: Within limit

or:

Energy Consumption
12,450 kWh
vs comparison baseline: +8%

MVP principle:

**A metric without context is just a number.**

Therefore favour:

**Value + Context + Status**

over standalone KPI values.

---

## 120. Workshop Status After Q73–Q87

Q73–Q87 are DECIDED at the MVP-scope level recorded above. No OPEN PRODUCT DECISION or FAR FROM MVP items were introduced in this continuation — all fifteen items are explicit MVP-boundary decisions, consistent with the workshop-direction change recorded in §77 and continued in §91 and §104.

Q73–Q87 refine MVP financial visibility and financial-language precision, MVP export vs. reporting boundaries, MVP alerting (conditions and delivery channels), the Healthy/Needs Attention/Insufficient Data site states, data-freshness and data-granularity visibility, and MVP presentation consistency (metric grammar, comparison periods, metric definitions, units/terminology, and value+context+status framing). They do not expand into, replace, or contradict the long-term intelligence direction captured in Q1–Q48 (§18–§75), the MVP analytical scope captured in Q49–Q60 (§79–§90), or the MVP experience/navigation boundaries captured in Q61–Q72 (§92–§103) — they add MVP financial, communication, alerting, state, and presentation-consistency decisions alongside the existing MVP decisions.

This remains a workshop record only.

No implementation is authorised by these decisions.
No Phase 9 work is authorised.
No UI/API/schema/architecture changes are authorised.
No production changes are authorised.

---

# WORKSHOP SESSION 2 — CONTINUATION (Q88–Q101, MVP FOCUS)

> This is a further continuation of the same Session 2 workshop discussion recorded in §17–§120 above. §1–§120 are preserved unchanged. Consistent with §77 (Workshop Direction Change) and §91/§104/§120, this continuation stays MVP-focused. Nothing below revises, restructures, or reinterprets Q1–Q87 or the Session 1 baseline — it is additive only.

---

## 121. Q88 — MVP First-Time Customer Experience

DECISION

The MVP first-time experience should be deliberately lightweight:

**Login → Select Portfolio/Site → Site Overview → Start analysing**

The customer is not taken through an EMS setup wizard.

Because configuration is handled through the WiseWatts Admin Portal:

- Sites and hierarchy are already prepared.
- Asset/meter relationships are already configured.
- Contract/tariff information is configured where applicable.
- Thresholds and other analytical configuration are already managed.

If something is unavailable or insufficiently configured, EMS should explain the limitation rather than asking the customer to perform administrative configuration.

Principle:

**Admin Portal prepares the environment. EMS helps the customer understand the environment.**

---

## 122. Q89 — MVP Returning-User Experience

DECISION

MVP should provide a lightweight returning-user experience, allowing the customer to resume their previous analytical context where appropriate:

- Last Portfolio
- Last Site
- Last time range
- Last analytical view

The current context must remain clearly visible so the customer always knows where they are and what period they are analysing.

This is a usability feature, not customer configuration or intelligence.

---

## 123. Q90 — MVP Search / Quick Navigation

DECISION

MVP includes search / quick navigation across the customer hierarchy to help customers reach analytical context quickly.

Examples:

Chiller 2 → Site → Space → Asset

Hyderabad → matching site(s)

Search is for navigating the customer hierarchy.

It is **not** a generic search across:

- Raw telemetry
- Technical fields
- Gateways
- Internal platform structures

---

## 124. Q91 — MVP Responsive Experience

DECISION

MVP must be responsive across desktop, tablet and mobile.

It is one EMS experience that adapts to the available screen/device rather than a separate mobile product.

Analytical hierarchy and usability must remain coherent across screen sizes, while presentation and interaction patterns can adapt appropriately.

Principle:

**One EMS experience, responsive across platforms.**

---

## 125. Q92 — MVP Performance Expectations

DECISION

MVP must provide fast initial usefulness.

The experience should prioritise:

**Initial useful information → progressively deeper information**

Example sequence:

1. Site Overview becomes available quickly.
2. Core health/status and key metrics appear.
3. Deeper charts and analytical details load progressively.
4. Longer-running operations have clear loading states rather than appearing frozen.

This is a product experience requirement: customers should receive useful information quickly rather than waiting for every component to load.

---

## 126. Q93 — MVP Error Handling

DECISION

MVP provides clear, customer-friendly error states for major analytical views.

Errors should explain:

- What could not be loaded
- Whether the issue affects the whole site or only that analysis
- What other analytics remain available
- What the customer can do next, if applicable

Example:

**Power Quality data unavailable**
We couldn't retrieve recent Power Quality data for this site. Energy and Demand analytics are still available.

Technical errors such as `Error 500` should not be the primary customer-facing explanation.

Principle:

**Technical complexity stays behind the product experience; the customer gets a useful explanation.**

---

## 127. Q94 — Energy Consumption Experience

DECISION

MVP Energy Consumption should answer:

- How much energy are we using?
- When are we using it?
- How does it compare with the selected baseline?
- Where is the consumption occurring?

It includes:

- Current/period consumption
- Consumption trend
- Selected comparison
- Relevant time granularity
- Status where a meaningful deviation exists
- Site → Space → Asset drill-down where supported
- Data freshness/quality
- Underlying analytical time-series inspection

It does **not** attempt to explain causes or recommend corrective actions.

---

## 128. Q95 — Maximum Demand Experience

DECISION

MVP Maximum Demand should answer:

- What is our demand?
- When did we reach our peak?
- How does that relate to our configured contract demand?
- Is there a meaningful exposure requiring attention?

It includes:

- Current/relevant maximum demand
- Demand trend
- Peak demand and when it occurred
- Comparison across relevant periods
- Contract demand where configured
- Utilisation/exposure against contract demand
- Clear status where a meaningful threshold is crossed or approached
- Appropriate time-series granularity
- Data freshness/quality
- Space → Asset drill-down where demand data supports it

It remains analytical exposure monitoring and does **not** attempt to determine why a peak occurred or recommend how to reduce it.

---

## 129. Q96 — Power Quality Experience

DECISION

MVP Power Quality focuses on:

- Power Factor (PF)
- THD

It should answer:

- How is our power quality?
- Is PF/THD within applicable limits?
- Has it changed materially over time?
- When did the issue occur?
- Where can I investigate further?

It includes:

- Current/relevant PF and THD values
- Trends over selected time range
- Applicable threshold/status where configured
- Comparison where meaningful
- Identification of significant deviations
- Data freshness/quality
- Appropriate time-series granularity
- Space → Asset drill-down where supported
- Plain-language explanation of PF and THD

It does **not** attempt to diagnose electrical causes or recommend corrective action.

---

## 130. Q97 — Energy Performance Experience

DECISION

MVP Energy Performance remains a **comparison-based** analytical experience, not a predictive experience.

It should answer:

- Are we performing better or worse than our comparison baseline?
- By how much?
- When did the change occur?
- Where is the difference occurring?

It includes:

- Current-period performance
- Historical baseline or configured expectation comparison
- Absolute and percentage variance where meaningful
- Performance/variance trend
- Material deviation periods
- Relevant time granularity
- Site → Space → Asset investigation where supported
- Evidence and comparison basis
- Data freshness/quality

Energy-intensity metrics requiring production, occupancy, weather or similar external context are **not** part of the default MVP unless such information is already reliably configured and available.

Core question:

**"How are we performing relative to our defined comparison?"**

---

## 131. Q98 — MVP Attention Experience

DECISION

MVP Attention consolidates meaningful analytical conditions from:

- Energy
- Maximum Demand
- Power Quality
- Energy Performance

Each attention item should communicate:

**What → Where → When → Metric → Trigger → Evidence → Data Quality → Investigate**

Example:

**Maximum Demand approaching contract limit**
Site: Hotel A
Peak: 892 kVA
Contract Demand: 900 kVA
Detected: 14:45, 10 Sep
Investigate →

MVP does **not** intelligently rank issues or recommend which issue to act on first.

---

## 132. Q99 — MVP Space Experience

DECISION

The Space experience is a contextualised version of the core Site analytical experience, not a separate product.

Where supported:

**Space Health / Overview → Energy → Demand → Power Quality → Performance → Attention**

It uses the same analytical grammar:

**Value → Context → Comparison → Trend → Status → Evidence / Data Quality**

The scope is narrowed to the selected Space and its available underlying data.

---

## 133. Q100 — MVP Asset Experience

DECISION

The Asset experience is a narrower, data-driven version of the common analytical experience.

Where supported, an Asset may show:

- Relevant energy consumption
- Relevant demand
- PF/THD where available
- Trend over time
- Meaningful comparison
- Status / Attention
- Data freshness/quality
- Supporting evidence

An Asset does not need to expose every metric.

Available and relevant measurements determine what can be shown.

Principle:

**Site → Space → Asset: same analytical principles, progressively narrower context, with metrics determined by available data.**

---

## 134. Q101 — MVP Navigation Context

DECISION

Customers should always have a clear indication of their current hierarchy and analytical context while navigating.

Example:

Portfolio: Hyderabad Hotels → Site: Hotel A → Space: HVAC Plant → Asset: Chiller 2

Alongside:

Energy → September → Compared with August

The customer should always know:

**Where am I?**

and

**What am I looking at?**

This is an MVP requirement, especially because customers can progressively navigate Portfolio → Site → Space → Asset.

---

## 135. Workshop Status After Q88–Q101

Q88–Q101 are DECIDED at the MVP-scope level recorded above. No OPEN PRODUCT DECISION or FAR FROM MVP items were introduced in this continuation — all fourteen items are explicit MVP-boundary decisions, consistent with the workshop-direction change recorded in §77 and continued in §91, §104 and §120.

Q88–Q101 cover the MVP first-time and returning-user experience, search/navigation, responsiveness, performance and error-handling expectations, and the detailed per-metric analytical experiences for Energy Consumption, Maximum Demand, Power Quality, Energy Performance and Attention, plus the Space and Asset experiences and persistent navigation context. They do not expand into, replace, or contradict the long-term intelligence direction captured in Q1–Q48 (§18–§75), the MVP analytical scope captured in Q49–Q60 (§79–§90), the MVP experience/navigation boundaries captured in Q61–Q72 (§92–§103), or the MVP financial/communication/consistency decisions captured in Q73–Q87 (§105–§119) — they add MVP onboarding, usability, and per-metric experience detail alongside the existing MVP decisions.

This remains a workshop record only.

No implementation is authorised by these decisions.
No Phase 9 work is authorised.
No UI/API/schema/architecture changes are authorised.
No production changes are authorised.

---

## Document History

| Date | Change |
|---|---|
| 2026-09-11 | Initial workshop baseline created, capturing decisions agreed in the Product Owner Workshop to date. Workshop in progress; further sessions expected. |
| 2026-09-11 (Session 2) | Appended §17–§39 (Session 2 addendum) capturing Product Owner decisions Q1–Q15 (customer job reaffirmed, customer outcome progression, post-login experience principle, B2B India principle, Maximum Demand/Power Quality direction, B2C residential direction, context-aware experience, first question, definition of normal, alert/explain/recommend model, recommendation-capability phasing, verification, configured+adaptive intelligence, progressive configuration, proactivity maturity, reporting's two purposes, trust/explainability, evidence classification), plus a Session 2 synthesis, preserved distinctions, and an updated open-items list. Session 1 content (§1–§16) preserved unchanged. Workshop remains in progress; Product Definition v0.2 not created; Phase 9 not started. |
| 2026-09-11 (Session 2, continued) | Appended §40–§53 continuing the same Session 2 workshop discussion, capturing Product Owner decisions Q16–Q26 (understanding energy use, prioritisation, act/execution boundary, action logging/detection/verification, recommendation experience, role/context-aware recommendations, multiple simultaneous opportunities, customer priorities, customer goals and targets, insufficient information, how opinionated WiseWatts should become), plus a Q16–Q26 consolidated-direction synthesis, v0.2 reconciliation notes, and a workshop-status statement. §1–§39 preserved unchanged. Workshop remains in progress; Product Definition v0.2 not created; Phase 9 not started; no code/schema/API/architecture/production changes made. |
| 2026-09-11 (Session 2, continued — reconciliation) | Appended §54–§78 continuing the same Session 2 workshop discussion, capturing Product Owner decisions Q27–Q48 (customer success, customer value across multiple non-combined dimensions, universal foundation + sector specialisation, layered intelligence transparency, customer challenge/feedback, action status & customer intent lifecycle, persistent customer/site context, learning from rejected recommendations, product boundary — energy first with adjacent-domain context, optimisation scope, energy analytics → energy management, the opportunity as primary UX unit, hierarchy-aware opportunities, two-dimensional opportunity lifecycle, resolved-opportunity value history, energy themes, site-specific intelligence, cross-customer learning with confidentiality constraints, exposing learned context, facts/interpretations/recommendations/predictions, self-correction & transparency, and prioritisation explainability), each preserving its DECIDED / DECIDED AT PRINCIPLE LEVEL / DECIDED — LONG-TERM / OPEN PRODUCT DECISION / FAR FROM MVP / MVP implication qualifiers as given. Also appended the Q16–Q48 consolidated workshop synthesis and a workshop-direction-change note (future sessions to focus on MVP scope and MVP-supporting foundations rather than further long-term intelligence detail). §1–§53 preserved unchanged, not duplicated. Workshop remains in progress; Product Definition v0.2 not created; Phase 9 not started; no code/schema/API/architecture/production changes made. |
| 2026-09-11 (Session 2, continued — MVP focus) | Appended §79–§91 continuing the same Session 2 workshop discussion, capturing Product Owner decisions Q49–Q60, all explicitly MVP-scoped per the §77 workshop-direction change: MVP boundary (hybrid, customer-value-defined B2B site-level snapshot: Energy/MD/PQ/Attention/Financial interpretation where supported), MVP analytical job (four core questions), MVP hierarchy/drill-down (Site→Space→Asset), MVP analytical scope (six areas), shared time context across views, comparison baseline (historical + configured expectations), expected performance as a comparison (not prediction) concept, historical comparison types (no sophisticated normalisation yet), Issues/Attention as analytical-not-intelligent, MVP investigation (Site→Space→Asset→Evidence, "what/where/evidence" not "why/what should I do"), evidence and trust as an MVP foundation, and data quality/analytical trust surfacing. No new OPEN PRODUCT DECISION or FAR FROM MVP items introduced — all twelve are DECIDED at MVP-boundary level. §1–§78 preserved unchanged, not duplicated. Workshop remains in progress; Product Definition v0.2 not created; Phase 9 not started; no code/schema/API/architecture/production changes made. |
| 2026-09-11 (Session 2, continued — MVP experience/navigation) | Appended §92–§104 continuing the same Session 2 workshop discussion, capturing Product Owner decisions Q61–Q72, all explicitly MVP-scoped: MVP landing experience (Site Overview / Energy Health as the unified landing view), MVP site scope (site as primary context), portfolio experience included but lower priority, portfolio MVP depth (full scope included, lowest implementation priority), MVP customer roles (Facility/Energy Manager primary; other personas share the same analytics without separate role-specific products), MVP customer actions (analysis/investigation only; no acknowledge/assign/log/verify workflows), MVP configuration boundary (WiseWatts Admin Portal owns configuration; customer EMS consumes it), MVP customer administration (limited to User & Role Management), MVP information architecture (Where: Portfolio→Site→Space→Asset; What: Overview→Energy→Demand→Power Quality→Performance→Attention; customer-facing concepts not technical ones), MVP Site Overview information hierarchy (status→attention→performance→MD→PQ→investigation paths), Overall Site Health as a transparent summary (not a proprietary composite score), and Significant Issues/Attention as meaningful predefined analytical conditions (not intelligent ranking). No new OPEN PRODUCT DECISION or FAR FROM MVP items introduced — all twelve are DECIDED at MVP-boundary level. §1–§91 preserved unchanged, not duplicated. Workshop remains in progress; Product Definition v0.2 not created; Phase 9 not started; no code/schema/API/architecture/production changes made. |
| 2026-09-11 (Session 2, continued — MVP financial/comms/consistency) | Appended §105–§120 continuing the same Session 2 workshop discussion, capturing Product Owner decisions Q73–Q87, all explicitly MVP-scoped: MVP financial visibility (shown where substantiated, not mandatory per site), MVP financial language (measured vs. estimated/calculated financial values, never mistaken for an actual bill), MVP export (underlying data + context, not a BI/report builder), MVP reporting (simple, communication-focused, distinct from export), MVP alerts (clear measurable conditions, no intelligent prioritisation/root-cause/recommendations/prediction), MVP alert delivery (in-product + email only for MVP; routing/escalation/SMS/WhatsApp/acknowledgement workflows deferred), Healthy-state experience (Healthy/Needs Attention/Insufficient Data site states), empty/insufficient-data experience (never interpreted as Healthy), MVP data freshness visibility, MVP data granularity (daily/hourly/15-minute, no raw telemetry exposure), MVP metric consistency grammar (value→comparison→trend→status→evidence), MVP comparison periods (automatic default, customer-adjustable), MVP metric definitions (concise, accessible), MVP units/terminology (customer vocabulary, not platform vocabulary), and MVP metric context (value + context + status, never a bare number). No new OPEN PRODUCT DECISION or FAR FROM MVP items introduced — all fifteen are DECIDED at MVP-boundary level. §1–§104 preserved unchanged, not duplicated. Workshop remains in progress; Product Definition v0.2 not created; Phase 9 not started; no code/schema/API/architecture/production changes made. |
| 2026-09-11 (Session 2, continued — MVP onboarding/usability/per-metric experience) | Appended §121–§135 continuing the same Session 2 workshop discussion, capturing Product Owner decisions Q88–Q101, all explicitly MVP-scoped: MVP first-time customer experience (lightweight, no setup wizard — Admin Portal prepares the environment, EMS explains it), MVP returning-user experience (resumes last context, always visible), MVP search/quick navigation (hierarchy navigation only, not raw telemetry/technical-field search), MVP responsive experience (one adaptive experience, not a separate mobile product), MVP performance expectations (fast initial usefulness, progressive loading), MVP error handling (customer-friendly explanations, not raw technical errors), and the detailed per-metric MVP analytical experiences for Energy Consumption, Maximum Demand, Power Quality, Energy Performance (comparison-based, not predictive) and Attention (consolidated, not intelligently ranked), plus the MVP Space experience (contextualised Site experience), MVP Asset experience (narrower, data-driven, metrics determined by availability), and MVP navigation context (always-visible hierarchy + analytical context). No new OPEN PRODUCT DECISION or FAR FROM MVP items introduced — all fourteen are DECIDED at MVP-boundary level. §1–§120 preserved unchanged, not duplicated. Workshop remains in progress; Product Definition v0.2 not created; Phase 9 not started; no code/schema/API/architecture/production changes made. |
