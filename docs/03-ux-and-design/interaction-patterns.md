# Interaction Patterns

Status: CURRENT (working hypothesis) · Last reviewed: 2026-09-13 · Owner: Product
Source of truth: `ems-information-architecture.md` §3 (archived), consolidated here.

These rules apply to **every** screen in
[information-architecture.md](information-architecture.md) — they are not
repeated per screen.

| Element | Behaviour |
|---|---|
| **Context breadcrumb** | Always shows the semantic path: `Organisation ▸ Site ▸ Space/Asset ▸ Parameter`. Clickable to move up. Never shows IDs. (EMS-REQ-013) |
| **Time-range control** | One shared component. Presets: Today, 7D, 30D, 3M, 1Y (+ custom). Emits `{from, to, resolution}`. Resolution is clamped to what the API supports (Phase 7 first slice: `raw`, `1h` for measurements). Unsupported combinations are disabled with a reason, never a silent failure. (EMS-REQ-100) |
| **Site / space / asset selector** | Scope-filtered to the user's access (server-side). Multi-site selection pattern is still an open interaction-design detail. |
| **Data-quality indicator** | The five states — `GOOD / GAP / ESTIMATED / INVALID / PARTIAL` — rendered consistently next to any value or series. `null` quality renders nothing. Never invents a quality value the API didn't return. (EMS-REQ-070) |
| **Loading state** | Skeleton/placeholder; never a blank screen or spinner-only. |
| **No-data state** | "No data yet" is **normal**, not an error — newly-commissioned devices, uncommissioned tiers, or a range before the sensor existed. Explains *why* where possible. See [ADR-011](../00-governance/decisions/ADR-011-insufficient-data-not-healthy.md) for the related "Insufficient Data ≠ Healthy" rule. (EMS-REQ-071) |
| **Empty state** | Distinct from no-data: the query is valid and the entity exists but has nothing to show for structural reasons (e.g. a site with zero spaces defined). Offers the next step — usually "contact your administrator," since configuration lives in the Administration App. |
| **Error state** | For genuine failures (401 → redirect to `/login`; 403 → "you don't have access"; 5xx → "something went wrong, retry"). Never leaks stack traces, SQL, table names, or identifiers. (EMS-REQ-105) |
| **Performance** | Fast page loads are a requirement (EMS-REQ-103). Target budgets not yet set numerically (Workshop Q92); initial view usable on first paint with progressive data fill. |
| **Responsive** | Works at phone width (~400px). Tables/charts scroll within their own container; page body never scrolls horizontally. One EMS experience, not a separate mobile product (Workshop Q91). |
| **Permission-awareness** | Nav items and drill-downs the user cannot access are hidden (UX only); the API still enforces access — see [ADR-007](../00-governance/decisions/ADR-007-analytics-api-boundary.md). |

## Common analytical grammar (Workshop Q83, Q87)

Where appropriate, every analytical metric follows:

**Current value → Comparison → Trend → Status → Evidence / Data Quality**

favouring **Value + Context + Status** over a standalone KPI number — "a
metric without context is just a number." This is an MVP consistency
principle, not a permanent constraint on future product evolution.
