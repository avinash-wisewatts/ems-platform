# Scope and Deferred Functionality

Status: CURRENT · Last reviewed: 2026-09-13 · Owner: Product
Source of truth: `ems-customer-requirements.md` v0.1 §13–§14 (archived), consolidated here.

Distinguishes what is **rejected/out of scope** for the customer EMS from
what is **deferred later intelligence** — real future capability, deferred
until its designated phase, per
[ADR-012](../00-governance/decisions/ADR-012-deferred-ai-recommendation-functionality.md).

## IMPROVE / MEASURE — later intelligence (`LATER`)

| ID | Title / description | Customer question | Priority | Source | Phase | Notes |
|---|---|---|---|---|---|---|
| EMS-REQ-120 | **Insights surface.** Read `analytics.insights` (narrow, evidence-referencing event log). | "What has the system noticed?" | LATER | ROADMAP | DDS Phase 14 | Detectors ship per-approval; detection logic outside schema. |
| EMS-REQ-121 | **Anomaly detection (customer-facing).** Surface anomalies with evidence. | "Anything abnormal?" | LATER | ROADMAP, ZEROWATT_TECHNICAL_REFERENCE | DDS Phase 14 | No AI/anomaly scoring before Phase 14. |
| EMS-REQ-122 | **Recommendations / actionable intelligence.** Turn findings into suggested actions. | "What should I do?" | LATER | ZEROWATT_TECHNICAL_REFERENCE | DDS Phase 14+ | IMPROVE stage. |
| EMS-REQ-123 | **Best-practice comparison.** Compare performance against recognised best practices. | "How do we compare to best practice?" | LATER | ZEROWATT_TECHNICAL_REFERENCE | DDS Phase 13–14 | No best-practice reference set exists today. |
| EMS-REQ-124 | **Energy-saving opportunity identification.** Highlight quantified saving opportunities. | "Where can I save?" | LATER | ZEROWATT_TECHNICAL_REFERENCE, INFERENCE | DDS Phase 14+ | |
| EMS-REQ-125 | **Did-the-action-work (MEASURE).** Before/after comparison around a recorded action. | "Did my change help?" | LATER | PRODUCT_OWNER | DDS Phase 13–15 | The fourth journey stage (MEASURE). |
| EMS-REQ-126 | **Digital logbook.** Combine manual operational readings/notes with automatic telemetry. | "Record a manual meter read." | LATER | ZEROWATT_TECHNICAL_REFERENCE | — | Needs a customer-write mechanism (PA-4). |
| EMS-REQ-127 | **AI assistant / continuous AI insights.** Conversational / always-on AI analysis. | "Ask the system." | LATER | ZEROWATT_TECHNICAL_REFERENCE | — | Explicitly deferred. No AI now. |
| EMS-REQ-128 | **Automatic GHG / carbon accounting.** Scope 1/2/3 emissions and sustainability reporting. | "What are our emissions?" | LATER | ZEROWATT_TECHNICAL_REFERENCE | DDS Phase 14+ | Conditional on customer requirement. |

## NOT IN SCOPE (customer EMS)

| ID | Title | Reason | Source |
|---|---|---|---|
| EMS-REQ-900 | Customer administration of organisations/sites/users/devices/config | Belongs to the Administration App — see [ADR-006](../00-governance/decisions/ADR-006-ems-web-app-vs-admin-portal.md). | ARCHITECTURE, PRODUCT_OWNER |
| EMS-REQ-901 | Generic query builder / free-form metric explorer for customers | Would require dynamic SQL and expose implementation structure. | ARCHITECTURE, PRODUCT_OWNER |
| EMS-REQ-902 | Customer access to Grafana as the EMS UI | Grafana is OPS/engineering — see [ADR-008](../00-governance/decisions/ADR-008-grafana-ops-role.md). | ARCHITECTURE |
| EMS-REQ-903 | Raw-tag / telemetry-name browser | Violates the "no raw-tag overload" principle (EMS-REQ-003). | PRODUCT_OWNER, ZEROWATT_TECHNICAL_REFERENCE |
| EMS-REQ-904 | Generalised billing engine | Cost is rate × consumption/demand only, conditional on tariff data existing. | ROADMAP |
| EMS-REQ-905 | New database entities invented to support a UI idea | Frozen-architecture change-control applies — see [../04-architecture/system-architecture.md](../04-architecture/system-architecture.md). | ARCHITECTURE |
| EMS-REQ-906 | AI/recommendation functionality ahead of its phase | See [ADR-012](../00-governance/decisions/ADR-012-deferred-ai-recommendation-functionality.md). | PRODUCT_OWNER, ROADMAP |
| EMS-REQ-907 | Cloning a reference product's navigation, terminology, or dashboard layout | The product owner requires a distinct WiseWatts product. | PRODUCT_OWNER |
| EMS-REQ-908 | Modifying Phase 6 / energy pipelines / Grafana / the Phase 7 contract to enable a screen | Requires a separate explicit architecture decision, not a product requirement. | ARCHITECTURE |

## Anti-pattern guardrails

A requirement or screen is rejected in review if it: needs data the
Analytics API does not expose and proposes to reach past the API to get it;
needs a new database entity/column to support a UI idea; becomes a
free-form query builder/metric-vs-metric explorer/raw-tag browser;
introduces dynamic SQL anywhere; introduces AI/recommendation/
anomaly-scoring ahead of its phase; requires a change to Phase 6, energy
pipelines, Grafana, or the Phase 7 contract without a separate explicit
architecture decision; or makes an energy number that also appears in
Grafana without a parity commitment.
