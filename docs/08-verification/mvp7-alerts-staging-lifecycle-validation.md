# MVP-7 Basic Alerts — Staging Lifecycle Validation Record (Part 1: Qualification → Active; Part 2: Resolution — BLOCKED)

Status: CURRENT · Last reviewed: 2026-09-14 · Owner: Engineering
Related feature: [Alerts](../07-features/alerts/README.md)
Related decisions: [ADR-016](../00-governance/decisions/ADR-016-q77-mvp7-basic-alerts.md), [ADR-017](../00-governance/decisions/ADR-017-mvp7-alert-architecture.md)

## What was validated

**Deployed revision:** `a533773ae4e84a2cfc6b78267e900ab973e83c83` (PR #61,
migration 241's transaction-control fix). Job 1127 explicitly authorized
and re-enabled 2026-09-14 ~22:36 IST.

**Result: Part 1 (qualification → Active) PASS, using real (not
manufactured) staging data. Part 2 (Active → Resolved) BLOCKED by
staging data — see below; not manufactured, per explicit instruction.**
Recurrence, data-gap, configuration-transition, retention, and UI
validation are explicitly NOT covered here (see "What this record does
not establish").

## What this record covers

All evidence below is from direct, read-only queries against staging
(`ssh ems-staging` → `docker compose exec timescaledb psql`), no
application code/migration/configuration change, and no manufactured or
forced alert condition — the two evaluated sites' real Energy Attention
state independently reached and stayed material.

### Candidates identified (prior session turn, before qualification completed)

Before this turn began, `analytics.alert_evaluation_candidates` held
exactly 2 `WATCHING_TRIGGER` rows (confirmed in the immediately preceding
session turn, after job re-enablement and 3 successful evaluation runs),
and `analytics.alerts` held 0 rows at that time — i.e., **no
customer-visible alert existed while qualification was in progress**,
confirmed live, not inferred.

### Qualification → Active transition (this turn)

By the time this turn's first query ran, `analytics.alert_evaluation_candidates`
was empty (0 rows) and `analytics.alerts` held exactly 2 `ACTIVE` rows —
i.e., both candidates naturally completed their 5-minute continuous
qualification window and were promoted to Active alerts entirely by the
running job's own scheduled evaluations, with no intervention this
session. The before/after states (2 candidates + 0 alerts, then later 0
candidates + 2 alerts) are each independently confirmed live; the
minute-by-minute intermediate polling of the qualification countdown
itself was not captured (real time elapsed on other work between the two
session turns) — see "What this record does not establish."

### Persisted alert fields (both rows, verified directly against `analytics.alerts` + `metadata.sites`)

| Field | Alert `ca27924a…` | Alert `ce923e9e…` |
|---|---|---|
| `state` | `ACTIVE` | `ACTIVE` |
| `condition_key` | `ENERGY_ATTENTION:PERCENT_DEVIATION_FROM_TYPICAL_REFERENCE:15:SITE:513296cc-...` | `ENERGY_ATTENTION:PERCENT_DEVIATION_FROM_TYPICAL_REFERENCE:15:SITE:870af241-...` |
| `metric` | `ENERGY_CONSUMPTION` | `ENERGY_CONSUMPTION` |
| Site (hierarchy context, joined) | `Unit 2` | `Coimbatore` |
| `space_id` / `asset_id` | `NULL` / `NULL` | `NULL` / `NULL` |
| `triggered_at` | `2026-09-14 22:36:40.786557+05:30` | `2026-09-14 22:36:40.786557+05:30` |
| `trigger_value` | `1.94344661` | `4766.436637` |
| `resolved_at` / `resolved_value` | `NULL` / `NULL` | `NULL` / `NULL` |
| `ended_at` / `ended_reason` | `NULL` / `NULL` | `NULL` / `NULL` |
| `previous_occurrence_count` (derived, same query `get_portal_site_alerts` uses) | `0` | `0` |
| `most_recent_previous_triggered_at` | `NULL` (correctly omitted at count 0) | `NULL` |

Threshold/reference: both `condition_key`s embed `15` (the ADR-010/
ADR-017 single-sourced ±15% threshold) — matches contract; the raw table
does not additionally persist a separate reference/typical value (the
frontend derives the threshold display from `condition_key`, per
`web/src/routes/alerts/AlertsArea.tsx`'s `thresholdReferenceLabel`,
already covered by existing unit tests). `space_id`/`asset_id` both
`NULL` confirms Site-level-only scope (ADR-016/ADR-017 Space/Asset
reconciliation) — no false Space/Asset alerting.

### Duplicate suppression (verified live, forward-looking, across 3 additional evaluation cycles after the alerts already existed)

| Check time (`last_evaluated_at`) | Total `analytics.alerts` rows | Active rows per site+condition |
|---|---|---|
| `22:49:04.190532+05:30` | 2 | 1 each |
| `22:51:04.192643+05:30` | 2 (same `alert_id`s, `triggered_at` unchanged) | 1 each |

`SELECT COUNT(*) FROM analytics.alerts` stayed at exactly 2 across
multiple additional 1-minute evaluation cycles while both underlying
conditions remained continuously true — no duplicate row was created for
either site+condition. The DB-level unique index
(`ux_alerts_one_active_per_condition`) is consistent with this
observation but was not itself stress-tested (e.g. concurrent-write race)
in this pass.

### Evaluator execution health across this entire window

`timescaledb_information.job_errors` for job 1127: still exactly 3 rows
throughout this turn — the same pre-fix rows from before migration 241
(21:04–21:06). **Zero new errors** (no `2D000`, no other error) across
qualification, Active-creation, and the subsequent duplicate-suppression
observation window.

## Part 2: Active → Resolved — BLOCKED by staging data (not attempted further)

**Identified**: the same two Active alerts from Part 1
(`ca27924a-d1aa-4312-8810-0b547601e957`, site "Unit 2"; `ce923e9e-e20a-43e6-a2d6-3a36435b900f`,
site "Coimbatore"), confirmed still `ACTIVE`, `resolved_at IS NULL`,
immediately before this part began.

**Directly observed mechanism (not inferred) preventing natural
resolution in a reasonable window**: querying
`analytics.evaluate_energy_attention_materiality(site_id)` live for both
sites returned `is_material = true`, `direction = 'HIGH'`, with
`window_from = 2026-09-13 00:00:00+05:30` / `window_to = 2026-09-14
00:00:00+05:30` for both — i.e. the evaluation is pinned to the single
most-recently-*completed* site-local calendar day ("yesterday"), per
migration 239's documented design (see
[07-features/alerts/README.md](../07-features/alerts/README.md) and
migration 239's header comment). That window is fixed until the next
site-local midnight rollover advances "yesterday" by one day — it cannot
change intraday no matter how many more times the 1-minute job runs
against it, and there is no guarantee the new day's comparison would even
be non-material once it does roll over (a separate, independent
evaluation against that day's own typical reference).

**Confirmed stable, not flapping, over a real observation window**: after
identifying this, waited ~3 further real evaluation cycles (~3 minutes)
and re-confirmed: both alerts still `ACTIVE`, `resolved_at` still `NULL`,
`last_evaluated_at` advancing normally; `analytics.alert_evaluation_candidates`
at 0 rows throughout (no `WATCHING_CLEAR` candidate was ever created,
because the condition never went false to start one);
`timescaledb_information.job_errors` for job 1127 unchanged at 3 rows
(zero new errors).

**Conclusion**: resolution validation is **blocked by the current shape
of real staging data**, not by any implementation defect — the evaluator
is working correctly and consistently; there is simply no naturally
occurring false observation to time a 1-minute clear window from yet.
Per explicit instruction, this was **not** worked around by manufacturing
or forcing a clear condition, waiting out the ~1+ hour to the next
calendar-day rollover (uncertain payoff even then), or altering data.
None of the resolution-specific verification items (resolved_at,
resolution value, trigger-field immutability, latest-value reflection,
duplicate-on-resolution suppression, resolved-alert historical
availability) were exercised — there was no resolution event to check
them against.

## Investigated mechanisms for controlled lifecycle conditions (read-only repository investigation, no execution)

Before proceeding further, the repository was searched for any existing,
safe way to produce a deterministic qualify/clear/data-gap/config-
transition condition on staging. Found:

- **`scripts/test/run_integration_environment.sh` + `assert_*.{sh,sql}`**:
  disposable-database-only (`compose.test.yaml`/`timescaledb-test`/
  `ems_test`), hardcoded in every script checked. Some fixtures insert
  directly into `analytics.energy_consumption_1min`/`15min`
  (bypassing the real pipeline); this pattern has no staging precedent.
- **`scripts/verify/smoke_mqtt_energy.sh` / `smoke_mqtt_environment.sh`**:
  target `compose.yaml` (the same file staging runs) and a real MQTT
  broker via `telegraf/.env` — **staging-capable**, not disposable-only,
  when run from the staging host itself, per this repository's own
  documentation (`docs/08-verification/test-strategy.md`,
  `docs/operations/CICD_PIPELINE.md`: "opt-in only... a dedicated,
  explicitly-authorized broker/credential context"). Goes through the
  real ingestion pipeline (does not bypass it). **Material limitation**:
  it can only add data to *today's* not-yet-closed day; it cannot affect
  the already-fixed "yesterday" window the two current Active alerts are
  evaluated against, and does not itself run/wait for the aggregation
  jobs that would later roll it into `analytics.energy_consumption_daily`.
- **No configuration/debug override for Attention materiality exists
  anywhere** in `app/src` or `postgres/` (searched, zero matches) — the
  ±15% threshold is a hardcoded constant on both the SQL and TypeScript
  sides. Configuration-transition validation has no safe mechanism at
  all, on staging or otherwise — this is a genuine product-surface gap
  (no Admin Portal UI for it), not a fixture-tooling gap.
- **No mechanism found for safely simulating a data-unavailable state**
  on staging without either a service-level action (pausing real
  ingestion — outside this investigation's read-only scope) or
  disposable-DB-only fixture manipulation.

**Conclusion**: no mechanism can *immediately* and *safely* produce a new
qualify/clear transition on staging. The two realistic paths — (a) wait
for the natural next-day rollover and observe the same two real sites'
new "yesterday," or (b) build a dedicated, freshly-commissioned test site
via the real Admin Portal and feed it controlled telemetry via the smoke
scripts across a full day — are each a separate, explicitly-authorized,
non-trivial undertaking, not something available within a single
validation turn. Data-gap and configuration-transition validation remain
blocked pending either new tooling or new product surface.

## Test site commissioning attempt (Avinash Home → Unit 2) and the telemetry-readiness gate

Path (b) above was subsequently pursued: a gateway and Energy Meter device
were commissioned on Avinash Home → Unit 2 via the real Admin Portal
onboarding wizard (not direct database inserts) — `gateway_id
c979158b-d62f-4ff0-8df1-1d745decae1f` ("Test Gateway"), `device_id
fc46288a-4842-472c-bcc5-cf325c0cc2a2` ("Test Energy Meter"), `protocol
MQTT`, `profile_code ENERGY_METER_ENISCOPE_V1` (verified live to match
staging's actual catalog: `device_category_id 34b8f2e4-...` "Energy
Meter", `device_model_id e49dc182-...` "Best Energy / Eniscope Energy
Meter", `gateway_model_id 99d83365-...` "Best Energy / Eniscope 8
Hybrid" — all confirmed compatible via `config.device_profile_categories`
and cross-checked against 54 real staging devices already using this
exact model/profile pairing), `identifier_type MQTT_UID`, `identifier_value
de:ad:be:ef:00:01:02:03` (confirmed fresh/unused before creation). Both
entities exist with `lifecycle_status = REGISTERED` — created, but not
yet commissioned/telemetry-active.

**Read-only investigation, this session, established exactly why they
cannot progress past `REGISTERED` without telemetry — evidenced live,
not inferred**: `analytics.v_commissioning_readiness` (`postgres/ddl/97_device_commissioning_action.sql`,
gateway-connectivity source updated by `postgres/ddl/116_gateway_connectivity_from_assigned_device_telemetry.sql`,
both still current as of `postgres/ddl/122_telemetry_pipeline_performance_state.sql`)
queried live for both entities:

| Entity | `commissioning_status` | `blocking_reason_codes` |
|---|---|---|
| Test Gateway | `BLOCKED` | `{GATEWAY_NEVER_SEEN}` |
| Test Energy Meter | `BLOCKED` | `{REQUIRED_TELEMETRY_POINTS_NOT_VALIDATED}` |

- **Gateway**: `GATEWAY_NEVER_SEEN` clears the moment *any* assigned
  device produces *any* valid `telemetry.normalized_points` row (or a
  `telemetry.device_status` row) — confirmed from
  `analytics.v_gateway_connectivity`'s own header comment: "A gateway is
  considered seen when any assigned device has produced mapped
  telemetry." A single successful smoke-test publish would clear this.
- **Device**: requires **every** `is_required = true` row in
  `config.profile_field_mapping` for `ENERGY_METER_ENISCOPE_V1` to have
  at least one valid, non-rejected `telemetry.normalized_points` row.
  Queried live: **58 required raw fields** (`A1-3, AE, AE1-3, C, D,
  D1-3, E, E1-3, Ex, Ex1-3, F, I, I1-3, In, P, P1-3, PF, PF1-3, Q,
  Q1-3, RE, RE1-3, REx, REx1-3, S, S1-3, U, U1-3, V, V1-3`).
  **`scripts/verify/smoke_mqtt_energy.sh`'s existing default payload
  covers only 27 of these 58** (`C, D, E, F, I, P, Q, S, U, V, P1-3,
  I1-3, V1-3, PF, PF1-3, E1-3, AE`) — it omits `A1-3, AE1-3, D1-3,
  Ex/Ex1-3, In, Q1-3, RE/RE1-3, REx/REx1-3, S1-3, U1-3` (31 fields).
  **Running the existing smoke test unmodified against this device
  would clear the gateway block but NOT the device block.**

**Whether the smoke tooling can safely target this device**: yes,
mechanically — it is a generic script parameterized by `SMOKE_MQTT_TOPIC`/
`SMOKE_DEVICE_UID` env vars, requires no code change to point at a
different device, and would publish additively (no metadata/history
modification, per its own design). It was **not run this session** (no
telemetry was published) — this section is a read-only readiness
investigation only.

**Exact evidence/configuration needed before sending any telemetry**:
either (a) a payload carrying all 58 required raw fields, or (b)
confirmation that the profile's required-field set is intentionally
this broad for a full Eniscope 8-Hybrid multi-circuit meter and a
narrower test is not achievable without a product/config decision on
relaxing `is_required` for fields irrelevant to a synthetic
single-purpose test device (not decided, not pursued). **Update, later
pass**: option (a) has since been implemented in the smoke script
itself (see "Smoke-tooling change" below) — the payload now carries all
58 fields — but telemetry still has **not** been published; execution
remains a separate, not-yet-authorized step.

### Follow-up: complete field-level evidence, and confirmation option (a) is correct

A further read-only pass closed the remaining open questions above,
resolving them in favor of **(a)**, not (b):

- **All 58 fields' full mapping** (`config.profile_field_mapping`,
  queried live) are `data_type='numeric'`, flat top-level JSON keys (no
  `json_path`/`transform_expression`), grouped as: 20 energy fields
  (Wh→kWh, ×0.001), 12 power fields (W/var/VA→kW/kvar/kVA, ×0.001), 8
  voltage fields (V, ×1), 5 current fields (A, ×1), 4 power-factor
  fields (unitless), 3 phase-angle fields (deg), 4 current-THD fields
  (%), 1 frequency field (Hz), 1 pulse-count field.
- **The exact validation rule**, from `postgres/ddl/37_telemetry_normalization_view.sql`'s
  live SQL: a value becomes `quality_code='GOOD'` (the only state
  counted by the commissioning-readiness gate) whenever it matches
  `^[[:space:]]*[+-]?(([0-9]+([.][0-9]*)?)|([.][0-9]+))([eE][+-]?[0-9]+)?[[:space:]]*$`
  — i.e. any well-formed number. No physical-plausibility/range check
  exists at this layer.
- **Real staging proof the full 58-field set is genuine, not a
  theoretical maximum**: the most recent real message from device
  `1d6ca88d-95ed-445d-90bf-653b7f0d837f` (one of the 54 real devices
  already using this profile), read from `telemetry.raw_messages`,
  contains **all 58 required fields in a single message** — confirming
  this is what a real Eniscope 8 Hybrid gateway actually sends, not an
  artificially broad requirement.
- **Conclusion**: option (a) is the correct path — the requirement is
  real (evidenced by real device traffic), so **extending the test
  tooling, not relaxing `is_required`, is warranted.** The minimum
  change (not implemented): add the 31 missing keys to
  `scripts/verify/smoke_mqtt_energy.sh`'s hardcoded payload block, same
  nesting level and validation tolerance as the 27 already present.
- **Remaining unknown, stated explicitly, not guessed away**: only the
  normalization-layer gate (the one `analytics.v_commissioning_readiness`
  actually checks) was audited for validation rules. Downstream stages
  (energy routing, `analytics.energy_consumption_daily` aggregation,
  Attention materiality) were not audited for range/plausibility
  rejection of synthetic values — not claimed safe, simply unverified.

### Complete 58-field mapping (live, `config.profile_field_mapping` / `metadata.logical_points` / `config.engineering_units`)

| raw_field | logical_point | source_unit | canonical_unit | scale |
|---|---|---|---|---|
| A1/A2/A3 | PHASE_ANGLE_L1/L2/L3 | — | deg | 1 |
| AE/AE1/AE2/AE3 | APPARENT_ENERGY_TOTAL/L1/L2/L3 | VAh | kVAh | 0.001 |
| C | PULSE_COUNT | — | count | 1 |
| D/D1/D2/D3 | CURRENT_THD_TOTAL/L1/L2/L3 | — | % | 1 |
| E/E1/E2/E3 | ENERGY_IMPORT_TOTAL/L1/L2/L3 | Wh | kWh | 0.001 |
| Ex/Ex1/Ex2/Ex3 | ENERGY_EXPORT_TOTAL/L1/L2/L3 | Wh | kWh | 0.001 |
| F | FREQUENCY | — | Hz | 1 |
| I/I1/I2/I3 | CURRENT_TOTAL/L1/L2/L3 | — | A | 1 |
| In | CURRENT_NEUTRAL | — | A | 1 |
| P/P1/P2/P3 | ACTIVE_POWER_TOTAL/L1/L2/L3 | W | kW | 0.001 |
| PF/PF1/PF2/PF3 | POWER_FACTOR_TOTAL/L1/L2/L3 | — | (unitless) | 1 |
| Q/Q1/Q2/Q3 | REACTIVE_POWER_TOTAL/L1/L2/L3 | var | kvar | 0.001 |
| RE/RE1/RE2/RE3 | REACTIVE_ENERGY_TOTAL/L1/L2/L3 | varh | kvarh | 0.001 |
| REx/REx1/REx2/REx3 | ENERGY_REACTIVE_EXPORT_TOTAL/L1/L2/L3 | varh | kvarh | 0.001 |
| S/S1/S2/S3 | APPARENT_POWER_TOTAL/L1/L2/L3 | VA | kVA | 0.001 |
| U/U1/U2/U3 | VOLTAGE_LL_AVG/L12/L23/L31 | — | V | 1 |
| V/V1/V2/V3 | VOLTAGE_LN_AVG/L1/L2/L3 | — | V | 1 |

All 58 rows: `data_type='numeric'`, `offset_to_canonical_unit=0`, flat top-level keys (no `json_path`/`transform_expression`). Confirmed live: **0** `is_required=false` rows exist for this profile — there is no optional tier.

### Telegraf topic-scheme mismatch (new finding, this pass)

`telegraf/config/telegraf.conf` (the file `compose.yaml` actually mounts read-only into the `telegraf` service) subscribes only to `wwems/v1/+/+/+/telemetry` and `wwems/v1/+/+/+/+/telemetry`. `scripts/verify/smoke_mqtt_energy.sh`'s default `SMOKE_MQTT_TOPIC` (`testeniscope/chillerroom/chiller`) does **not** match either pattern and would not be ingested at all under the currently deployed config — this had not previously been checked. Live real-gateway traffic uses the 6-segment consolidated form, e.g. `wwems/v1/MEENAXY_PHARMA/UNIT_2/Eniscope_2_Meenaxy_Unit2/telemetry` (confirmed against `metadata.organizations.code`/`metadata.sites.code`, live). For the dummy site the equivalent form is `wwems/v1/AVINASH_HOME_INC/UNIT_2/<gateway-segment>/telemetry` (org code `AVINASH_HOME_INC`, site code `UNIT_2`, both confirmed live). Device/tenant attribution is resolved solely from `payload.rtdata[0].uid` (confirmed by reading `postgres/ddl/37_telemetry_normalization_view.sql`'s `resolved_devices` CTE, which never references topic) — the topic content itself only has to satisfy Telegraf's 6-segment wildcard shape to be ingested at all; it does not affect which device/org/site the data lands on. `scripts/verify/smoke_mqtt_energy.sh` was **not** changed to hardcode this topic — `SMOKE_MQTT_TOPIC` remains the override point, per the script's existing design.

### Downstream-safety audit for the 58 fields (this pass, read-only)

- **38 instantaneous fields** (`P/Q/S` total+phases, `V/U` total+phases, `I` total+phases+`In`, `PF` total+phases, `F`, `A1-3`, `D/D1-3`, `C`): traced through the live `telemetry.v_energy_measurements_full_resolution` view definition (`pg_get_viewdef`, live) — each is a bare `MAX(numeric_value) FILTER (... quality_code = 'GOOD' ...)`. No range/plausibility check of any kind exists at this or any later stage for these fields.
- **20 cumulative-register fields** (`E/E1-3`, `Ex/Ex1-3`, `RE/RE1-3`, `REx/REx1-3`, `AE/AE1-3`): all route through `config.energy_register_semantics` (confirmed all 20 rows exist, `is_active=true`, `counter_direction='INCREASING'`, `reset_behavior='REJECT_DELTA'`, `expected_max_interval_delta` ≈1,000,000–1,500,000 in the register's native Wh/varh/VAh unit) into `analytics.classify_energy_register_delta`. Read directly: when `p_previous_register IS NULL` (true for this device's very first-ever reading on every one of these 20 registers, since it has zero prior `telemetry.energy_measurements` rows) the function returns `'INITIAL'`/`is_valid=FALSE` **unconditionally, before any magnitude check runs** — the chosen literal value cannot trigger `IMPLAUSIBLE_DELTA` on a first reading regardless of size. This makes all 20 fields safe for a single first-time smoke publish. (A future *repeat* run against this same device, if the script keeps these values as static literals, would compute `delta = 0` — `INCREASING` counter, `current == previous` — which classifies as ordinary `'GOOD'`/`is_valid=TRUE`, not implausible; still safe, just not representative of real consumption.)
- **Energy Attention materiality**: unaffected by a single synthetic message — it compares complete site-local calendar-day aggregates, which requires the continuous-aggregate rollups to run over a closed day boundary; one smoke-test point does not by itself produce a daily aggregate.
- **Not audited this pass**: whether any Grafana panel or reporting view applies its own display-side range clamping (out of scope — commissioning readiness and the alert pipeline were the target, not dashboards).

### Smoke-tooling change (implemented, not executed)

`scripts/verify/smoke_mqtt_energy.sh`'s payload now carries all 58 required fields (previously 27/58). The 31 added fields' values were taken directly from a real, currently-active Eniscope device's most recent raw message on this same profile (`telemetry.raw_messages`, live, uid/did masked) rather than invented, per this pass's instruction to prefer real evidence. `SMOKE_MQTT_TOPIC`/`SMOKE_DEVICE_UID` remain the only targeting overrides; no topic was hardcoded into the script. A new static, no-network/no-DB assertion (`scripts/test/assert_smoke_mqtt_energy_payload_completeness.sh`) verifies the payload contains all 58 fields exactly once and that both override variables are still present; it was run locally and passed. **No MQTT message has been published, and no staging or production state was changed, as part of this update** — the script change and the new test are the only artifacts of this pass.

## What this record does not establish

- **The live, minute-by-minute qualification countdown itself.**
  Real time elapsed on unrelated work (documentation, git operations)
  between confirming the 2 candidates existed and confirming they had
  become Active alerts — the record has strong before/after evidence,
  not a continuous timelapse. A future validation pass could confirm
  this more tightly (e.g. by polling `alert_evaluation_candidates` at
  under-1-minute intervals from the moment a candidate first appears).
- **Resolution** (Active → Resolved after 1 continuous minute false) —
  **attempted this session, found BLOCKED by staging data** (see "Part 2"
  above), not simply skipped.
- **Recurrence** beyond the trivial zero-prior-occurrence case (no
  Ended/Resolved alert of either condition has existed yet to recur
  against).
- **Data-gap / recovery behavior (ADR-016 §4).** A later read-only
  investigation traced this precisely, found two real implementation
  gaps against the original ADR-016 §4 text (the required customer
  messaging does not exist at any layer; recovery while the condition is
  still material silently continues the same Active row instead of
  ending it), and found the original §4 text itself ambiguous about the
  required end state. A product decision (2026-09-15) resolved the
  ambiguity — Ended, with a controlled two-cause reason code — recorded
  in ADR-016's §4/§7 amendment and ADR-017's conceptual-data-model
  addition. **Status: IMPLEMENTED and locally tested (migration 242,
  2026-09-15) — NOT YET deployed to staging/production, NOT YET observed
  against real data.** Migration 242 adds the schema
  (`data_unavailable`, `ended_reason_code`), extends
  `analytics.evaluate_alerts()` with the flagging and Ended-transition
  logic, and extends both portal read functions and the frontend. Tests:
  16 static SQL contract assertions, a live-execution lifecycle test
  against a disposable TimescaleDB instance (the full qualify → Active →
  data-unavailable → recovery → Ended → fresh-qualification → new-Active
  sequence, plus a negative/guard scenario), and extended API/frontend
  tests — all passing. The live-execution test caught and fixed a real,
  previously-latent PL/pgSQL defect (a bare `RECORD` variable set to
  `NULL` reverting to "not yet assigned") in the exact pattern migration
  239/241 already used for the configuration-transition branch, never
  triggered before because that branch was unreachable. This remains
  distinct from a staging-data or test-mechanism limitation like the
  resolution/config-transition entries elsewhere in this list — it is now
  fully implemented and locally proven, only staging/production
  deployment and real-data observation remain.
- **Configuration-transition behavior (ADR-016 §8)** — **NOT YET TESTED /
  NOT CURRENTLY TESTABLE**, not merely "not yet validated." A later,
  dedicated read-only investigation traced this precisely: the
  ACTIVE → ENDED configuration-transition logic exists in
  `analytics.evaluate_alerts()` (migration 239) — it compares the Active
  alert's stored `condition_key` against the freshly-evaluated one and, on
  a mismatch, sets `state='ENDED'` — and the simultaneous
  configuration-change-plus-condition-clearing precedence (§8: Ended, not
  Resolved) is structurally implemented, since this check runs
  unconditionally before the resolution path can start. But Attention
  configuration is currently **static/hardcoded** (threshold `15` baked
  into both the SQL and TypeScript source; no config table, Admin Portal
  page, or API exists to change it — confirmed by repository-wide search)
  — so `condition_key` can never actually change for a live site, making
  this branch **unreachable in normal operation today**, exactly as the
  migration's own inline comment states ("Unreachable today... but
  implemented so it is correct the moment a condition's definition ever
  changes"). Existing automated tests (`test_alert_evaluation_contract.py`,
  `test_analytics_api_v1_alerts_routes.py`) confirmed to provide only
  static string-presence / router-level mock-fixture coverage of this
  branch, never executing the actual `condition_key`-diff logic — so there
  is no executable lifecycle test coverage either. Testing this requires
  building a real Attention configuration mechanism first (a product/
  architecture scope addition, not a staging-environment or test-data
  limitation like the resolution blocker above) — not something a safer
  test procedure can work around.
- **Frontend/UI rendering of these real alerts** (list, detail view,
  filters, header indicator) — not exercised this pass; only the
  persisted data and its recurrence-derivation query were checked
  directly against the database.
- **The 30-minute persistence-retry path** (ADR-016 decision 6) — no
  persistence failure occurred to exercise it.
- Whether the ±15% threshold is the right number for these two real
  customer sites — a product judgment outside this pass's scope.

## Production confirmation

This validation was performed against **staging only**. Production was
not accessed, queried, or changed at any point.
