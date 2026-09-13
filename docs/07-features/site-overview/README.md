# Feature: Site Overview

Status: CURRENT · Last reviewed: 2026-09-13 · Owner: Product + Engineering
MVP stage: MVP-3 · Related decisions: [ADR-003](../../00-governance/decisions/ADR-003-mvp-information-model.md), [ADR-004](../../00-governance/decisions/ADR-004-site-overview-primary-destination.md), [ADR-011](../../00-governance/decisions/ADR-011-insufficient-data-not-healthy.md)

## Purpose

The single coherent MONITOR home for a site — "how are we doing, and is
there anything I need to pay attention to?" — so the customer never has to
choose between separate analytical dashboards (Workshop Q61).

## Requirements

[EMS-REQ-020](../../02-requirements/functional-requirements.md) through
[EMS-REQ-024](../../02-requirements/functional-requirements.md).

## User experience

[../../03-ux-and-design/information-architecture.md](../../03-ux-and-design/information-architecture.md)
§"Site Overview ★ MVP landing page". Information hierarchy (Workshop Q70):
Overall Site Health/Status → Attention/Exceptions → Energy Performance →
Maximum Demand → Power Quality → investigation paths. Principle: "tell the
customer the story first; provide analytical depth afterwards."

## Business rules

Three site states: Healthy · Needs Attention · Insufficient Data — see
[ADR-011](../../00-governance/decisions/ADR-011-insufficient-data-not-healthy.md).
Overall Site Health is **not** a proprietary composite score — a concise,
transparent, traceable summary of the underlying analytical conditions
(Workshop Q71).

## Data / API dependencies

Composite screen, built directly on [hierarchy](../hierarchy/README.md)
(MVP-1), [energy](../energy/README.md), [demand](../demand/README.md), and
[power-quality](../power-quality/README.md) (all MVP-2), all landed first
as sequenced. No dedicated Site Overview *endpoint* was needed or built —
the screen composes existing Energy/Demand/Power-Quality API calls
client-side.

## Architecture

[../../04-architecture/application-architecture.md](../../04-architecture/application-architecture.md);
consumes the Analytics API boundary exclusively (
[ADR-007](../../00-governance/decisions/ADR-007-analytics-api-boundary.md)).

## Validation

`SiteOverview.tsx` landed (PR #50, commit `ddbe5a4`) with 389 lines of
dedicated tests (`SiteOverview.test.tsx`) plus the PR's overall 146/146
frontend + 74/74 backend regression suite. See
[../../08-verification/staging-validation.md](../../08-verification/staging-validation.md)
for the full staging validation record and its explicitly-scoped
limitations — that record covers this exact screen, not a separate,
earlier platform milestone.

## Release status

**DONE** (2026-09-13, PR #50, commit `ddbe5a4`). `SiteOverview.tsx`
replaces the `ShellHome.tsx` placeholder at `/home`.

## Known limitations

Default time period for the screen is not decided as a product question
beyond what the shared `TimeRangePicker` already provides. See
[../../08-verification/staging-validation.md](../../08-verification/staging-validation.md)
for the browser-validation and real-data limitations recorded against this
screen specifically.

## Future scope

Insights strip (Post-MVP), role-specific overview variants (exec vs.
engineer).
