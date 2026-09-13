# Terminology

Status: CURRENT · Last reviewed: 2026-09-13 · Owner: Product
Source of truth: `ems-product-definition.md` §8, Workshop Q86

The customer EMS uses the words in the left column. The platform-internal
term is shown only to keep engineers oriented — it is **never shown to
customers** (product principle 2, [product-definition.md](product-definition.md) §7).

| Customer term | Meaning | Platform-internal (not shown to customers) |
|---|---|---|
| **Organisation** / **Portfolio** | The tenant; the set of sites a customer owns | `metadata.organizations` / `organization_id` |
| **Site** / **Facility** | A physical facility | `metadata.sites` |
| **Space** / **Area** | A room / zone within a site | `metadata.spaces` (Building → Floor → Space) |
| **Asset** / **Equipment** / **System** | A piece of equipment or a composite of equipment | `metadata.assets` (`asset_nature: PHYSICAL \| VIRTUAL`) |
| **Measurement** / **Reading** | A single value at a point in time, in context | a row in a domain measurement table |
| **Parameter** | The *meaning* of a measurement ("Temperature", "Active Power") | `config.parameters` (via `logical_points.parameter_id` + `qualifier`) |
| **Consumption** | Energy used over a period (kWh) | `analytics.energy_consumption_*` (1min/5min/15min/hourly/daily) |
| **Demand** | Rate of energy use over an interval; **peak demand** = the maximum | `demand_intervals` / `demand_state` |
| **Cost** | Money, from tariff × consumption/demand | `config.tariffs` / `analytics.cost_values` — **not built yet** (verified: no such table exists) |
| **Comfort** / **Environment** | Temperature, humidity, dew point, CO₂, etc. for a space | `telemetry.environment_measurements` |
| **Performance** | Derived, comparative view of how well an asset/site is doing vs. expected | `parameter_calculations` / `analytics.derived_parameter_values` |
| **Data quality** | `GOOD / GAP / ESTIMATED / INVALID / PARTIAL` on a reading or series | `quality_code`, `is_estimated` |
| **Functional category** | A meaningful grouping of meters/assets (HVAC, Lighting, Process) | Open — no home in the frozen model yet (gap PA-2) |
| **Running hours** | Hours an asset was running | Derived — **not built yet** (`LATER`) |

## Units (Workshop Q86)

Customer/business-facing terminology and units, not internal engineering
vocabulary: Energy → kWh/MWh; Demand → kW/kVA; Power Factor → PF; Power
Quality → PF/THD; Cost → ₹ where applicable. Technical concepts get concise
plain-language explanations where necessary.

## Evidence classification vocabulary (distinct — do not confuse the two)

The workshop introduced a second, unrelated vocabulary for classifying the
basis of a product *output* (a claim, alert, or recommendation the product
makes to a customer) — not for describing UI terms:

| Class | Meaning | Example |
|---|---|---|
| **MEASURED** | Directly supported by available telemetry/data | "Consumption increased 14%." |
| **ESTIMATED** | Calculated from available information using a stated methodology | "≈₹42,000 additional cost based on the configured tariff." |
| **INFERRED** | Derived from observed patterns/context | "The increase appears associated with extended HVAC operation." |
| **PREDICTED** | Forward-looking, model-based | "If the pattern continues, next month's cost may increase by ≈X." |

This is distinct from, and must not be confused with, this documentation
set's own evidence-labelling tags (`[ZEROWATT-OBSERVED]`, `[INFERRED]`,
`[WISEWATTS-DECISION]`, `[ARCH-CONSTRAINT]`, `[OPEN]`) used throughout the
archived v0.1 product documents to mark provenance of a *documentation
statement* — the workshop's vocabulary marks provenance of a *product
output*. Reconciling the two, if needed, remains an open item (Workshop
§52).
