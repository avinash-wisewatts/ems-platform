# WiseWatts EMS — Product Definition

> **Status:** WORKING DRAFT  ·  **Version:** 0.1.1  ·  **Owner:** Product  ·  **Last updated:** 2026-09-11 (§12/§13 status pointers only — see Version History; no product decision altered)
>
> **Source basis:**
> - `docs/DDS/analytics-platform-future-state-architecture.md` (CONCEPTUALLY FROZEN) — authoritative platform architecture
> - `docs/DDS/analytics-platform-future-state-architecture-implementation-roadmap.md` — authoritative technical roadmap
> - PR #44 (`docs(DDS): clarify Administration App vs EMS Web Application boundary`) — the product-boundary clarification, now merged to `staging`
> - ZeroWatt EMS demonstration video + `Zerowatt-Technical-Overview.pdf` — **reference / inspiration only**, supplied by the product owner; not committed to this repository; not a specification to copy
> - Product-owner brief that commissioned this document set
>
> This is an **initial v0.1 working product definition**. It is not final. Every classification, priority and hypothesis in this set is subject to product-owner review.

---

## 0. How to read this document set

Seven documents live under `docs/product/`. This one (`ems-product-definition.md`) is the entry point: vision, users, boundary, journey, principles, terminology, goals and non-goals. The others go deeper:

| Doc | Answers |
|---|---|
| `ems-product-definition.md` (this) | *What are we building for the customer, and why?* |
| `ems-customer-requirements.md` | *What specific capabilities, and at what priority?* |
| `ems-information-architecture.md` | *What screens, what does each show, how do they connect?* |
| `ems-product-architecture.md` | *How does the product sit on top of the frozen platform architecture?* |
| `ems-product-roadmap.md` | *What customer outcome does each technical phase deliver?* |
| `ems-requirements-traceability.md` | *Does every UI idea have the semantic/API support to build it?* |
| `README.md` | *Which document answers which question.* |

**The DDS documents remain authoritative for platform architecture.** Nothing in `docs/product/` overrides them. Where a product requirement would need an architecture change, this set records it as an explicit dependency — it does not assume it.

### Evidence labelling (used throughout the set)

Every non-trivial statement is tagged so the product owner can see where it came from:

| Tag | Meaning |
|---|---|
| `[ZEROWATT-OBSERVED]` | Seen in the ZeroWatt demo/technical overview. Reference only — not automatically a WiseWatts requirement. |
| `[INFERRED]` | A reasonable deduction by the author. **Not fact.** Needs confirmation. |
| `[WISEWATTS-DECISION]` | A deliberate WiseWatts product choice recorded here. Still a v0.1 draft choice. |
| `[ARCH-CONSTRAINT]` | Imposed by the frozen DDS / existing platform. Not negotiable at the product layer. |
| `[OPEN]` | `OPEN — PRODUCT DECISION REQUIRED`. No answer yet; do not invent one. |

---

## 1. Product vision

`[WISEWATTS-DECISION]` The WiseWatts EMS is **not** "a collection of dashboards and charts."

> **The WiseWatts EMS is a facility intelligence system that starts with "How are we doing?", lets the customer investigate "Why?", and eventually helps answer "What should we do?"**

### 1.1 The four-stage customer experience

```text
MONITOR      How are we doing?
    ↓
INVESTIGATE  Why is this happening?
    ↓
IMPROVE      What should we do?
    ↓
MEASURE      Did the action improve performance?
```

`[WISEWATTS-DECISION]` **MONITOR** and **INVESTIGATE** are the near-term product (Phases 8–12). **IMPROVE** and **MEASURE** are later capabilities (Phases 13–15+). No AI, recommendation, or anomaly-scoring functionality is implemented ahead of its phase — see `docs/product/ems-product-roadmap.md`.

`[INFERRED]` The stages are a *lens on the whole product*, not four separate areas of the app. A single screen can support MONITOR ("today's kWh vs. expected") and open a path to INVESTIGATE ("show me the hour it spiked"). The product's job is to make the next question cheap to ask.

