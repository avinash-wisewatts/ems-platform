# Feature: Demand

Status: CURRENT · Last reviewed: 2026-09-13 · Owner: Product + Engineering
MVP stage: MVP-2 · Related requirements: [EMS-REQ-022, 032, 041](../../02-requirements/functional-requirements.md)

## Purpose

Answer "what is our demand, when did we peak, and how does that relate to
our contracted demand?" (Workshop Q95).

## Requirements

[EMS-REQ-022](../../02-requirements/functional-requirements.md) (current &
peak demand vs. contracted), [EMS-REQ-032](../../02-requirements/functional-requirements.md)
(peak investigation), [EMS-REQ-041](../../02-requirements/functional-requirements.md)
(Grafana parity).

## User experience

[../../03-ux-and-design/information-architecture.md](../../03-ux-and-design/information-architecture.md)
§"Energy — Demand": demand trend, peak demand with timestamp, contracted/
agreed demand line, distance to the limit; zoom to a peak event and see
contributing assets (Post-MVP for attribution — the underlying
contributing-equipment analysis is not yet built).

## Business rules

Remains **analytical exposure monitoring** — does not attempt to determine
why a peak occurred or recommend how to reduce it (Workshop Q95). Contract
demand appears only where configured — no fabricated limit.

## Data / API dependencies

- **LIVE at both the analytics and API layer**: `analytics.demand_intervals`,
  `analytics.demand_state` underlie `GET /api/v1/sites/{site_id}/demand`
  and `/demand/current` (Slice B, PR #48); `DemandOverview.tsx` is a real
  screen.
- Contracted-demand *limit* configuration — still a separate, smaller
  admin-config gap (no threshold exists anywhere in the schema — confirmed
  by the MVP-3 Attention decision explicitly excluding a demand threshold
  rule for this reason).

## Architecture

[../../06-platform/telemetry/pipeline.md](../../06-platform/telemetry/pipeline.md)
§"Demand tier: watermark + status-guarded re-finalization (migration 210)"
— demand's status-guarded upsert (a finalized `VALID` interval is frozen; a
`NO_DATA`/`INCOMPLETE` interval is repaired once late data arrives).

## Validation

Underlying demand-calculation engine watermark-driven and self-healing as
of migration 210, live-verified on staging. Slice B (PR #48) landed with
its own frontend/backend test suite.

## Release status

**DONE** (2026-09-13, PR #48, Slice B).

## Known limitations

Two Grafana panels on `site-overview.json` use "demand" semantics that are
**neither** this dedicated demand engine — a known, open inconsistency, not
fixed by this documentation reorganization. See
[../../06-platform/grafana/README.md](../../06-platform/grafana/README.md)
§"Known dashboard-level inconsistency."

## Future scope

Demand-approaching alerts (MVP-7), peak-event contributing-equipment
attribution (Post-MVP), demand-charge cost modelling (Financial track,
blocked on tariff data).
