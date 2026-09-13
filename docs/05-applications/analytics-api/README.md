# Analytics API

Status: CURRENT · Last reviewed: 2026-09-13 · Owner: Architecture
Full contract detail: [../../04-architecture/api-architecture.md](../../04-architecture/api-architecture.md)
Related decisions: [ADR-007](../../00-governance/decisions/ADR-007-analytics-api-boundary.md)

The Analytics API (Phase 7 of the DDS implementation roadmap) is the single
customer-facing semantic data boundary. It is not a separate "application"
in the deployment sense today — it is a thin FastAPI layer plus additive
`v_grafana_*`-pattern views/functions, served from the same application
image as the Administration App and consumed by the EMS Web Application
(and, for the equivalent existing Grafana-facing surface, by Grafana).

See:

- [../../04-architecture/api-architecture.md](../../04-architecture/api-architecture.md) — the full contract, live endpoints, and extension model.
- [../ems-web/README.md](../ems-web/README.md) — the primary consumer.
- [../../06-platform/grafana/README.md](../../06-platform/grafana/README.md) — the parallel, longer-established `v_grafana_*` presentation boundary Grafana consumes, which the Analytics API extends rather than duplicates.
