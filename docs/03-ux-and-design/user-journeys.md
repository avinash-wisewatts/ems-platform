# User Journeys

Status: CURRENT (working hypothesis) · Last reviewed: 2026-09-13 · Owner: Product
Source of truth: `ems-product-definition.md` §5, `ems-information-architecture.md` §1, §5 (archived), consolidated here.

## Core customer journey

```text
Login
  ↓
Organisation / Portfolio        (single-site customers land directly on Site Overview — Workshop Q62)
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

Two rules shape every screen (design intent):

1. **Every headline number offers a cheap next question.** A KPI is a door,
   not a dead end — drill-down to time / space / system / asset /
   measurement.
2. **Semantic context around every measurement** — `Site → Space →
   Parameter → Value`, never `device → logical point → raw field`.

## Returning-user experience (Workshop Q89)

MVP resumes the customer's previous analytical context where appropriate:
last Portfolio, last Site, last time range, last analytical view. Current
context always stays clearly visible. This is a usability feature, not
customer configuration or intelligence.

## Search / quick navigation (Workshop Q90)

MVP includes search across the customer hierarchy (e.g. "Chiller 2 → Site →
Space → Asset," "Hyderabad → matching site(s)") — never a generic search
across raw telemetry, technical fields, gateways, or internal platform
structures.

## Screen → journey-stage map

| Stage | Screens |
|---|---|
| **MONITOR** | Portfolio Overview, Sites, Site Overview, Spaces list, Assets list, Environment (grid), Energy Consumption (headline), Demand (headline), Alerts (active) |
| **INVESTIGATE** | Site Overview drill-downs, Space detail, Asset Overview / Performance / Measurements, Energy Consumption (trend/spike), Demand (peak event), Breakdown, Power Quality, Analytics (Trends / Comparisons / Correlations), Alerts (history) |
| **IMPROVE** *(later)* | Insights, Recommendations, benchmarking, Sustainability |
| **MEASURE** *(later)* | Comparisons before/after an action, Reports, baseline re-fit |

See [information-architecture.md](information-architecture.md) for the
full screen-by-screen treatment.
