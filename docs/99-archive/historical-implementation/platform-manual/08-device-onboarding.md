# Device Onboarding

```
Status: CURRENT
Last verified: 2026-08-24
Verification basis: Repository, Staging
```

## Two onboarding paths exist

### Path A — application-driven (`admin.*` functions)

This is the intended path for normal operation, executed by the admin portal through the least-privilege `ems_app` role (see `postgres/ddl/76_admin_onboarding_contract.sql`). The portal never gets raw INSERT/UPDATE/DELETE on `metadata`/`config`/`telemetry`/`analytics` — only `EXECUTE` on specific `admin.*` functions and `SELECT` on controlled lookup views (e.g. `admin.v_active_device_profiles`).

Two generations of this contract exist in the repository and both matter for understanding "current":

- **76_admin_onboarding_contract.sql** (earlier): a single `admin.onboard_energy_asset(...)` call that creates/reconciles organization, site, gateway model, gateway, device model, device, device identifier, root asset, and asset-device assignment in one request. Idempotent by design ("repeating the same onboarding request reconciles existing records instead of creating duplicates").
- **79_independent_device_inventory.sql / 92_asset_device_relationship_management.sql / 97_device_commissioning_action.sql** (later): finer-grained functions — `admin.create_device(...)`, `admin.assign_device_to_asset(...)`, `admin.commission_device(...)` — each independently permissioned and independently audited. This is the path actually exercised for real work in this repo (its validation logic is the most current).

**STATUS: the repository contains both generations. Which one the current admin-portal UI actually calls was not independently verified this session — inferred from the fact that the granular functions (create_device/assign_device_to_asset/commission_device) are the ones with live audit trail evidence (see below), so treat the granular path as the current one and the single-call `onboard_energy_asset` as historical/superseded, not confirmed dead code.**

`admin.create_device(...)` validates, in order, before any write: actor has `device.manage` permission and site access; gateway exists and isn't `DECOMMISSIONED`; name/external_id/protocol/lifecycle_status format checks; **`device_model_id` must belong to `device_category_id`** (`metadata.device_models.device_category_id` match); **profile must be compatible with the category via `config.device_profile_categories`**; if a location is given, building→floor→space chain must resolve under the gateway's own site. `admin.assign_device_to_asset(...)` separately checks the actor can access both the asset's and the device's site before inserting into `metadata.asset_devices`. `admin.commission_device(...)` is the only sanctioned way to move a device to `lifecycle_status='ACTIVE'` — see `16-commissioning.md`.

Every successful `admin.*` mutation writes one row to `admin.onboarding_audit` (`requested_by`, `request_payload`, `result_payload`, `created_at`). Verified live this session: 22 `COMMISSION_DEVICE` audit rows for `requested_by='admin_avinash'`.

### Path B — direct SQL (used for the Meenaxy Pharma bulk migration)

Earlier in this project, 22 devices/assets for Meenaxy Pharma were built in staging via a hand-written transactional migration script that inserted directly into `metadata.assets`, `metadata.devices`, `metadata.device_identifiers`, and `metadata.asset_devices` — **bypassing `admin.create_device`/`admin.assign_device_to_asset` entirely.** This was a deliberate one-time bulk-load choice, not the normal workflow, and it is significantly riskier: none of `admin.create_device`'s inline validation runs, so every constraint it would have checked had to be replicated by hand as pre-flight assertions in the migration script (`RAISE EXCEPTION` on any missing prerequisite before any write).

**What actually enforces correctness on the direct-SQL path, verified live on staging (`ems_admin` role — `ems_readonly` could not even see these triggers via `information_schema.triggers`, a real, unexplained visibility gap between the two roles):**

