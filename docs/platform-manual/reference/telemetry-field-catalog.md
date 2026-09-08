# Telemetry Field Catalog — ENERGY_METER_ENISCOPE_V1

```
Status: CURRENT
Last verified: 2026-08-24
Verification basis: Staging (live query, config.profile_field_mapping joined to metadata.logical_points, via ems_admin)
```

The `ENERGY_METER_ENISCOPE_V1` device profile maps exactly **50** logical points, confirmed live and matching the `config.device_point_configuration` count populated for every one of the 22 Meenaxy Pharma devices. This is the full list, grouped by measurement category (grouping is descriptive, not a schema construct):

## Current (per-phase + total + THD)
`CURRENT_L1`, `CURRENT_L2`, `CURRENT_L3`, `CURRENT_NEUTRAL`, `CURRENT_TOTAL`, `CURRENT_THD_L1`, `CURRENT_THD_L2`, `CURRENT_THD_L3`, `CURRENT_THD_TOTAL`

## Voltage (line-neutral, line-line, per-phase)
`VOLTAGE_L1`, `VOLTAGE_L2`, `VOLTAGE_L3`, `VOLTAGE_LN_AVG`, `VOLTAGE_L12`, `VOLTAGE_L23`, `VOLTAGE_L31`, `VOLTAGE_LL_AVG`

## Active energy (import/export, per-phase + total)
`ENERGY_IMPORT_L1`, `ENERGY_IMPORT_L2`, `ENERGY_IMPORT_L3`, `ENERGY_IMPORT_TOTAL`, `ENERGY_EXPORT_L1`, `ENERGY_EXPORT_L2`, `ENERGY_EXPORT_L3`, `ENERGY_EXPORT_TOTAL`

## Reactive energy/power
`ENERGY_REACTIVE_ENERGY_L1/L2/L3`, `ENERGY_REACTIVE_EXPORT_L1/L2/L3`, `ENERGY_REACTIVE_EXPORT_TOTAL`, `ENERGY_REACTIVE_POWER_L1/L2/L3`

## Apparent energy/power
`ENERGY_APPARENT_ENERGY_L1/L2/L3`, `ENERGY_APPARENT_POWER_L1/L2/L3`

## Power quality
`POWER_FACTOR_L1`, `POWER_FACTOR_L2`, `POWER_FACTOR_L3`, `POWER_FACTOR_TOTAL`, `FREQUENCY`, `PHASE_ANGLE_L1/L2/L3`

## Other
`PULSE_COUNT`

All 50 are `data_type='numeric'`; none carry a `json_path` value in the live schema (path resolution presumably happens via `raw_field_name`/`transform_expression` on the underlying `config.profile_field_mapping` row rather than a JSONPath expression — not independently traced this pass).

## Where these land downstream

Each logical point corresponds to a column (or set of per-phase columns) in `telemetry.energy_measurements` (75 columns total — see `07-telemetry-pipeline.md`). The canonical semantic layer treats **`ENERGY_IMPORT_TOTAL`** and **`ENERGY_EXPORT_TOTAL`** specially: `config.energy_register_semantics` maps these two logical points (via `flow_interpretation='GRID_IMPORT'`/`'GRID_EXPORT'`) as the authoritative cumulative registers used for consumption-delta classification at every aggregation resolution — the other 48 points are informational/diagnostic telemetry, not consumption-accounting inputs.
