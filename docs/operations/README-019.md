# Migration 019 — Asset Dashboard consolidated read-path fix

This patch closes the remaining Asset Dashboard issues reported after migrations 016–018.

## Fixed

- Demand Status no longer relies on the broad Grafana demand view. A parameterized
  automatic-ASSET-demand summary is used instead.
- Missing system-managed ASSET demand policies are defensively backfilled.
- Current Demand always has an explicit no-value state (`No current data`) and never
  substitutes historical demand as current demand.
- Telemetry uses compact `telemetry.device_telemetry_state` through a parameterized
  tenant/asset function and always returns an explicit state for a valid asset.
- Energy, Energy Consumption Trend and Energy Performance no longer query
  `analytics.v_grafana_asset_energy_intervals`, which unions broad tenant-wide
  1/5/15-minute register-delta views.
- New `analytics.get_grafana_asset_energy_intervals(...)` applies Grafana org,
  asset/device and time predicates first, includes one preceding register sample,
  and then performs canonical counter/reset/gap classification.
- Adds `(device_id, bucket_start DESC)` index to the energy hypertable for the new path.
- Does not grant Grafana direct access to the private `config` schema.

## Expected dashboard behavior

- Demand Status: READY / PROVISIONAL / VALID / NO_DATA / capability reason, not
  obsolete SITE-gating semantics.
- Current Demand: numeric provisional demand when available; `No current data`
  when the current 15-minute window genuinely has no usable telemetry.
- Telemetry: VALIDATED / RECEIVING / STALE / SILENT / NEVER_SEEN /
  NO_ASSIGNED_DEVICE, not an empty card.
- Energy panels: asset/time-bounded and substantially faster.
