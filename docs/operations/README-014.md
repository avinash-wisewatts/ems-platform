# Migration 014 — Asset demand Grafana contract

Purpose: wire the Asset Overview dashboard to the canonical demand subsystem delivered by migrations 011–013.

Key behavior:
- never labels instantaneous power as demand;
- current demand comes from `analytics.demand_state`;
- peak/average/profile come from finalized `analytics.demand_intervals`;
- demand unit follows the effective site policy (`kW` or `kVA`);
- unsupported/unconfigured meter capability remains visible through demand readiness/status;
- tenant isolation continues through `metadata.grafana_organization_map`.
