# Commissioning

```
Status: CURRENT
Last verified: 2026-08-24
Verification basis: Repository, Staging
```

## Three states that are easy to confuse

1. **A device exists** — a row is present in `metadata.devices`. This alone means nothing about telemetry.
2. **A device is commissioned** — `metadata.devices.lifecycle_status = 'ACTIVE'`, set only through the controlled `admin.commission_device(...)` function.
3. **A device is producing telemetry** — `telemetry.device_telemetry_state.latest_received_timestamp` is recent. This can be true or false independent of (2): a device could theoretically be `ACTIVE` and silent, or (less commonly, and only via the direct-SQL path — see `08-device-onboarding.md`) receiving real MQTT data while still `REGISTERED`.

These are three separate facts, each independently checkable, and the manual/dashboards treat them separately (`device-diagnostics.json`'s "Telemetry state" panel is not the same thing as `lifecycle_status`).

## `lifecycle_status` values

| Entity | Values | Enforced by |
|---|---|---|
| `metadata.devices.lifecycle_status` | `REGISTERED`, `ACTIVE`, `INACTIVE`, `DECOMMISSIONED` | CHECK constraint `devices_lifecycle_status_chk` + trigger `trg_reject_obsolete_device_lifecycle_status` |
| `metadata.gateways.lifecycle_status` | `REGISTERED`, `COMMISSIONING`, `ACTIVE`, `INACTIVE`, `DECOMMISSIONED` | CHECK constraint `gateways_lifecycle_status_chk` |
| `metadata.assets.lifecycle_status` | `DRAFT`, `COMMISSIONING`, `ACTIVE`, `INACTIVE`, `DECOMMISSIONED` | CHECK constraint `assets_lifecycle_status_chk` |

`metadata.devices.operational_policy` (`STANDALONE` default, or `ASSET_ASSIGNED`) is a separate flag, FK'd to `config.device_operational_policies`, that governs whether commissioning readiness requires an asset relationship to exist (`requires_asset_assignment=TRUE` for `ASSET_ASSIGNED`).

## The controlled commissioning path

`metadata.devices` has a trigger, `trg_reject_uncommissioned_active_device`, whose function body checks: on any attempt to write `lifecycle_status='ACTIVE'`, unless `current_user = 'ems_admin'` **and** a session variable `ems.controlled_device_commissioning_id` is set to exactly the device's own id, the write is rejected with `Use the controlled commissioning action to activate a device.` In practice this means the *only* sanctioned way to activate a device is through `admin.commission_device(p_actor_portal_user_id, p_device_id)` (`postgres/ddl/97_device_commissioning_action.sql`), which sets that session variable internally before performing the UPDATE, then writes an `admin.onboarding_audit` row (`operation='COMMISSION_DEVICE'`).

**Worked example, verified live this session**: all 22 Meenaxy Pharma devices were inserted via the direct-SQL migration with `lifecycle_status='REGISTERED'` (per explicit instruction, to avoid asserting a state the data hadn't earned). Sometime after that migration committed, `admin.onboarding_audit` shows 22 separate `COMMISSION_DEVICE` rows, `requested_by='admin_avinash'`, timestamped within a ~2-minute window — a human using the application's controlled action, not a side effect of the migration or any database trigger. After that, `metadata.devices.lifecycle_status` for all 22 was confirmed `ACTIVE`. This is the concrete distinction: the migration made the devices *exist*; a separate, later, explicit action *commissioned* them.

## `analytics.v_commissioning_readiness`

A unified readiness view covering `ASSET`, `GATEWAY`, and `DEVICE` entity types (verified live — `pg_get_viewdef`). For devices, its `commissioning_status` CASE logic (live-read, current):

```
WHEN lifecycle_status = 'ACTIVE'        THEN 'COMMISSIONED'
WHEN lifecycle_status = 'COMMISSIONING' THEN 'IN_PROGRESS'
WHEN lifecycle_status = 'DECOMMISSIONED' THEN 'FAILED'
WHEN gateway_id/device_model_id/profile_id IS NULL           THEN 'BLOCKED'
WHEN no matching config.device_profile_categories row        THEN 'BLOCKED'
WHEN validated_required_point_count < required_point_count   THEN 'BLOCKED'
WHEN operational_policy='ASSET_ASSIGNED' AND no asset_devices row THEN 'BLOCKED'
ELSE 'READY'
```

`is_ready` is a separate boolean with equivalent (but not textually identical) logic, and `blocking_reason_codes` gives the specific machine-readable reason(s) (e.g. `GATEWAY_REQUIRED`, `DEVICE_PROFILE_REQUIRED`, `QUALIFYING_PRIMARY_METER_REQUIRED`).

**Verified live, post-commissioning**: all 22 Meenaxy devices show `commissioning_status='COMMISSIONED'`, `is_ready=true`, `blocking_reason_codes={}`.

**Note on required points**: `ENERGY_METER_ENISCOPE_V1`'s `config.profile_field_mapping` has `is_required=FALSE` on every one of its 50 rows (set by an archived migration, `73_payload_profile_catalog_cleanup.sql` — "Eniscope payload fields are optional... a specific Eniscope payload may omit supported points"). This means `required_point_count=0` for these devices, so the "validated required points" gate in the CASE above is trivially satisfied regardless of how many points have actually validated — commissioning readiness for this profile does not, by itself, prove telemetry is flowing. Cross-check `telemetry.device_telemetry_state`/`analytics.v_device_telemetry_availability` separately (see `07-telemetry-pipeline.md`) rather than treating `COMMISSIONED`/`is_ready=true` as proof of live data.

## Gateway commissioning is separate and was intentionally left alone

The Meenaxy Pharma migration explicitly did not touch gateway `lifecycle_status` — all 3 gateways remained `REGISTERED` throughout, even after their devices were commissioned to `ACTIVE`. `analytics.v_commissioning_readiness` for `GATEWAY` entities uses `gateway.lifecycle_status`, connectivity-policy `last_seen_at` thresholds, and `gateway_model_id` presence — independent of any device under it. **A device can be `ACTIVE` and receiving real telemetry while its own gateway is still formally `REGISTERED`** — verified live this session, not merely theoretical. Whether this state (device commissioned, gateway not) is something the operational workflow should allow long-term is an open question, not addressed by any repository evidence found — flagged here, not resolved.
