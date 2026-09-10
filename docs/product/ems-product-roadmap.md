# WiseWatts EMS — Product Roadmap (customer-outcome view)

> **Status:** WORKING DRAFT  ·  **Version:** 0.1  ·  **Owner:** Product  ·  **Last updated:** 2026-09-10
>
> **Source basis:** `docs/DDS/analytics-platform-future-state-architecture-implementation-roadmap.md` (Phases 7–17, verbatim phase objectives), `ems-product-definition.md`, `ems-information-architecture.md`.
>
> **This does NOT change the authoritative roadmap.** The technical roadmap's phase definitions, objectives, dependencies, and gates are unchanged. This document adds one thing per phase: **the customer outcome** — what a customer can newly do, and which product screens/capabilities light up. Where the customer roadmap and the technical roadmap could drift, the **technical roadmap wins**.

Labels: `[ARCH-CONSTRAINT]` (from the technical roadmap) · `[WISEWATTS-DECISION]` (product framing) · `[OPEN]`.

---

## 0. Mapping principle

`[WISEWATTS-DECISION]` The customer product is delivered **through** the technical phases, not alongside them. Every customer capability traces to: a **screen** (`ems-information-architecture.md`), an **API capability** (Phase 7 boundary), and a **semantic/data capability** (a DDS mechanism). If any of those three is missing, the capability is not "ready" regardless of how finished the UI looks — this is what `ems-requirements-traceability.md` enforces.

`[ARCH-CONSTRAINT]` Every phase still requires its own explicit approval before any staging or production change. Nothing here authorises work.

```text
Customer outcome  ⟵  Product screen  ⟵  Analytics API capability  ⟵  Semantic/data mechanism  ⟵  Roadmap phase
```

---

## 1. Foundation

### Phase 7 — Analytics API / Query Boundary  *(done: first slice on staging)*

- **Technical objective (verbatim):** "the stable contract between the data model and any consumer."
- **Customer outcome:** *none directly* — this is the door the customer product walks through. It guarantees the EMS Web Application never touches raw tables or Grafana.
- **What exists now:** `GET /api/v1/me`, `GET /api/v1/sites`, `GET /api/v1/sites/{id}/energy/consumption`, `GET /api/v1/spaces/{id}/measurements` (TEMPERATURE / HUMIDITY / DEW_POINT; DEW_POINT from the Phase 6 persisted tier). `no_data` is a normal 200; inaccessible resources 404 with no existence leak; flat error envelope.
- **Product dependency:** every screen. The gap between "first slice" and "everything the IA needs" is the subject of Phases 9–15.

### Phase 8 — Frontend Foundation  *(done: shell on staging behind `/app`)*

- **Technical objective (verbatim):** "the React/TypeScript application shell — no feature dashboards yet."
- **Customer outcome:** an internal user can **log in, land in a scoped shell, pick an organisation/site, and navigate an empty scaffold** — proving auth, tenancy, navigation, the shared time-range control, one charting foundation, and the loading/no-data/error/quality state components, all against real staging data. No customer-facing analytics yet.
- **Product framing:** this is the **EMS Web Application** (customer-facing), a separate surface from the Administration App; delivered as an independently deployable artifact; `/app` is a delivery detail (see `ems-product-architecture.md` §7).
- **Screens lit:** shell chrome, site selection, an empty Site "home". Everything else is placeholder.

---

## 2. Near-term customer product (MONITOR → INVESTIGATE)

### Phase 9 — Core Site / Asset / Space UX

