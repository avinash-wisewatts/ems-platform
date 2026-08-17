# Migration 016 — Asset Dashboard runtime fix

This forward migration fixes two production issues exposed by the fresh Asset Dashboard V1:

1. approved Grafana resolver calls failed with `permission denied for schema config` because the resolver functions were SECURITY INVOKER even though callers were intentionally granted EXECUTE;
2. Telemetry, Assigned Devices and Active Alarms inherited a legacy full-history `normalized_points` aggregation through `analytics.v_grafana_devices`, making every dashboard refresh unnecessarily slow.

The migration keeps `config` private, makes the fixed non-dynamic resolver functions owner-rights with locked search paths, and rebuilds the asset-device and active-alarm Grafana views on the compact telemetry-state contract introduced in migration 003.

The dashboard also stops showing operating-state/runtime panels by default when no explicit run-status/asset-health signal has been commissioned. A `Demand status` KPI takes the former operating-state slot so empty demand values have an explicit reason such as `DISABLED`, `SOURCE_NOT_CONFIGURED`, or `BASIS_NOT_SUPPORTED`.
