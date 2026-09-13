# 00 — Governance

Status: CURRENT · Last reviewed: 2026-09-13 · Owner: Product + Engineering

This directory governs *how the documentation itself works* and records *why*
material decisions were made — not what the product does (that's
[01-product/](../01-product/)) and not how the system is built (that's
[04-architecture/](../04-architecture/)).

| Document | Purpose |
|---|---|
| [documentation-governance.md](documentation-governance.md) | Lightweight rules: what kind of change updates what kind of document. |
| [source-of-truth.md](source-of-truth.md) | Priority order when sources conflict; how to record an unresolved contradiction. |
| [decisions/](decisions/) | Architecture/Decision Records (ADRs) — material product and architecture decisions, with evidence. |
| [decision-log.md](decision-log.md) | One-line index of every ADR: status, date, and what it decided. |
| [change-history.md](change-history.md) | This reorganization's own change log, and a pointer to the platform's pre-existing operational change history. |
| [local-development-boundaries.md](local-development-boundaries.md) | Local development / repository-hygiene rules (single canonical checkout, branch discipline). |

## Relationship to the frozen architecture and the workshop baseline

This directory does not restate the DDS architecture or the Product Owner
Workshop baseline — it points to them and extracts *decisions* from them into
ADR form. The underlying evidence documents remain the primary source:

- `docs/DDS/analytics-platform-future-state-architecture.md` (kept at its
  current path — see [source-of-truth.md](source-of-truth.md))
- [`../99-archive/superseded-product/ems-product-owner-workshop-baseline.md`](../99-archive/superseded-product/ems-product-owner-workshop-baseline.md)
  (Q1–Q101 workshop decision record)