- **Technical objective (verbatim):** "the first real feature surface — navigation and relational views, no energy/efficiency analytics yet."
- **Customer outcome:** a customer can **navigate their facility in their own terms** — Site Overview (structural), Spaces list + Space detail (environmental, using the live measurements endpoint), Assets list + Asset Overview with the **component tree** and **spaces-served** map, and a Device/Point diagnostic view that hides raw table names and routing config. First delivery of "no raw-tag overload."
- **Screens lit:** Site Overview (structure + environmental headline), Spaces (list + detail), Assets (list + Asset Overview), Analytics/Trends (environmental series).
- **API capability needed beyond today:** "spaces for a site" and "assets for a site" lists; asset-relationship + asset↔space read objects; comfort-target metadata. (Additive `v_grafana_*` views per the technical roadmap.)
- **Semantic mechanism:** Phases 2–3 relationships/bindings (`asset_points`/`space_points`, `asset_relationships`, `asset_space_relationships`, migration 228 device-specific binding).
- **Exit (customer view):** a real multi-asset, multi-space staging site is fully navigable and matches database ground truth.
- `[OPEN]` This is the **proposed Phase 9 starting point** — see §5.

### Phase 10 — Energy Analytics

- **Technical objective (verbatim):** "replicate (not yet replace) customer-facing energy workflows, run in parallel with Grafana."
- **Customer outcome:** the customer gets **energy consumption, demand, load profile, comparisons and energy breakdown** in the EMS Web Application — matching the 7 existing Grafana dashboards exactly (numerical parity is the gate). This is where "Is today's consumption normal?" and "Why did demand peak?" become answerable in-product. **Grafana remains the customer system of record** until Phase 17 accepts each workflow.
- **Screens lit:** Energy Consumption (full), Energy Demand (full), Energy Breakdown (subject to functional-category decision, gap PA-2), Analytics/Comparisons (period/site), Site Overview energy KPIs with real comparisons.
- **API capability needed:** demand series, breakdown-by-meter-role, comparison surfaces — all reading `analytics.energy_consumption_*` / `demand_intervals` through Phase 7; **energy backend untouched**.
- **Exit (customer view):** every energy workflow is numerically identical to Grafana for a representative sample (incl. DST + multi-tier), formally signed off — the precondition Phase 17 needs before any Grafana energy dashboard can be retired.

### Phase 11 — Asset Performance

- **Technical objective (verbatim):** "condition-monitoring UX, using the motor domain as the first production-quality reference implementation."
- **Customer outcome:** for instrumented equipment (motor domain first), the customer can see **operating status, condition parameters (runtime, vibration, temperatures), and per-asset efficiency**, closing the Point→Parameter→Subject→Domain→Derived→Quality loop for a real domain. Extends to other `asset_health` domains only after the motor reference is validated in production.
- **Screens lit:** Asset Performance, Asset Measurements (asset-scoped), Asset Overview condition section, Power Quality (if in scope), Site Overview "worst system".
- **API capability needed:** `asset_health`-backed parameter series + derived parameters (e.g. COP) via Phase 7.
- **Exit (customer view):** one real motor's complete chain is demonstrable end-to-end in the product.

### Phase 12 — Real-Time and Data Quality

- **Technical objective (verbatim):** "telemetry health/freshness/quality surfaces, reusing existing mechanisms."
- **Customer outcome:** the customer can **trust the numbers** — live status, freshness, communication health, and point-level quality (`GOOD/GAP/INVALID/ESTIMATED/PARTIAL`) surfaced consistently; a customer can tell "this reading is stale" from the product, not from an ops SQL playbook.
- **Screens lit:** a customer-facing Data Quality / Connectivity view; quality indicators everywhere (already scaffolded in Phase 8) now backed by real state; "data-quality health" KPI on Site/Portfolio Overview.
- **API capability needed:** `device_telemetry_state` / `device_status` / `device_live_point_state` read through Phase 7.
- **Exit (customer view):** a customer (or their operator) can diagnose a stale/failed device from the product alone.

---

## 3. Later customer product (IMPROVE → MEASURE)

### Phase 13 — Advanced Efficiency Analytics

- **Technical objective (verbatim):** "baseline/expected-performance, normalized performance, operating envelope, cross-asset comparisons."
- **Customer outcome:** "How are we doing?" gains a **real answer to "compared to what?"** — computed baselines / expected-performance bands overlaid on energy and asset-performance views, operating-envelope context, and **fair cross-asset comparisons** (only within an `asset_type_id`). Baselines are explicitly probabilistic and bake in before exposure.
- **Screens lit:** baseline overlays on Energy Consumption and Asset Performance; Analytics/Comparisons (cross-asset league tables); Site Overview "vs. expected".
- **Semantic mechanism:** baseline as a `parameter_calculations` specialization (fit/regression engine) — no parallel baseline schema.
- **Exit (customer view):** at least one baseline live, monitored, demonstrably sane over a multi-week window.

