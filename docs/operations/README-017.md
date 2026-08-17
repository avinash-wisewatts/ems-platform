# Migration 017 — Automatic Asset Demand Decoupling

This migration separates SITE demand activation from ASSET demand analytics.

## Canonical behaviour

SITE demand remains user-managed:
- Enabled/Disabled
- 15/30 minute interval
- kW/kVA basis
- GRID_IMPORT or SITE_CONSUMPTION source

ASSET demand is platform-managed:
- no enable/disable control
- source is the asset PRIMARY_METER
- 15-minute interval
- ACTIVE_POWER_KW basis
- method selected from meter capability: METER_NATIVE, ENERGY_COUNTER_DELTA, TIME_WEIGHTED_POWER

A disabled SITE demand policy no longer suppresses ASSET demand calculation.

## Compatibility

The existing `config.site_demand_policies` table becomes a policy carrier with an explicit `policy_scope` (`SITE` or `ASSET`). This preserves existing `demand_policy_id` foreign keys and historical demand rows without fabricating policy identity.

A system-managed ASSET policy is seeded for every non-decommissioned site and automatically created for future sites.
