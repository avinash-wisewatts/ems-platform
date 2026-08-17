# Migration 012 — Demand capability resolution

Migration 012 adds the vendor-neutral capability layer required before demand calculations are scheduled.

It does **not** calculate or finalize demand. Instead it:

- repairs SITE-scope demand interval idempotency where nullable `asset_id` made the migration-011 unique constraint insufficient;
- adds an explicit semantic contract for true meter-native demand registers;
- derives counter-delta capability from `config.energy_register_semantics`, canonical mappings, and enabled `config.device_point_configuration`;
- derives time-weighted-power capability only when the canonical active/apparent power point is mapped and enabled for that device;
- resolves the best trustworthy method in this order: `METER_NATIVE`, `ENERGY_COUNTER_DELTA`, `TIME_WEIGHTED_POWER`;
- resolves SITE sources only from the policy-selected authoritative site-energy role;
- resolves ASSET sources only from the asset `PRIMARY_METER` relationship;
- makes the existing Site Admin demand-readiness status capability-aware without exposing calculation-method controls to normal users.

No meter/vendor is hard-coded as capable merely because telemetry currently contains a non-NULL value. Capability comes from the device profile, canonical logical-point mapping and semantic contracts. Runtime data coverage and source-resolution checks remain the responsibility of the future calculation processor.
