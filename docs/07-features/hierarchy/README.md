# Feature: Hierarchy

Status: CURRENT · Last reviewed: 2026-09-13 · Owner: Product + Engineering
MVP stage: MVP-1 · Related decisions: [ADR-002](../../00-governance/decisions/ADR-002-hierarchy-model.md), [ADR-013](../../00-governance/decisions/ADR-013-deferred-asset-component-tree.md)

## Purpose

Let a customer reach a space or asset by name, with context that changes
the meaning of every metric shown at each level — the foundation every
other MVP screen depends on.

## Requirements

[EMS-REQ-010 through EMS-REQ-017](../../02-requirements/functional-requirements.md#navigation--context)
(navigation & context); [EMS-REQ-030](../../02-requirements/functional-requirements.md#investigate--why-is-this-happening) (progressive drill-down).

## User experience

Organisation/Portfolio → Site → Space → Asset, with Space and Asset as
drill-down targets rather than primary top-level navigation (Workshop
Q51/Q99). Breadcrumb always visible; see
[../../03-ux-and-design/navigation.md](../../03-ux-and-design/navigation.md)
and [../../03-ux-and-design/information-architecture.md](../../03-ux-and-design/information-architecture.md)
§"Spaces (list) · Space detail" / "Assets (list) · Asset Overview."

## Business rules

Context is not merely navigation — it changes what a metric means:
Organisation asks "which sites need attention," Site asks "how is this
facility performing," Space asks "where is the problem," Asset asks "what
equipment may be contributing" (Workshop Q4). Single-site customers must
never be forced through portfolio ceremony. The full navigable asset
component-tree UI is explicitly deferred — see
[ADR-013](../../00-governance/decisions/ADR-013-deferred-asset-component-tree.md).

## Data / API dependencies

- Schema: `metadata.sites`, `metadata.buildings/floors/spaces`,
  `metadata.assets`, `metadata.asset_devices` — **LIVE**.
- "Spaces for a site" list endpoint — **LIVE** (`GET /api/v1/sites/{site_id}/spaces`).
- "Assets for a site" list endpoint — **LIVE** (`GET /api/v1/sites/{site_id}/assets`).
- Asset-relationship + asset↔space read objects — **MISSING**, still
  deferred (frozen-architecture concepts not yet implemented — see
  [../../04-architecture/system-architecture.md](../../04-architecture/system-architecture.md)).
  Note: `metadata.assets.space_id` (a single nullable 1:1 FK, migration
  232) is the only live asset↔space relationship today — the richer
  `asset_space_relationships` many-to-many table is a DDS future-state
  design only, not implemented.

## Architecture

[../../04-architecture/system-architecture.md](../../04-architecture/system-architecture.md)
(the frozen Asset/Space/AssetRelationship/AssetSpaceRelationship model);
[../../06-platform/telemetry/data-model.md](../../06-platform/telemetry/data-model.md)
(the current, live implementation model). See
[ADR-002](../../00-governance/decisions/ADR-002-hierarchy-model.md) for the
noted, unresolved tension between the two framings.

## Validation

Landed with 116/116 frontend tests passing, typecheck/lint clean, 10/10
backend hierarchy contract tests passing (commit `ddbe5a4`'s MVP-1
closeout). See
[../../08-verification/staging-validation.md](../../08-verification/staging-validation.md).

## Release status

**DONE** (2026-09-13, PR #46 + MVP-1 closeout in PR #50, commit `ddbe5a4`).
`GET /api/v1/sites/{site_id}/spaces` and `/assets` are live; real
`SpacesList`/`SpaceDetail`/`AssetsList`/`AssetDetail` screens replace the
placeholder.

## Known limitations

The full navigable component-tree UI remains deferred (see
[ADR-013](../../00-governance/decisions/ADR-013-deferred-asset-component-tree.md)) —
not delivered by MVP-1's closeout, by explicit decision.

## Future scope

Full navigable component-tree ("AHU-01 → Fan → Motor"), asset↔space
"serves" map editing, functional-category-based grouping (blocked on PA-2,
still genuinely open).
