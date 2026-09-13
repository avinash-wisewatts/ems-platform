# Decision Records (ADRs)

Status: CURRENT · Last reviewed: 2026-09-13 · Owner: Product + Engineering

This directory holds Architecture/Decision Records for material product and
architecture decisions — not a record of every implementation choice. See
[../documentation-governance.md](../documentation-governance.md) for what
warrants an ADR.

## Format

```text
# ADR-NNN: <Decision>

Status:
Date:
Decision owners:
Related requirements:
Related features:

## Context
## Decision
## Rationale
## Alternatives considered
## Consequences
## Evidence / references
## Implementation references
## Validation references
```

**Evidence discipline**: every ADR in this set is written strictly from
material already in the repository (the Product Owner Workshop baseline,
the frozen DDS architecture, the product documentation set, or the platform
manual). Where the available source material does not establish a field —
an alternative considered, a date, an owner, a rationale — the ADR says so
explicitly: `Not established in available source material.` Nothing is
invented to fill a gap.

## Index

See [../decision-log.md](../decision-log.md) for the one-line index of every
ADR with its status and date.

| ADR | Decision |
|---|---|
| [ADR-001](ADR-001-product-vision-and-principles.md) | EMS product vision and principles |
| [ADR-002](ADR-002-hierarchy-model.md) | Organisation → Site → Space → Asset customer hierarchy |
| [ADR-003](ADR-003-mvp-information-model.md) | Overview → Energy → Demand → Power Quality → Performance → Attention information model |
| [ADR-004](ADR-004-site-overview-primary-destination.md) | Site Overview as the primary MVP landing destination |
| [ADR-005](ADR-005-energy-demand-pq-contextual-nav.md) | Energy / Demand / Power Quality as contextual, not unrelated permanent top-level, navigation |
| [ADR-006](ADR-006-ems-web-app-vs-admin-portal.md) | EMS Web Application vs. Administration App separation |
| [ADR-007](ADR-007-analytics-api-boundary.md) | The Analytics API as the sole customer-facing semantic data boundary |
| [ADR-008](ADR-008-grafana-ops-role.md) | Grafana retained as the OPS/engineering interface |
| [ADR-009](ADR-009-slice-c-historical-reference-methodology.md) | "Slice C" historical typical-reference methodology *(not established — see record)* |
| [ADR-010](ADR-010-mvp3-attention-materiality-policy.md) | MVP-3 Energy Attention materiality policy *(not established — see record)* |
| [ADR-011](ADR-011-insufficient-data-not-healthy.md) | Insufficient Data must never be represented as Healthy |
| [ADR-012](ADR-012-deferred-ai-recommendation-functionality.md) | Deferred AI / anomaly / recommendation functionality |
| [ADR-013](ADR-013-deferred-asset-component-tree.md) | Deferred asset component-tree functionality |
