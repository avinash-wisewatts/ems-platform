# EMS Analytics Platform — Future-State Architecture Stress Test

```
Status: FINAL PRE-IMPLEMENTATION VALIDATION
Prepared: 2026-09-07
Inputs: docs/DDS/analytics-platform-future-state-architecture.md (proposal,
unmodified), docs/DDS/analytics-platform-future-state-architecture-review.md
(red-team, unmodified). No database, migration, application, Grafana,
staging, or production change was made to produce this document.
```

This document takes the **revised** architecture from the red-team review
(§19 of that document) as the baseline under test — not the original
proposal — and pressure-tests it against ten concrete equipment/energy
scenarios. Where this stress test finds the baseline still too complicated,
it says so and simplifies further. It does not re-litigate findings the
red-team review already settled unless a scenario produces new evidence.

## 1. Executive conclusion

The core model — **Organization → Site → (Building → Floor → Space)**,
**Asset** (physical or virtual) with typed, effective-dated
**AssetRelationship** and **AssetSpaceRelationship**, **Point → Parameter**
(with qualifier) bound to an optional **Asset or Space subject** via
effective-dated **AssetPoint/SpacePoint**, domain-specific **measurement
storage**, and a **ParameterCalculation** mechanism for derived values —
handles all ten scenarios without any new entity type. Every scenario that
initially looked like it might need something new (a "System" entity, a
"Site subject," a lighting-specific concept, a dynamic grouping mechanism)
turned out to be expressible with the existing five concepts once traced
through carefully.

The stress test did surface **three concrete, small corrections** that were
either missing or too broad in the red-team review's revised model — none of
them add a new table or entity, all three are refinements to already-planned
structures:

1. `ParameterCalculation`'s inputs need an explicit **resolution mode**
   (`SELF` / `RELATED` / `AGGREGATE_CHILDREN`) — several real calculations
   (pump specific-energy, plant-level COP, a virtual "HVAC Total") need an
   input from a *different* asset than the one the output is being computed
   for, which neither prior document specified precisely.
2. The red-team review's generalized `cumulative_register_semantics` table
   was **too broad** — it should split into (a) broadening
   `energy_register_semantics` itself to also cover fuel/thermal energy
   registers (gas meters are still energy accounting), and (b) a genuinely
   simpler `counter_rollover_behavior` for non-energy monotonic counters
   (runtime hours, starts, pulse totals) that never had a "flow direction"
   concept to begin with.
3. **Storage routing must key off the *source's accounting role* (is this
   point behind a `PRIMARY_METER`/`SECONDARY_METER` relationship of category
   "Energy Meter"), not the parameter's unit alone** — a VFD- or PLC-reported
   power estimate must not silently land in the energy-accounting domain
   table next to a real meter's register-derived reading.

No scenario required a generalized polymorphic Subject, a "System"/"Zone"
entity, a Site-level subject-binding table, or a dynamic tag/asset-type-based
grouping mechanism — each was tested explicitly and rejected with a concrete
alternative already available in the model (§4, §10).

**Freeze recommendation: MINOR CORRECTIONS** (§6).

---

## 2. Scenario-by-scenario results

Each scenario uses the structure A–H from the brief. Where a subsection has
nothing new beyond what's already established, it says so briefly rather than
repeating prior text.

### Scenario 1 — Main Electrical Meter

| | |
|---|---|
| **A. Physical** | Site → Gateway → Device (energy meter). **No Asset is created for the main meter.** The scenario's own instruction — don't invent an asset relationship merely because a physical meter exists — is correct, and the schema already supports this: `telemetry.energy_measurements.asset_id` is nullable, and `config.site_energy_meter_roles(site_id, device_id, meter_role)` binds the device to the site's energy equation directly, with no asset in between. |
| **B. Semantic** | Points: `ENERGY_IMPORT_TOTAL` (cumulative), `ACTIVE_POWER_TOTAL`, `VOLTAGE_L1/L2/L3`, `CURRENT_L1/L2/L3`, `POWER_FACTOR_TOTAL`. Parameters: `ENERGY`, `POWER`, `VOLTAGE`, `CURRENT`, `POWER_FACTOR` — `VOLTAGE`/`CURRENT` use `qualifier ∈ {L1,L2,L3,TOTAL}` (same simultaneous-instance rule as always). No new parameters needed. |
| **C. Measurement path** | `Device → Point → Parameter → (no Subject) → energy_measurements(site_id, device_id, asset_id=NULL)`. This is the simplified path *unmodified* — the "Subject" step is genuinely optional here, not a special case. |
| **D. Relationships** | None invented. `config.site_energy_meter_roles` (existing, `meter_role='SITE_CONSUMPTION'` or the import/export/generation components) is the only binding, and it is **not** an `AssetRelationship`. |
| **E. Energy** | Direct — this *is* the energy measurement, at its most basic. No derivation needed for the raw import/export totals. |
| **F. Derived** | Site-level demand (existing `analytics.demand_intervals` mechanism, unchanged) — no new derived-parameter machinery required for this scenario. |
| **G. History** | Meter replaced (CT swap, unit swap): a new `Device` row, `metadata.device_identifiers` re-pointed; `site_energy_meter_roles` is already effective-dated in the live schema, so the old device's role closes and the new device's role opens — this already works today, no gap found. |
| **H. Failure/quality** | Standard `quality_code`/gap handling, unchanged. No calculation involved, so no quality-propagation complexity — the simplest possible case. |

