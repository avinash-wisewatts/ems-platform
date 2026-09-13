# ADR-008: Grafana retained as the OPS/engineering interface

Status: Decided
Date: 2026-09-10 (product architecture v0.1), consistent with the DDS implementation roadmap's Phase 17
Decision owners: Architecture
Related requirements: EMS-REQ-007, EMS-REQ-902
Related features: [Grafana](../../06-platform/grafana/README.md)

## Context

Grafana is the platform's only current analytical presentation layer (7
dashboards, all reading `analytics.v_grafana_*`). Building a customer-facing
web application raises the question of what happens to Grafana.

## Decision

**Grafana remains an OPS/engineering surface, retained indefinitely.**
Customer-facing Grafana workflows migrate to the EMS Web Application **only**
through the roadmap's per-workflow parity process (Phase 17): numerical
parity, timestamp/timezone parity, tenant-scope parity, filtering parity,
performance, explicit customer acceptance, then a bake-in period during
which the Grafana dashboard stays live and reachable. **Grafana is never the
customer UI**, and no product requirement in this documentation set
shortcuts that process.

## Rationale

Grafana's 7 dashboards are the platform's most mature, validated analytical
surface. Retiring pieces of it without a proven numerical match to what
customers already see risks silently changing numbers customers rely on —
the parity gate exists specifically to prevent that.

## Alternatives considered

Not established in available source material.

## Consequences

- Grafana continues serving ops/engineering (`analytics.v_pipeline_health`,
  operational diagnostics) indefinitely, even after every customer-facing
  workflow has migrated (DDS roadmap Phase 17 exit criterion).
- The EMS Web Application does not embed, proxy, or authenticate against
  Grafana.
- No workflow retires all at once — migration is workflow-by-workflow, never
  a full cutover.

## Evidence / references

- `docs/product/ems-product-definition.md` §3.3 — [../../99-archive/superseded-product/ems-product-definition.md](../../99-archive/superseded-product/ems-product-definition.md)
- `docs/product/ems-product-architecture.md` §2.3 — [../../99-archive/superseded-product/ems-product-architecture.md](../../99-archive/superseded-product/ems-product-architecture.md)
- `docs/DDS/analytics-platform-future-state-architecture-implementation-roadmap.md` Phase 17

## Implementation references

Phase 17 has not started — it depends on every prior phase's per-workflow
numerical-parity signoff, starting with Phase 10 (Energy Analytics).

## Validation references

Not applicable yet — no workflow has reached its parity gate.
