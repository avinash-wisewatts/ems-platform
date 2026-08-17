# Migration 006 — Canonical Failure Classification

Purpose: stop false `PARTIAL_NORMALIZATION` and `NO_PERSISTED_NORMALIZED_ROWS`
classifications caused by mutable `raw_message_id` / `platform_received_at` lineage on
canonical normalized rows.

The classifier now evaluates persisted coverage by the normalized uniqueness identity:
`(device_id, event_time, logical_point_id)`.

It preserves:
- 20-minute failure-classification grace
- existing failure taxonomy
- full raw payload in `telemetry.raw_message_failures`
- 30-day failure retention and 7-day compression policy
- existing Timescale job 1052 and schedule

It does not rewrite historical failure rows. Historical quarantine records remain until
retention expires; newly classified messages use canonical identity matching.