**Finding**: this scenario is the cleanest possible demonstration that **not
every meter needs an Asset**. If a business later wants meter-level
condition tracking (a CT ratio issue, a meter firmware fault) they *can*
create an "Incomer" Asset and use the existing `asset_devices` `PRIMARY_METER`
pattern — but the architecture must not require it.

---

### Scenario 2 — Motor + VFD + Vibration Sensor

| | |
|---|---|
| **A. Physical** | Motor = Asset. VFD = **optional** Asset — only if the business wants VFD-specific analytics (drive faults, VFD-reported input/output power loss) independent of the motor; otherwise VFD-sourced points (speed, VFD current) bind straight to the Motor. This is an onboarding decision, not an architecture requirement — the schema is neutral either way. Vibration sensor = Device, three (or four, with an RMS-computing firmware) Points on it. |
| **B. Semantic** | `RUN_STATUS` (STATE parameter, vocabulary via `config.status_definitions`), `SPEED` (NUMERIC), `CURRENT`, `CASING_TEMPERATURE`, `VIBRATION` with `qualifier ∈ {X,Y,Z}` — three simultaneous readings of one physical phenomenon from one sensor, the textbook qualifier case. `VIBRATION_RMS` is a **derived** parameter (`SELF`-scoped: sqrt(x²+y²+z²) or the sensor's own RMS field), not a fourth qualifier value — RMS is a computed summary, not a fourth simultaneous instance. |
| **C. Measurement path** | Unmodified — every point binds directly to the Motor Asset via `AssetPoint`, whether or not a separate VFD Asset exists. |
| **D. Relationships** | `AssetRelationship(VFD, DRIVEN_BY→wrong direction — correct is Motor DRIVEN_BY VFD is also wrong; the physically correct fact is the VFD supplies/controls power to the Motor)` — recommend a `CONTROLLED_BY` or `SUPPLIED_BY` type, distinct from `DRIVEN_BY` (which Scenario 3 shows is the correct type for Pump↔Motor, a mechanical coupling, not an electrical supply relationship). This is a small, useful correction: `DRIVEN_BY` should be reserved for mechanical driving; a VFD's relationship to its motor is electrical supply/control, and conflating the two types would make relationship-type meaning fuzzy. Only created if a separate VFD Asset exists at all. |
| **E. Energy** | **Only points reached through an `asset_devices` `PRIMARY_METER`/`SECONDARY_METER` relationship to a device of category "Energy Meter" route into `energy_measurements`.** A VFD's own reported power estimate is a diagnostic/condition value, not accounting-grade — it belongs in `asset_health`/the generic table, even though its unit is watts. **This is a real gap in both prior documents**: neither specified that storage routing must key off the *source's accounting role*, not the parameter's physical unit. See §5, correction 3. |
| **F. Derived** | Runtime (state-duration over `RUN_STATUS`), `VIBRATION_RMS`, energy-per-run-hour (own energy ÷ own runtime derived value) — all `SELF`-scoped, no cross-asset traversal needed for this scenario. |
| **G. History** | Vibration sensor moved to a different motor: `AssetPoint` effective-dating closes the old binding, opens the new one — already covered by the red-team review, reaffirmed here with a concrete example. |
| **H. Failure/quality** | Sensor disconnected → `GAP`; `VIBRATION_RMS` inherits `GAP` (worst-wins over required inputs — X, Y, Z are all required for a true RMS). |

**Finding**: the model needs **no concept beyond Point → Parameter →
Asset/Space** for this scenario — the only genuine gap is the routing-by-role
rule (correction 3) and a relationship-type naming refinement
(`SUPPLIED_BY`/`CONTROLLED_BY` vs. `DRIVEN_BY`).

---

### Scenario 3 — Pump + Motor + Flow

| | |
|---|---|
| **A. Physical** | Pump and Motor are separate Assets — a real, common industrial distinction (pump curve/cavitation analytics vs. motor electrical/vibration health are genuinely different concerns owned by different maintenance disciplines). Flow meter and pressure sensor: Devices whose points bind to the **Pump** (process-side measurements belong to the process equipment, not the driver). |
| **B. Semantic** | `FLOW`, `PRESSURE` (Pump), `POWER`/`CURRENT` (Motor), `RUN_STATUS` (either, commonly Motor). No new parameters. |
| **C. Measurement path** | Unmodified. |
| **D. Relationships** | `AssetRelationship(Pump, DRIVEN_BY, Motor)` — exactly the case this relationship type was designed for. At this scale (2 assets, 1 relationship row) it is **not** elaborate — confirms `AssetRelationship` is well-matched to its intended granularity, not over-built for it. |
| **E. Energy** | Motor's own meter (or a shared meter for the pump-motor set, in which case it's simplest to bind `PRIMARY_METER` to whichever asset the business considers "the metered unit" — commonly the Motor, since it's the electrical load). |
| **F. Derived** | **Pump specific-energy (kWh/m³)** is the scenario's key test: its inputs are the Motor's energy (a *different* asset than the one the derived value is being computed *for*, i.e. the Pump) and the Pump's own flow. This requires `ParameterCalculation`'s input references to say "this input comes from the asset related to me via `DRIVEN_BY`," not just "this input comes from my own points." **Neither prior document specified this — see §5, correction 1.** |
| **G. History** | Motor replaced (same pump, new motor): new Motor Asset, old `DRIVEN_BY` relationship closes, new one opens — pump specific-energy calculated *after* replacement automatically reads from the new motor; calculated *before* stays correctly attributed to the old one, because the relationship traversal is resolved as of the reading's own time, not "current." |
| **H. Failure/quality** | Flow meter fails → `GAP` on `FLOW` → specific-energy (required input) inherits `GAP`. |

**Finding**: `AssetRelationship` is sufficient and not overbuilt for this
scenario. The real gap is in the *calculation* mechanism's input resolution,
not the relationship model.

---

### Scenario 4 — Chiller Plant

| | |
|---|---|
| **A. Physical** | Chiller Plant = Asset (a "System/Plant," per the red-team review's ruling — just an Asset, `asset_type_id='Chiller Plant'`, not a new entity type). Chillers, CHW pumps, CDW pumps, cooling tower = separate Assets, each `COMPONENT_OF` the Plant. Compressor: usually **not** a separate Asset — its RLA/run-status are almost always reported as Chiller-level points by the chiller's own controller, not an independently metered/sensed device; only model it separately if it genuinely has its own instrumentation. |
| **B. Semantic** | `CHW_SUPPLY_TEMP`/`CHW_RETURN_TEMP`/`CDW_SUPPLY_TEMP`/`CDW_RETURN_TEMP`/`FLOW`/`RLA` bind to **whichever asset the point is physically measured at** — a header-mounted sensor serving multiple chillers binds to the Plant; a chiller-mounted sensor binds to that Chiller. This is an onboarding-time choice per point, not an architecture gap. `OUTDOOR_WET_BULB_TEMP` binds to **neither an Asset nor a Space** — see D. |
| **C. Measurement path** | For plant/chiller-scoped points: unmodified. For outdoor wet-bulb: `Device → Point → Parameter → (no Subject) → domain table (site_id populated, asset_id/space_id NULL)` — identical in shape to Scenario 1's main-meter path. **No third "Site subject" binding table is needed** — `site_id` is already a structural column on every measurement table, independent of `asset_points`/`space_points`. This resolves a question this review was tempted to raise (does Site need its own binding mechanism?) with a concrete "no." |
| **D. Relationships** | N `COMPONENT_OF` rows (Chillers/pumps/tower → Plant) — linear growth, no awkwardness at real plant scale (a 6-chiller plant is 6 rows, not a schema change). |
| **E. Energy** | Each Chiller normally has its own meter (`PRIMARY_METER`, per-chiller) — `energy_measurements` scoped by chiller `asset_id`. |
| **F. Derived** | ΔT (`SELF`, return−supply, same asset), Cooling Load (`SELF`, flow×ΔT), per-chiller COP (`SELF`, power÷cooling load). **Plant-level COP** is the scenario's key test: it must aggregate (sum power, sum cooling load) across all Chillers `COMPONENT_OF` the Plant — this is the `AGGREGATE_CHILDREN` resolution mode from §5 correction 1, exercised here in its "sum over structural children" form (distinct from Scenario 3's "single related asset" form — both are needed). |
| **G. History** | A chiller decommissioned/replaced mid-plant: existing `lifecycle_status` + effective-dated `COMPONENT_OF` — plant-level rollups computed after the swap correctly exclude/include the right set of children as of each point in time. |
| **H. Failure/quality** | One chiller's flow meter fails: that chiller's COP goes `GAP`; **does the plant-level rollup go `GAP` entirely, or degrade gracefully (e.g., report on N-1 chillers with a `PARTIAL` quality code)?** This is a real design question this scenario surfaces that neither prior document answered — recommend `AGGREGATE_CHILDREN` calculations default to "worst-wins across contributing children, with an explicit `PARTIAL` quality state (distinct from `GAP`) when some-but-not-all children contributed," rather than forcing an all-or-nothing degrade. Flag as a refinement to add alongside correction 1, not a new mechanism. |

**Finding**: nothing becomes awkward at plant scale. The `AGGREGATE_CHILDREN`
resolution mode (with a `PARTIAL` quality state) is the one real addition
this scenario requires.

---

### Scenario 5 — AHU Serving Multiple Rooms

| | |
|---|---|
| **A. Physical** | AHU = Asset. Ballroom A, Ballroom B, Corridor = Spaces (existing hierarchy). |
| **B. Semantic** | `SUPPLY_AIR_TEMP`/`RETURN_AIR_TEMP`/`AIRFLOW`/`FAN_POWER`/`FAN_STATUS`/`COOLING_VALVE_POSITION` — all bind to the AHU Asset. No qualifiers needed (each is a single simultaneous reading). |
| **C. Measurement path** | Unmodified — every AHU point binds to the AHU Asset via `AssetPoint`; room-level environmental points (if any — temperature/humidity/CO2/occupancy sensors physically in the rooms) bind to the respective Space via `SpacePoint`, entirely independently. |
| **D. Relationships** | `AssetSpaceRelationship(AHU-01, SERVES, Ballroom A)`, `(AHU-01, SERVES, Ballroom B)`, `(AHU-01, SERVES, Corridor)` — three rows, M:N by construction, no special casing. **Confirmed sufficient — this was the scenario's own explicit question, and the answer is yes.** |
| **E. Energy** | AHU's own meter, scoped to the AHU asset — unchanged, no redesign. |
| **F. Derived** | ΔT across the coil (supply−return), fan specific power (`SELF`). Per-space energy attribution is **explicitly not built** here — the red-team review's deferred `analytics.asset_space_energy_allocation` remains deferred; this scenario reaffirms that decision rather than reversing it, since no new requirement for it appeared. |
| **G. History** | AHU re-ducted to serve Ballroom B and Corridor only (drops Ballroom A): the `SERVES` row to Ballroom A gets `effective_to` set, closing it; a `SERVES` row to Corridor opens if newly added. Any energy-attribution estimate computed after the change reflects the new set; estimates computed before remain attributed to what was actually true then. |
| **H. Failure/quality** | Standard, no new considerations beyond what's already covered. |

**Finding**: the core relationship model is sufficient as-is — this scenario
required zero corrections.

---

### Scenario 6 — Refrigeration Rack + Multiple Cabinets

| | |
|---|---|
| **A. Physical** | Rack = Asset. Each Cabinet = separate Asset, `COMPONENT_OF` the Rack (near-universal in practice — cabinets are independently maintained equipment with their own temperature/door performance). |
| **B. Semantic** | **Key finding**: `CABINET_TEMPERATURE` is **one parameter, with no qualifier at all**, instantiated once per cabinet via distinct `AssetPoint` bindings (one row per cabinet's own Asset). The "which cabinet" distinction is carried entirely by the **subject** (`asset_points.asset_id`), never by a qualifier. Using a qualifier for "which cabinet" (e.g., `qualifier='CABINET_3'`) would be exactly the "excessive/generalized qualifier machinery" the brief warns against — qualifier is reserved for multiple *simultaneous instances of one physical measurement act* (phases, axes), never for "which instance of a repeated piece of equipment." `DOOR_STATUS`/`DEFROST_STATUS` (STATE, per-cabinet) follow the same rule. |
| **C. Measurement path** | Unmodified, once per cabinet. |
| **D. Relationships** | N `COMPONENT_OF` rows (cabinets → rack), same shape as Scenario 4's chillers-under-a-plant — confirms the pattern is genuinely reusable across unrelated equipment domains, not chiller-specific. |
| **E. Energy** | Rack-level meter (`compressor power`) — cabinets typically have no individual meter (DX systems are usually metered at the rack/compressor level, not per case). |
| **F. Derived** | Per-cabinet door-open duration (state-duration, `SELF`) — **one `ParameterCalculation` definition, scoped to the Cabinet asset type, applied automatically once per cabinet instance** — a clean demonstration that the calculation framework already scales to "many identical instances" without per-cabinet special-casing. Rack-level COP/efficiency: **honestly flagged as often not cleanly computable** for a DX refrigeration rack the way chiller CHW flow×ΔT is (there's no direct "cooling delivered" measurement without extra instrumentation) — this is a **physics/instrumentation limit, not an architecture limit**, and should not be mistaken for a schema gap. |
| **G. History** | A cabinet physically relocated to a different rack (rare but real, e.g. store remodel): `COMPONENT_OF` effective-dating handles it exactly like Scenario 3's motor replacement. |
| **H. Failure/quality** | A door sensor fails → `GAP` on that cabinet's `DOOR_STATUS` only — does not affect sibling cabinets' quality, confirming subject-scoped quality isolation works correctly at fan-out scale. |

**Finding**: the Parameter model **remains understandable** at this scale
specifically *because* the qualifier-vs-subject rule is enforced — this
scenario is the clearest evidence for stating that rule explicitly as a
guardrail (§5).

---

### Scenario 7 — Lighting System

| | |
|---|---|
| **A. Physical** | Lighting circuit = Asset (optional — same Scenario-1 pattern: if nobody needs circuit-level tracking, no asset, just a meter). Lighting controller = Device (rarely its own Asset unless independently monitored for faults). Occupancy/lux sensors = Devices whose points describe the **room**, not a light fixture. |
| **B. Semantic** | `OCCUPANCY`, `ILLUMINANCE` — **Space-scoped parameters**, bound via `SpacePoint`, exactly like the AHU scenario's room environmental sensors. No lighting-specific parameter type needed. |
| **C. Measurement path** | Unmodified — occupancy/lux via `SpacePoint`; circuit power via `AssetPoint` (or unbound, per Scenario 1's pattern) — identical shapes to prior scenarios, just applied to a different equipment domain. |
| **D. Relationships** | `AssetSpaceRelationship(Lighting Circuit 3, SERVES, Corridor)`, `(..., SERVES, Ballroom A)` — **the exact same `SERVES` type as the AHU scenario**, no new relationship type. |
| **E. Energy** | Circuit-level metering, same `PRIMARY_METER` pattern as anything else. |
| **F. Derived** | Lighting energy per occupied-hour (circuit energy ÷ a space-level occupancy-derived duration) — a genuinely useful cross-subject derived parameter (input from an Asset, input from a Space) — confirms `ParameterCalculation` inputs must be able to reference points bound to *either* subject type, not just Assets, which both prior documents implicitly assumed without stating. |
| **G. History** | A circuit rewired to serve a different zone: same `SERVES` effective-dating pattern. |
| **H. Failure/quality** | Standard, nothing new. |

**Finding**: **zero lighting-specific entities were needed.** This is the
strongest single piece of evidence in this stress test that the model is
genuinely domain-agnostic rather than shaped around HVAC/energy examples —
lighting reuses every concept verbatim. The one real addition (derived
parameters mixing Asset- and Space-bound inputs) is a small, necessary
generalization, not new complexity.

---

### Scenario 8 — Boiler / Heating System

| | |
|---|---|
| **A. Physical** | Boiler = Asset. Circulation pump = separate Asset, `DRIVEN_BY` (Scenario 3's pattern, reused verbatim). Gas meter = Device. |
| **B. Semantic** | `SUPPLY_TEMP`/`RETURN_TEMP`/`FLOW`/`BURNER_STATUS` bind to the Boiler. `GAS_CONSUMPTION` is a **cumulative register**, structurally identical to electrical energy import (direction, rollover, reset) but a different unit (m³) and a different accounting meaning (fuel input, not electrical). |
| **C. Measurement path** | Unmodified. |
| **D. Relationships** | `AssetRelationship(Circulation Pump, DRIVEN_BY, Boiler-side motor)` — reused, no new type. |
| **E. Energy** | **This scenario is the direct test of the red-team review's proposed `cumulative_register_semantics` generalization, and it shows that generalization was too broad.** A gas meter genuinely needs the same shape of contract energy already has — `flow_interpretation` (a fuel-input register is still *energy accounting*, just non-electrical) — whereas a **non-energy** monotonic counter (Scenario 2's motor `runtime_hours_total`, `starts_count`) never had a "flow direction" concept in the first place. **Correction 2** (§5): split into (a) broadening `config.energy_register_semantics.flow_interpretation` to include fuel/thermal flows, keeping it in the energy domain where gas genuinely belongs, and (b) a separate, simpler `config.counter_rollover_behavior` (no `flow_interpretation` column at all) for true non-energy counters. Auxiliary electrical (circulation pump power): ordinary electrical energy measurement, own or shared meter, same as Scenario 3. |
| **F. Derived** | Thermal output (flow × ΔT × constant — identical shape to Scenario 4's cooling load, opposite thermal direction, reinforcing the calc mechanism is genuinely generic, not HVAC-specific), efficiency = thermal output ÷ fuel energy input (a derived parameter whose two inputs come from **different domain tables** — one from a "thermal" derived-parameter tier, one from a fuel-energy measurement — the generic mechanism handles this fine, since it only ever references `parameter_id`s, never storage location). |
| **G. History** | Boiler retrofitted with a new burner (different gas-register behavior): a profile/semantics change, handled the same way any register-semantics correction is (§13 of the red-team review — reviewed backfill, not silent reinterpretation). |
| **H. Failure/quality** | Gas meter reports an implausible delta (`expected_max_interval_delta` exceeded): same `REJECT_DELTA`-class handling energy already has, once (a) above extends coverage to fuel registers. |

**Finding**: no boiler-specific architecture was needed — the real output of
this scenario is correction 2, a genuine simplification of the prior review's
over-broad generalization.

---

### Scenario 9 — Solar PV + Battery + Grid

| | |
|---|---|
| **A. Physical** | Grid connection: no Asset required (Scenario-1 pattern) or an optional nominal "Utility Service" Asset. PV Inverter = Asset. Battery + Battery Inverter = Asset(s) (one or two, depending on whether the business wants inverter-specific diagnostics separate from the battery's own state). |
| **B. Semantic** | `SOC` (state of charge), `CELL_VOLTAGE`, `INVERTER_TEMPERATURE` — Battery/PV-asset condition parameters, ordinary `AssetPoint` bindings, nothing new. |
| **C. Measurement path** | For condition parameters: unmodified, `AssetPoint`-bound. For the site energy-balance components (import/export/generation/charge/discharge): **not asset-bound at all** — see D. |
| **D. Relationships** | **This is the scenario's central test, and the existing `config.site_energy_meter_roles` table already answers it correctly**: `GRID_IMPORT`, `GRID_EXPORT`, `ONSITE_GENERATION`, `BATTERY_CHARGE`, `BATTERY_DISCHARGE`, `SITE_CONSUMPTION` are **device roles in a site-level accounting equation**, resolved independently of whatever `AssetRelationship` graph exists among the physical PV/Battery/Grid equipment. **The brief's own instruction — do not force every energy-accounting concept to become an `AssetRelationship` — is exactly right, and the schema already gets this right today.** Physical topology (`Asset`/`AssetRelationship`, for condition/health monitoring of the PV inverter and battery) and energy accounting (`site_energy_meter_roles`, for the balance equation) are two **independent** models that happen to reference the same underlying devices — this is intentional, not a gap. |
| **E. Energy** | `Derived Site Consumption = Grid Import + Generation − Grid Export − Battery Charge + Battery Discharge` — this formula is **already documented in the live schema's own file header** (`postgres/ddl/85_site_energy_meter_roles.sql`). It is itself a derived/virtual parameter (`AGGREGATE_CHILDREN`-shaped, but over accounting roles, not asset composition) — no asset needed to hold it. |
| **F. Derived** | Site Consumption (as above), self-consumption ratio (generation actually used on-site ÷ total generation), battery round-trip efficiency (discharge energy ÷ charge energy, `SELF`-scoped to the Battery asset). |
| **G. History** | A second PV inverter added later: a new `site_energy_meter_roles` row (`ONSITE_GENERATION`) opens alongside the existing one — `site_energy_meter_roles` already supports multiple devices per role (its own DDL comment: "a device may legitimately hold multiple roles… the same device/role/site combination cannot have overlapping active periods" — multiple *different* devices in the *same* role is unconstrained, by design). |
| **H. Failure/quality** | Grid meter reports a gap: Site Consumption (derived, required input) goes `GAP` — worst-wins, consistent with every other derived-parameter case in this document. |

**Finding**: **this scenario required zero new concepts.** It is the
cleanest possible confirmation that physical-topology relationships and
energy-accounting semantics are correctly kept separate in the existing
schema, and that this separation should be preserved, not "cleaned up" into
one unified model — doing so would be a regression, not an improvement.

---

### Scenario 10 — Virtual "HVAC Total"

| | |
|---|---|
| **A. Physical** | "HVAC Total" = a **virtual Asset** (`asset_nature='VIRTUAL'`), no device, no gateway. |
| **B. Semantic** | Its energy figure is entirely derived — `is_derived=true` on the output parameter, no `logical_points` reference it directly. |
| **C. Measurement path** | `(no Device/Point) → ParameterCalculation → analytics.derived_parameter_values(asset_id = HVAC Total)`. |
| **D. Relationships** | **Key finding**: the cleanest way to define membership ("which real assets count toward HVAC Total") is an ordinary `AssetRelationship(Chiller-N, COMPONENT_OF, HVAC Total)` row **per member asset** — explicit, auditable, effective-dated — rather than a dynamic tag/asset-type query (e.g., "sum every asset whose `asset_type_id` is in {Chiller, AHU, Cooling Tower}"). A dynamic membership rule would silently change what's included whenever `asset_type_id`s are edited elsewhere, with no historical record of when an asset joined or left the total. Explicit `COMPONENT_OF` rows give a visible, effective-dated membership trail for free — **and this is the exact same mechanism Scenario 4's plant-level COP already needed** (`AGGREGATE_CHILDREN`). No separate "virtual grouping" mechanism is needed; a virtual Asset's rollup and a real Plant's rollup are the same calculation shape. |
| **E. Energy** | Sum of each member's own `energy_consumption_*` — the `AGGREGATE_CHILDREN` resolution mode, unified with Scenario 4. |
| **F. Derived** | HVAC Total energy, HVAC Total % of site consumption (a second derived parameter dividing by the site-level consumption from Scenario 1/9). |
| **G. History** | A new AHU added to the HVAC Total definition: a new `COMPONENT_OF` row opens at that date; totals computed before that date correctly exclude it, totals after correctly include it — this is exactly why explicit membership rows (not a dynamic tag query) were the right choice. |
| **H. Failure/quality** | One member's energy is `GAP` for an interval: per Scenario 4's refinement, the total reports `PARTIAL`, not silently `GOOD` on a partial sum. |

**Finding**: fully supported by the existing derived-parameter +
`AssetRelationship` mechanism, provided `AGGREGATE_CHILDREN` (correction 1) is
added. No new "virtual entity type" hierarchy is needed — a virtual Asset
*is* an Asset, full stop.

---

## 3. Cross-scenario findings

| # | Question | Answer | Evidence |
|---|---|---|---|
| 1 | Does every physical measurement need an Asset? | **No.** | Scenario 1 (main meter), Scenario 4 (outdoor wet-bulb), Scenario 9 (derived Site Consumption) — all resolve via `site_id`/`device_id` alone, no Asset, no Space. |
| 2 | Does every Asset need a Device? | **No.** | Scenario 10 (virtual HVAC Total) has zero devices; a pure composition Asset (Scenario 4's Chiller Plant) may have none of its own either, only via its children. |
| 3 | Does every Point need an Asset? | **No.** | Scenarios 1/4/9 — unbound points; Scenarios 5/6/7 — bound to a Space instead. |
| 4 | Can one Point describe different subjects over time? | **Yes.** | Effective-dated `AssetPoint`/`SpacePoint` (Scenarios 2, 3, 5, 8 "G" sections). |
| 5 | Can one Device provide measurements for multiple Assets? | **Yes**, at the Point level, not the Device level. | A multi-channel device's individual points can bind to different assets independently — the binding is per-Point, never per-Device. |
| 6 | Can one Asset have measurements from multiple Devices? | **Yes.** | Scenario 2 (Motor: vibration sensor device + VFD/energy meter device, both bind to one Motor) — already how `asset_devices` supports `PRIMARY_METER`+`SECONDARY_METER`+condition sensors today. |
| 7 | Can one Asset serve multiple Spaces? | **Yes.** | Scenario 5 (AHU→3 spaces), Scenario 7 (lighting circuit→2 spaces). |
| 8 | Can multiple Assets serve one Space? | **Yes.** | M:N by construction — a room can have `SERVES` rows from an AHU, a lighting circuit, and (in a kitchen) refrigeration, simultaneously. |
| 9 | Can a measurement describe a Space rather than an Asset? | **Yes.** | Scenarios 5/6/7 — occupancy, lux, room temperature via `SpacePoint`. |
| 10 | Can a calculated measurement have no physical sensor? | **Yes.** | Runtime, ΔT, COP, HVAC Total — none has a device/point of its own. |
| 11 | Can a virtual Asset exist without pretending to be physical equipment? | **Yes**, provided `asset_nature`/`is_derived` are always surfaced wherever a value is shown, so a consumer never mistakes a modeled figure for a directly metered one. | Scenario 10. |
| 12 | Can energy accounting exist without becoming physical topology relationships? | **Yes — and it already does, today, live.** | Scenario 9, `config.site_energy_meter_roles`. |

**The recurring theme across all twelve**: the "Subject" question this whole
investigation kept circling is resolved by recognizing that `organization_id`/
`site_id` are **structural, mandatory, always-present columns**, not a
"subject" requiring a binding table — `Asset` and `Space` are the only two
*optional* enrichment subjects on top of that. There was never a missing
third subject type; Site was never a gap, because it was never meant to be a
bindable subject in the first place.

---

## 4. Complexity findings

| Concept | Classification | Basis |
|---|---|---|
| Generalized polymorphic "Subject" supertype | **REMOVE** (reaffirmed) | No scenario needed it; every case resolved via Asset, Space, or neither. |
| A third "Site subject" binding table (`site_points`) | **REMOVE** (newly and explicitly rejected) | `site_id` is already structural on every measurement row (Scenarios 1, 4, 9). |
| Asset + Space as the only two optional subject bindings | **KEEP** | Sufficient across all 10 scenarios, 8 equipment domains. |
| `AssetRelationship` (typed, effective-dated, exclusion-constrained) | **KEEP** | Validated at real scale (6-chiller plant) and real minimal scale (1 pump + 1 motor) without awkwardness either way. |
| `AssetSpaceRelationship` (`SERVES` etc.) | **KEEP** | Identical shape reused, unmodified, across HVAC (Scenario 5) and lighting (Scenario 7) — genuine domain-agnostic reuse. |
| Point + Parameter + qualifier | **KEEP, with a stated guardrail** | Qualifier is only for simultaneous multi-instance readings of one physical act (phases, axes) — **never** a stand-in for "which asset instance" (Scenario 6's cabinets). This rule should be written into the schema's documentation/onboarding UI validation, not left implicit. |
| `component_asset_id` on `AssetPoint` | **REMOVE** (reaffirmed) | No scenario needed it back; `AssetRelationship` fully covers component-scoped binding. |
| Effective-dating on `AssetPoint`/`SpacePoint`/`AssetRelationship`/`AssetSpaceRelationship`/`device_field_mapping` | **KEEP** | Directly exercised by "sensor moved" (2, 3), "AHU re-ducted" (5), "cabinet relocated" (6), "PV inverter added" (9), "member added to virtual total" (10). |
| Effective-dating on `config.parameters`/units | **Still not needed — reaffirmed REMOVE** | No scenario required it. |
| One generalized `cumulative_register_semantics` table for all counters | **SIMPLIFY** | Split into (a) broadened `energy_register_semantics` (covers fuel/thermal energy registers, keeps `flow_interpretation`) and (b) a simpler `counter_rollover_behavior` (no `flow_interpretation`) for true non-energy counters. See Scenario 8. |
| Storage routing keyed on parameter unit/category alone | **REMOVE this assumption — ADD role-based routing** | A VFD-reported power estimate must not route into the energy domain table just because its unit is watts (Scenario 2). Route by the source's `PRIMARY_METER`/`SECONDARY_METER` accounting role, not parameter shape. |
| `config.parameter_routing` (codegen mechanism) | **KEEP** (unchanged from red-team review) | No scenario contradicted the codegen-not-dynamic-SQL correction. |
| `generic_point_measurements`, capped dimensions | **KEEP, unchanged** | No scenario needed more than `parameter_id`/`point_id`/`asset_id`/`space_id`/quality/estimated. |
| `ParameterCalculation`'s input resolution (as originally/red-team specified: implicit "own asset" only) | **MISSING → ADD** `SELF` / `RELATED` / `AGGREGATE_CHILDREN` modes | Required by Scenarios 3, 4, 7, 9, 10 — the single most load-bearing correction from this stress test. |
| `PARTIAL` quality state for partial aggregate rollups | **MISSING → ADD** (small, an additional `quality_code` value, not a new mechanism) | Scenario 4, 10 — a child missing shouldn't force an all-or-nothing `GAP`/`GOOD` choice on a sum over many children. |
| Dynamic tag/asset-type-based virtual grouping | **REMOVE / never adopt** | Scenario 10 — explicit `AssetRelationship` membership is simpler, auditable, and unifies with the plant-rollup mechanism already needed anyway. |
| `asset_nature` (`VIRTUAL`/`PHYSICAL`) flag | **KEEP** | Concretely exercised by Scenario 10, beyond the hypothetical example in the earlier documents. |
| `analytics.asset_space_energy_allocation` | **DEFER** (reaffirmed) | Scenario 5 explicitly confirms the core relationship model is sufficient without it; no scenario forced it in. |
| `analytics.insights` / baseline-as-derived-parameter | **DEFER** (reaffirmed) | Out of this stress test's scope by design; nothing here contradicts the red-team review's deferral. |
| Runtime dynamic SQL for routing | **REMOVE** (reaffirmed) | No scenario changed this conclusion. |
| Formula/expression DSL | **REMOVE** (reaffirmed, strengthened) | Every derived parameter across all 10 scenarios, including the cross-asset ones, is expressible as plain SQL/window functions once `SELF`/`RELATED`/`AGGREGATE_CHILDREN` exist — no DSL was needed even for the plant/virtual rollup cases, which were the scenarios most likely to seem to need one. |

---

## 5. Required corrections

Three corrections to the red-team review's revised model (§19 of that
document), all additive/refining, none requiring a new table beyond what was
already planned:

1. **`config.parameter_calculations.input_parameter_refs`** gains an explicit
   resolution mode per input: `{parameter_id, role, required, resolution_tier,
   traversal: 'SELF' | {relationship_type, direction} | {aggregate_over:
   relationship_type}}`. `SELF` = same asset/subject as the output (the
   default, most common case). A relationship-typed traversal = "read this
   input from the single asset related to me via this relationship type/
   direction" (Scenario 3's pump specific-energy, Scenario 2's motor+VFD
   case). `aggregate_over` = "sum/average this input across every asset
   related to me via this relationship type" (Scenario 4's plant COP,
   Scenario 10's virtual HVAC Total — the same mechanism, unified).
2. A derived value computed via `aggregate_over` gains a `PARTIAL` quality
   state (alongside the existing worst-wins `GOOD`/`ESTIMATED`/`GAP`/
   `INVALID` lattice) for "some but not all contributing children had valid
   data for this interval" — distinct from a full `GAP`.
3. **Split the red-team review's proposed `cumulative_register_semantics`**:
   (a) broaden `config.energy_register_semantics.flow_interpretation` to
   include fuel/thermal energy registers (gas, steam, thermal-BTU meters —
   still energy accounting, stays in the energy-specific table); (b) add a
   separate, simpler `config.counter_rollover_behavior(profile_id,
   logical_point_id, counter_direction, rollover_behavior, rollover_value,
   reset_behavior, expected_max_interval_delta)` — no `flow_interpretation`
   column — for genuinely non-energy monotonic counters (runtime hours,
   start counts, pulse totals).
4. **Add an explicit routing rule**: a point routes into an energy-domain
   measurement table (or the fuel-register variant from correction 3) **only
   if it is reached through an `asset_devices` relationship of type
   `PRIMARY_METER`/`SECONDARY_METER` to a device of category "Energy
   Meter"/"Gas Meter"/etc.** A point with an energy-shaped unit (watts,
   kWh) reached through any other path (a VFD's own diagnostic report, a PLC
   estimate) routes into `asset_health`/`generic_point_measurements` instead,
   however "power-like" its unit looks. This is a rule addition to
   `config.parameter_routing`'s resolution logic (§10 of the red-team
   review), not a new table.

None of these four corrections change the entity list from the red-team
review's §19.B — they refine `ParameterCalculation`'s internals and the
routing rule's resolution logic.

---

## 6. Final architecture-freeze recommendation

### MINOR CORRECTIONS

The architecture handles all ten scenarios — across electrical metering,
motor/VFD condition monitoring, pump systems, a multi-asset chiller plant,
AHU-to-multi-room service, a multi-cabinet refrigeration rack, lighting, a
fuel-burning boiler, solar/battery/grid accounting, and a virtual rollup —
cleanly, using the same five core concepts (`Asset`, `AssetRelationship`,
`AssetSpaceRelationship`, `Point`+`Parameter`, `ParameterCalculation`)
throughout, with **zero new entity types** required anywhere in this stress
test. No scenario broke the model or exposed a fundamental gap. The four
corrections in §5 are real and should be folded into the architecture before
implementation planning begins — they are refinements to one already-planned
mechanism (`ParameterCalculation`'s input resolution) and one already-planned
generalization (register semantics) that was found to be slightly too broad,
not new machinery.

### The "Simple Architecture" test, answered directly

> If we ignored the current database implementation entirely and designed the
> EMS from scratch based only on these ten scenarios, would we arrive at
> essentially the same architecture?

**Mostly yes — with three specific places where the existing implementation's
gravity had pulled earlier drafts slightly off a from-scratch design, all
three now corrected in this document:**

1. **`component_asset_id` on `asset_points`** — this existed in the original
   proposal because it echoed a column-adding instinct natural to someone
   looking at the existing (dormant) `asset_points` table, not because any
   real scenario needed it. A from-scratch design, working only from the
   scenarios, would reach `AssetRelationship`-based component modeling
   directly and never propose a redundant column. **Already removed** (red-
   team review, reaffirmed here).
2. **A single generalized `cumulative_register_semantics` table** — this
   came from over-indexing on "reuse the existing `energy_register_semantics`
   pattern" as a reflex, rather than asking what non-energy counters actually
   need. A from-scratch design would notice immediately (as Scenario 8 forced
   this document to notice) that "flow direction" is meaningless for a
   runtime-hours counter and would never have merged the two. **Corrected in
   §5.3.**
3. **The instinct to ask whether Site needs its own subject-binding table**
   — this concern only arose from pattern-matching against `asset_points`/
   `space_points` existing as tables at all; a from-scratch design would
   never invent a binding table for a column (`site_id`) that's already
   present on every row. **Resolved (rejected) in §3, cross-scenario finding
   #1 and the recurring-theme note.**

**Does the difference affect core architecture, or only migration/
compatibility?** All three are **core-conceptual corrections**, not
migration-only concerns — but all three make the model **simpler**, not more
complex, and none requires reworking anything else already planned for the
Foundation stage. This is the intended outcome: the smallest coherent set of
concepts, arrived at by pressure rather than by reuse-for-its-own-sake.

### Explicit list of concepts that should NOT be added

- A generalized polymorphic Subject supertype.
- A Site-level subject-binding table (`site_points`).
- `System`/`Plant`/`Zone`/`Process`/`Equipment Group` as new entity types
  (all are Assets, or plain groupings of Spaces, when actually needed).
- A dynamic tag/asset-type-based virtual-grouping mechanism.
- `component_asset_id` on `asset_points`.
- One single cumulative-register-semantics table spanning both energy and
  non-energy counters without a flow/non-flow split.
- Runtime dynamic SQL for telemetry routing.
- A general-purpose formula/expression DSL for derived parameters.
- `EnergyAllocation`/attribution modeling in the core (Foundation-stage)
  schema.
- A rich Baseline/Anomaly/Insight schema beyond the thin
  derived-parameter-reuse-plus-narrow-event-log already recommended.
- Effective-dating on `config.parameters`/`engineering_units` themselves.
- Lighting-, refrigeration-, or boiler-specific entities of any kind — every
  domain tested reused the same five core concepts without exception.

---

🤖 Generated with [Claude Code](https://claude.com/claude-code)