### 1.2 What "facility intelligence" means here

`[WISEWATTS-DECISION]` The customer should be able to reason about their facility in **their own terms** — sites, spaces, systems, equipment, energy bills, comfort, production — and never in the platform's terms — devices, logical points, raw fields, hypertables, Grafana orgs. The semantic model (`Organisation → Site → Space → Asset → Parameter`, plus asset relationships) is the vocabulary the product exposes. See §6 and `docs/product/ems-information-architecture.md`.

---

## 2. Target users

`[INFERRED]` from the architecture's permission model (`admin.portal_user_has_permission`), the ZeroWatt "role-based dashboards" capability `[ZEROWATT-OBSERVED]`, and the Radisson Blu / Meenaxy Pharma tenants already onboarded.

| Persona | Primary questions | Notes |
|---|---|---|
| **Facility / energy manager** (single site) | How is my site doing? Why is the bill up? Where is the waste? | The core near-term user. |
| **Portfolio / corporate energy lead** (multi-site) | Which sites are worst? Are we improving? Consolidated numbers. | Needs portfolio roll-ups; `[OPEN]` how much depth. |
| **Plant / operations engineer** (industrial) | Equipment performance, running hours, shift context, demand peaks and their causes. | Industrial tenants (e.g. Meenaxy Pharma). Shift/running-hours capabilities are `LATER`. |
| **Sustainability / ESG owner** | Carbon, Scope 1/2/3, reporting formats. | `LATER` — Phase 14+. |
| **Executive / non-operational viewer** | One-glance status; a monthly report. | Read-mostly; role-appropriate simplified view. |

`[OPEN]` **Which roles exist in the customer EMS application?** The Administration App's role model is not assumed to be the customer EMS's role model. `OPEN — PRODUCT DECISION REQUIRED`.

`[ARCH-CONSTRAINT]` Whatever roles exist, permission enforcement is **server-side** (Phase 7 SECURITY DEFINER functions + session middleware). Frontend permission checks gate navigation/UX only — they are never the security boundary.

---

## 3. Product boundary

### 3.1 Administration App — existing, unchanged

