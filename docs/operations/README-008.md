# Migration 008

Forward-fixes migration 007 normalization timeout by replacing the correlated per-device-element call to `telemetry.resolve_site_capture_bucket` with set-based policy resolution and wall-clock bucket calculation. It preserves site policy precedence, effective ranges, site timezone alignment, late-arrival allowance, latest-per-device selection, and downstream normalized semantics.

It also marks failures detected before migration 007 as `LEGACY_CLOSED`, preserving them for the existing 30-day quarantine retention while excluding them from automatic recovery.
