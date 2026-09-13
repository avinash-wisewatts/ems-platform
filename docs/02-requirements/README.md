# 02 — Requirements

Status: CURRENT · Last reviewed: 2026-09-13 · Owner: Product

Canonical source for **what capabilities are required, at what priority**,
and **whether the underlying platform can support them today.** Consolidated
from `docs/product/ems-customer-requirements.md` and
`ems-requirements-traceability.md` (both v0.1/v0.2, archived at
[../99-archive/superseded-product/](../99-archive/superseded-product/)).

| Document | Purpose |
|---|---|
| [functional-requirements.md](functional-requirements.md) | The `EMS-REQ-NNN` capability catalogue: customer question → capability → priority → source → status → dependencies. |
| [non-functional-requirements.md](non-functional-requirements.md) | Cross-cutting experience requirements: performance, responsiveness, error handling, consistency. |
| [requirements-traceability.md](requirements-traceability.md) | The control matrix: requirement → screen → API capability → semantic/data capability → MVP stage → status. The **MVP-readiness-authoritative** view. |
| [scope-and-deferred-functionality.md](scope-and-deferred-functionality.md) | What is explicitly NOT in scope, and what is `LATER` (deferred later-intelligence capability). |

## Conventions

**Priority**: `MUST` (required for the relevant phase) · `SHOULD` (important,
not blocking) · `COULD` (useful future enhancement) · `LATER` (explicitly
deferred) · `NOT-IN-SCOPE` (rejected or intentionally outside the customer
EMS).

**Status**: `DRAFT` · `PO-REVIEW` (needs product-owner decision) · `BLOCKED`
(needs an architecture/API decision) · `READY-FOR-DESIGN` (agreed enough to
design against).

Every requirement is expressed **business-question-first**: *customer
question → capability → metric/semantic concept → required data →
visualisation/interaction*. IDs are stable once assigned.

## Traceability chain

```text
Requirement (EMS-REQ-nnn) / Workshop decision (Qn)
        ↓
Customer screen / capability  (03-ux-and-design/)
        ↓
API capability                (Phase 7 Analytics API)
        ↓
Semantic / data capability    (DDS mechanism)
        ↓
MVP stage                     (01-product/roadmap.md)
        ↓
Implementation status
```

See [requirements-traceability.md](requirements-traceability.md) for the
live-verified status of every link in this chain.
