# Feature: Energy

Status: CURRENT · Last reviewed: 2026-09-13 · Owner: Product + Engineering
MVP stage: MVP-2 · Related requirements: [EMS-REQ-020, 021, 027, 031, 040](../../02-requirements/functional-requirements.md)

## Purpose

Answer "how much energy are we using, and is it normal?" — the first of
MVP's four core analytical questions (Workshop Q50).

## Requirements

[EMS-REQ-021](../../02-requirements/functional-requirements.md) (energy vs.
expected/baseline), [EMS-REQ-027](../../02-requirements/functional-requirements.md)
(period comparison), [EMS-REQ-031](../../02-requirements/functional-requirements.md)
(trend + spike inspection), [EMS-REQ-040](../../02-requirements/functional-requirements.md)
(Grafana numerical parity).

## User experience

[../../03-ux-and-design/information-architecture.md](../../03-ux-and-design/information-architecture.md)
§"Energy — Consumption": consumption total + comparison, trend at
appropriate resolution, top meter-role/system contribution. Graceful
degradation when a resolution tier isn't commissioned for a site (e.g.
`energy_consumption_5min` on a 60-second-capture site) — never an error.

## Business rules

Comparison basis (Workshop Q54/Q56): previous period, same period
previously, or a rolling historical average by default; configured
expectation where the customer has supplied one. **Expected performance is
a comparison concept, not a prediction concept** (Q55) — no adaptive/
predictive baselines in MVP. Any energy number shown must eventually carry
a Grafana parity commitment before Grafana's equivalent workflow retires
(see [ADR-008](../../00-governance/decisions/ADR-008-grafana-ops-role.md)).

## Data / API dependencies

- `GET /api/v1/sites/{site_id}/energy/consumption` (`1h`/`1d`) — **LIVE**.
- `GET /api/v1/sites/{site_id}/energy/consumption/evidence` — **LIVE** (Slice C, PR #49).
- `GET /api/v1/sites/{site_id}/energy/consumption/typical-reference` —
  **LIVE** — the historical comparison surface (median of up to 8
  comparable windows, ≥70% coverage each). See
  [ADR-009](../../00-governance/decisions/ADR-009-slice-c-historical-reference-methodology.md).
- 5-minute/15-minute resolution tiers not yet exposed via the API, though
  the underlying aggregation exists (Workshop Q82).

## Architecture

[../../04-architecture/data-architecture.md](../../04-architecture/data-architecture.md);
[../../06-platform/telemetry/aggregation.md](../../06-platform/telemetry/aggregation.md)
(the 5-tier resolution ladder and why `_5min` can be legitimately empty);
[../../06-platform/telemetry/pipeline.md](../../06-platform/telemetry/pipeline.md)
(watermark/bounded-catchup mechanics).

## Validation

Underlying consumption data verified end-to-end on staging (raw ingestion
through 1-minute/15-minute/hourly aggregation to Grafana-facing views) for
a real 22-device fleet. Slice C (comparison) landed with 1,277 backend +
112 frontend tests passing. See
[../../08-verification/staging-validation.md](../../08-verification/staging-validation.md).

## Release status

**DONE** (2026-09-13). Consumption (PR #46), comparison/evidence (PR #49,
Slice C) all live on `origin/staging`.

**Export CSV (2026-09-15, Q75 Increment 1, MVP-6):** an "Export CSV"
action was added to this screen, serializing the already-displayed period
total, comparison, evidence, and freshness state to a CSV file
client-side (no new endpoint). Implemented, tested, not yet deployed to
`origin/staging`. See
[functional-requirements.md §Export](../../02-requirements/functional-requirements.md#export)
and
[requirements-traceability.md §11](../../02-requirements/requirements-traceability.md#11-status-update-2026-09-15--q75-increment-1-energy-contextual-csv-export-implemented-not-deployed).

## Known limitations

No tariff/cost schema exists anywhere — financial views on energy (cost-
to-date, EMS-REQ-025) are blocked on a genuine data dependency, not a
scope question (Workshop Q73/Q74).

## Future scope

Cost overlay, functional-category breakdown (blocked on PA-2), baseline/
expected-performance bands (Post-MVP, DDS Phase 13), multi-utility
monitoring (water/gas/thermal — schema exists, no loader).
