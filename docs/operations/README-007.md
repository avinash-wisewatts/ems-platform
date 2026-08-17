# Migration 007 — Site-frequency normalization and recovery

This patch changes the production telemetry contract so the site capture policy controls canonical normalization resolution.

## Included changes

- `telemetry.raw_messages` retention: 7 days -> 48 hours.
- `telemetry.raw_message_failures` retention remains 30 days.
- One finalized latest source sample per wall-clock `(site, bucket, device)` is recorded in `telemetry.capture_bucket_samples`.
- `telemetry.load_normalized_points_incremental` expands only selected samples into logical points.
- The shared normalization job runs every 5 minutes and catches up every closed bucket since its checkpoint.
- Late-arrival tolerance from `config.telemetry_capture_policies` is honored before a bucket finalizes.
- Failure persistence checks apply only to selected capture samples; ordinary high-frequency raw packets are not failures merely because they are not normalized.
- Raw MQTT receipt state is stored separately in `telemetry.device_raw_receipt_state`; gateway connectivity uses raw arrival rather than normalization cadence.
- Existing energy/environment routing remains in place, but its input is now already site-frequency normalized, so it no longer receives full-resolution normalized history to downsample.
- Failure quarantine gains recovery lifecycle fields.
- `telemetry.run_failed_message_recovery_job` runs hourly with bounded retries and preserves the original failure row for audit.

## Recovery scope

Automatic replay is bounded and conservative. It re-evaluates quarantined failures while the original raw row is still available inside the 48-hour raw retention window. If the original raw row has expired, the 30-day quarantine payload remains for forensic/manual recovery and the automatic worker records that condition instead of fabricating a new raw receipt.

## Operational latency

A one-minute capture site still stores one canonical sample per minute, but with a five-minute normalization schedule those one-minute samples arrive in batches. Dashboard/domain latency is therefore normally 0-5 minutes plus processing and late-arrival allowance.

Connectivity is independent: the raw-receipt state job runs every minute and records actual raw arrival timestamps.