| Trigger | Table | Still fires on direct INSERT? | What it checks |
|---|---|---|---|
| `trg_generate_asset_external_id` | `metadata.assets` | Yes | normalizes `external_id`, generates one if blank |
| `assets_validate_physical_location` | `metadata.assets` | **Yes — and it bit us.** | if `space_id` is set, `floor_id` AND `building_id` must *also* be set explicitly on the row (not just derivable by joining through `space→floor→building`). The first version of the migration only set `space_id` and failed with `Asset space requires its floor and building.` |
| `trg_validate_asset_hierarchy` | `metadata.assets` | Yes (no-op for flat assets) | prevents parent-asset cycles/cross-org/cross-site parents |
| `trg_validate_asset_ownership` / `trg_validate_device_ownership` / `trg_validate_asset_device_ownership` | assets/devices/asset_devices | Yes | org/site consistency across FK relationships (`validate_tenant_site_ownership`) |
| `trg_validate_device_physical_location` | `metadata.devices` | Yes (no-op if building/floor/space all NULL) | device's org must match its gateway's org; any set location must belong to the gateway's site |
| `trg_validate_asset_device_relationship` | `metadata.asset_devices` | Yes | relationship type must be active in `config.asset_device_relationship_types`; device category must be listed in `config.asset_device_relationship_category_compatibility` for that relationship type; `PRIMARY_METER` specifically requires the device's category to be `Energy Meter` |
| `trg_reject_obsolete_device_lifecycle_status` | `metadata.devices` | Yes | only `REGISTERED`/`ACTIVE`/`INACTIVE`/`DECOMMISSIONED` allowed |
| `trg_reject_uncommissioned_active_device` | `metadata.devices` | Yes | blocks direct writes of `lifecycle_status='ACTIVE'` outside the controlled commissioning session (see `16-commissioning.md`) — irrelevant if you insert as `REGISTERED`, which the Meenaxy migration did |
| `trg_sync_device_points_after_profile_change` | `metadata.devices` | Yes, on INSERT too | auto-populates `config.device_point_configuration` from `config.profile_field_mapping` for the device's profile — this is *not* optional/skippable, it fires automatically |

**NOT enforced by any trigger on direct INSERT** (confirmed by reading `metadata.validate_asset_device_relationship()`'s live body): the `config.device_profile_categories` compatibility check that `admin.create_device` does inline in application code. A direct INSERT into `metadata.devices` with a mismatched profile/category combination will succeed at the database level with no error — the safety net here is entirely in the `admin.create_device` function body, which the direct-SQL path does not go through. **If you use Path B, you must manually assert this yourself**, exactly as the Meenaxy migration script did (resolve `config.device_categories` by name, resolve `config.device_profiles` by `profile_code`, assert a matching row exists in `config.device_profile_categories` before inserting any device).

**Recommendation**: use Path B only for scripted bulk/historical data loads under explicit review, never as a substitute for normal onboarding. Every constraint `admin.create_device` enforces in application code must be re-derived and asserted by hand, and at least one (`assets_validate_physical_location`) is *only* enforced by a DB trigger not documented anywhere in the repository's DDL comments — it was discovered by hitting it.

## What's created automatically vs explicit

| Created automatically | Must be explicit |
|---|---|
| `config.device_point_configuration` rows (via `trg_sync_device_points_after_profile_change`, from `config.profile_field_mapping`) | organization, site, location hierarchy, gateway |
| `metadata.assets.external_id` if left blank (via `trg_generate_asset_external_id`) | device model row (vendor/model/category) — no reference **seed** auto-creates these and `metadata.device_models` starts empty on a fresh deployment; individual models are added by targeted forward migrations (first one: migration 219 seeds `Best Energy / Air Sense` in the `Environmental Sensor` category) |
| `admin.onboarding_audit` row, when going through `admin.*` functions | device profile ↔ category compatibility row in `config.device_profile_categories` — no reference seed populates this table at all; rows are added by targeted forward migrations (migration 219 links `ENVIRONMENT_SENSOR_AIRSENSE_V1` ↔ `Environmental Sensor`; `ENERGY_METER_ENISCOPE_V1` ↔ `Energy Meter` was added out of band on staging 2026-08-24). Until a profile has a row here, `admin.v_active_device_profiles` returns it with `device_category_ids = {}` and the wizard's `filterProfiles()` hides it for every category |
| — | the `MQTT_UID` device identifier |
| — | the asset↔device `PRIMARY_METER` relationship |
| — | moving a device from `REGISTERED` to `ACTIVE` (always a deliberate commissioning action — see `16-commissioning.md`) |

See `16-commissioning.md` for the distinction between a device *existing*, being *commissioned*, and *producing telemetry* — do not conflate onboarding completion with any of those.
