# ADR-006: EMS Web Application vs. Administration App separation

Status: Decided; already merged into the frozen architecture (PR #44). Amendment 2 (2026-11-18): alert-rule configuration and alert acknowledgement move into the customer EMS through audited server-side write functions — see below and [ADR-024](ADR-024-customer-configurable-alert-rules.md)
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
  **SUPERSEDED for alert rules only (Amendment 2, 2026-11-18):** alert-rule
  configuration belongs in the customer EMS
  ([ADR-024](ADR-024-customer-configurable-alert-rules.md)); functional
  categories, tariffs and onboarding are unchanged.
- The customer EMS is read-only for MVP; any future customer-write action
  routes through an Administration-App-owned mechanism, never an ad hoc
  frontend write (`ems-product-architecture.md` §2.2).
  **SUPERSEDED (Amendment 2, 2026-11-18):** customer-initiated writes
  (Reports export jobs, ADR-014 Amendment 2; alert rules and alert
  acknowledgement, ADR-024) go through the customer API and
  SECURITY DEFINER database write functions, not an
  Administration-App-owned mechanism. "Never an ad hoc frontend write"
  still holds without exception.
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

**Amendment 1 (2026-10-26) — dedicated `ems-web` container.** Approved by
the user as "Option A" after a read-only topology investigation (no reverse
proxy or TLS on either host). The `-web` image runs as its own `ems-web`
compose service; `admin-portal` proxies `/app/*` to it, after its existing
authentication/authorization middleware, when `EMS_WEB_UPSTREAM` is set.
This makes the frontend restartable and rollbackable by recreating only
`ems-web` (`scripts/release/deploy_web.sh`, `deploy-web.yml`), without
touching the Administration App process. Same origin, URL, cookie and
permissions; no second auth system. The bind-mounted bundle hook stays as
the fallback. Status: **merged (PR #156, `f9f241a`) and deployed to staging 2026-10-26; staging `/app` is proxied to `ems-web` since 08:00 UTC (web-only rollback/roll-forward verified, runs 40289406885 / 40289499596); logged-in browser acceptance pending; not on production**; production remains API-only (release
plan D6). **Since ADR-023 Amendment 3 (2026-11-04) the proxy is removed:**
with `EMS_WEB_UPSTREAM` set, admin-portal answers `/app` with 404 and the
frontend is served only on the customer host. Superseded as the target by
[ADR-023](ADR-023-customer-staff-separation.md), which removes the
Administration App from the customer request path entirely.
Alternative rejected: a front reverse proxy with `auth_request` (moves the
public port binding, adds shared ingress ahead of the TLS work). See
[../../04-architecture/deployment-architecture.md](../../04-architecture/deployment-architecture.md).

**Amendment 2 (2026-11-18) — customer writes for alert configuration and
acknowledgement.** Decided by the Product Owner
([ADR-024](ADR-024-customer-configurable-alert-rules.md)). In the
customer EMS, customer site administrators and WiseWatts `GLOBAL` `ADMIN`
staff create, edit, enable/disable and (soft-)delete alert rules; those
same administrators, customer operators and WiseWatts `GLOBAL`
`OPERATOR` staff acknowledge alerts (a `GLOBAL` `VIEWER` is read-only); every
authorised site user views them. Every action is audited with the actual
actor and whether it was a customer user or WiseWatts staff. The
application separation itself is unchanged — the
Administration App does not gain or lose any alert screen, and no
Administration App workflow changes. The write path is: EMS Web App →
authenticated same-origin JSON request to the customer API → route-level
dedicated permission + same-site check → SECURITY DEFINER database
function that re-checks permission and site/asset/parameter relationships
and writes the change and its `admin.audit_events` row in one
transaction. The frontend never writes to the database. Status:
**decided, not implemented.**

## Validation references

Phase 8 exit criterion met: an internal user can log in, select an
organisation/site, and see a correctly scaffolded shell against real staging
data. Feature screens themselves (`PlaceholderArea.tsx`) are not yet built.
