# Data Model: Organization → Site → Location → Gateway → Device → Asset

```
Status: CURRENT
Last verified: 2026-08-24
Verification basis: Repository (postgres/ddl/04_metadata.sql) + Staging (live, via the Meenaxy Pharma commissioning worked example)
```

## The hierarchy

```
Organization  (tenant boundary)
  └─ Site
       └─ Building
            └─ Floor
                 └─ Space
       └─ Gateway  (physical concentrator, optionally placed in a building/floor/space)
            └─ Device  (physical meter/sensor behind the gateway)
                 └─ [asset_devices] ──── Asset  (a piece of production equipment)
```

Worked example, entirely from the Meenaxy Pharma staging commissioning done in this session (business keys, not internal UUIDs — see `15-environment-management.md`... actually `18-` for the UUID-vs-business-key discussion):

- Organization `MEENAXY_PHARMA` ("Meenaxy Pharma")
- Site `UNIT_2` ("Unit 2")
- Building `PRODUCTION` → Floors `GROUND`, `MEZZANINE` → Spaces `PRODUCTIONLINE_1`, `PRODUCTIONLINE_2` (under `GROUND`), `DISTRIBUTIONPANEL` (under `MEZZANINE`)
- Gateways `ENISCOPE_1_MEENAXY_UNIT2`, `ENISCOPE_2_MEENAXY_UNIT2`, `ENISCOPE_3_MEENAXY_UNIT2`
- Devices: 22, each on one of the three gateways, e.g. `E1_EM1_MICROPLV_P1_1`
- Assets: 22, e.g. `MICRO_PULVERIZER_P1_MPL_01`, each linked to exactly one device via `asset_devices` with `relationship_type='PRIMARY_METER'`

## The identity chain that isn't a straight line

A device's telemetry does not identify it directly by database UUID — it identifies it by a **physical identifier** first:

```
MQTT_UID (physical hardware address, e.g. 80:34:28:16:22:fe:00:01)
   │  metadata.device_identifiers, identifier_type='MQTT_UID'
   │  UNIQUE across the entire platform (not per-org — see 15-mqtt-and-telegraf.md)
   ▼
metadata.devices.id (internal UUID)
```

From there, a device carries several *separate* classification concepts that are easy to conflate:

| Concept | Table | Example | Question it answers |
|---|---|---|---|
| Device model | `metadata.device_models` | vendor=`Best Energy`, model=`Eniscope Energy Meter` | What physical product is this? |
| Device category | `config.device_categories` | `Energy Meter` | What class of thing is it, for compatibility rules? (every device model must declare exactly one) |
| Device profile | `config.device_profiles` | `ENERGY_METER_ENISCOPE_V1` | How do I interpret its raw telemetry payload? (reusable across many physical device models, in principle) |
| Asset type | `metadata.asset_types` | `Electric Motors (Standalone)` | What kind of production equipment is the *asset* being metered, independent of the meter itself |
| Asset | `metadata.assets` | `MICRO_PULVERIZER_P1_MPL_01` | The actual piece of equipment a business user cares about |
| Telemetry point | `metadata.logical_points` | `ENERGY_IMPORT_TOTAL` | One named measurable field within a device's telemetry payload |

**Common confusion this causes:** "device model" and "device profile" sound interchangeable but are not — a device model is a hardware/vendor fact (`config.device_categories` FK, used for asset-relationship compatibility checks); a device profile is a payload-interpretation fact (defines the 50 `logical_points` a given telemetry JSON maps to, via `config.profile_field_mapping`). A device row carries both `device_model_id` and `profile_id` independently, and `admin.create_device()` validates that the chosen profile is compatible with the chosen model's category via `config.device_profile_categories` — model and profile are cross-checked, not implicitly linked.

## "Device exists" is not "device is commissioned" is not "device is producing telemetry"

These are three separate, independently-observable states — do not conflate them when diagnosing an issue:

1. **Device exists**: a row in `metadata.devices` with a `device_model_id`, `profile_id`, and `gateway_id`. `lifecycle_status` defaults to `REGISTERED`.
2. **Device is commissioned**: `lifecycle_status='ACTIVE'`, which the database (`trg_reject_uncommissioned_active_device`) only permits via the controlled `admin.commission_device()` application function, not a direct `UPDATE`.
3. **Device is producing telemetry**: `telemetry.device_telemetry_state.latest_received_timestamp` is recent. Verified this session: a device can be `ACTIVE` and simultaneously have live telemetry — but the two facts come from different tables (`metadata.devices.lifecycle_status` vs. `telemetry.device_telemetry_state`) and must be checked separately. A device can be `REGISTERED` (not commissioned) while still receiving telemetry into raw tables, since ingestion doesn't gate on lifecycle_status.

See `16-commissioning.md` for the full commissioning workflow, and `08-device-onboarding.md` for how a device row is created in the first place.
