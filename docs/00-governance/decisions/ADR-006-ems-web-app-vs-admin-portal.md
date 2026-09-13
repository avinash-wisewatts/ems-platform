# ADR-006: EMS Web Application vs. Administration App separation

Status: Decided; already merged into the frozen architecture (PR #44)
Date: 2026-09-10 (product decision); PR #44 merged to `staging` (DDS §F.0 boundary clarification)
Decision owners: Product Owner; Architecture
Related requirements: EMS-REQ-001, EMS-REQ-006, EMS-REQ-900
Related features: [Applications](../../05-applications/README.md)

## Context

The platform had one existing application (`admin-portal`, FastAPI +
server-rendered Jinja2) serving both onboarding/administration and,
implicitly, whatever customer-facing surface existed. A new customer-facing
product needed a boundary that didn't quietly turn into "redesign the admin
portal."

## Decision

The **Administration App** (today's `admin-portal`) remains the
administrative/operational interface — organisation/site/user/device
administration, onboarding, commissioning — **left operationally intact**
and **not** part of the customer EMS build. It is extended in place with new
`admin.*` write functions; it is never rewritten by the customer-EMS
roadmap.

A **new, separate Customer EMS Web Application** is built for understanding
facility performance, investigating energy/environmental behaviour,
navigating sites/spaces/assets, and (eventually) recommendations/reporting.
It is **NOT a redesign of the Administration App** — the two are separate
applications with different purposes that **may share** authentication and
backend/API services without merging.

The EMS Web Application is **independently deployable**: releasable and
rollbackable without changing the Administration App, Grafana, the database,
or the energy subsystem. `/app` (its current staging route) is a routing
detail, not its architectural identity.

## Rationale

`ems-product-definition.md` §3: keeping the applications separate lets each
evolve at its own pace and be rolled back independently; conflating them
would make the customer app's release cadence hostage to admin/onboarding
changes and vice versa.

## Alternatives considered

Not established in available source material — the decision is recorded as
already made, not as a choice among named alternatives.

## Consequences

- Configuration of alert rules, functional categories, tariffs, and
  onboarding stays in the Administration App even where the customer EMS
  surfaces or triggers related information (Workshop Q67, Q68, Q98).
- The customer EMS is read-only for MVP; any future customer-write action
  routes through an Administration-App-owned mechanism, never an ad hoc
  frontend write (`ems-product-architecture.md` §2.2).
- Rolling back the EMS Web Application has no effect on the Administration
  App, Grafana, the database, or telemetry pipelines.

## Evidence / references

- `docs/product/ems-product-definition.md` §3, §4 — [../../99-archive/superseded-product/ems-product-definition.md](../../99-archive/superseded-product/ems-product-definition.md)
- `docs/product/ems-product-architecture.md` §2, §7 — [../../99-archive/superseded-product/ems-product-architecture.md](../../99-archive/superseded-product/ems-product-architecture.md)
- Workshop baseline §98 (Q67), §99 (Q68) — [../../99-archive/superseded-product/ems-product-owner-workshop-baseline.md](../../99-archive/superseded-product/ems-product-owner-workshop-baseline.md)
- `docs/DDS/analytics-platform-future-state-architecture.md` §F.0 (added by PR #44)

## Implementation references

Phase 8 (Frontend Foundation) — **DONE**, verified landed on `origin/staging`
as of 2026-09-11 (10 commits, `e5fd026`…`7c4349a`). Delivered as an
independently versioned `-web:<sha>` artifact mounted read-only into the
admin-portal container and served same-origin under `/app` — a delivery
mechanism, not the architectural boundary. See
[../../05-applications/README.md](../../05-applications/README.md).

## Validation references

Phase 8 exit criterion met: an internal user can log in, select an
organisation/site, and see a correctly scaffolded shell against real staging
data. Feature screens themselves (`PlaceholderArea.tsx`) are not yet built.
