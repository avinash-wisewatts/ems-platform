# Migration 018 — Grafana config permission-boundary fix

## Why this migration exists

Production diagnostics showed two owner-rights regressions behind the Asset Dashboard
`permission denied for schema config` errors:

1. `analytics.resolve_demand_capability(...)` was recreated by migration 017 and is
   currently `SECURITY INVOKER`, undoing the protection established by migration 016.
2. `config.resolve_interval_quality_rule(...)` is `SECURITY INVOKER`; the canonical
   1/5/15-minute energy-consumption views call it while it reads private
   `config.interval_quality_rules`.

## What 018 changes

It makes only those two published resolver boundaries `SECURITY DEFINER`, locks each
function to a fixed `search_path`, preserves the intended EXECUTE grants, and keeps
the underlying config schema/tables private.

It does **not** grant Grafana `USAGE ON SCHEMA config` or direct `SELECT` on config
tables.

## Expected dashboard impact

After application and tenant dashboard reconciliation/hard refresh:

- Demand Status: permission error cleared
- Current Demand: permission error cleared
- Demand Context: permission error cleared
- Energy KPI: permission error cleared
- Energy Consumption Trend: permission error cleared
- Energy Performance: permission error cleared

Whether a panel then shows a value or an explicit no-data/readiness state depends on
the selected asset and time range; that is separate from the permission defect.
