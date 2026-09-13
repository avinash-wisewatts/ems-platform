# Device Onboarding and Commissioning

Status: CURRENT · Last reviewed: 2026-08-24
Verification basis: Repository + Staging

## Two onboarding paths exist

### Path A — application-driven (`admin.*` functions)

The intended path for normal operation, executed by the admin portal
through the least-privilege `ems_app` role. Two generations exist in the
repository:

- **`76_admin_onboarding_contract.sql`** (earlier): a single
  `admin.onboard_energy_asset(...)` call creating/reconciling
  organization/site/gateway/device/asset/identifier/assignment in one
  request. Idempotent by design.
- **`79_independent_device_inventory.sql` / `92_asset_device_relationship_management.sql`
  / `97_device_commissioning_action.sql`** (later): finer-grained functions
  — `admin.create_device(...)`, `admin.assign_device_to_asset(...)`,
  `admin.commission_device(...)` — each independently permissioned and
  audited. **This is the path actually exercised for real work** (its
  validation logic is most current) — inferred from live audit-trail
  evidence, not independently confirmed against the current UI's actual
  call graph.

`admin.create_device(...)` validates, in order: actor has `device.manage`
permission and site access; gateway exists and isn't `DECOMMISSIONED`;
format checks; `device_model_id` belongs to `device_category_id`; profile
compatible with category via `config.device_profile_categories`; location
chain resolves under the gateway's own site.

Every successful `admin.*` mutation writes one row to
`admin.onboarding_audit`.

### Path B — direct SQL (used for the Meenaxy Pharma bulk migration)

22 devices/assets for Meenaxy Pharma were built via a hand-written
transactional migration script, bypassing `admin.create_device`/
`admin.assign_device_to_asset` entirely — a deliberate one-time bulk-load
choice, significantly riskier since none of `admin.create_device`'s inline
validation runs.

**What still enforces correctness on the direct-SQL path** (verified live,
`ems_admin` role): every trigger on `metadata.assets`/`devices`/
`asset_devices` still fires on direct INSERT — `trg_generate_asset_external_id`,
`assets_validate_physical_location` (bit the Meenaxy migration —
"Asset space requires its floor and building"), `trg_validate_asset_hierarchy`,
ownership triggers, `trg_validate_asset_device_relationship`,
`trg_reject_obsolete_device_lifecycle_status`,
`trg_reject_uncommissioned_active_device`,
`trg_sync_device_points_after_profile_change`.

**NOT enforced by any trigger on direct INSERT**: the
`config.device_profile_categories` compatibility check — that safety net is
entirely in `admin.create_device`'s application code. A direct INSERT with
a mismatched profile/category combination will succeed at the database
level with no error. Use Path B only for scripted bulk/historical loads
under explicit review, never as a substitute for normal onboarding.

## What's created automatically vs. explicit

| Created automatically | Must be explicit |
|---|---|
| `config.device_point_configuration` rows (via trigger, from `profile_field_mapping`) | organization, site, location hierarchy, gateway |
| `metadata.assets.external_id` if left blank | device model row — no reference seed auto-creates these; `metadata.device_models` starts empty on a fresh deployment |
| `admin.onboarding_audit` row, via `admin.*` functions | device profile ↔ category compatibility row in `config.device_profile_categories` — no reference seed populates this table at all |
| — | the `MQTT_UID` device identifier |
| — | the asset↔device `PRIMARY_METER` relationship |
| — | moving a device from `REGISTERED` to `ACTIVE` (always deliberate — see below) |

## Commissioning

Three states, each independently checkable (see
[data-model.md](data-model.md)): a device *exists*, is *commissioned*
(`lifecycle_status='ACTIVE'`), and is *producing telemetry*.

`lifecycle_status` values: devices `REGISTERED`/`ACTIVE`/`INACTIVE`/
`DECOMMISSIONED`; gateways add `COMMISSIONING`; assets add `DRAFT`.
`metadata.devices.operational_policy` (`STANDALONE` default or
`ASSET_ASSIGNED`) governs whether commissioning readiness requires an asset
relationship.

### The controlled commissioning path

Trigger `trg_reject_uncommissioned_active_device` rejects any write of
`lifecycle_status='ACTIVE'` unless `current_user = 'ems_admin'` **and** a
session variable `ems.controlled_device_commissioning_id` matches the
device's own id — set only by
`admin.commission_device(p_actor_portal_user_id, p_device_id)`, which then
writes an `admin.onboarding_audit` row (`operation='COMMISSION_DEVICE'`).

Worked example: all 22 Meenaxy Pharma devices were inserted `REGISTERED`
via the direct-SQL migration; a separate, later, explicit action (traced to
a human portal user via `admin.onboarding_audit`) commissioned them to
`ACTIVE`, and real MQTT telemetry began flowing within minutes.

### `analytics.v_commissioning_readiness`

A unified readiness view across `ASSET`/`GATEWAY`/`DEVICE`. For devices,
`commissioning_status` resolves `COMMISSIONED` / `IN_PROGRESS` / `FAILED` /
`BLOCKED` (with machine-readable `blocking_reason_codes`) / `READY`.

**Note on required points**: `ENERGY_METER_ENISCOPE_V1`'s field mapping has
`is_required=FALSE` on every one of its 50 rows, so `required_point_count=0`
— commissioning readiness for this profile does not, by itself, prove
telemetry is flowing. Cross-check `telemetry.device_telemetry_state`
separately.

### Gateway commissioning is independent

A device can be `ACTIVE` and receiving real telemetry while its own
gateway is still formally `REGISTERED` — verified live, not theoretical.
Whether this should be allowed long-term is an open question, not addressed
by any repository evidence found.