### Phase 14 — Cost / Benchmarking / Intelligence Foundations

- **Technical objective (verbatim):** "tariffs, cost, benchmarking, anomaly detection, insights, recommendations — deliberately thin."
- **Customer outcome:** the first **IMPROVE**-stage capabilities — **cost** views (rate × consumption + demand charges) *if a real customer requires tariffs*; **benchmarking** vs. baseline/best-practice; an **Insights** surface (`analytics.insights` — narrow, evidence-referencing) and the first, approval-gated **recommendations**. Detection logic lives in application/analytics code, never the schema. Each detector ships behind its own approval.
- **Screens lit:** Energy Cost (conditional), Analytics/Comparisons (benchmarking), Insights, first Recommendations, Sustainability/Carbon foundations (conditional).
- `[OPEN]` #7 (which cost capabilities are commercially required) gates the cost portion.
- **Exit (customer view):** one real insight, from real data, human-reviewed as non-spurious, before any detector runs unattended.

### Phase 15 — Reporting

- **Technical objective (verbatim):** "reports/exports/scheduled reporting, using the by-now-stable analytics/API layer."
- **Customer outcome:** the customer can **produce the documents they owe other people** — report builder/viewer, export UX (PDF/Excel), scheduled generation — with figures that match what they see on screen (Phase 10 parity), reading **only** through Phase 7.
- **Screens lit:** Reports (catalogue, viewer, export, schedules).
- **Exit (customer view):** a scheduled report runs unattended in staging for a full cycle with correct output.

### Phase 16 — Hardening and Scale

- **Technical objective (verbatim):** "performance, tuning, security, observability, recovery — under representative production-scale workloads."
- **Customer outcome:** the product **stays fast and correct at real multi-tenant, multi-year scale** — bundle-size/load-performance review, API caching strategy, retention/compression for every new tier, tenant-isolation penetration tests, backup/recovery validation. Behaviour must not change — only performance characteristics.
- **Screens lit:** none new — this makes existing screens hold up. Directly serves the "fast page loads" product requirement.
- **Exit (customer view):** every object has a tested retention policy and passes a representative-scale performance review.

### Phase 17 — Grafana Customer Workflow Migration

- **Technical objective (verbatim):** "migrate each customer-facing workflow only after parity is proven; Grafana remains for ops/engineering indefinitely."
- **Customer outcome:** **the EMS Web Application becomes the default customer entry point, one workflow at a time.** Per workflow: numerical parity, timestamp/timezone parity, tenant-scope parity, filtering parity, performance, **explicit customer acceptance**, then the default switches — with the Grafana dashboard kept live through a bake-in period and a trivial rollback (point the default back at Grafana). At the end, Grafana's customer-facing role is fully retired; Grafana continues serving ops/engineering.
- **Screens lit:** no new screens — this flips ownership of existing ones from Grafana to the EMS Web Application.
- **Exit (whole program):** every customer-facing workflow migrated with acceptance + bake-in; Grafana customer role retired.

---

## 4. Capability → phase summary

`[WISEWATTS-DECISION]` mapping of the ZeroWatt-referenced capability catalogue (see `ems-customer-requirements.md`) onto phases. Priorities in §12 of the requirements doc.

