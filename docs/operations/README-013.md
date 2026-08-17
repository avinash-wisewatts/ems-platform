# 013 — Demand calculation processor

This forward migration consumes the vendor-neutral demand capability resolver
from migration 012 and calculates canonical SITE/ASSET demand.

Implemented methods:

- `METER_NATIVE`
- `ENERGY_COUNTER_DELTA`
- `TIME_WEIGHTED_POWER`

Key behavior:

- Site-local wall-clock 15/30-minute alignment.
- Demand-policy effective dating.
- Separate source receipt deadline and downstream processing grace.
- Counter reset/rollover and maximum-delta rejection using existing
  `config.energy_register_semantics`.
- Time-weighted power refuses insufficient source resolution and does not bridge
  long telemetry gaps.
- `analytics.demand_state` contains provisional current-interval state.
- `analytics.demand_intervals` receives finalized, idempotent SITE/ASSET rows.
- TimescaleDB job runs once per minute with a bounded three-hour lookback.

Do not apply to production until `ems_test` application, focused verification,
`make test-db`, and `make verify-all` have passed.