`[ARCH-CONSTRAINT]` The **Administration App** (today's `admin-portal`, FastAPI + server-rendered Jinja2) remains the administrative/operational interface. It is **left operationally intact** and is **not** part of the customer EMS build. Its purpose:

- organisation administration
- site administration
- user administration and permissions
- device administration
- configuration
- onboarding / commissioning
- operational / admin workflows

The roadmap extends it in place (new `admin.*` write functions for new relationship tables); it is never rewritten by this roadmap. Configuration of things like alert rules and functional categories belongs **primarily in the Administration App**, even where the customer EMS surfaces or triggers them `[INFERRED]`.

### 3.2 Customer EMS Web Application — new

`[WISEWATTS-DECISION]` A **new customer-facing application**. Purpose:

- understand facility / site performance
- investigate energy and environmental behaviour
- navigate sites, spaces and assets
- analyse consumption and demand
- understand equipment performance
- identify problems / anomalies
- **eventually** provide recommendations, intelligence, reporting and sustainability capabilities

`[ARCH-CONSTRAINT]` The EMS Web Application **consumes the Analytics API** (the Phase 7 query boundary). It must **not** directly expose:

- raw telemetry structures
- database implementation details
- internal tables
- Grafana queries
- implementation-specific identifiers (device IDs, logical-point IDs, raw field names, Grafana org IDs)

`[WISEWATTS-DECISION]` The EMS Web Application is **NOT a redesign of the Administration App**. The two are separate applications with different purposes. They **may share** authentication, authorisation and backend/API services; sharing those services does not merge them.

### 3.3 Grafana — OPS/engineering surface

`[ARCH-CONSTRAINT]` Grafana **remains an OPS / engineering surface**. It is retained for ops/engineering indefinitely. Customer-facing Grafana workflows are migrated to the EMS Web Application **only** through the roadmap's existing per-workflow **parity process** (Phase 17): numerical parity, timestamp/timezone parity, tenant-scope parity, filtering parity, performance, explicit customer acceptance, then a bake-in period during which the Grafana dashboard stays live. Nothing in this product set shortcuts that process. **Grafana is never the customer UI.**

### 3.4 The layering (product view)

```text
        Administration App                 Customer EMS Web Application
   (admin/ops; existing; intact)        (customer-facing; new; this product)
                │                                       │
                │  writes (admin.* functions)           │  reads only
                └───────────────┬───────────────────────┘
                                ▼
                        Analytics API  (Phase 7 query boundary — the contract)
                                ▼
                Semantic / Analytics Platform  (v_grafana_* views + functions,
                   config.parameters, asset/space relationships, derived params)
                                ▼
                  Telemetry / Data Platform  (MQTT → Telegraf → TimescaleDB,
                     energy_measurements, environment_measurements, …)

        Grafana  ── reads the same semantic layer, OPS/engineering only,
                    customer role retired workflow-by-workflow via Phase 17 parity
```

See `docs/product/ems-product-architecture.md` for the full treatment.

---

## 4. `/app` — a routing detail, not the product identity

`[ARCH-CONSTRAINT]` (recorded in the DDS §F.0 by PR #44, restated here for the product audience)

- `/app` is the **current staging route** used to expose the EMS Web Application.
- `/app` is a **routing / deployment detail**. It is **NOT** the architectural identity of the EMS application.
- The **final product boundary is the EMS Web Application itself**, wherever it is served.
- Nothing commits the EMS Web Application to living permanently at `/app`.

`[WISEWATTS-DECISION]` **Deployment principle:** the EMS Web Application is treated as an **independently deployable application** — independently releasable and rollbackable **without changing the Administration App**. The **preferred** implementation/deployment approach is a **separate EMS Web Application image/container**. Separate-container deployment is an **implementation/deployment decision, not a frozen conceptual-architecture requirement**. Rolling the EMS Web Application back has **no effect** on the Administration App, Grafana, the database, Phase 6 pipelines, or the energy subsystem. (Phase 8's staging mechanism currently delivers it as an independently versioned `-web:<sha>` artifact mounted read-only into the admin-portal container and served same-origin under `/app`; that is a delivery mechanism, not the boundary.)

---

## 5. Core customer journey (initial conceptual model)

`[WISEWATTS-DECISION]` Starting model, **not** a final UI specification.

```text
Login
  ↓
Organisation / Portfolio        (skipped or collapsed for single-site customers — [OPEN])
  ↓
Site
  ↓
Site Overview                   ("How are we doing?" — MONITOR)
  ↓
 ┌───────────────┬────────────────┬───────────────┐
 ↓               ↓                ↓
Energy        Environment       Assets
 ↓               ↓                ↓
Consumption   Temperature      Asset Performance
Demand        Humidity         Measurements
Cost          (other params)
Breakdown
 ↓
Analytics                       ("Why is this happening?" — INVESTIGATE)
 ↓
Report / Action                 (IMPROVE / MEASURE — later)
```

Detailed screen-by-screen treatment: `docs/product/ems-information-architecture.md`.

---

## 6. Information hierarchy principle

`[ARCH-CONSTRAINT] + [WISEWATTS-DECISION]` The customer-facing experience uses the **semantic model**, not telemetry/database structures.

Conceptual hierarchy:

```text
Organisation → Site → Space / Area → Asset → Measurement / Parameter
```

`[WISEWATTS-DECISION]` **Do not** assume every screen follows this hierarchy rigidly. Energy, for instance, is often site-scoped and meter-role-scoped rather than space-scoped `[ARCH-CONSTRAINT]` (`config.site_energy_meter_roles` is independent of the asset/space graph). The rule is: **expose meaningful EMS concepts, not database entities.**

`[ZEROWATT-OBSERVED]` A key UX principle taken as inspiration: avoid **"raw-tag overload."** Provide **contextual hierarchy around every measurement**. The customer sees:

```text
Radisson Blu  →  Banquet Hall 2  →  Temperature  →  24.3 °C
```

never device IDs, logical-point IDs, raw field names, or Grafana variables.

`[OPEN]` **Should Space be a primary navigation concept, or primarily a drill-down target?** `OPEN — PRODUCT DECISION REQUIRED`.

---

## 7. Product principles

1. **Business questions first, not chart types.** `[WISEWATTS-DECISION]` Every requirement is expressed as: *customer question → business capability → metric / semantic concept → required data → visualisation / interaction*. See `docs/product/ems-customer-requirements.md`.
2. **Semantic vocabulary only.** `[ARCH-CONSTRAINT]` No raw telemetry terminology in the customer UI. No implementation identifiers. No Grafana queries.
3. **Progressive investigation.** `[WISEWATTS-DECISION]` Every "how are we doing" number should have a path to "why." How deep that path goes is `[OPEN]` (see §16, Q4).
4. **The Analytics API is the only door.** `[ARCH-CONSTRAINT]` The frontend never queries PostgreSQL / TimescaleDB / Grafana / internal analytics objects directly. No frontend query builder. No dynamic SQL.
5. **Performance is a product requirement.** `[ZEROWATT-OBSERVED] + [WISEWATTS-DECISION]` Fast page loads are a requirement, not an afterthought (`EMS-REQ` catalogue, MUST).
6. **"No data" is a normal state.** `[ARCH-CONSTRAINT]` A newly-commissioned device's empty history reads as "no data yet," never an error (matches Phase 8's state components and `24-troubleshooting.md`).
7. **Quality is always visible.** `[ARCH-CONSTRAINT]` `GOOD / GAP / ESTIMATED / INVALID / PARTIAL` are surfaced consistently wherever a measurement is shown. The product never invents quality values the API does not provide.
8. **Role-appropriate views.** `[ZEROWATT-OBSERVED] + [INFERRED]` Different users see information appropriate to their role; enforcement is server-side.
9. **Don't clone ZeroWatt.** `[WISEWATTS-DECISION]` Extract capabilities and workflows; design a distinct WiseWatts product. Do not copy its navigation, terminology, or dashboard layout.
10. **The frozen architecture wins.** `[ARCH-CONSTRAINT]` No product requirement silently forces a technical architecture change; unmet needs are recorded as explicit dependencies.

---

## 8. Terminology (customer-facing vocabulary)

`[WISEWATTS-DECISION]` The customer EMS uses these words. The platform-internal term is shown only to keep engineers oriented — it is **never shown to customers**.

| Customer term | Meaning | Platform-internal (not shown to customers) |
|---|---|---|
| **Organisation** / **Portfolio** | The tenant; the set of sites a customer owns | `metadata.organizations` / `organization_id` |
| **Site** / **Facility** | A physical facility | `metadata.sites` |
| **Space** / **Area** | A room / zone within a site | `metadata.spaces` (Building → Floor → Space) |
| **Asset** / **Equipment** / **System** | A piece of equipment or a composite of equipment (a "Chiller Plant" is one Asset composed of members) | `metadata.assets` (`asset_nature: PHYSICAL | VIRTUAL`) |
| **Measurement** / **Reading** | A single value at a point in time, in context | a row in a domain measurement table |
| **Parameter** | The *meaning* of a measurement ("Temperature", "Active Power") | `config.parameters` (via `logical_points.parameter_id` + `qualifier`) |
| **Consumption** | Energy used over a period (kWh, and fuel/thermal where present) | `analytics.energy_consumption_*` (1min/5min/15min/hourly/daily) |
| **Demand** | Rate of energy use / power over an interval; **peak demand** = the maximum | `demand_intervals` / `demand_state` |
| **Cost** | Money, from tariff × consumption/demand | `config.tariffs` / `analytics.cost_values` — **not built yet** (Phase 14) |
| **Comfort** / **Environment** | Temperature, humidity, dew point, CO₂, etc. for a space | `telemetry.environment_measurements` (+ `space_id`), Phase 6 persisted `SPACE_DEW_POINT` |
| **Performance** | Derived, comparative view of how well an asset/site is doing vs. expected | `parameter_calculations` / `analytics.derived_parameter_values` |
| **Data quality** | `GOOD / GAP / ESTIMATED / INVALID / PARTIAL` on a reading or series | `quality_code`, `is_estimated` |
| **Functional category** | A meaningful grouping of meters/assets (e.g. "HVAC", "Lighting", "Process") | `[OPEN]` — see §16 and `ems-customer-requirements.md` |
| **Running hours** | Hours an asset was running, derived from telemetry | derived — **not built yet** (`LATER`) |

---

## 9. Product goals (v0.1)

`[WISEWATTS-DECISION]`

- **G1 — One honest number.** A customer can answer "how is my site doing right now / today / this month" in one screen, with a comparison to expected/baseline, and with data quality visible.
- **G2 — A cheap next question.** From any headline number, the customer can move one step toward "why" (a time, a system, a space, an asset) without leaving the flow.
- **G3 — Their vocabulary.** The customer never sees a device ID, logical-point ID, raw field name, or Grafana artefact.
- **G4 — Portfolio and site.** Multi-site customers get consolidated views; single-site customers are not taxed with portfolio ceremony.
- **G5 — Trust.** No-data, partial-data and estimated-data are shown truthfully; numbers that also appear in Grafana match Grafana (Phase 10 parity discipline).
- **G6 — Independently shippable.** The EMS Web Application ships and rolls back on its own, without touching the Administration App, Grafana, the database, Phase 6, or energy.
- **G7 — A path to intelligence.** The structure supports IMPROVE/MEASURE later without a rebuild — but nothing AI/recommendation is shipped before its phase.

---

## 10. Product non-goals (v0.1)

`[WISEWATTS-DECISION]` / `[ARCH-CONSTRAINT]`

- **Not** a rebuild or replacement of the Administration App.
- **Not** a Grafana replacement for ops/engineering; Grafana stays.
- **Not** a generic query builder / metric explorer for customers. No dynamic SQL. No raw-tag browser.
- **Not** a place that exposes telemetry structure, internal tables, or implementation identifiers.
- **Not** an AI product in the near term. No recommendation engine, no anomaly scoring, no "continuous AI insights", no AI assistant before Phase 14+.
- **Not** a billing engine. Cost is rate × consumption/demand (Phase 14), not a generalised billing system.
- **Not** a driver of schema change. The product does not invent database entities to satisfy a UI idea, and does not introduce new architecture to satisfy a mock-up.
- **Not** a reason to modify Phase 6, the energy subsystem, Grafana, or the Phase 7 API contract without an explicit, separate architecture decision.
- **Not** a clone of ZeroWatt's navigation, terminology, or layout.

---

## 11. Relationship to the frozen architecture

`[ARCH-CONSTRAINT]` This product definition is consistent with, and subordinate to, the DDS. Specifically it preserves:

- Organisation → Site structure; tenant isolation on every row.
- Space / Asset / Point / Parameter semantics (§B.2, §B.3); the two optional subject types (Asset, Space) and the rejection of a polymorphic "Subject".
- Typed, effective-dated asset relationships and asset↔space relationships (§B.4, §B.5); device-specific point binding (migration 228).
- The Analytics API boundary (Phase 7) as the only customer read path.
- Declarative routing (Phase 4), persisted derived calculations (Phases 5–6), the existing `SPACE_DEW_POINT` implementation (migration 230).
- The Phase 7 API contract (no change without an explicit architecture decision).
- Grafana's OPS/engineering role and the Phase 17 parity migration strategy.
- Energy-subsystem stability — `energy_measurements`, the 5-tier ladder, `config.energy_register_semantics`, `demand_intervals`/`demand_state` are untouched.

Any product requirement that cannot be supported today is marked with an explicit dependency in `docs/product/ems-customer-requirements.md` and `docs/product/ems-requirements-traceability.md`.

---

## 12. Open product decisions (index)

> **IMPLEMENTATION STATUS UPDATE (2026-09-11):** the Product Owner Workshop (`ems-product-owner-workshop-baseline.md` §92–134, Q49–Q101) has since answered most of the items below. This index is **not rewritten** — the decisions themselves live in the workshop baseline, which is authoritative for them — but each item is marked with where its answer now lives, so this document stops reading as more open than it is. Only genuinely unresolved items remain unmarked.

1. First landing page after login. → **Resolved:** Q61, Q88.
2. Portfolio-first vs. site-first for multi-site customers. → **Resolved:** Q62, Q63.
3. The five headline things on the initial Site Overview. → **Resolved:** Q70, Q71, Q72.
4. How customers select among multiple sites. → Touched by Q90 (search/quick nav); exact selection pattern still an interaction-design detail, not a scope question.
5. Which roles exist in the customer application. → **Resolved:** Q65 (Facility/Energy Manager is the primary persona) — the existing `ADMIN`/`OPERATOR`/`VIEWER` role model has not yet been explicitly mapped to it (an implementation task, not an open product question).
6. How alerts appear (and where they are configured). → **Resolved:** Q77, Q78 (appearance); Q67 (configuration stays in the Administration App).
7. Which energy-cost capabilities are commercially required. → **Resolved:** Q73 (financial visibility is MVP scope wherever accurate/sufficiently configured; not mandatory per site). The remaining question is a data/configuration dependency, not a scope decision — see `ems-requirements-traceability.md` §4.
8. Initial target industries. → **Still open** — not addressed by Q49–Q101.
9. How much asset detail customers should see. → **Resolved:** Q100 (a narrower, data-driven version of the common analytical experience).
10. Required reporting formats. → Partially resolved: Q76 gives the general shape (simple, derived, no builder); specific export/report file formats remain undecided.
11. Whether Space is primary navigation or drill-down. → **Resolved:** Q51, Q99 — drill-down (a contextualised version of the Site experience), not primary top-level navigation.
12. How functional categories are defined and by whom. → **Still open** — not addressed by Q49–Q101; remains blocked on `PA-2`.
13. What "normal" / baseline performance means, and who sets it. → **Resolved:** Q54, Q55, Q56, Q97 — historical comparison (previous period / same period previously / rolling average) is the MVP default; configured expectation is used where the customer has supplied it; no predictive/adaptive modelling. See `ems-product-roadmap.md` §6 for the implementation-readiness read of this decision.

---

## 13. Product owner's five key questions

> **IMPLEMENTATION STATUS UPDATE (2026-09-11):** answered by the workshop, per below. Recorded verbatim as originally asked; answers are pointers to the authoritative workshop decisions, not restated here.

1. **When a customer logs in, what should they see first?** → **Resolved:** Q61 (Site Overview / Energy Health), Q88 (Login → Select Portfolio/Site → Site Overview → Start analysing).
2. **If a customer has multiple sites, should they land at portfolio level or directly on a site?** → **Resolved:** Q62 — Site is primary; single-site customers land directly on Site Overview.
3. **What are the five most important things the customer should know about their facility?** → **Resolved:** Q70 (Site Overview information hierarchy), Q71 (Overall Site Health as a plain summary, not a score).
4. **When something looks wrong, how far should the customer be able to investigate?**
   ```text
   High energy → system → asset → space → time → measurement
   ```
   → **Resolved:** Q51 (Site → Space → Asset), Q58 (MVP investigation depth).
5. **What should our EMS do substantially better than the ZeroWatt product / reference?** → **Still open** — not directly addressed by Q49–Q101; remains a genuine open differentiation question, not an implementation dependency.

---

## 14. Version history

| Version | Date | Change |
|---|---|---|
| 0.1 | 2026-09-10 | Initial working draft. Product boundary, vision, journey, principles, terminology, goals/non-goals, open decisions, PO's five questions. Companion docs A–G created together. |
| 0.1.1 | 2026-09-11 | **IMPLEMENTATION STATUS UPDATE.** §12 and §13 items marked with pointers to their now-resolved answers in `ems-product-owner-workshop-baseline.md` Q49–Q101. No product decision was altered, added, or invented here — the decisions remain recorded only in the workshop baseline. |