| Customer capability | Priority (draft) | Phase | Notes |
|---|---|---|---|
| Organisation/portfolio + site context | MUST | 8–9 | Portfolio depth `[OPEN]` #2 |
| Site Overview ("how are we doing?") | MUST | 9–10 | Headline metrics `[OPEN]` #3 |
| Spaces + environmental measurements | MUST | 9 | Live now for series; list endpoint Phase 9 |
| Assets + relationships + component tree | MUST | 9 | |
| Energy consumption + basic comparison | MUST | 10 | Parity-gated |
| Demand + peak analysis | MUST/SHOULD | 10 | Contributing-equipment attribution → 10/11 |
| Trends + time-range controls | MUST | 9–10 | Curated series only |
| No-data / error / quality states | MUST | 8 | Scaffolded; real backing 12 |
| Role/permission-aware experience | MUST | 8–9 | Roles `[OPEN]` #5 |
| Responsive + performance-conscious UI | MUST | 8, 16 | Budgets `[OPEN]` |
| Energy breakdown | SHOULD | 10 | Blocked on functional categories (PA-2) |
| Asset performance / condition monitoring | SHOULD | 11 | Motor domain first |
| Environmental ↔ energy correlation (curated) | SHOULD | 10–13 | Curated, not free-form (PA-5) |
| Alerts (view) | SHOULD | — | Model `[OPEN]` #6; relates to insights (14) |
| Power-quality analysis | SHOULD | 11/13 | High-res electrical params |
| Cost | SHOULD/LATER | 14 | Conditional on customer requirement (PA-3, `[OPEN]` #7) |
| Reporting | SHOULD | 15 | Formats `[OPEN]` #10 |
| Functional categories | SHOULD | 10 | Definition `[OPEN]` #12 (PA-2) |
| Richer portfolio views | SHOULD | 9–13 | `[OPEN]` #2 |
| Baseline / "compared to expected" | SHOULD | 13 | Probabilistic; bake-in |
| Benchmarking vs. best practice | LATER | 13–14 | |
| Insights / anomaly surface | LATER | 14 | Approval-gated detectors |
| Recommendations / actionable intelligence | LATER | 14+ | IMPROVE stage |
| Running hours | LATER | — | Derived; not scheduled |
| Start-up detection | LATER | — | Needs a model; not scheduled |
| Shift analysis / shift dashboards | LATER | — | Needs a shift-context model (`[OPEN]`) |
| Digital logbook | LATER | — | Introduces customer writes (PA-4) |
| Live single-line / energy flow | LATER | — | Real-time SLD |
| Tariff optimisation | LATER | — | Beyond rate × consumption |
| Multi-channel (mobile/email/messaging) | LATER | — | |
| Carbon / GHG accounting (Scope 1/2/3) | LATER | 14+ | Conditional |
| AI assistant / continuous AI insights | LATER | — | **No AI before its phase** |

---

## 5. Proposed Phase 9 starting point

`[WISEWATTS-DECISION]` (draft — `PRODUCT OWNER REVIEW REQUIRED`)

Start Phase 9 with **Site → Spaces → Space detail**, because:

1. It is the **only** feature area with a **live** Phase 7 endpoint today (`/api/v1/spaces/{id}/measurements`, incl. Phase 6 persisted `DEW_POINT`) — real customer value with the least new API surface.
2. It exercises the whole "semantic context around a measurement" principle end-to-end (`Site ▸ Space ▸ Parameter ▸ Value`, no raw tags) on real Radisson Blu / Meenaxy Pharma data.
3. It validates the Phase 8 foundation (time-range control, charting, no-data/quality states, drill-down) against real data before energy parity work (Phase 10) begins.
4. It has a clean rollback story and no dependency on the unresolved functional-category (PA-2) or cost (PA-3) decisions.

**Immediately after** (still Phase 9): Site Overview (structural) → Assets list + Asset Overview with the component tree and spaces-served map. Energy (Phase 10) follows once the relational UX is proven.

**Blocking questions before Phase 9 implementation is authorised:** PO Q1 (landing page), Q2 (portfolio vs site), Q3 (Site Overview headline metrics), Q4 (investigation depth), Q11 (Space as nav vs. drill-down), Q5 (roles). These do not block *design refinement*, but Q3 and Q11 shape Phase 9 screens directly.

---

## 6. Version history

| Version | Date | Change |
|---|---|---|
| 0.1 | 2026-09-10 | Initial working draft. Customer-outcome view of Phases 7–17, capability→phase map, proposed Phase 9 starting point. Authoritative roadmap unchanged. |
