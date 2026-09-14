# Navigation

Status: CURRENT (working hypothesis) · Last reviewed: 2026-09-13 · Owner: Product
Source of truth: `ems-information-architecture.md` §2, §6 (archived), consolidated here.

## Working hypothesis

Mirrors the product owner's proposed structure, adjusted so energy/
environment/assets are reachable both in site context and as cross-cutting
areas. **See [ADR-005](../00-governance/decisions/ADR-005-energy-demand-pq-contextual-nav.md)**
for the noted tension between this draft and the workshop's later,
more specific Q69 "Where × What" framing — not resolved by this
reorganization.

```text
CUSTOMER EMS
├── Overview                     ← portfolio/org level (multi-site); or redirect to Site Overview (single-site)
├── Sites
│   └── Site
│       ├── Overview
│       ├── Spaces  ──► Space detail
│       └── Assets  ──► Asset detail
├── Energy            (site-scoped by default; portfolio roll-up where supported)
│   ├── Consumption
│   ├── Demand
│   ├── Cost                     ← LATER; hidden until tariffs exist
│   ├── Breakdown
│   └── Power Quality            ← SHOULD
├── Environment
│   ├── Temperature
│   ├── Humidity
│   └── Other Parameters
├── Assets
│   ├── Asset Overview
│   ├── Asset Performance        ← Post-MVP
│   └── Asset Measurements
├── Analytics
│   ├── Trends
│   ├── Comparisons
│   └── Correlations             ← curated only, never a free-form query builder
├── Alerts                        ← SHOULD/MVP-7; implemented 2026-09-14 (ADR-016/ADR-017), staging validation pending; in-product only (header indicator + this area); config stays in Administration App (Q67)
├── Export                        ← MVP-6; decided 2026-09-14 (ADR-014), not implemented; also reachable contextually from Energy/Demand/Power Quality screens, not only here
└── Reports                       ← MVP-6; Site Performance Report decided + implemented 2026-09-14 (ADR-015), not yet deployed; Reports-area-only (no contextual access, unlike Export); rest of Q76 remains open

Future areas (record only; NOT approved MVP features):
├── Insights                      (Post-MVP — analytics.insights event log)
├── Recommendations               (Post-MVP — IMPROVE stage)
├── Sustainability / Carbon       (Post-MVP — GHG accounting)
└── AI Assistant                  (deferred — no AI before its phase)
```

## Open navigation questions

| # | Question | Status |
|---|---|---|
| 1 | First landing page | **Resolved:** Site Overview / Energy Health (Workshop Q61, Q88). |
| 2 | Portfolio-first vs. site-first | **Resolved:** Site is primary (Q62, Q63). |
| 4 | How a customer selects among multiple sites | Touched by Q90 (search/quick nav); exact selection pattern still an interaction-design detail. |
| 6 | How Alerts appear and where configured | **Resolved, in full detail (2026-09-14):** in-product only — header Active-alert-count indicator + dedicated Alerts area; no email/SMS/WhatsApp/sharing, correcting the archived Q78 "in-product + email" statement; configuration stays in the Administration App (Q67). See [ADR-016](../00-governance/decisions/ADR-016-q77-mvp7-basic-alerts.md). |
| 11 | Space: primary nav or drill-down | **Resolved:** drill-down (Q51, Q99) — see [ADR-002](../00-governance/decisions/ADR-002-hierarchy-model.md). |
| 12 | How functional categories slot into navigation | **Still genuinely open** — not addressed by Q49–Q101. |

## Cross-cutting screen elements

See [interaction-patterns.md](interaction-patterns.md) for the breadcrumb,
time-range control, and state-handling rules that every screen in
[information-architecture.md](information-architecture.md) follows.
