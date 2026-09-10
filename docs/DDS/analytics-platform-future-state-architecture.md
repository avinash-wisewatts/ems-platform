# EMS Analytics Platform — Future-State Architecture

```
Status: CONCEPTUALLY FROZEN — see "Architecture Status" below
Prepared: 2026-09-07; corrections incorporated 2026-09-07
Verification basis: docs/platform-manual/* (primary source, per investigation
brief) + targeted repository verification (postgres/ddl/*, postgres/migrations/*)
where the manual was silent or a live schema-shape question needed a direct
answer, + docs/DDS/analytics-platform-future-state-architecture-review.md
(red-team) + docs/DDS/analytics-platform-future-state-architecture-stress-test.md
(ten-scenario practical validation). No database, migration, or application
code was modified to produce this document.
```

This document is the conceptual future-state data architecture for the
WiseWatts EMS platform's evolution from an energy-accounting system toward a
general asset-performance and energy-efficiency platform. It went through
three passes before reaching its current state: an initial proposal
(current-state study + independent design), a red-team review (validated
against the live schema and corrected), and a ten-scenario practical stress
test (validated against real equipment/energy cases and corrected again). All
three corrections passes are folded into this document; the standalone review
and stress-test documents remain as the evidentiary record of *why* each
correction was made, but this document is the single authoritative statement
of *what* the architecture is. No schema, migration, or code change is
included or implied to have happened as a result of writing it.

---

## Architecture Status — CONCEPTUALLY FROZEN

1. **The architecture has passed the practical ten-scenario stress test**
   (`docs/DDS/analytics-platform-future-state-architecture-stress-test.md`) —
   main electrical metering, motor+VFD+vibration condition monitoring, a
   pump/motor system, a multi-chiller plant, an AHU serving multiple rooms, a
   multi-cabinet refrigeration rack, a lighting system, a boiler/heating
   system, solar+battery+grid energy accounting, and a virtual cross-asset
   rollup — every scenario was modeled without introducing a new entity type.
2. **The four corrections identified by that stress test are incorporated**
   into this document (§B.3, §B.4, §B.6, §B.7 below carry them inline; see
   also the stress-test document's §5 for the reasoning).
3. **The conceptual model is now frozen.** Organization, Site, Building,
   Floor, Space, Asset, AssetRelationship, AssetSpaceRelationship, Device,
   Point, Parameter, AssetPoint, SpacePoint, ParameterCalculation, and the
   hybrid domain/generic measurement storage layer are the complete set of
   core concepts. No additional core entity is authorized by this document.
4. **Further work should not introduce new core entities or abstractions
   unless implementation reveals a genuine contradiction** — not a
   convenience, not a symmetry argument, not a legacy-schema quirk. See
   "Architecture change control," below.
5. **Future requirements must first be evaluated against the existing model**
   (can it be expressed as an Asset, a Space, a Relationship, a Point, a
   Parameter, or a Calculation?) before anyone proposes a new concept.
6. **Implementation and migration decisions must not silently alter the
   conceptual architecture.** Where the live schema is awkward relative to
   this model, that is a migration/compatibility problem to be solved in the
   implementation roadmap, never a reason to bend this document — see the
   three-way distinction immediately below.

### Conceptual architecture vs. implementation architecture vs. migration/compatibility architecture

These are three different documents/concerns, deliberately kept separate:

- **Conceptual architecture** (this document): what the EMS future state *is*
  — the entities, their relationships, and the rules governing them,
  independent of how or when they get built. This is what is frozen.
- **Implementation architecture** (`docs/DDS/analytics-platform-future-state-
  architecture-implementation-roadmap.md`): *how* the conceptual model gets
  built — phased schema/service/frontend work, sequencing, dependencies. It
  must implement this document faithfully; it does not get to redefine it.
- **Migration/compatibility architecture** (also in the implementation
  roadmap, per phase): *how the platform transitions* from what exists today
  (hardcoded routing, dormant `asset_points`, energy-only quality semantics)
  to the frozen conceptual model, without a big-bang rewrite and without
  regressing the mature energy subsystem. Compatibility shims, dual-write
  periods, and compatibility views belong here — they are never a reason to
  add complexity to the conceptual model itself.

### Architecture change control

A proposal to add a new core entity or abstraction to this document must
demonstrate all five of the following, or it does not get added:

1. At least one real EMS requirement cannot be represented cleanly with the
   existing model (Organization/Site/Space, Asset, AssetRelationship,
   AssetSpaceRelationship, Device, Point, Parameter, AssetPoint/SpacePoint,
   ParameterCalculation, domain/generic measurement storage).
2. The requirement is not merely a legacy-compatibility problem (those belong
   in the migration/compatibility architecture, not here).
3. The proposed concept cannot reasonably be represented using Asset, Space,
   Point, Parameter, Relationship, or Calculation — including as a `VIRTUAL`
   asset, a relationship type, or a calculation input-resolution mode.
4. Simpler alternatives have been considered and documented, not skipped.
5. The new concept has a clear lifecycle, ownership, tenant boundary, and
   analytical purpose — not just a plausible-sounding name.

Absent all five, the answer is: **do not add it to the core architecture.**

---

## A. Current-state understanding

### A.1 Tenant and physical hierarchy

```
Organization (tenant boundary)
  └─ Site
       ├─ Building → Floor → Space         (physical location tree)
       └─ Gateway → Device                  (physical telemetry sources)
Asset                                        (separate hierarchy)
  ├─ parent_asset_id (self-FK, flat/unused today — all 22 Meenaxy assets are top-level)
  ├─ space_id / building_id / floor_id       (optional physical placement, independent of any device's placement)
  └─ asset_devices (M:N) → Device, typed by relationship_type
```

`organization_id` is a `NOT NULL` FK carried directly on every table that needs
tenant scoping — there is no separate "tenant" abstraction. This is simple and,
per `docs/platform-manual/14-authentication-and-tenancy.md`, consistently
enforced by triggers, not just convention.

**A genuinely good, underappreciated design decision already in the schema**:
device identity is split into four independent concepts that do *not* collapse
into each other — `metadata.device_models` (hardware/vendor fact),
`config.device_categories` (compatibility class), `config.device_profiles`
(payload-interpretation fact), and `metadata.asset_types` (what kind of
equipment, independent of the meter). A device row carries `device_model_id` and
`profile_id` independently, and they are cross-checked, not assumed linked. This
is exactly the kind of separation the future-state model needs to extend to
*parameters*, not just devices.

### A.2 Telemetry pipeline, and where its intelligence actually lives

```
Physical device --MQTT--> Telegraf --> raw_messages
                                          │  (resolve MQTT_UID → device, profile_field_mapping → logical_point)
                                          ▼
                                  normalized_points  (device_id, logical_point_id, event_time, numeric_value, quality_code)
                                          │  ROUTED BY HARDCODED SQL, per device profile_code
                              ┌───────────┼────────────────────┬───────────────────┐
                              ▼           ▼                    ▼                   ▼
                   energy_measurements  environment_measurements  water_measurements  asset_health
                      (routed, live)      (routed, live)          (schema only —      (schema only —
                                                                    no loader exists)   no loader exists)
                              │           │
                              ▼           ▼
                   ca_energy_* (CAGG)  ca_environment_* (CAGG)
                              │
                              ▼
        analytics.energy_consumption_{1min,5min,15min,hourly,daily}
        (persisted, register-semantics-classified: GOOD/GAP/reset/rollover)
                              │
                              ▼
                 analytics.v_grafana_* / analytics.get_grafana_* (tenant-scoped presentation boundary)
                              │
                              ▼
                          Grafana dashboards
```

Two facts matter more than the diagram shows:

1. **The pipeline's real semantic intelligence — register-delta classification,
   watermark-driven bounded catch-up, per-tier trailing reconciliation
   (migrations 205–214) — exists *only* for the energy domain.** Environment has
   a watermark (migration 211) but no quality classification comparable to
   energy's rollover/reset/gap logic. Nothing else has either.
2. **Routing from `normalized_points` into a domain table is hardcoded SQL, not
   data-driven.** `postgres/ddl/124_parameterized_domain_routing.sql` (despite
   its name — "parameterized" there refers to a query-plan technique, LATERAL
   joins, not a data model) pivots `normalized_points` into `energy_measurements`
   with ~50 `MAX(...) FILTER (WHERE logical_point = 'ENERGY_IMPORT_L1' AND
   profile_code = 'ENERGY_METER_ENISCOPE_V1')` clauses, and does the equivalent
   for `environment_measurements` against a second hardcoded profile code and
   point list. **Onboarding a new device profile whose points should land in one
   of these tables today requires a new SQL procedure or a new `FILTER` clause
   block — not new configuration rows.** This is the single largest piece of
   architectural debt this investigation found, and it is the direct blocker for
   every example in this brief (a chiller or motor profile cannot be routed
   without a code change today).

### A.3 A proto-generic-parameter model already exists in the schema — and is dormant

This was not called out anywhere in the platform manual, and is worth stating
plainly because it changes the shape of the future-state proposal: the schema
**already contains** most of the tables a "Point vs. Parameter vs. Subject" model
needs. They are simply unused by the live pipeline.

| Table | Columns (as deployed) | Live role today |
|---|---|---|
| `metadata.logical_points` | `id, name (globally unique), description, unit_id → config.engineering_units, data_type` | The vendor-neutral vocabulary used by `config.profile_field_mapping` — but every consumer resolves it by matching the literal `name` string in hardcoded SQL, not by joining semantic metadata. |
| `config.point_categories` | `id, name, description` | Exists; not referenced by any routing, aggregation, or Grafana object found in this investigation. |
| `config.engineering_units` | `id, symbol, description` | Referenced by `logical_points.unit_id`; not otherwise consumed downstream (no unit-conversion or display logic was found reading it). |
| `metadata.device_field_mapping` | `device_id, raw_field_name, logical_point_id, source_unit_symbol, scale_to_canonical_unit, offset_to_canonical_unit` | A **device-level** (not profile-level) field mapping with real unit-conversion columns already modeled. `config.profile_field_mapping` (profile-level) is what's actually live; this device-level override table's live usage was not confirmed. |
| `metadata.asset_points` | `asset_id, logical_point_id, point_role, UNIQUE(asset_id, logical_point_id)` | **This is, verbatim, the "asset/parameter mapping" table the brief asks whether the architecture needs.** It already exists. It is referenced only inside two legacy migration files (`001_ems_platform_baseline`, an archived pre-baseline migration) and is not read by any current view, routing procedure, or Grafana object found in this repository. |

**What this means concretely**: "this vibration measurement belongs to Motor A"
is not actually representable today in any queryable way except by walking
`asset_devices` back to the *device* that produced it and trusting that the
device has no other purpose — there is no live mechanism binding a specific
*point* (one channel of a multi-channel sensor) to a specific *asset* or
*asset-component*, independent of which device produced it. `asset_points`
was clearly designed to be that mechanism and was never finished/wired in.

### A.4 Domain tables that anticipate this brief's exact examples — and are 100% unpopulated

`postgres/ddl/11_asset_health.sql` and `postgres/ddl/10_water_measurements.sql`
define fixed wide-column TimescaleDB hypertables. `asset_health` in particular
already has columns named `vibration_x_mm_s`, `vibration_y_mm_s`,
`vibration_z_mm_s`, `bearing_temperature_c`, `winding_temperature_c`,
`runtime_hours_total`, `starts_count`, `alarm_code`, `fault_code`,
`operating_state` — i.e., someone already designed this table with the Motor
example in this brief specifically in mind. A Grafana view,
`analytics.v_grafana_asset_health_history`, already selects from it and is
provisioned to `ems_app`/`ems_readonly`/`grafana_reader`.

**Verified this session: `INSERT INTO telemetry.asset_health` appears nowhere in
the repository.** No routing procedure, loader, migration, or test populates it.
It is schema-only aspiration — a real foundation to build on, but a "partially
implemented" one in the strict sense: the storage and presentation-view ends
exist; the ingestion middle is entirely absent. `water_measurements` is in the
same state (schema only, no loader found).

### A.5 Analytics/semantic layer

`analytics.energy_consumption_{1min,5min,15min,hourly,daily}` (persisted,
quality-classified) plus a documented second, purely-statistical layer
(`telemetry.ca_energy_*`, TimescaleDB continuous aggregates) that dashboards
must *not* query directly — `docs/platform-manual/11-aggregation.md` is explicit
that the two look similar and must not be confused. A separate `demand_intervals`
/`demand_state` pair implements 15-minute demand finalization with its own
status-guarded upsert semantics (migration 210) — a third, parallel analytical
model, not a variant of the consumption ladder. All three (consumption ladder,
demand, environment_daily) were independently hardened into the same
watermark + bounded-catchup + trailing-reconciliation pattern across migrations
205–214, which is a strong, proven, reusable mechanism — but it was built three
separate times, once per domain, because there is no shared "register a new
watermark-driven analytical tier" abstraction. `~80` views live in `analytics`,
with a documented, unresolved finding (`23-known-issues-and-drift.md` #8) that
~20+ `v_energy_*` views are near-duplicates — a live cautionary tale for adding
more ad hoc views per new domain rather than a disciplined presentation layer.

### A.6 Space/AHU-serves-multiple-rooms: currently unmodeled

`metadata.buildings/floors/spaces` exist and are populated (verified in the
Meenaxy Pharma example). But:
- `telemetry.environment_measurements` has **no `space_id` column at all** —
  only `organization_id/site_id/gateway_id/device_id/asset_id`. An environment
  sensor's readings can be attributed to a device and (optionally) an asset, but
  never directly to a space.
- There is no `asset_devices`-style typed relationship table between assets and
  spaces. "AHU-01 serves Ballroom A and Ballroom B" (a many-to-many,
  asset-to-space relationship) has no home in the current schema at all — this
  is a genuine, clean gap, not drift.

### A.7 Frontend reality

There is no unified analytics frontend today. Two separate surfaces exist:

- **admin-portal** (`app/`, FastAPI + server-rendered Jinja2 templates, e.g.
  `organizations.html`, `device_detail.html`) — the onboarding/commissioning
  CRUD surface (organization → site → gateway → device → asset, plus Grafana
  provisioning/reconciliation). Not an analytics UI.
- **Grafana** — 7 dashboards under `grafana/dashboards/core/`, every one reading
  exclusively from `analytics.v_grafana_*` views/functions, tenant-isolated via
  Grafana-org + `${__org.id}`, plus a dedicated live-streaming path
  (`live-telemetry` service → WebSocket → a custom Grafana datasource plugin)
  that never exposes MQTT credentials to the browser.

This matters for deliverable F below: "what should the frontend expose" is
answered today entirely by what shape of SQL view Grafana can consume, not by
any application-level API contract — there is no REST/GraphQL analytics API
today, only the DB view layer itself as the API.

### A.8 Strengths / constraints / debt / reusable foundations — summary

**Strengths** — worth explicitly preserving, not redesigning away:
- Clean separation of device model / category / profile / asset-type identity.
- A real, hard-won operational pattern for self-healing analytical pipelines
  (watermark + bounded catch-up + trailing reconciliation), proven across five
  independent tiers.
- Consistent tenant-scoping discipline (`organization_id` everywhere, DB
  triggers *and* app-layer checks as two independent layers).
- A genuine semantic layer for energy specifically — register direction,
  rollover, reset, and gap classification is real domain knowledge, computed
  once per resolution and never re-derived from raw registers downstream.
- A disciplined Grafana access boundary (`v_grafana_*` only, `${__org.id}`
  filtering, no direct raw-table dashboard queries by policy).

**Constraints / architectural debt**:
- Routing from telemetry into domain tables is hardcoded per-profile SQL, not
  configuration-driven — the platform's single biggest scaling blocker for new
  equipment domains.
- The semantic/quality-classification intelligence is energy-only; every other
  domain is a plain last-write-wins/COALESCE table with no notion of data
  quality beyond a single `quality_code` column.
- The already-designed parameter/asset-mapping tables (`asset_points`,
  `device_field_mapping`, `point_categories`) are dormant — a half-finished
  migration, not a working feature, and a trap for anyone who assumes their
  presence in the schema means they're load-bearing.
- `asset_health`/`water_measurements` are unpopulated aspirational schema.
- No asset-relationship-type graph beyond a flat, currently-unused
  `parent_asset_id` self-reference; no asset↔space relationship at all.
- View sprawl (~20+ near-duplicate `v_energy_*` views) is a documented, open
  problem — a warning against solving new-domain analytics by adding more
  bespoke views per dashboard need.
- Watermark/reconciliation machinery is proven but domain-specific; no shared
  "register a new self-healing analytical tier" abstraction exists yet.

**Reusable foundations to build the future state on** (not replace):
`metadata.logical_points` + `config.engineering_units` + `config.point_categories`
+ `metadata.device_field_mapping` (revive and extend, don't reinvent);
`metadata.asset_devices`'s typed-relationship + compatibility-vocabulary pattern
(extend the same shape to asset↔asset and asset↔space); the
`telemetry.pipeline_state` watermark/reconcile pattern (generalize instead of
re-implementing per domain); the `v_grafana_*` tenant-scoped presentation
boundary; the parallel wide-domain-table-plus-CAGG pattern energy/environment
already validate operationally for TimescaleDB.

---

## B. Proposed future-state conceptual model

### B.1 Design principle

Keep everything in §A.8's "strengths" list. Close the debt by **finishing what
the schema already started** (`logical_points`/`asset_points`/
`device_field_mapping`) rather than inventing a parallel model, and by making
routing **declarative** instead of hardcoded. Add exactly the new concepts the
brief's examples require and no more: a real Parameter registry, a Point↔Parameter
split, an Asset↔Space relationship, a typed Asset↔Asset relationship, and a
narrow generic landing table for parameters that haven't yet earned a dedicated
domain table.

### B.2 Entities

**Organization and Site carry `organization_id`/`site_id` as structural,
mandatory context on every measurement row — they are never a "Subject" a
point must be bound to.** `Asset` and `Space` are the only two *optional*
subject-binding targets. A generalized polymorphic Subject abstraction is
explicitly rejected (see B.3).

```
Organization ──< Site ──< Building ──< Floor ──< Space
                    │
                    ├──< Gateway ──< Device
                    │
                    └──< Asset (asset_nature: PHYSICAL | VIRTUAL)
                                 >── parent_asset_id (kept, "primary parent" convenience)
                                 >── AssetRelationship (NEW, typed, effective-dated, M:N — see B.4)
                                 >── AssetSpaceRelationship (NEW, typed, effective-dated, M:N — see B.5)
                                 >── AssetDevice (existing asset_devices, unchanged)

Device ──< Point (existing metadata.logical_points row occurrence,
                   via config.profile_field_mapping / metadata.device_field_mapping)
                   │
                   └── parameter_id, qualifier → Parameter (NEW: config.parameters)
                   └── (via effective-dated AssetPoint / SpacePoint) → Subject: Asset | Space
                       [no component_asset_id — a component that needs independent
                        binding is its own Asset, related via AssetRelationship]

Parameter (NEW config.parameters)
   ── unit_id → EngineeringUnit (existing; immutable once live)
   ── parameter_category (existing point_categories, repurposed as Parameter category)
   ── value_kind, aggregation_method, direction_of_good, interpolation_policy, is_derived
   ── invariant: EITHER ≥1 Points reference it (observed) OR exactly one active
      ParameterCalculation produces it (derived) — never both, never neither

ParameterCalculation (NEW, only for is_derived parameters — see B.7)
   ── output_parameter_id, calculation_version, effective_from/to
   ── input_parameter_refs[]: {parameter_id, role, required, resolution_tier,
        traversal: SELF | RELATED(relationship_type, direction) | AGGREGATE_CHILDREN(relationship_type)}
   ── null_handling, required_resolution, applicable_asset_type_id, output_unit_id
   ── materialization: view | analytics.derived_parameter_values (persisted)

Measurement storage (unchanged shape, extended coverage):
  telemetry.energy_measurements        (existing, energy-specific, unchanged;
                                         broadened to cover fuel/thermal energy
                                         registers alongside electrical — see B.6a)
  telemetry.environment_measurements   (existing, extended with space_id)
  telemetry.water_measurements         (existing, wired to a real loader)
  telemetry.asset_health               (existing, wired to a real loader —
                                         covers Motor/Chiller/Refrigeration
                                         condition parameters)
  telemetry.generic_point_measurements (NEW, narrow: time, org, site, device,
                                         asset_id, space_id, parameter_id,
                                         point_id, numeric_value | state_value,
                                         quality_code, is_estimated) — landing
                                         zone for a parameter before its domain
                                         has earned a dedicated wide table
```

**"System"/"Plant"/"Zone"/"Process" are not new entity types.** A Chiller
Plant, an HVAC System, or any other composite piece of infrastructure a
business cares about is simply an `Asset` (`asset_type_id='Chiller Plant'`,
etc.), composed from its members via `AssetRelationship` — it reuses every
existing asset mechanism (lifecycle, metering, condition points) for free.
Likewise a purely calculated concept with no physical meter of its own (a
"Total HVAC Load" summed across many real assets) is still just an `Asset` —
one with `asset_nature='VIRTUAL'` — never a separate hierarchy of virtual
entity types. This was tested explicitly (chiller plant composition, a
virtual cross-asset rollup) and held without exception; see the stress test
document, Scenarios 4 and 10.

### B.3 Points vs. Parameters vs. Subjects — the core answer

Three concepts, never conflated, matching the brief's own framing exactly:

- **Point = measurement source identity.** "Channel 3 of Sensor 22." Already
  modeled correctly today as the combination of `(device_id, logical_point_id,
  raw_field_name)` flowing through `normalized_points`. No new table needed —
  this concept is fine as-is.
- **Parameter = measurement meaning.** "Vibration RMS." New: `config.parameters`,
  a genuinely canonical registry, distinct from the current
  `metadata.logical_points`, which today conflates *meaning*
  (`CURRENT`, `TEMPERATURE`) with *point-level qualifiers* (`CURRENT_L1` vs.
  `CURRENT_L2` vs. `CURRENT_TOTAL` are the same parameter, three different
  phase-qualified points). Recommendation: **do not rename or restructure
  `logical_points`** — it correctly represents "the vocabulary a profile emits."
  Instead, add `metadata.logical_points.parameter_id → config.parameters` (a new
  nullable FK) and a `qualifier` column (`L1`/`L2`/`L3`/`TOTAL`/`NEUTRAL`/NULL).
  `CURRENT_L1`, `CURRENT_L2`, `CURRENT_L3`, `CURRENT_TOTAL` all point at one
  `config.parameters` row (`CURRENT`), differing only in `qualifier`. This is
  additive — every existing consumer of `logical_points.name` keeps working
  unchanged.
- **Subject = what the measurement is about.** Exactly two optional subject
  types: an Asset, or a Space — never a generalized polymorphic "Subject"
  supertype (rejected explicitly; see "Architecture Status" above), and never
  a third "Site subject" (Site context is structural, carried on every row
  via `site_id`, not something a point binds to — confirmed by the stress
  test's Scenario 1/4/9: a main site meter, an outdoor weather sensor, and a
  derived site-consumption figure all have no Asset and no Space, and need
  none). Revive `metadata.asset_points` (asset_id, logical_point_id,
  point_role) as the live mechanism, and add its space-scoped sibling,
  `metadata.space_points` (space_id, logical_point_id, point_role), for
  sensors that describe a room rather than a piece of equipment (CO2,
  occupancy). **Both are effective-dated** (`effective_from`/`effective_to`,
  with a GiST exclusion constraint against overlap for the same
  `(subject, logical_point_id)`, modeled directly on the live, proven
  `config.site_energy_meter_roles` idiom) — without this, re-pointing a
  sensor at a different asset would silently rewrite the meaning of every
  historical reading it ever produced. `point_role` is a controlled
  vocabulary shared with `asset_device_relationship_types`' pattern.
  **`asset_points` does not carry a `component_asset_id`.** A point that
  belongs to a named sub-component (a bearing on a motor) binds directly to
  that component's *own* `Asset` row — the component is a first-class Asset
  related to its parent via `AssetRelationship` (§B.4), not a special column.
  Two ways to express "this point is about the sub-component" would be a real
  ambiguity risk the first time they disagreed; there is exactly one.

  **Phase 2 amendment (migration 228):** because `metadata.logical_points` is a
  deliberately *global* vocabulary that every device of one profile shares, the
  binding key and its GiST exclusion above are on the device-specific **Point**
  `(device_id, logical_point_id)` — already materialised, per device, by
  `config.device_point_configuration` — scoped `(device_id, logical_point_id,
  effective_range)`; `metadata.asset_devices` is unchanged and still records the
  separate Device—Asset operational association.

**Qualifier guardrail**: `qualifier` (on `logical_points`, e.g. `L1`/`L2`/
`L3`/`TOTAL`/`X`/`Y`/`Z`) exists **only** for multiple simultaneous readings
of one physical measurement act from one point-cluster describing one subject
(three phases of one CT, three axes of one vibration sensor). It must
**never** be used as a stand-in for "which instance of a repeated piece of
equipment" — ten refrigeration cabinets each reporting "temperature" are ten
`AssetPoint` bindings to ten distinct Cabinet Assets, with **no qualifier at
all**, not one `CABINET_TEMPERATURE` parameter with ten qualifier values. The
subject binding, never the qualifier, carries "which instance."

This gives the exact chain the brief asks for:

```
Device (source) → Point (device_field_mapping / profile_field_mapping)
      → Parameter (config.parameters, via logical_points.parameter_id + qualifier)
      → Subject, optional (asset_points / space_points → Asset | Space; often none)
      → stored observation (domain table or generic_point_measurements)
      → analytics (domain-specific rollups, or derived-parameter calculations)
```

### B.4 Asset relationships: typed, effective-dated, first-class

Keep `assets.parent_asset_id` as a cheap, always-available "primary parent" for
simple tree display (it already has a working cycle-prevention trigger). Add:

```sql
metadata.asset_relationships (
  id, organization_id,
  from_asset_id  → assets(id),   -- e.g. the Fan
  to_asset_id    → assets(id),   -- e.g. the AHU
  relationship_type TEXT → config.asset_relationship_types(code),  -- COMPONENT_OF, DRIVEN_BY, SUPPLIED_BY, PART_OF...
  effective_from TIMESTAMPTZ, effective_to TIMESTAMPTZ,
  created_at ...
  -- GiST EXCLUDE (from_asset_id WITH =, relationship_type WITH =, effective_range WITH &&)
  --   where exclusivity is expected for the type (e.g. a Fan has exactly one
  --   DRIVEN_BY motor at a time) — modeled on config.site_energy_meter_roles'
  --   proven ex_site_energy_meter_role_no_overlap idiom
)
```

modeled directly on the existing, proven `asset_devices` +
`asset_device_relationship_types` +
`asset_device_relationship_category_compatibility` pattern (a seeded controlled
vocabulary table, plus the same "which type is valid for which asset-type pair"
compatibility table, plus the same trigger-enforcement style already used for
`asset_devices`). Effective-dating answers "was this motor driving this fan on
the date of this reading" for equipment that gets swapped — a real requirement
once condition/efficiency analytics start asking "did this fan's problem
originate in the fan or the motor driving it."

**Corrections from practical validation** (stress test §5/§7 of the review):
`AssetRelationship` is a **graph (M:N), not a tree** — parallel chillers,
redundant pumps, and a motor that drives different pumps over its life are
just multiple rows; the existing single-parent `trg_validate_asset_hierarchy`
(on `parent_asset_id`) cannot be reused for it, and cycle-prevention on the
new relationship must be scoped **per relationship_type** (enforced for
hierarchical types like `COMPONENT_OF`, not necessarily for a symmetric
type). Each `config.asset_relationship_types` row declares its directionality
convention (`HIERARCHICAL_UP`/`HIERARCHICAL_DOWN`/`SYMMETRIC`) so onboarding
is unambiguous about which end is which. `DRIVEN_BY` is reserved for
mechanical coupling (pump↔motor); a VFD's relationship to the motor it
supplies is a distinct type (`SUPPLIED_BY` or `CONTROLLED_BY`) — conflating
electrical supply with mechanical drive would blur relationship-type meaning.
**Lead/lag/primary/backup are explicitly not relationship types.** They are
operational state that changes on its own schedule (sometimes daily),
structurally different from stable physical composition — model as either a
small effective-dated `metadata.asset_operational_roles(asset_id, role_code,
effective_from/to)` table (role changes on human timescales) or a `STATE`
Parameter reported by a BMS and bound via `AssetPoint` (role changes on
operational timescales) — never as a value in the same vocabulary as
`COMPONENT_OF`/`DRIVEN_BY`.

### B.5 Asset ↔ Space relationships

```sql
metadata.asset_space_relationships (
  id, organization_id,
  asset_id → assets(id),
  space_id → spaces(id),
  relationship_type TEXT → config.asset_space_relationship_types(code),  -- SERVES, LOCATED_IN, COOLS, HEATS, VENTILATES, SUPPLIES, EXHAUSTS, MONITORS
  effective_from, effective_to, is_active,
  created_at ...
)
```

Many-to-many by construction (AHU-01 SERVES Ballroom-A and Ballroom-B;
AHU-02 also SERVES Ballroom-B; a space can be served by multiple assets of
different kinds at once — an AHU, a lighting circuit, refrigeration in a
kitchen — simultaneously). Same seeded controlled-vocabulary +
trigger-validation pattern as `asset_devices`, **plus the same
effective-dating + GiST exclusion constraint as `AssetRelationship`** (an
AHU's serving map changes when ductwork is reconfigured, and history must
reflect what was actually true at the time — validated by the stress test's
"AHU changes which spaces it serves" failure scenario). `SERVES` is
domain-agnostic by design — the stress test confirmed the identical type
covers HVAC, lighting, and refrigeration without any per-domain relationship
type. `telemetry.environment_measurements` gains a `space_id` column
(nullable, populated at routing time by resolving the reading's device →
asset → `asset_space_relationships`, or directly via `space_points` for a
space-mounted sensor with no owning asset) so "average conditions in Ballroom A"
becomes a direct filter, not a multi-hop join done ad hoc in every dashboard
query.

**Energy attribution across a `SERVES` relationship (e.g., splitting AHU-01's
metered energy across Ballroom A/B) is deliberately not modeled here.**
`AssetSpaceRelationship` answers *topology* ("does AHU-01 serve this room")
cleanly and completely on its own — the stress test's AHU scenario confirmed
this explicitly. An energy *split* across that topology is always an estimate
(you cannot physically un-mix conditioned air and meter each room's share),
never a measured fact, and belongs in a future, separate, clearly-flagged
analytics-schema construct (an `allocation_method`-carrying table, analytics
schema, Advanced-analytics stage) — introduced only once a concrete
requirement exists, never assumed automatically from the existence of a
`SERVES` relationship.

### B.6 Generic vs. specialized measurement storage — the actual recommendation

The brief asks to weigh one giant generic table vs. separate domain tables vs. a
canonical layer plus specialized models. Given what's already proven in this
codebase (energy_measurements' 75-column wide table plus continuous aggregates
performs and compresses well at the platform's actual data volumes, per
`11-aggregation.md`/`22-performance.md`), the answer is a **hybrid, not a
binary choice**, and it's the same evolutionary path the platform already
walked once for energy and once for environment:

1. **`telemetry.normalized_points` stays the universal landing layer** —
   unchanged, no per-domain knowledge, exactly as today.
2. **A parameter earns a wide, domain-specific hypertable (`energy_measurements`,
   `environment_measurements`, `asset_health`, `water_measurements`, and future
   domains) once it has real production volume and a stable, known column set**
   — because TimescaleDB compression, continuous aggregates, and query planning
   all benefit from a fixed, columnar-friendly wide table over a hot narrow one.
   This is not new: it's the pattern the current system already uses for two of
   four domains, and it should simply be finished (wire up `asset_health` and
   `water_measurements`, both already schema-complete for the Motor/Chiller/
   Refrigeration examples) rather than replaced.
3. **A new narrow generic table, `telemetry.generic_point_measurements`, is the
   landing zone for everything else** — any parameter that doesn't yet justify a
   dedicated wide table (a first-of-its-kind vibration deployment, a one-off
   custom sensor). It carries `parameter_id`/`point_id`/`asset_id`/`space_id`
   plus a `numeric_value`/`state_value` pair and the same
   `quality_code`/`is_estimated` columns every other domain table already
   carries — no new quality model. When a parameter in this table accumulates
   enough volume/maturity to justify its own wide table (as vibration+thermal
   parameters likely will once motor/chiller condition monitoring is live at
   scale), it gets **promoted**: a new dedicated table is created, routing is
   pointed at it, and `generic_point_measurements` stops receiving that
   parameter going forward — history in the generic table is retained, not
   migrated, exactly like retention/rollup boundaries already work elsewhere in
   this schema. **Promotion is threshold-triggered, not judgment-triggered**:
   any parameter exceeding a stated volume (e.g. N rows/day) or deployment
   breadth (e.g. across more than M assets) within a defined window must be
   promoted before the next onboarding wave in that domain — without an
   enforced threshold, the generic table silently becomes exactly the
   poorly-performing universal EAV table this design otherwise avoids, just by
   neglect instead of by design. `generic_point_measurements` compresses with
   `segmentby(parameter_id)`, not `segmentby(device_id)` — its heterogeneity is
   far higher along the parameter axis than the device axis.
4. **Routing into any of the above becomes table-driven, not hardcoded — and is
   keyed on the source's accounting role, never on the parameter's unit
   alone.** A new `config.parameter_routing` table (parameter_id,
   destination_table, destination_column, applicable_device_category_id or
   profile_id) replaces the `FILTER (WHERE logical_point = '...')` blocks in
   `load_energy_measurements_incremental`/`load_environment_measurements_incremental`.
   **A point routes into an energy-domain measurement table only if it is
   reached through an `asset_devices` relationship of type `PRIMARY_METER`/
   `SECONDARY_METER` to a device of an accounting-meter category ("Energy
   Meter," "Gas Meter," etc.)** — a VFD's own reported power estimate, or a
   PLC's diagnostic wattage figure, is not accounting-grade merely because its
   unit is watts; it routes into `asset_health`/`generic_point_measurements`
   as a condition/diagnostic value instead, however power-like it looks. This
   is a semantic routing rule, not a new abstraction — it constrains how
   `parameter_routing` resolves a destination, it does not add a table.
   Execution: a small, offline, CI-time generator reads `config.
   parameter_routing` and emits the actual `CREATE OR REPLACE PROCEDURE` — the
   same hand-reviewable `FILTER`-pivot shape used today, machine-generated
   instead of hand-typed — as a normal, reviewed, versioned migration file,
   **not** runtime-dynamic SQL (which would risk silently losing the
   deliberate, performance-tuned `LATERAL`-probe query shape the current
   routing procedure already goes out of its way to force). This is the
   change that actually unblocks adding a chiller or motor profile without a
   hand-written migration.

### B.6a Cumulative counter semantics — energy stays energy-scoped, non-energy counters get their own, simpler concept

Cumulative-counter behavior (direction, rollover, reset) is **not** a
universal property of a "cumulative" parameter — it is scoped to the device
profile that emits the reading (`config.energy_register_semantics` already
proves this, keying off `(profile_id, logical_point_id)`, not a parameter-
level flag). Two corrections converge here, both scenario-driven:

- **Energy registers** (electricity, gas, thermal/steam, or any other genuine
  energy/fuel accounting flow): `config.energy_register_semantics` is
  **broadened**, not replaced — its `flow_interpretation` vocabulary extends
  to cover fuel/thermal flows (a gas meter's cumulative register is still
  energy accounting, and genuinely needs direction/rollover/reset semantics
  the same way electricity does) — the table, its rollover/reset/gap
  classification logic, and its downstream `analytics.energy_consumption_*`
  consumers are otherwise **untouched**.
- **Non-energy monotonic counters** (runtime hours, start counts, pulse
  totals — e.g. `telemetry.asset_health.runtime_hours_total`/`starts_count`,
  already schema-complete and unwired) get a **separate, deliberately
  simpler** `config.counter_rollover_behavior(profile_id, logical_point_id,
  counter_direction, rollover_behavior, rollover_value, reset_behavior,
  expected_max_interval_delta)` — the same shape minus `flow_interpretation`,
  which never had meaning for a runtime counter in the first place. This is a
  correction to an earlier draft of this document, which had proposed one
  single generalized table for all cumulative counters — too broad, per
  practical validation; keeping the split makes each table simpler and more
  honest about what it actually models.

### B.7 Derived parameters

```sql
config.parameter_calculations (
  id, output_parameter_id, calculation_version INT, is_active,
  formula_definition JSONB,      -- {expression, engine: 'SQL_EXPR' | 'WINDOW_FUNCTION'} — no formula DSL
  input_parameter_refs JSONB,    -- [{parameter_id, role, required: bool, resolution_tier,
                                  --   traversal: 'SELF' | {type:'RELATED', relationship_type, direction}
                                  --              | {type:'AGGREGATE_CHILDREN', relationship_type}}]
  applicable_asset_type_id,
  output_unit_id,
  null_handling TEXT,            -- 'NULL_IF_ANY_MISSING' | 'NULL_IF_REQUIRED_MISSING' | 'ESTIMATE_WITH_FLAG'
  required_resolution TEXT,      -- every required input must be read at this tier; a mismatch rejects, never silently mixes
  materialization_strategy,
  effective_from, effective_to   -- a formula revision is itself effective-dated
)

analytics.derived_parameter_values (
  ..., calculation_id, calculation_version, input_quality_summary JSONB, quality_code, ...
)
```

**Input resolution — three modes, deliberately constrained, no general-purpose
relationship-traversal language:**

- **`SELF`** — the input comes from the same subject as the output (the
  default, most common case: `Chiller → CHW supply temperature` feeding
  `Chiller → ΔT`).
- **`RELATED(relationship_type, direction)`** — the input comes from the one
  specific asset related to the output's subject via a named
  `AssetRelationship` (`Pump → specific energy` reads flow from itself but
  energy from the Motor it's `DRIVEN_BY`).
- **`AGGREGATE_CHILDREN(relationship_type)`** — the input is summed/averaged
  across every asset related to the output's subject via a named
  relationship (a Chiller Plant's COP aggregating power and cooling load
  across every Chiller `COMPONENT_OF` it; a virtual "HVAC Total" Asset
  aggregating energy across its explicitly-related member assets — the same
  mechanism, whether the parent is a real Plant or a `VIRTUAL` asset).

No other traversal shape is supported, and none is anticipated to be needed —
this is a deliberately small, closed set, not an extensible query language.

`analytics.derived_parameter_values` is a persisted hypertable, same shape
discipline as `energy_consumption_*`, computed by per-calculation refresh
procedures registered exactly like `analytics.run_energy_consumption_*_job` —
watermark-driven, bounded catch-up, reconciliation-eligible (using a
**recency-based** fingerprint — comparing each input's newest `calculated_at`/
`received_at` against the derived row's own `calculated_at` — since derived
parameters have heterogeneous, arbitrary inputs unlike the fixed-shape
sample-count fingerprints the native energy tiers use), using the same
`telemetry.pipeline_state` mechanism already proven five times over. Every
stored derived value is stamped with `calculation_id`/`calculation_version`,
so a later formula correction doesn't silently rewrite the meaning of
historical numbers without a visible trail.

**Quality propagation — worst-wins over required inputs only:** a derived
value's `quality_code` is the worst quality among its *required* inputs
(`INVALID` > `GAP` > `ESTIMATED` > `GOOD`), never among optional/diagnostic
inputs — a missing optional input cannot poison an otherwise-valid result. An
`AGGREGATE_CHILDREN` calculation additionally supports **`PARTIAL`**: when
some but not all contributing children produced valid data for the interval
(five of six chillers reporting, one in `GAP`), the aggregate reports
`PARTIAL` rather than being forced into an all-or-nothing choice between a
falsely-confident `GOOD` and an unnecessarily total `GAP`. `PARTIAL` is a
value in the existing quality lattice, not a new quality model.

This keeps "what a derived parameter *is*" (data, editable without a
migration) separate from "how it's computed and kept fresh" (reviewed code,
like any other pipeline job) — mirroring the platform's own existing
separation between `config.energy_register_semantics` (meaning) and
`analytics.refresh_energy_consumption_*` (mechanism). Formulas are plain
reviewed SQL expressions or window-function procedures — **no general-purpose
formula/expression DSL is built**; every derived parameter validated across
all ten stress-test scenarios, including the cross-asset ones, is expressible
this way. Simple derivations (runtime-from-status, a temperature delta) can be
plain SQL view-based calculations with no persisted tier; genuinely reusable
cross-asset-type formulas (COP, kW/ton, a plant/virtual rollup) warrant
persistence once dashboards depend on querying them over time ranges. Baseline
and expected-performance modeling (Advanced-analytics stage, out of scope for
this document beyond noting it) reuse this exact mechanism — a calculation
whose `formula_definition.engine` is a fit/regression rather than a plain
expression — rather than inventing a parallel "Baseline" concept.

---

## C. Data-flow architecture

```
Physical devices (meters, sensors, condition/status inputs)
        │  MQTT
        ▼
Telegraf → telemetry.raw_messages                              [unchanged]
        │  normalization: MQTT_UID → device, profile_field_mapping → logical_point
        ▼
telemetry.normalized_points  (device_id, logical_point_id, event_time, value, quality_code)
        │                                                        [unchanged]
        │  NEW: semantic interpretation — resolve logical_point → parameter_id (+qualifier)
        │       resolve subject — asset_points / space_points → asset[.component] | space
        ▼
config.parameter_routing (declarative) decides destination:
        │
        ├─→ domain measurement tables (energy_measurements, environment_measurements,
        │    asset_health, water_measurements) — wide, quality-classified, CAGG-backed
        │    [existing pattern, extended to cover asset_health/water_measurements
        │     and driven by data instead of hardcoded SQL]
        │
        └─→ telemetry.generic_point_measurements — narrow landing zone for
             not-yet-promoted parameters                          [NEW]
        │
        ▼
Aggregation (unchanged mechanism, extended coverage):
  domain-specific continuous aggregates + persisted, quality-classified
  analytics.<domain>_consumption/summary_{1min..daily} tables, each on the
  existing watermark + bounded-catchup + reconciliation job pattern
        │
        ▼
Derived/calculated parameters (NEW):
  analytics.derived_parameter_values, computed by parameter_calculations,
  same watermark job pattern, consuming one or more domain/generic tiers
        │
        ▼
Semantic/Grafana-facing views (existing pattern, extended):
  analytics.v_grafana_* — asset-shaped, space-shaped, org/site-shaped,
  never raw-table-shaped, always tenant-filtered by grafana_org_id
        │
        ▼
Frontend: Grafana dashboards (existing) + any future purpose-built UI
  consuming the same view layer or a thin API wrapping it — never the raw schema
```

**Where each transformation happens, explicitly:**
- *Physical → raw*: Telegraf, stateless, no semantic knowledge (unchanged).
- *Raw → normalized*: the normalization loader, resolves identity only, still no
  domain knowledge (unchanged).
- *Normalized → semantic (parameter + subject)*: **new** — a lightweight
  resolution step (can be a view or the same loader step) that looks up
  `logical_points.parameter_id` and `asset_points`/`space_points`, making
  "what does this number mean, and about what" a data-driven fact from this
  point forward in the pipeline rather than something re-derived by every
  downstream consumer.
- *Semantic → domain storage*: **existing mechanism, made data-driven** via
  `parameter_routing` instead of hardcoded FILTER clauses.
- *Domain storage → aggregation*: existing CAGG + persisted-tier pattern,
  extended to asset_health/water_measurements/generic_point_measurements.
- *Aggregation → derived parameters*: **new** analytical tier, reusing the
  existing job/watermark infrastructure verbatim.
- *Everything → presentation*: existing `v_grafana_*` boundary, extended with
  asset/space-shaped views for the new relationship types.

---

## D. Five scenario walkthroughs

### D.1 Motor

- **Points**: a vibration sensor emits points `VIBRATION_X`, `VIBRATION_Y`,
  `VIBRATION_Z` (device_field_mapping/profile_field_mapping, as today); an
  energy meter on the same motor emits `ENERGY_IMPORT_TOTAL`,
  `ENERGY_ACTIVE_POWER_TOTAL`, etc.; a status input emits `RUN_STATUS`.
- **Parameters**: each `VIBRATION_*` point's `logical_points.parameter_id` →
  `VIBRATION` parameter with `qualifier` X/Y/Z (plus a separately-computed
  `VIBRATION_RMS`, likely a derived parameter over X/Y/Z — see below);
  `BEARING_TEMPERATURE`, `CASING_TEMPERATURE`, `AMBIENT_TEMPERATURE` are three
  distinct `config.parameters` rows even though all three might arrive as raw
  points named similarly by different vendors — this is exactly why a canonical
  parameter registry separate from the raw point name matters.
- **Subject**: `asset_points` binds the vibration/temperature points directly to
  Motor A's `asset_id` (`point_role='PRIMARY'` or `'DIAGNOSTIC'`); the energy
  meter is already bound via the existing `asset_devices` `PRIMARY_METER`
  relationship (unchanged).
- **Stored observation**: vibration/thermal/run-status points route (via
  `parameter_routing`) into `telemetry.asset_health` (already schema-complete
  for exactly this — `vibration_x_mm_s`, `bearing_temperature_c`,
  `running_status` all already exist as columns, just unwired to a loader);
  energy points continue into `energy_measurements`, unchanged.
- **Analytics**: "this motor consumes this much energy while operating under
  these conditions" is a join between `analytics.energy_consumption_15min`
  (existing) and an `asset_health`-derived 15-minute condition rollup (new,
  same CAGG pattern), both keyed by `asset_id` and time bucket — no schema hack,
  just two existing-shaped aggregation tiers joined by the identity columns
  every layer already carries.

### D.2 Chiller

- **Points/Parameters**: `CHW_SUPPLY_TEMP`, `CHW_RETURN_TEMP`,
  `CONDENSER_SUPPLY_TEMP`, `CONDENSER_RETURN_TEMP`, `FLOW`, `WET_BULB_TEMP`,
  `RLA`, `RUN_STATUS`, plus electrical parameters via the existing energy-meter
  path.
- **Subject**: all condition/flow parameters bind to the Chiller asset via
  `asset_points`; electrical via `asset_devices` (unchanged).
- **Stored observation**: condition/flow parameters route into `asset_health`
  (temperature/flow columns) or a promoted chiller-specific table once volume
  justifies it; electrical stays in `energy_measurements`.
- **Analytics — COP / kW-per-ton, without hardcoding the formula into the core
  schema**: a `config.parameter_calculations` row defines `COP` as a function of
  `{ELECTRICAL_INPUT_POWER (from energy_measurements), COOLING_OUTPUT (derived
  from FLOW × (CHW_RETURN_TEMP − CHW_SUPPLY_TEMP), itself a
  parameter_calculation)}`, scoped to `applicable_asset_type_id = 'Chiller'`.
  "Is energy consumption increasing without a corresponding increase in cooling
  output?" and "is the chiller outside its expected efficiency envelope?" become
  queries over `analytics.derived_parameter_values` compared against a baseline
  — which is exactly the kind of question the brief says not to hardcode into
  the schema, and here it isn't: the *formula* lives in `config`, the *result*
  lives in a persisted analytical tier, and "expected envelope" is a downstream
  analytics/insights concern, not a new schema concept.

### D.3 Refrigeration

- **Points/Parameters**: `CABINET_TEMP`, `EVAPORATOR_TEMP`, `AMBIENT_TEMP`,
  `COMPRESSOR_STATUS`, `DOOR_STATUS` (boolean/state parameter), plus energy via
  the existing meter path.
- **Subject**: bound to the refrigeration asset via `asset_points`.
- **Stored observation**: temperature/status parameters into `asset_health`
  (or generic table pre-promotion); `DOOR_STATUS` is a `value_kind='STATE'`
  parameter — **door-open duration is a derived parameter** (state-duration
  calculation over `DOOR_STATUS` transitions, the same `runtime derived from
  status` pattern the brief calls out generically), not a raw stored column —
  demonstrating why `value_kind`/`is_derived` need to be first-class parameter
  metadata rather than assumptions baked into ingestion code.

### D.4 AHU / Spaces

- **Asset↔Space**: `asset_space_relationships` records `AHU-01 SERVES
  Ballroom-A` and `AHU-01 SERVES Ballroom-B` (two rows, same asset, two spaces,
  `relationship_type='SERVES'`).
- **Space-scoped parameters**: `TEMPERATURE`, `HUMIDITY`, `CO2`, `OCCUPANCY`
  points from sensors physically located in Ballroom A bind via
  `space_points` (or via `environment_measurements.space_id`, populated at
  routing time) directly to the space — independent of which AHU serves it.
- **Asset-scoped parameters**: AHU supply/return air temperature, fan power,
  filter differential pressure bind to the AHU asset via `asset_points`/energy
  meter, as in the Motor/Chiller cases.
- **Analytics**: "how much energy is being consumed to maintain conditions in
  Ballroom A" is a query joining `analytics.energy_consumption_*` for AHU-01
  (filtered to the time range) against `asset_space_relationships` (which AHUs
  serve Ballroom A — possibly more than one) against space-scoped environment
  aggregates for Ballroom A — a multi-hop join across explicit, typed
  relationships, not a schema hack, and not possible at all in the current
  schema (no asset↔space relationship, no `space_id` on environment
  measurements).

### D.5 One sensor, many measurements (Sensor 22)

- **Points**: `device_field_mapping`/`profile_field_mapping` already correctly
  models this — Sensor 22 is one `device_id`; each of its four channels is a
  distinct `raw_field_name` → distinct `logical_point_id` row, all sharing the
  same `device_id`. No change needed here; this is the part of the current
  schema that already gets "one device, many points" right.
- **Parameters**: Point 1 (vibration) and Point 4 (a second temperature) each
  resolve to different `config.parameters` rows via their own
  `logical_points.parameter_id` — Point 2 and Point 4, even if both are
  "temperature," may resolve to *different* parameters (`BEARING_TEMPERATURE`
  vs. `AMBIENT_TEMPERATURE`) if they're wired to measure different physical
  things, which is a per-point (not per-device) fact.
- **Subject**: this is exactly why subject-binding must happen at the **point**
  level (`asset_points.logical_point_id`), not the **device** level. Point 1
  (vibration) might bind to Motor A while Point 2 (a status point) binds to a
  different asset entirely, or to a named sub-component of Motor A (a
  bearing) — modeled as the bearing's *own* Asset row, related to Motor A via
  `AssetRelationship` (§B.4), not a special column on `asset_points` — the
  device is not the subject, and the current schema, which has no live
  point-level subject binding at all (§A.3), cannot express this distinction
  today. The proposed model fixes exactly this gap, without adding any new
  device- or point-identity concept — it only finishes wiring the
  subject-binding layer that was already designed and never connected.

  **Phase 2 amendment (migration 228):** "point level, not device level" means a
  specific *enabled point of* a device — `config.device_point_configuration
  (device_id, logical_point_id)` — so `asset_points`/`space_points` carry
  `device_id` as a component of that existing Point identity, not as a new concept.

---

## E. Energy integration

**Stays energy-specific, deliberately, not touched for conceptual purity:**
- `telemetry.energy_measurements`'s 75-column wide shape, its continuous
  aggregates, and `config.energy_register_semantics`' rollover/reset/gap
  classification logic. This is genuinely specialized domain knowledge (how
  cumulative registers behave) with no generic equivalent to fall back to, and
  it is the platform's most mature, most validated subsystem — rebuilding it
  onto a generic parameter model would trade real, hard-won correctness for
  conceptual purity, which CLAUDE.md's own working-style rules argue against.
- The 5-tier resolution ladder and its watermark/reconciliation machinery stay
  as-is; other domains *reuse the same pattern* (§B.7, §C) rather than sharing
  the same tables.

**Becomes generic, and energy adopts it too:**
- The point→parameter→subject identity chain (§B.3) — energy's
  `logical_points` rows (`ENERGY_IMPORT_TOTAL`, `CURRENT_L1`, etc.) get
  `parameter_id`/`qualifier` values exactly like every other domain, so a
  cross-domain query ("show me all `ACTIVE_POWER` readings regardless of
  source device type") becomes possible without energy-specific special-casing.
- The routing *mechanism* (`config.parameter_routing`, §B.6 point 4) — energy's
  hardcoded FILTER-clause routing procedure gets rewritten to be
  data-driven, closing the "add a device profile without a code change" gap
  for energy too, without changing `energy_measurements`' storage shape or any
  downstream consumer.
- The watermark + bounded-catchup + reconciliation job pattern — already
  general-purpose in practice (proven across 5 tiers); formalizing it as the
  standard mechanism for every new analytical tier (demand, environment_daily,
  and now asset-health/derived-parameter tiers) avoids re-implementing it a
  sixth and seventh time from scratch.

**What connects the two**: `config.parameters` entries for `ENERGY_IMPORT_TOTAL`
etc. exist in the same registry as every other domain's parameters — energy
doesn't get a separate vocabulary, it's simply the parameter domain with the
richest downstream analytical tier attached to it. A derived parameter like COP
(§D.2) genuinely spans both worlds: one input parameter resolves from
`energy_measurements` (mature, specialized), the other from `asset_health`/
`generic_point_measurements` (newer, generic) — the derived-parameter framework
is exactly the connective tissue the brief asks for, and it is domain-agnostic
about where its inputs physically live.

**Energy accounting stays distinct from physical asset topology.** Site-level
energy-balance roles (`config.site_energy_meter_roles`: grid import/export,
on-site generation, battery charge/discharge, site consumption) are an
**already-live, already-correct** precedent for this: they classify a
device's contribution to a site's energy equation, entirely independent of
whatever `AssetRelationship`/`AssetSpaceRelationship` graph exists among the
physical equipment (a PV inverter and battery can be fully modeled as Assets
with their own condition monitoring, while their contribution to the site's
import/export/generation balance is tracked through a completely separate
mechanism). This separation is validated, not accidental — it must be
preserved, not "unified" into one model for symmetry's sake.

---

## F. Frontend implications

Current reality (§A.7) is that "frontend" means two different things — an
onboarding CRUD tool (admin-portal) and a dashboard tool (Grafana) — with **no
application-level analytics API**; Grafana's SQL views *are* the API today. The
future-state model should make that boundary an explicit, intentional design
choice rather than an accident: **the frontend (whichever surface renders it)
should consume domain-shaped read views/functions, never raw tables** — exactly
the discipline `v_grafana_*` already enforces, extended to the new entities.

### F.0 Application surfaces — Administration App and the EMS Web Application

> Amendment (2026-09-10): this subsection makes an already-implied boundary
> explicit. It is an application/deployment clarification, not a change to the
> frozen conceptual model (§"Architecture Status", §"Conceptual architecture
> vs. implementation architecture") — no core entity, relationship, rule, or
> the Phase 7 API contract changes.

The future state has **two distinct application surfaces with different
purposes** — not one application replacing another:

- **Administration App** — the existing administrative/operational interface
  (today's `admin-portal`, `app/`), used by authorised users to manage
  organisations, sites, users, devices, configuration and onboarding. It is
  left operationally intact; this roadmap extends it in place (new `admin.*`
  write functions) and never rewrites it.
- **EMS Web Application** — the customer-facing analytical product for the
  site, space, asset, energy, environmental, performance, data-quality and
  other customer EMS workflows the roadmap defines. It is a new, additive
  surface.

Rules governing the two surfaces:

- The **EMS Web Application consumes the Analytics API** (the Phase 7 query
  boundary). It must **not** directly access raw telemetry, internal database
  structures, implementation-specific tables, or Grafana queries — the same
  discipline `v_grafana_*` already enforces, restated here as an application
  boundary.
- The two surfaces **may share authentication, authorisation, and
  backend/API services**. Sharing those services does not make the EMS Web
  Application a redesign or replacement of the Administration App; each keeps
  its own purpose and lifecycle.
- **Grafana remains an OPS/engineering surface.** Its customer-facing
  workflows are retired only workflow-by-workflow through this roadmap's
  existing parity process (Phase 17) — nothing here shortcuts that.

**On the `/app` route.** `/app` is the **current staging route used to expose
the EMS Web Application**. It is a routing/deployment detail, **not** the
architectural identity or the application boundary — the boundary is the EMS
Web Application itself. Nothing here commits the EMS Web Application to living
permanently at `/app`.

### Site view
Energy (existing `v_grafana_sites`/consumption rollups), plus: a
**Spaces panel** (list of spaces with current environmental snapshot, once
`space_id`/`space_points` exist), a **Systems panel** (assets grouped by
`asset_relationships` composition — "3 AHUs, 12 motors, 1 chiller plant"), and
an **efficiency/anomaly summary** once derived parameters exist (§B.7) —
each backed by a new `v_grafana_site_*` view following the exact pattern
already used for energy.

### Asset view
Energy (existing), operating state and relevant condition parameters (new, from
`asset_health`/generic table via `asset_points`), trends and alarms (existing
alarm views extended), efficiency and comparisons (derived-parameter values,
compared across assets of the same `asset_type_id` — a fair comparison because
`config.parameters`/`parameter_calculations` are asset-type-scoped, not
per-asset ad hoc), and health/performance rollups. An asset's **component
tree** (via `asset_relationships`) becomes a navigable structure — "AHU-01 → Fan
→ Motor" — each level showing its own bound parameters.

### Space view
**New, does not exist today.** Environmental conditions (space-scoped
measurements), assets serving the space (`asset_space_relationships`, reverse
direction from the asset view), energy attribution (sum of consumption for
every asset that `SERVES` this space, with the caveat — surfaced in the UI, not
hidden — that a shared AHU's energy is not automatically apportioned per space
without an explicit allocation rule, which is an analytics-layer decision, not
a schema one), comfort/performance against a target band (`direction_of_good`/
target metadata on the relevant parameters), trends, anomalies.

### Device/Point view
Raw telemetry (existing `v_grafana_normalized_points`/`v_grafana_point_catalog`),
mapped parameter (new — surfacing `logical_points.parameter_id` resolution so
an operator can see "this raw field is interpreted as `BEARING_TEMPERATURE`"),
subject (new — "and it's attributed to Motor A" or "unattributed," which is
itself a useful onboarding-completeness signal, mirroring the existing
`v_commissioning_readiness` pattern), quality, and history.

### What the frontend API should expose (not raw structure)
Whether the eventual consumer is Grafana or a future purpose-built app, the
same rule that already governs `v_grafana_*` should govern every new surface:
expose asset-shaped, space-shaped, and site-shaped read objects
(`v_grafana_asset_condition_summary`, `v_grafana_space_environment_summary`,
`v_grafana_asset_efficiency_*`, following the naming and tenant-filtering
conventions already established) — never `metadata.asset_points` or
`telemetry.generic_point_measurements` directly. Grafana can likely absorb
Space views and cross-domain panels through this same view layer without a new
frontend being strictly necessary in the near term; a purpose-built app becomes
worth building once genuinely relational, interactive features are needed
(navigating an asset-relationship graph, editing an asset↔space "serves" map,
authoring `parameter_calculations`) that outgrow what a dashboarding tool can
reasonably present — that is a Capabilities/Advanced-phase decision, not a
Foundation-phase one (§G).

---

## G. Implementation roadmap

The detailed, phased backend+frontend implementation plan for this frozen
architecture lives in a dedicated document —
`docs/DDS/analytics-platform-future-state-architecture-implementation-roadmap.md`
— rather than here, so that *how and when* this gets built (an implementation
concern, revised as the program proceeds) stays clearly separated from *what
it is* (this document, frozen). That roadmap covers, in order: a current-state
analytics inventory; the semantic foundation (`config.parameters`, Point→
Parameter mapping); the subject/relationship foundation (`AssetPoint`/
`SpacePoint`/`AssetRelationship`/`AssetSpaceRelationship`); the domain
measurement foundation (wiring `asset_health`/`water_measurements`, the
generic landing table); the routing architecture (config → codegen'd
procedure, energy parity gate); the derived-calculation foundation and its
persisted tier; the analytics API/query boundary; a React/TypeScript frontend
foundation; core Site/Asset/Space UX; energy analytics migration (run in
parallel with Grafana until numerical parity is proven); asset-performance UX
(motor condition monitoring as the first production-quality reference); real-time
and data-quality surfaces; advanced efficiency analytics; cost/benchmarking/
intelligence foundations (deliberately thin); reporting; hardening/scale; and
finally the customer-facing Grafana-workflow migration (Grafana remains for
ops/engineering). Nothing in this document authorizes any of that work —
each phase requires its own explicit approval before touching staging or
production, per CLAUDE.md §§3–4 and §11.

---

🤖 Generated with [Claude Code](https://claude.com/claude-code)
