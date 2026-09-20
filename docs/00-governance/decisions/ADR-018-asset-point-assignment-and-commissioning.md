# ADR-018: Asset ↔ Data Point Assignment and the Commissioning Gate for Analytics

Status: Decided (product/architecture); not implemented. Amended 2026-09-20
(same day) to separate Device Commissioning from Asset Commissioning — see
"Amendment" section below; the amendment refines decision 3 and clarifies
decision 9, it does not reverse any decision in this record.
Date: 2026-09-20
Decision owners: Product + Architecture
Related requirements: Not established in available source material — this
decision did not originate from the Q1–Q101 Product Owner Workshop baseline.
It originated from a dedicated Analytics requirements-gap investigation (the
EMS Web App Analytics page work) and a subsequent read-only architecture
investigation of the telemetry pipeline, both conducted this session.
Related features: EMS Web App Analytics page (currently in requirements-gap
phase; the PDF requirements document driving that work is a temporary,
uncommitted development artifact per that workstream's own handling rules,
not a repository document — it is described here in prose, not linked).

## Context

The Analytics page requirements call for determining, per asset, which
semantic data points are available for charting. The naive approach — ask
"what can this asset's wired meter report" — was evaluated and rejected.
Investigation (this session, read-only, against `origin/staging`) established
that the platform already has a purpose-built model for the correct
question ("what has actually been assigned to this asset"), but that model
is unpopulated and unused by any live code path:

- `metadata.asset_points(asset_id, device_id, logical_point_id,
  organization_id, point_role, effective_from, effective_to,
  effective_range)` is the intended, effective-dated, constraint-enforced
  binding of a semantic point to an Asset. **Verified on staging: 0 rows.**
  No seed or migration has ever inserted into it (migration 224's own header
  comment states this explicitly).
- The catalogue actually driving today's Grafana asset-point selector
  (`analytics.v_grafana_asset_point_selector`) is derived instead from
  `metadata.assets → metadata.asset_devices → metadata.devices →
  config.device_point_configuration (is_enabled) → metadata.logical_points`
  — i.e., from device wiring and device-model capability, never from
  `asset_points`. This view must not be treated as authoritative for
  Analytics.
- Telemetry is attributed to an asset today via a `BEFORE INSERT` trigger,
  `telemetry.set_energy_measurement_asset_id()` → `telemetry.
  resolve_primary_asset_id(device_id, organization_id, site_id)`, which
  resolves purely through `metadata.asset_devices.relationship_type =
  'PRIMARY_METER'`. **Verified on staging**: an asset with
  `lifecycle_status = 'DRAFT'` ("Chiller1") already had 2,799 rows of
  attributed energy telemetry in a 2-day window — proving asset history is
  accumulating today independent of any commissioning state.
- A genuine commissioning-readiness model already exists —
  `metadata.assets.lifecycle_status` (DRAFT/COMMISSIONING/ACTIVE/
  DECOMMISSIONED), `metadata.assets.metering_requirement`, and
  `analytics.v_commissioning_readiness` (`is_ready`,
  `blocking_reason_codes`) — and a real, permission-gated, audited Admin
  Portal action, `admin.commission_asset()` (`POST
  /administration/assets/{asset_id}/commission`), already flips
  `lifecycle_status` to `ACTIVE` only when `v_commissioning_readiness.
  is_ready` is true. **This existing action never touches
  `metadata.asset_points`.** The readiness/commissioning system and the
  telemetry-attribution system are both real and both mature, but they do
  not communicate.
- The authoritative architecture source for the intended model is `docs/DDS/
  analytics-platform-future-state-architecture.md` §B.3 ("Points vs.
  Parameters vs. Subjects — the core answer"), which states the intended
  chain as `Device → Point → Parameter → Subject (asset_points/space_points)
  → stored observation → analytics`, and explicitly directs: "**Revive**
  `metadata.asset_points`... **as the live mechanism**." Migrations 224
  (effective-dating + no-overlap exclusion) and 228 (re-keyed to
  `(device_id, logical_point_id)`, composite FK into `config.
  device_point_configuration`, so a binding can only ever target a point
  the device is actually configured to produce) implement the schema for
  this, but explicitly deferred population to "a separately-authorized
  commissioning step" that has never been built.

## Decision

**Decided product behavior** (not yet implemented — see Consequences):

1. **Analytics data-point availability is authoritative from
   `metadata.asset_points`, not from device/meter capability.** Analytics
   must never derive an asset's available data points from the device
   model/profile's theoretical capability, an "Eniscope family" or other
   source-technology grouping, or the current Grafana asset-point selector
   view. The semantic measurement model (`config.parameters`, `metadata.
   logical_points`) remains generic and source-agnostic; Eniscope (or any
   other meter brand) is a source technology behind that model, never the
   customer-facing vocabulary.
2. **`metadata.asset_points` is confirmed as the intended, sole,
   authoritative asset↔point relationship** for this purpose. No second,
   Analytics-specific assignment mechanism is to be built (§11 below).
3. **Commissioning model: Automatic initial candidate assignment + Admin
   adjustment ("Option C").** When commissioning an asset, the system
   proposes the wired device's currently-configured points as candidates;
   an Admin must confirm or adjust which of those candidates actually
   belong to the asset before they become authoritative.
4. **Pre-commissioning telemetry stays device-level.** Telemetry received
   before an asset's points are confirmed may be retained (as device-level
   history), but must not automatically become asset history merely
   because a device happens to be wired to the asset.
5. **Initial commissioning backfill is scoped to confirmed points only.**
   When an asset is first commissioned, retained historical telemetry is
   backfilled into asset history **only** for the points actually
   confirmed as assigned — never for every point the underlying device
   happens to support. Worked example (as decided): a device with 30
   configured points, of which commissioning confirms 18 for Asset A → the
   18 confirmed points are eligible for historical backfill into Asset A's
   history; the other 12 remain device-level data, never becoming Asset A
   history.
6. **Adding a point later does not backfill.** If a point is assigned to an
   already-active (already-commissioned) asset after the fact, its history
   for that asset starts at the assignment time — its prior device-level
   telemetry is not backfilled. This is intentionally different from rule 5
   (initial commissioning), which does backfill.
7. **Moving a point between assets is an explicit Admin Portal operation**
   ("Move Sensor / Data Point"): close the current `asset_points` binding
   (asset A) at the move time, open a new one (asset B) from the move time
   forward. Asset A retains all history accumulated while the binding was
   open; Asset B receives no historical data from before the move; future
   telemetry follows the new binding.
8. **Historical attribution is immutable once written.** Removing or moving
   an assignment affects only future attribution. Data already attributed
   to an asset as history remains attributed to that asset — assignment
   changes never rewrite past Analytics results.
9. **Device onboarding and asset commissioning are distinct.** Device
   profile/configuration (`config.device_point_configuration.is_enabled`)
   governs what a device is technically capable of reporting; asset
   commissioning (`metadata.assets.lifecycle_status`, `metering_
   requirement`, `analytics.v_commissioning_readiness`, `admin.
   commission_asset()`) governs whether an asset is ready to be treated as
   a first-class analytical subject. **Current verified behavior is an
   acknowledged architectural gap, not desired product behavior**: today,
   `metadata.asset_devices.relationship_type = 'PRIMARY_METER'` alone
   causes telemetry to receive an asset_id via `telemetry.
   resolve_primary_asset_id()`, regardless of `lifecycle_status` — including
   while an asset is `DRAFT`.
10. **Preserve the layered architecture; do not collapse concepts.** The
    intended (and, short of the gate in item 9, largely already-built)
    chain is: `Device telemetry → normalized/device-level history →
    confirmed asset assignment (asset_points) → asset history → Analytics`.
    Device-level telemetry and asset history are different concepts and
    must remain queryable/reasoned-about separately.
11. **The Analytics availability model is exactly the second layer.**
    `Platform semantic catalogue` (`config.parameters`/`metadata.
    logical_points`) defines what the platform *understands*.
    `Asset-point assignment` (`metadata.asset_points`) defines what
    measurements actually *belong to* an asset. `Telemetry` determines
    whether/when data *exists* for an assigned point. Analytics reads
    availability from the second layer exclusively; it does not build a
    parallel assignment mechanism of its own.

**Verified current implementation** (distinct from the above — this is what
exists today, not what is decided to be built):

- `metadata.asset_points`: schema present (effective-dated, FK-constrained
  to `config.device_point_configuration`), **0 rows on staging**, no
  Admin Portal read or write path anywhere in `app/src`.
- Telemetry attribution (`telemetry.resolve_primary_asset_id()`) uses
  `asset_devices`/`PRIMARY_METER` only, with no `lifecycle_status` or
  `asset_points` check — the gap named in decision 9.
- `analytics.v_asset_consumption_daily` (and, by the same pattern, the
  sibling `v_asset_*` rollup views) independently re-derives asset
  attribution the same ungated way at the aggregate layer.
- A real commissioning-readiness/gate mechanism already exists and is
  already Admin-Portal-visible (`assets.html`, via `list_accessible_
  commissioning_readiness` → `admin.list_accessible_commissioning_
  readiness()` → `analytics.v_commissioning_readiness`), and a real,
  audited "commission" action (`admin.commission_asset()`) already exists
  and already gates on `is_ready` — but it only flips `lifecycle_status`,
  never touches `asset_points`.
- A mature device↔asset relationship-management workflow already exists
  (assign device to asset, edit relationship metadata, **replace primary
  meter with a required reason**, remove relationship) — operating at the
  device-wiring level, not the point level. The "replace primary meter"
  action is useful existing precedent for the shape of a future "Move
  Sensor / Data Point" operation (decision 7), but is not that operation.

**Future implementation requirements** (explicitly not designed or built by
this ADR — recorded as scope, not as a design):

- A mechanism that generates candidate point assignments from a device's
  configured points at commissioning time (decision 3).
- An Admin Portal read/write surface for `metadata.asset_points`: view
  confirmed points, confirm/reject candidates, add/remove assignments, and
  the explicit "Move Sensor / Data Point" operation (decision 7) — none of
  this exists today.
- A backfill mechanism triggered specifically at initial commissioning
  confirmation, scoped to confirmed points only (decision 5), distinct from
  the no-backfill behavior for points added later (decision 6).
- A decision — deliberately **not** made by this ADR — about which
  architectural seam enforces the commissioning gate: at `telemetry.
  resolve_primary_asset_id()` itself (gating what is ever written), or at
  the `analytics.v_asset_*` rollup layer (gating only what Analytics is
  allowed to read, leaving raw device-level persistence unchanged). See
  Consequences.

## Rationale

The "Automatic initial candidate + Admin adjustment" model (decision 3)
avoids the two rejected extremes: pure-manual assignment before any usable
data exists would make commissioning a heavy, error-prone, ground-up survey
task even when a device's configured points are a very likely correct
starting set; pure-automatic assignment (i.e., today's de facto behavior)
is exactly the failure mode this ADR exists to close, since it made a
`DRAFT` asset accumulate real analytical history. Candidate-then-confirm
gives a fast default while keeping a human decision as the thing that
actually makes data authoritative.

The asymmetry between initial-commissioning backfill (decision 5, backfills)
and later point additions (decision 6, does not backfill) reflects that
initial commissioning is confirming an already-known, already-flowing
device's identity against an asset for the first time — the retained
device-level history is legitimately that asset's history from the moment
the wiring was real. A point added to an *already-active* asset later is a
distinct event (a new sensor, a corrected mapping, expanded scope) whose
prior device-level data was never evaluated against that asset and should
not be silently promoted.

Immutability of historical attribution (decision 8) follows directly from
migration 224's own stated rationale for effective-dating `asset_points` in
the first place: re-pointing a binding must not "silently rewrite the
meaning of every historical reading it ever produced."

Reusing the second layer as Analytics' sole availability model (decision 11)
follows ADR-007's existing principle that the Analytics API is the single
semantic boundary — inventing a parallel assignment mechanism would create
exactly the kind of duplicated semantic authority ADR-007 already rejects
for the read path.

## Alternatives considered

Not established in available source material as formally evaluated
alternatives for decisions 4–11. For decision 3 specifically, the two
implicit alternatives — pure-manual assignment, and pure-automatic
assignment (today's status quo) — are named above in Rationale as the
bounds "Option C" was chosen between; no other named option (e.g., a
third-party commissioning workflow, a bulk-import mechanism) was evaluated
in this session.

## Consequences

- Until implemented, the architectural gap named in decision 9 remains
  live: telemetry continues to be attributed to assets purely via
  `PRIMARY_METER` wiring, with no commissioning gate, exactly as verified
  on staging.
- The Analytics page cannot correctly answer "what data points are
  available for this asset" until `metadata.asset_points` is populated
  through some version of the mechanism in decision 3 — this is a hard
  blocking dependency for that workstream, not a nice-to-have.
- The **seam decision** (raw-persistence gate vs. Analytics-read-layer gate,
  noted under Future implementation requirements) has different
  consequences: gating at `resolve_primary_asset_id()` changes what is ever
  written to `energy_measurements.asset_id` for an uncommissioned asset;
  gating at the `v_asset_*` rollup layer leaves raw persistence unchanged
  (recoverable later) but changes only what Analytics is allowed to
  surface. This ADR does not choose between them.
- No code, schema, or data was changed by this ADR. `metadata.asset_points`
  remains empty on staging as of this decision.

## Evidence / references

- `docs/DDS/analytics-platform-future-state-architecture.md` §B.3 (Points
  vs. Parameters vs. Subjects).
- `postgres/migrations/224_asset_space_point_temporal_binding.sql` (
  effective-dating, no-overlap exclusion, explicit "zero rows... until a
  separately-authorized commissioning step" note).
- `postgres/migrations/228_device_specific_asset_space_point_binding.sql`
  (re-keying to device-specific Point identity, composite FK into `config.
  device_point_configuration`).
- Staging (`origin/staging`-deployed image `28038ac...`, verified via
  `docker inspect`), read-only, this session:
  `metadata.asset_points` row count (0); `pg_get_functiondef` for
  `telemetry.load_normalized_points_incremental`,
  `telemetry.load_energy_measurements_incremental`,
  `telemetry.set_energy_measurement_asset_id`,
  `telemetry.resolve_primary_asset_id`, `admin.commission_asset`;
  `pg_get_viewdef` for `analytics.v_grafana_asset_point_selector`,
  `analytics.v_asset_consumption_daily`, `analytics.v_commissioning_
  readiness`; the "Chiller1" `DRAFT`-lifecycle asset with 2,799 attributed
  `energy_measurements` rows in a 2-day window.
- `app/src/asset_management_service.py` (`commission_asset`,
  `list_accessible_commissioning_readiness`); `app/src/main.py` (asset
  administration routes: create/edit/update/commission, device-relationship
  assign/replace-primary-meter/remove, `render_asset_administration`).

## Implementation references

Not established — no implementation exists yet for decisions 3, 5, 6, 7, or
the seam decision under Future implementation requirements.

## Validation references

Not established — no implementation exists yet to validate.

---

## Amendment 1 (2026-09-20): Device Commissioning / Asset Commissioning Model

This amendment refines decision 3 above by splitting "commissioning" into
two distinct concepts — **Device Commissioning** and **Asset Commissioning**
— and records a read-only verification of the device side against the
actual repository and staging implementation. It supersedes no earlier
decision; where it adds nuance the original decision did not have (device
commissioning's conditional coupling to asset assignment, and the
normalization-vs-readiness ordering below), that nuance is called out
explicitly as a **verified correction**, not folded silently into the
original text.

### New agreed product/architecture model

**Device Commissioning is automatic.** A device is considered commissioned
when the platform has sufficient information to reliably interpret its
telemetry: device identity/UUID is established, a device profile/model is
attached, and point mappings are available so telemetry can be normalized.
Device commissioning is an ingestion/capability concern. It does not mean
the device's points belong to an asset — a commissioned device may exist
before it is assigned to any asset.

**Asset Commissioning is explicit.** An asset starts `DRAFT`/
`COMMISSIONING`. The platform automatically presents candidate data points
based on the commissioned device's configuration. An authorised Admin
reviews the candidates, confirms which points actually belong to the asset,
may adjust the selection, and explicitly commissions the asset. Asset
commissioning is a semantic-ownership decision, not a device-wiring
decision — this is the same "Automatic initial candidate + Admin
adjustment" model as decision 3 above, now stated with Device Commissioning
named as the separate, prior stage that produces the candidates.

**Asset commissioning establishes asset-history eligibility** exactly as
decisions 3, 5, and 8 above already state: on success, confirmed
asset↔point assignments become authoritative, the asset becomes `ACTIVE`,
retained historical telemetry for confirmed points only may be backfilled,
future telemetry for confirmed points becomes asset history, and unassigned
device points remain device-level telemetry indefinitely. Initial
commissioning vs. later assignment vs. removal vs. move follow decisions
4/5/6/7/8 unchanged.

**Layering preserved:** `Device capability → Device-level telemetry →
Asset-point assignment → Asset history → Analytics`, with device capability,
the platform semantic vocabulary, asset-point assignment, and telemetry
availability kept as four distinct concepts, per decision 10.

**Reuse, no parallel system:** the existing device profile/mapping
infrastructure, `metadata.asset_points`, its effective-dating, `admin.
commission_asset()`, `analytics.v_commissioning_readiness`, the existing
Admin asset/device relationship management, and the existing audit/
permission patterns are all to be reused. No parallel commissioning system
is to be built for Analytics (restates decision 11).

### Verification against the repository and staging (read-only)

Performed against `origin/staging`'s deployed database (function/view
bodies read via `pg_get_functiondef`/`pg_get_viewdef`; no writes) and the
repository's `postgres/ddl`/`app/src` source.

- **Device identity/UUID**: established by `metadata.device_identifiers`
  (`identifier_type = 'MQTT_UID'`, matched case-insensitively) resolving to
  `metadata.devices.id`, joined through `metadata.gateways` for `site_id`.
  Verified in `telemetry.load_normalized_points_incremental()`'s deployed
  body.
- **Device profile**: `metadata.devices.profile_id` (FK to `config.
  device_profiles`). The normalization loader's only device-level gate is
  `d.profile_id IS NOT NULL` — confirmed by direct inspection of its body.
- **Point mappings for normalization**: `config.profile_field_mapping`
  (profile-level; `mapping_source = 'DEVICE_PROFILE'`) unioned with
  `metadata.device_field_mapping` (device-level override;
  `mapping_source = 'DEVICE_OVERRIDE'`), each additionally requiring a
  matching `config.device_point_configuration` row with `is_enabled = true`
  for that exact `(device_id, logical_point_id)`.
- **Is there an explicit device-commissioning state/action, or only a
  conceptual one? Verified correction to the proposed model: it is
  explicit, not conceptual.** `admin.commission_device(actor, device_id)`
  is a real, deployed, permission-gated (`device.manage`), audited
  (`admin.onboarding_audit`) function, wired to a live Admin Portal route
  (`app/src/main.py:3252`, `commission_device_administration`). It sets
  `metadata.devices.lifecycle_status = 'ACTIVE'` only when
  `analytics.v_commissioning_readiness` (`entity_type = 'DEVICE'`) reports
  `is_ready = true`. Sibling `admin.commission_gateway()` exists
  identically for gateways. Both confirmed present as deployed functions on
  staging (`pg_proc` lookup), not merely defined in the repository.
- **What device readiness actually requires** (from
  `analytics.v_commissioning_readiness`'s `device_readiness` CTE,
  `postgres/ddl/97_device_commissioning_action.sql`, confirmed matching the
  deployed view): `gateway_id`, `device_model_id`, and `profile_id` all set;
  the device's profile compatible with its model's category
  (`config.device_profile_categories`); **every one of the profile's
  `is_required` points already has at least one validated row in
  `telemetry.normalized_points`** (58 of 70 `profile_field_mapping` rows
  are `is_required` on staging — a real, non-trivial check); and, **only
  when `metadata.devices.operational_policy = 'ASSET_ASSIGNED'`**, at least
  one `metadata.asset_devices` row already exists for the device. The
  policy is real and consequential on staging: 55 of 59 devices are
  `ASSET_ASSIGNED`, 4 are `STANDALONE`.
- **What must be true before `telemetry.load_normalized_points_incremental()`
  can normalize a device's telemetry — verified precisely, and it is
  narrower than "commissioned"**: only `profile_id IS NOT NULL`, an
  applicable `config.telemetry_capture_policies` row, and at least one
  enabled `(device_id, logical_point_id)` mapping. **`lifecycle_status` is
  never checked; `admin.commission_device()` having been called is never
  checked.** Normalization runs regardless of whether the device has ever
  been through the explicit commission action.

### Gap between the current implementation and the new agreed model

Two distinct, previously-unstated gaps, found only by this verification —
recorded so the current system is not read as already implementing the new
model:

1. **Ordering is inverted from what "commissioning gates normalization"
   would imply.** The proposed model's summary — "UUID + profile + point
   mappings → device commissioned → telemetry can be normalized" — reads as
   a gate: commission, then normalize. The verified reality is the reverse
   for the *required*-point check: `admin.commission_device()`'s own
   readiness condition requires that normalization has **already**
   produced validated data for every required point. Explicit device
   commissioning is therefore best understood as a **confirmatory audit
   action** — proof that ingestion is genuinely working — not a
   prerequisite gate that must occur before normalization is allowed to
   run. Normalization itself is gated only by the narrower, purely
   structural condition (§ above), which has no formal "commissioned"
   flag at all.
2. **Device commissioning is not always independent of asset assignment.**
   The new agreed model states a device "may exist before it is assigned to
   an asset" without qualification. Verified: this is true only for
   `STANDALONE`-policy devices. For `ASSET_ASSIGNED`-policy devices — the
   large majority on staging (55 of 59) — `admin.commission_device()`
   cannot succeed until at least one `metadata.asset_devices` relationship
   already exists. The two commissioning concepts are cleanly separable in
   the schema's *intent* (device readiness never inspects `metadata.
   asset_points`, and asset commissioning's own readiness never inspects
   device `lifecycle_status`), but are not unconditionally decoupled in
   practice for most devices today.
3. **Restates, precisely, the gap already on record (decision 9 / original
   Context)**: none of the above — `lifecycle_status` on either device or
   asset, `admin.commission_device()`, `admin.commission_asset()`, or
   `analytics.v_commissioning_readiness` — has any effect on
   `telemetry.resolve_primary_asset_id()`, which still attributes telemetry
   to an asset purely via `asset_devices.relationship_type =
   'PRIMARY_METER'`. This amendment does not change that finding; it only
   sharpens the device-side half of the picture around it. **Superseded in
   part by Amendment 3 below**: Amendment 3 decides to remove
   `PRIMARY_METER`'s special status entirely, which changes how this
   finding's replacement mechanism must work — see Amendment 3.

No code, schema, configuration, or data was changed in the course of this
verification.

---

## Amendment 2 (2026-09-20): Many-to-Many Asset ↔ Device Association

This amendment records a further product/architecture decision and its
read-only verification: Device Commissioning must be independent of asset
association, and Asset ↔ Device is many-to-many, not 1:1 — one asset may be
associated with multiple devices, and one device may be associated with
multiple assets (e.g., Device X's Active Power L1/L2/L3 assigned to Asset A
while its Voltage L1/L2/L3 is assigned to Asset B; Asset C associated with
Devices X, Y, and Z). `metadata.asset_devices` answers "which devices are
potentially relevant to this asset"; `metadata.asset_points` answers "which
specific measurements actually belong to this asset." Associating a device
with an asset must not auto-assign all of that device's points — device
points become candidates for Admin review, per Amendment 1's model.
`metadata.asset_points` remains the sole authoritative source for Analytics
availability (restates decision 2/11 — no change).

> **Note, updated by Amendment 4 (final)**: this Amendment 2 originally
> treated `PRIMARY_METER`'s `ASSET_AND_DEVICE_UNIQUE` exclusivity as a
> deliberate, unaffected reservation (see the verification below) — that
> framing is **correct and final**: Amendment 3 briefly proposed removing
> it, but Amendment 4 supersedes Amendment 3 and retains it exactly as
> described here. The cardinality findings below (base cardinality, the
> `exclusivity_policy` mechanism, the absence of a hidden 1:1 assumption
> elsewhere) all stand as verified, current fact — no schema change. The one
> genuine correction, which survives from Amendment 3 into Amendment 4 for
> a *different* reason, concerns the closing claim that `telemetry.
> resolve_primary_asset_id()` "is unaffected and remains correct": that
> claim was about the *schema constraint* (still true) but glossed over the
> *attribution logic built on top of it* — using the resolved device to
> auto-write `energy_measurements.asset_id`, and by extension treat that
> telemetry as asset history. That was always the original architectural
> gap this ADR exists to close (Amendment 1, decision 9), independent of
> whether `PRIMARY_METER` keeps its exclusivity or not. See Amendment 4's
> telemetry-attribution entry.

### Verification: does the schema already support this? Yes — deliberately.

Verified against staging (`\d metadata.asset_devices`, plus the deployed
bodies of every trigger/function it names):

- **Base cardinality**: `UNIQUE(asset_id, device_id, relationship_type)` is
  the only constraint on the triple itself — it permits one asset to hold
  many devices and one device to serve many assets, for any
  `relationship_type`, including the *same* device and asset pair under
  *different* types simultaneously (e.g., `PRIMARY_METER` and
  `TEMPERATURE_SENSOR` on the same asset/device pair).
- **`PRIMARY_METER` alone is hard-constrained to strict 1:1 in both
  directions**, by two partial unique indexes:
  `UNIQUE(asset_id) WHERE relationship_type='PRIMARY_METER'` and
  `UNIQUE(device_id) WHERE relationship_type='PRIMARY_METER'` (each present
  twice, under two different constraint names — a pre-existing, harmless
  duplication, not a change made here). One asset can have at most one
  `PRIMARY_METER` device; one device can be `PRIMARY_METER` for at most one
  asset. **(Historical framing — see the note above: Amendment 3 removes
  this reservation as a target-architecture decision. The constraint itself
  is unchanged on staging as of this writing.)**
- **This is a deliberate, named, generalized policy, not a coincidence of
  `PRIMARY_METER`'s own special-casing.** `config.asset_device_relationship_
  types.exclusivity_policy` carries exactly two values on staging:
  `PRIMARY_METER → ASSET_AND_DEVICE_UNIQUE`; every one of the other eight
  types (`SECONDARY_METER`, `TEMPERATURE_SENSOR`, `PRESSURE_SENSOR`,
  `FLOW_SENSOR`, `VIBRATION_SENSOR`, `RUN_STATUS`, `FAULT_STATUS`,
  `STATUS_INPUT`) → `NON_EXCLUSIVE`. `SECONDARY_METER`'s own description
  ("Additional energy meter associated with an asset") already matches the
  target model's "associated device that contributes candidate points"
  concept precisely. This confirms the target many-to-many model needs **no
  schema change** for any relationship type other than `PRIMARY_METER`
  itself — which Amendment 3 addresses directly.
- **No hidden 1:1 assumption elsewhere.** `metadata.assert_asset_device_
  relationship()` (the trigger body backing every insert/update) checks
  only tenant/site consistency, relationship-type/device-category
  compatibility, and the `PRIMARY_METER`-must-be-an-Energy-Meter rule — no
  additional cardinality restriction. `admin.assign_device_to_asset()` is a
  thin, permission-checked pass-through `INSERT`, relying entirely on the
  above constraints (its own exception handler names the `PRIMARY_METER`
  uniqueness case explicitly, confirming it was designed with this
  cardinality in mind). `app/src/templates/asset_detail.html` already
  renders relationships as a list (`{% for r in relationships %}`), each
  independently editable/removable, with a repeatable "Assign device" form
  — no singular-device UI assumption exists.
- **`telemetry.resolve_primary_asset_id()`'s own SQL is unaffected and
  remains correct** — `PRIMARY_METER` keeps its exclusivity (Amendment 4),
  so its `... LIMIT 1` stays deterministic, exactly as originally stated
  here. **What still needs to change, per Amendment 4, is not this
  resolver's device-lookup logic but what the trigger does with the
  result** — auto-writing `energy_measurements.asset_id` (and thereby
  treating that telemetry as asset history) from a bare device-wiring fact,
  rather than from a confirmed `asset_points` assignment. See Amendment 4's
  telemetry-attribution entry (Class B, for that reason specifically).

### Part 2 — `ASSET_ASSIGNED` operational policy

`config.device_operational_policies` has two codes: `STANDALONE` ("may be
commissioned without an asset relationship") and `ASSET_ASSIGNED`
("requires at least one valid asset relationship before commissioning").
Verified enforcement, in exactly one place, duplicated in two callers: the
`device_readiness` CTE inside `analytics.v_commissioning_readiness`
(`postgres/ddl/97_device_commissioning_action.sql`) blocks a device's
`is_ready`/marks it `BLOCKED` when `operational_policy = 'ASSET_ASSIGNED'
AND NOT EXISTS (SELECT 1 FROM metadata.asset_devices ad WHERE ad.device_id
= d.id)` — note this check accepts **any** `relationship_type`, not
specifically `PRIMARY_METER`. `admin.commission_device()` enforces the same
condition indirectly, by requiring that view's `is_ready = true`. On
staging, 55 of 59 devices are `ASSET_ASSIGNED`; 4 are `STANDALONE`.

**What would have to change conceptually for device commissioning to no
longer require an asset relationship** (identified, not implemented): the
`operational_policy = 'ASSET_ASSIGNED'` branch of `device_readiness`'s
blocking condition would need to be removed or the policy itself retired/
redefaulted to `STANDALONE` platform-wide, since it is currently the sole
mechanism coupling device commissioning to asset association. Nothing else
in the verified pipeline (normalization, `resolve_primary_asset_id()`,
`asset_points`) depends on `operational_policy` at all — the coupling is
isolated to this one readiness branch and the two functions that read it.

### Part 3 — Candidate-point derivation

Conceptual flow verified against the existing data model:

```
Asset → metadata.asset_devices (ALL relationship_type rows, not only
         PRIMARY_METER)
      → metadata.devices → config.device_point_configuration
         (is_enabled = true)
      → metadata.logical_points (candidate semantic points)
      → Admin reviews/selects
      → metadata.asset_points (authoritative)
```

**The join shape already exists and already spans every relationship
type**: `analytics.v_grafana_asset_point_selector`'s deployed definition
joins `metadata.assets → metadata.asset_devices → metadata.devices →
config.device_point_configuration (is_enabled) → metadata.logical_points`
with **no `relationship_type` filter at all** — it already surfaces
candidate-shaped rows for a device linked via `SECONDARY_METER` or any
sensor type, not only `PRIMARY_METER`. This is directly reusable as the
read-side query pattern for a real candidate-point endpoint/view; what does
not exist is anything that lets an Admin act on those rows to write into
`metadata.asset_points` (confirmed, unchanged from Amendment 1: no
`asset_points` read or write path exists anywhere in `app/src`).

**Resolved.** `metadata.asset_points`'s uniqueness is scoped to
`(device_id, logical_point_id, effective_range)` (migration 228), **not**
`(asset_id, logical_point_id, effective_range)` — deliberately, so "two
different devices may bind the same logical point independently"
(migration 228's own stated rationale). This schema-level permissiveness
is unchanged: multiple identical semantic assignments may still exist in
the general `asset_points` model wherever already permitted. **However,
simultaneous multiple contributing sources for an Asset's canonical
Energy, Power, and Power Quality metrics are not a supported product
state** — each of these canonical metrics has exactly one semantic
measurement set per Asset. A source change for one of these metrics is
handled as replacement, per the already-established historical behavior
(decisions 6/7/8, Amendment 6): the outgoing source retains its
historical attribution; the new source starts from its effective
assignment time; no backfill.

No code, schema, configuration, or data was changed in the course of this
verification.

---

## Amendment 3 (2026-09-20): Decision to Remove `PRIMARY_METER` as a Special Relationship, and Full Impact Trace

> **SUPERSEDED BY AMENDMENT 4 (below), same day.** The decision to remove
> `PRIMARY_METER`'s special status is reversed: `PRIMARY_METER` is
> **retained**, with its existing `ASSET_AND_DEVICE_UNIQUE` 1:1 constraint
> unchanged, meaning specifically "the device designated as the primary
> electrical measurement source for an asset" — not "all of that device's
> points belong to the asset." This section is kept, unedited, as the
> historical record of the investigation that led to the correction —
> **do not treat its "remove PRIMARY_METER" decision as current.** Amendment
> 4 reclassifies every object identified below under the corrected model.

**Decision** (historical — see notice above): `PRIMARY_METER`'s special
status — the `ASSET_AND_DEVICE_UNIQUE`
`exclusivity_policy` and every downstream assumption that a device wired
this way is "the" authoritative source for an asset — is removed. Asset ↔
Device becomes many-to-many with no privileged relationship type; asset
measurement ownership is determined solely by confirmed, source-specific
`metadata.asset_points` assignments (per Amendments 1 and 2). This is a
target-architecture decision; nothing below has been implemented. **This
amendment revises Amendment 2's closing claim about `resolve_primary_
asset_id()`** — see the note inserted there.

### Method

Every deployed function and view on staging whose body text contains
`PRIMARY_METER` was enumerated via `pg_proc`/`pg_views` system-catalog
search (34 objects: 17 functions, 17 views) and read via
`pg_get_functiondef`/`pg_get_viewdef`. The repository was separately grepped
for `PRIMARY_METER` across `app/`, `web/`, and `postgres/migrations/`. No
object was classified from its name alone — every classification below
reflects the object's actual body/usage as read.

### Classification legend

**A** = remove entirely (the reference is incidental — a comment, a legacy
path, or an allow-list entry — no replacement mechanism needed). **B** =
replace with asset-point assignment (the object hard-depends on
`PRIMARY_METER` as its sole resolution mechanism for "the asset's device";
without a replacement it returns nothing / breaks outright). **C** =
represents a legitimate, different concept that needs its own replacement
mechanism (the object doesn't merely stand in for asset-point assignment —
it answers a genuinely different question, such as "which one device should
a live-state tile show" or "does this asset have a qualifying direct
meter," and needs its own redesign, not simply a swap-in of `asset_points`).

### Schema (constraints/indexes)

| Object | Usage | Class |
|---|---|---|
| `asset_devices_primary_meter_asset_uq` / `asset_devices_primary_meter_device_uq` (+ 2 duplicate-named twins) | Partial unique indexes enforcing `ASSET_AND_DEVICE_UNIQUE` | **A** — dropped; `PRIMARY_METER` (if kept as a label at all) becomes `NON_EXCLUSIVE` like the other 8 types |
| `config.asset_device_relationship_types.exclusivity_policy = 'ASSET_AND_DEVICE_UNIQUE'` row | The policy value itself | **A** — reclassify to `NON_EXCLUSIVE`, or retire the code entirely |
| `metadata.assert_asset_device_relationship()` | `PRIMARY_METER`-must-be-an-"Energy Meter"-category check | **A** — this specific rule is removed with the special-casing; the function's tenant/site/category-compatibility checks are otherwise untouched |

### Telemetry ingestion / asset attribution

| Object | Usage | Class |
|---|---|---|
| `telemetry.resolve_primary_asset_id()` | Sole resolution: `asset_devices WHERE relationship_type='PRIMARY_METER' LIMIT 1` | **B** — this is precisely the function Amendment 1 already identified as needing to be replaced by an `asset_points`-driven resolution; this trace confirms it has no other logic to preserve. (Amendment 2 had provisionally read this as unaffected, on the assumption `PRIMARY_METER`'s exclusivity would remain reserved — this amendment reverses that.) |
| `telemetry.set_energy_measurement_asset_id()` trigger | Thin wrapper calling the above | **B** — follows automatically once the resolver changes |

### Analytics / Energy / Demand rollup views (customer & Grafana-facing)

All of the following share **the identical pattern** — a device-scoped
aggregate joined to `analytics.v_asset_devices ... AND relationship_type =
'PRIMARY_METER'` as a **hard filter** — verified individually, not assumed
from one example:

`v_asset_consumption_15min`, `v_asset_consumption_daily`,
`v_asset_consumption_monthly`, `v_asset_demand_15min`,
`v_asset_energy_15min`, `v_asset_hierarchy_rollup_daily`,
`v_asset_load_profile_hour_of_day`, `v_asset_load_profile_hourly`,
`v_asset_peak_demand_daily`, `v_asset_peak_demand_monthly`,
`v_asset_selector`, `v_grafana_asset_electrical_samples`,
`v_grafana_asset_energy_intervals`.

**Class: B for all** — each would return zero rows for every asset the
moment `PRIMARY_METER` loses its uniqueness/meaning, since the join
condition itself disappears. Each needs to be re-pointed at confirmed
`asset_points` assignments for the relevant semantic point(s) instead of a
device-relationship join.

**Customer-facing API functions, same hard-filter pattern, Class B**:

- `analytics.get_portal_asset_power_trend()` — backs the live, recently
  shipped `GET /sites/{id}/assets/{id}/power-trend` endpoint. Its
  `primary_meter` CTE is `WHERE ad.asset_id=p_asset_id AND
  relationship_type='PRIMARY_METER' LIMIT 1`; with no qualifying row, the
  function returns **no data for any asset** — this is a concretely
  identified "would break" case for an already-shipped customer feature,
  not a hypothetical.
- `analytics.get_grafana_asset_electrical_trend()` — same hard-filter
  shape, same break.
- `analytics.resolve_demand_capability()` — its `asset_source` CTE resolves
  an asset's demand-capable device **exclusively** via `relationship_type =
  'PRIMARY_METER'`; its own failure code is literally named
  `'NO_PRIMARY_METER'`. Backs Asset Demand capability resolution. **Class
  B**, and notably the function's *site*-scope path uses a *different*,
  already-generic mechanism (`config.site_energy_meter_roles`) — evidence
  that a non-`PRIMARY_METER` resolution pattern already exists elsewhere in
  the codebase and could inform the asset-scope replacement.
- `analytics.get_canonical_energy_read()` — hard-filters identically; its
  own comment says "Tenant authorization + asset + PRIMARY_METER device +
  gateway + site... with no PRIMARY_METER... collapse to" (i.e., it already
  treats "no PRIMARY_METER" as a valid, handled null-data case, not an
  error) — still **Class B**, but the existing null-handling path is
  reusable scaffolding for "no confirmed point assigned yet."

### A genuinely different pattern — live-state / telemetry-context functions (Class C)

`analytics.get_grafana_asset_live_state()`,
`analytics.get_grafana_asset_telemetry_context()`,
`analytics.get_grafana_asset_connectivity_context()`,
`admin.get_portal_asset_live_state()`, `analytics.v_grafana_energy_samples`,
`analytics.v_grafana_normalized_points` do **not** hard-filter on
`PRIMARY_METER` — they use `CASE WHEN relationship_type='PRIMARY_METER'
THEN 0 ELSE 1 END` purely as an **ordering tie-breaker** when an asset has
more than one associated device, to pick which device's live reading to
show first. **These already tolerate multiple devices per asset today** and
would degrade gracefully (arbitrary-but-stable ordering) rather than break
outright if `PRIMARY_METER` disappeared — but "which single device's live
tile does this asset show" is a genuinely different question from asset-
point assignment (a live tile shows one device's instantaneous reading, not
a confirmed semantic point series), and needs its own replacement
tie-breaker rule, not an automatic swap-in of `asset_points`. **Class C.**

### Commissioning / readiness (Class C)

- `analytics.v_asset_meter_coverage_configuration` — entirely built on
  "does this asset have exactly one `PRIMARY_METER` device categorized as
  an Energy Meter" (`qualifying_direct_meter` CTE). Feeds
  `analytics.v_commissioning_readiness`'s `DIRECT_METER_REQUIRED` branch,
  which in turn gates `admin.commission_asset()`. **Without a replacement,
  every `DIRECT_METER_REQUIRED` asset becomes permanently un-commissionable**
  (`coverage_status` would always read `MISSING_DIRECT_METER`). This is a
  real, legitimate, distinct concept — "does this asset have adequate
  direct metering coverage" — that needs its own `asset_points`-based
  definition (e.g., "has at least one confirmed energy-family point"), not
  a delete. **Class C.**
- `admin.list_accessible_asset_meter_coverage()` — thin wrapper over the
  above; inherits its classification.
- `admin.list_accessible_reconciliation_queue()` — surfaces a dedicated
  `MISSING_PRIMARY_METER` data-quality issue type in the Admin reconciliation
  dashboard. **Class C** — the underlying question ("this asset needs
  metering attention") is legitimate and should be reframed around missing
  `asset_points` confirmation, not deleted.

### Admin UI / API (device-relationship management)

- `admin.replace_asset_primary_meter()` (`POST .../replace-primary-meter`)
  — exists solely to atomically swap a `PRIMARY_METER` relationship under
  its uniqueness constraint. **Class B** — once `PRIMARY_METER` is
  non-exclusive, "replace the primary meter" as a distinct atomic operation
  no longer has a well-defined meaning; it is superseded by the general
  "Move Sensor / Data Point" operation already decided in Amendment 1
  (decision 7), which operates on `asset_points`, not `asset_devices`.
- `admin.remove_asset_device_relationship()` — has one `PRIMARY_METER`-
  specific guard: blocks removing a `PRIMARY_METER` relationship from an
  `ACTIVE`, `DIRECT_METER_REQUIRED` asset. **Class C** — the underlying
  safety intent ("don't silently strip an active asset's only qualifying
  meter") is legitimate and should be re-expressed against confirmed
  `asset_points` coverage, not deleted outright.
- `admin.assign_device_to_asset()` — its `unique_violation` exception
  message explicitly names the `PRIMARY_METER` case. **Class A** — the
  message simply stops being reachable once the unique index is dropped.
- `app/src/templates/asset_detail.html` — renders a `PRIMARY_METER`-only
  "Replace primary meter" form per relationship row. **Class B**, tied
  directly to `replace_asset_primary_meter`'s removal/supersession above.
- `admin.onboard_energy_asset_legacy_upsert()` and
  `admin.validate_onboarding_asset_relationship()` — the "legacy" bulk
  onboarding path re-implements the same `PRIMARY_METER` 1:1 checks in
  application logic (better error messages ahead of the DB constraint:
  `'Device already PRIMARY_METER for asset %'`, `'Asset already has a
  different PRIMARY_METER'`, `PRIMARY_METER_EXISTS`,
  `DEVICE_PRIMARY_METER_ASSIGNED`). **Class C** — named "legacy," so
  whether this path is retired outright or updated is itself a product
  decision (see Remaining Decisions below), not a mechanical replacement.

### Frontend (`web/`)

`web/src/api/types.ts` and `web/src/api/endpoints.ts` mention
`PRIMARY_METER` only in **doc comments** explaining backend behavior for
the Demand/Power-Trend endpoints — no TypeScript type, enum, or runtime
branch depends on the string anywhere in `web/src`. **Class A** — comments
need updating for accuracy once the backend changes; no frontend logic
changes are implied by this decision itself.

### Reports / tests

`PRIMARY_METER` appears across roughly 18 backend contract/regression test
files (e.g., `test_asset_demand_automatic_decoupling_contract.py`,
`test_asset_power_trend_routes.py`, `test_commissioning_readiness_contract.py`,
`test_relationship_management.py`, `test_reconciliation_queue_contract.py`)
and 3 frontend test files (`assetLiveParams.test.ts`, `AssetView.test.tsx`,
`useAssetLiveSocket.test.ts`), plus roughly 20 historical migrations that
built this incrementally (`012_demand_capability_resolution.sql`,
`042_canonical_energy_read.sql`, `097_device_commissioning_action.sql` /
`ddl/97`, `245_analytics_api_asset_demand.sql`,
`246_analytics_api_asset_power_trend.sql`, among others) — not individually
read line-by-line in this pass; listed as evidence that these tests pin
*today's* `PRIMARY_METER`-based behavior as current, correct, expected
behavior, and every one of them will need revision once the resolution
mechanism changes. **Not classified A/B/C individually** — they are tests
of the objects already classified above, not independent architectural
objects.

### Summary — what would break if `PRIMARY_METER` disappeared with no replacement

A live, already-shipped customer endpoint
(`GET /sites/{id}/assets/{id}/power-trend`) would silently return no data
for every asset; Asset-level Demand capability resolution would report
`NO_PRIMARY_METER` for every asset; every asset-level Analytics/Grafana
rollup view (consumption, demand, energy, load-profile, peak-demand,
hierarchy-rollup) would return zero rows; every `DIRECT_METER_REQUIRED`
asset would become permanently un-commissionable via `admin.commission_asset()`;
and the Admin "replace primary meter" action and reconciliation queue's
`MISSING_PRIMARY_METER` issue type would reference a constraint that no
longer exists. None of this is acceptable to ship as a bare removal — every
Class B and Class C item needs its replacement designed before
`PRIMARY_METER`'s special status is actually dropped. This amendment
records the decision and the full trace; it does not authorize or perform
the removal itself.

No code, schema, configuration, or data was changed in the course of this
investigation.

---

## Amendment 4 (2026-09-20): `PRIMARY_METER` Is Retained — Corrected Model and Final Classification

**This amendment supersedes Amendment 3's "remove PRIMARY_METER" decision.**
Amendment 3 is kept above, unedited, as the historical record of the
investigation that led to this correction; its classification table used
different A/B/C definitions than this one and must not be read as current.

### Corrected target model

- **`PRIMARY_METER` is retained**, with its existing schema exactly as-is:
  the `ASSET_AND_DEVICE_UNIQUE` `exclusivity_policy` and its two partial
  unique indexes stay. **No schema change results from this amendment.**
- Its meaning is specifically and narrowly: **the device designated as the
  primary electrical measurement source for an asset.** It is a
  device-level designation, not a claim about which of that device's
  points belong to the asset.
- **It does not mean all data points produced by that device belong to the
  asset.** A device may be an asset's `PRIMARY_METER` and simultaneously
  report dozens of logical points; which of those points are the asset's
  confirmed measurements is answered exclusively by `metadata.asset_points`
  (unchanged from decisions 1/2/11 and Amendment 2).
- Asset ↔ Device **remains many-to-many** exactly as Amendment 2 verified —
  this amendment changes nothing about that finding. `PRIMARY_METER` is
  simply one optional, specially-constrained relationship type among the
  nine; every other type stays `NON_EXCLUSIVE` as already confirmed.
- **Analytics must not infer asset data-point ownership from
  `PRIMARY_METER`.** This is the operative rule driving every
  reclassification below: a function or view that currently treats "device
  X is this asset's `PRIMARY_METER`" as sufficient grounds to present that
  device's readings *as the asset's confirmed measurement history* is
  using `PRIMARY_METER` for a purpose the retained model no longer permits
  it to serve — regardless of how intuitive that shortcut feels for
  inherently electrical metrics like Demand or Energy. Existing
  `PRIMARY_METER` uses that genuinely mean "identify the asset's designated
  electrical source device" (a device-relationship question) are
  unaffected and correct.

### Reclassification — new definitions (distinct from Amendment 3's A/B/C)

**A** = Keep as-is — legitimate primary-meter functionality (answers "which
device is this asset's designated primary electrical source," a
device-relationship question; does not present that device's data as
confirmed asset measurement history). **B** = Keep the underlying
device-designation concept, but change the attribution/ownership logic —
currently uses `PRIMARY_METER` to conclude that data *belongs to* the
asset (asset history, an Analytics series, a confirmed measurement),
which must instead be established via `metadata.asset_points`. **C** =
Remove/replace — `PRIMARY_METER` is being required for something that
should not need a primary meter at all.

Every object is the same one traced in Amendment 3; only the
classification changes.

#### Schema (constraints/indexes) — all Class A, unchanged

`asset_devices_primary_meter_asset_uq`/`_device_uq` (+ duplicates), the
`ASSET_AND_DEVICE_UNIQUE` `exclusivity_policy` row, and
`assert_asset_device_relationship()`'s "a `PRIMARY_METER` must be an Energy
Meter category device" rule are all **exactly the legitimate meaning
retained** — a primary *meter* should indeed be a qualifying energy meter,
and the 1:1 constraint is precisely "one designated primary electrical
source per asset, one asset per meter." No change.

#### Telemetry ingestion / asset attribution — Class B

- `telemetry.resolve_primary_asset_id()` / `telemetry.
  set_energy_measurement_asset_id()` trigger — the device-lookup query
  itself (`asset_devices WHERE relationship_type='PRIMARY_METER' LIMIT 1`)
  is legitimate and stays deterministic (Class-A-shaped on its own). **What
  makes this Class B is what the trigger does with the result**: it
  auto-writes `energy_measurements.asset_id`, which is exactly "inferring
  asset data-point ownership from `PRIMARY_METER`" — the prohibited
  pattern. This is unchanged from Amendment 1's original finding (decision
  9's gap) and is not new to this amendment; retaining `PRIMARY_METER`
  does not resolve it. The replacement attribution logic must consult
  `metadata.asset_points`, gated by asset commissioning, per decisions
  3–9.

#### Analytics / Energy / Demand rollup views and functions — Class B

`v_asset_consumption_15min`, `v_asset_consumption_daily`,
`v_asset_consumption_monthly`, `v_asset_demand_15min`,
`v_asset_energy_15min`, `v_asset_hierarchy_rollup_daily`,
`v_asset_load_profile_hour_of_day`, `v_asset_load_profile_hourly`,
`v_asset_peak_demand_daily`, `v_asset_peak_demand_monthly`,
`v_asset_selector`, `v_grafana_asset_electrical_samples`,
`v_grafana_asset_energy_intervals`, `analytics.get_portal_asset_
power_trend()`, `analytics.get_grafana_asset_electrical_trend()`,
`analytics.get_canonical_energy_read()`, and
`analytics.resolve_demand_capability()` **all currently present a
`PRIMARY_METER` device's readings as the asset's confirmed Analytics
history/capability** — every one of these is exactly the prohibited
inference under the retained model's explicit rule, regardless of
retaining `PRIMARY_METER` itself. **Class B for all**: the device-
designation concept can stay (and may still usefully narrow *which*
device's telemetry to look at once an asset_points assignment names a
point), but the ownership/attribution claim must come from confirmed
`asset_points`, not the `PRIMARY_METER` join alone.

**Flagged tension, not resolved here**: `resolve_demand_capability()` and
the Demand/Energy rollups are the case where this rule is least intuitive
— Demand is inherently a single-device physical reading, and requiring a
*separate* `asset_points` confirmation for, e.g., `ACTIVE_POWER_TOTAL` on
top of an already-designated `PRIMARY_METER` may feel redundant to an
Admin. The model as stated does not carve out an exception, so this
reclassification follows the rule as given — but whether commissioning UX
should auto-suggest/streamline confirming the core electrical-family
points the moment a `PRIMARY_METER` is designated (still requiring
explicit confirmation, per decision 3, just reducing friction) is a real,
open product question. See Remaining Decisions.

#### Live-state / telemetry-context functions — Class A

`analytics.get_grafana_asset_live_state()`,
`analytics.get_grafana_asset_telemetry_context()`,
`analytics.get_grafana_asset_connectivity_context()`,
`admin.get_portal_asset_live_state()`, `analytics.v_grafana_energy_samples`,
`analytics.v_grafana_normalized_points` use `PRIMARY_METER` only as an
ordering preference for **which device's transient, right-now reading** to
show first when an asset has multiple associated devices. This is not an
asset-history/Analytics-series ownership claim — it is exactly "prefer the
designated primary electrical source's live reading," the retained
concept's legitimate use. **No change.**

#### Commissioning / readiness — Class A

- `analytics.v_asset_meter_coverage_configuration` (and its wrapper
  `admin.list_accessible_asset_meter_coverage()`) — asks "has this asset
  been assigned a qualifying `PRIMARY_METER`," a device-relationship
  question, not a point-ownership one. This is precisely the retained,
  legitimate meaning. **No change** — it remains valid to gate
  `DIRECT_METER_REQUIRED` commissioning readiness on "has a designated
  primary electrical source," independent of which specific points are
  later confirmed on `asset_points`.
- `admin.list_accessible_reconciliation_queue()`'s `MISSING_PRIMARY_METER`
  issue — flags an asset with no designated primary electrical source yet.
  Legitimate, unchanged. (A *separate*, additional issue type for "primary
  meter designated but no `asset_points` confirmed yet" would be a new
  capability, not a reclassification of this one — see Remaining
  Decisions.)

#### Admin UI / API (device-relationship management) — Class A

`admin.replace_asset_primary_meter()` (atomically swaps which device is
designated primary meter), `admin.remove_asset_device_relationship()`'s
guard against removing an active asset's only qualifying meter,
`admin.assign_device_to_asset()`'s `PRIMARY_METER`-naming exception
message, `app/src/templates/asset_detail.html`'s "Replace primary meter"
form, and the legacy `admin.onboard_energy_asset_legacy_upsert()` /
`admin.validate_onboarding_asset_relationship()` 1:1 checks are **all
legitimate device-designation management, unchanged** under the retained
model. **Flagged, not resolved**: replacing an asset's `PRIMARY_METER`
device does not itself touch any `metadata.asset_points` rows bound to the
old device — whether "replace primary meter" should prompt an Admin to
also review/re-confirm point assignments tied to the outgoing device is an
open product question (distinct from, but related to, the already-decided
"Move Sensor / Data Point" operation, which moves a *point*, not a
*primary-meter designation*). See Remaining Decisions.

#### Frontend (`web/`) — Class B, editorial only

`web/src/api/types.ts`/`endpoints.ts`'s doc comments describing the Demand/
Power-Trend endpoints as reading "the asset's `PRIMARY_METER` device" will
need updating once those endpoints' backing functions change their
attribution logic (Class B above) — no frontend runtime behavior changes
from this amendment itself.

#### Reports / tests

Only the tests covering the Class-B-reclassified objects (telemetry
attribution, the asset-level Analytics/Grafana rollups, `get_portal_
asset_power_trend`, `resolve_demand_capability`, `get_canonical_energy_
read`) will need revision once their attribution logic changes. Tests
covering Class-A objects (relationship management, meter-coverage
readiness, live-state ordering) are unaffected by this amendment.

### Remaining product/architecture decisions (only what this trace surfaced)

1. **The Demand/Energy tension** (flagged above): should confirming core
   electrical `asset_points` be streamlined/auto-suggested at the moment a
   `PRIMARY_METER` is designated, given the rule requires explicit
   confirmation regardless?
2. **Primary-meter replacement's interaction with `asset_points`**: when an
   Admin replaces an asset's designated `PRIMARY_METER` device, should the
   system prompt for review of any point assignments tied to the outgoing
   device, given they are not automatically migrated? The one-semantic-
   measurement-set-per-Asset rule (Amendment 2's corrected ambiguity
   paragraph) constrains any future design here — a replacement cannot
   result in two simultaneously contributing sources for the same
   canonical metric — but does not by itself resolve whether the
   replacement flow should prompt for point-assignment review.
3. **Whether a distinct "primary meter designated but no points confirmed"
   reconciliation-queue issue type is worth adding**, alongside the
   existing, unchanged `MISSING_PRIMARY_METER` issue.
4. **All decisions already on record and still open**: the seam for the
   commissioning gate itself (Amendment 1's Future Implementation
   Requirements), the same-semantic-point-from-two-devices ambiguity
   (Amendment 2), and the `ASSET_ASSIGNED` operational-policy decoupling
   (Amendment 2, Part 2) — none of these are affected by retaining
   `PRIMARY_METER` and remain exactly as previously recorded.

No code, schema, configuration, or data was changed in the course of this
revision.

---

## Amendment 5 (2026-09-20): Asset Data Point Assignment UX

Decided UX for the Admin Portal surface that manages `metadata.asset_points`
for an asset (the read/write surface named as missing under "Future
implementation requirements" and by decision 3's candidate/confirm model).
Not implemented — decision only.

- **Landing state**: a table of the asset's currently assigned data points
  — columns Data Point, Friendly Name, Device Name, Status, Edit. This
  table **is** the asset's current authoritative `asset_points`
  configuration, displayed, not a draft of it.
- **Empty state**: if no points are assigned, an "Assign Data Points"
  empty-state prompt in place of the table.
- **Edit** opens the assignment flow (the editing interface for that same
  configuration, per decision 3's candidate-generation model):
  1. User selects a device from a dropdown.
  2. That device's available data points are shown grouped by
     measurement/category.
  3. Points already assigned to this asset from that device are pre-checked,
     shown as `Status = Assigned`, with their existing friendly names
     preserved.
  4. The user may uncheck existing points or check additional candidate
     points; friendly names remain editable throughout.
  5. **Multiple identical semantic measurements are permitted** — consistent
     with Amendment 2's finding that `asset_points`' uniqueness is scoped
     per-device, not per-asset, so the same semantic point from two
     different devices can coexist on one asset (that ambiguity is
     unresolved at the data-model level; this UX decision does not resolve
     it either — it simply doesn't prevent the case at entry).
  6. Changes become authoritative only on an explicit save/confirm action —
     no autosave, no implicit commit while reviewing.

No code, schema, configuration, or data was changed in the course of
recording this decision.

---

## Amendment 6 (2026-09-20): Commissioning Trigger and Backfill State Machine

Decided final mechanism for reaching `ACTIVE`, replacing the standalone
admin action described earlier in this record. Not implemented — decision
only.

- **The separate "Commission Asset" user action is removed.** Commissioning
  is no longer a distinct click; it is triggered by the point-assignment
  Save flow (Amendment 5) itself. This supersedes decision 3's and the
  original Context's description of `admin.commission_asset()` as a
  standalone admin-triggered action — its underlying readiness/audit
  pattern remains reusable plumbing, but the user-facing separate action is
  gone.
- **Trigger**: on an asset's first successful data-point assignment Save,
  the system detects that initial commissioning has not yet occurred.
- **State machine**: the asset enters `COMMISSIONING`; an asynchronous
  background job performs the initial historical backfill for the
  confirmed assigned points only (per decision 5), bounded to retained
  telemetry within the **90-day commissioning backfill window** (Amendment
  8) — never for unassigned device points, and never reaching further back
  than 90 days before the assignment/commissioning point. The UI shows
  "Historical Backfill: In Progress" for the duration. The asset becomes `ACTIVE` **only after** the backfill
  completes successfully — `ACTIVE` is now backfill-conditioned, not
  merely readiness-conditioned as originally described.
- **Durable backfill state** (`Pending` / `Running` / `Completed` /
  `Failed`) must be recorded so a failure can be retried safely — new
  infrastructure, not yet built; no such state exists in the repository or
  on staging today.
- **Subsequent changes never backfill**, restating decision 6: later point
  additions, removals, replacements, or friendly-name edits do not trigger
  the backfill job; a newly added point's history starts at its assignment
  time.
- **Historical immutability holds**, restating decision 8: existing asset
  history is never rewritten or deleted by later assignment changes.

No code, schema, configuration, or data was changed in the course of
recording this decision.

---

## Amendment 7 (2026-09-20): Option A — Point-Level Telemetry as the Canonical Attribution Foundation

**Decision.** Option A is chosen: **point-level telemetry —
`telemetry.normalized_points` and appropriate point-level aggregates —
becomes the canonical analytical foundation for asset attribution.**
`metadata.asset_points` remains the authoritative Asset ↔ Device + Logical
Point relationship, including its effective-dated time boundaries
(unchanged from decisions 1/2/11 and Amendments 1–2). Asset attribution
must no longer treat `PRIMARY_METER` as proof that *all* telemetry from
that device belongs to the asset (this operationalizes, at the mechanism
level, the ownership rule already decided in Amendment 4). Initial
commissioning backfill (Amendment 6) resolves **retained point-level
telemetry** through confirmed `asset_points`; subsequent assignments start
from their assignment time and do not backfill (restates decisions 5/6, now
grounded specifically in the point-level mechanism, not a domain-table
rewrite). **The underlying device telemetry is preserved as-is — this
decision does not create a second copy of telemetry merely to establish
asset ownership**; attribution is expressed by resolving through
`asset_points` against the existing point-level record, not by duplicating
data and stamping it with `asset_id`.

**Rationale**, referencing the evidence from the immediately preceding
read-only pipeline trace:

- `telemetry.normalized_points` already carries the exact identity shape
  attribution needs — `(device_id, logical_point_id, event_time,
  numeric_value)` as literal columns, verified directly — with **no
  transformation required** to join it against `asset_points`.
- `analytics.generic_telemetry_15m`/`generic_telemetry_1h` already exist as
  live, actively-populated TimescaleDB continuous aggregates over the same
  `(device_id, logical_point_id)` grain (verified: 575,252 rows in a 2-day
  sample on the 15-minute tier alone), confirming a point-level aggregation
  layer is not hypothetical — it is already running, merely not yet
  load-bearing for customer Analytics (its only current consumer is
  `analytics.get_grafana_explorer_intervals`).
- By contrast, the wide domain tables (`telemetry.energy_measurements`,
  every `telemetry.ca_energy_*` tier) are **already pivoted** — fields like
  `active_power_l1_w` are named columns, not `logical_point_id` rows — so
  they cannot be joined against `asset_points` directly; building
  attribution on the point-level layer instead of on these tables avoids
  requiring an unpivot of already-shipped, high-volume hypertables.
- `analytics.demand_intervals`/`demand_state` demonstrated, in the same
  investigation, that this platform already knows how to physically
  populate `asset_id` from a batch calculation (`analytics.
  refresh_demand_analytics()`) rather than only via a row-level trigger —
  useful existing precedent for how a future point-level-derived asset
  attribution could be materialized where needed, without inventing a new
  mechanism shape from nothing.

**Consequences.**

- Any Analytics capability that reads asset-attributed history must
  ultimately resolve through `asset_points` against point-level telemetry,
  not through a `PRIMARY_METER` device-relationship join — this is the
  mechanism-level consequence of decisions already made (1, 2, 9, 11) and
  Amendment 4's ownership rule.
- Because the wide domain tables cannot be joined directly, satisfying this
  decision for Energy/Demand-shaped data requires either deriving those
  domain shapes from point-level telemetry going forward, or introducing an
  explicit, maintained mapping from each wide-table field to its
  corresponding `logical_point_id` — a design question, not resolved here.
- `PRIMARY_METER` is **not removed and not demoted from every use** —
  consistent with Amendment 4, it remains valid wherever it answers "which
  device is this asset's designated primary electrical source" (device
  designation, a live-state/ordering preference, a candidate-generation
  source per decision 3). It is simply no longer permitted to stand in as
  the *point-attribution* mechanism itself.
- No second copy of telemetry is created. This decision is scoped to how
  attribution is *resolved*, not to duplicating or relocating the
  underlying device data.

**Implementation implications — required impact/migration areas** (not
designed or built here; identified per the investigation's own findings):

1. **Wide `energy_measurements`/`ca_energy_*` tables**: every asset-level
   consumer currently reading these via a `PRIMARY_METER` join (the Class B
   list already recorded in Amendment 3/4: `telemetry.
   resolve_primary_asset_id()`, all `v_asset_consumption_*`, `v_asset_
   energy_15min`, `v_asset_hierarchy_rollup_daily`, `v_asset_load_
   profile_*`, `v_asset_peak_demand_*`, `v_asset_selector`, `v_grafana_
   asset_electrical_samples`, `v_grafana_asset_energy_intervals`,
   `get_portal_asset_power_trend()`, `get_grafana_asset_electrical_
   trend()`, `get_canonical_energy_read()`) needs a redesigned attribution
   path consistent with Option A — the specific mechanism (unpivot vs.
   mapping table vs. deriving these domains fresh from point-level data) is
   an open design question.
2. **Demand (`demand_intervals`/`demand_state`)**: `analytics.
   refresh_demand_analytics()`'s `PRIMARY_METER`-driven asset resolution
   (and its companion `resolve_demand_capability()`) must move to an
   `asset_points`-based resolution; note demand values are themselves
   *calculated* from one or more source points and today do not persist
   which `logical_point_id` fed the calculation — this may need to change
   for the calculation to be `asset_points`-traceable.
3. **Existing asset views/functions/APIs**: the full Class B inventory from
   Amendment 3/4 is the authoritative list of what changes; nothing new is
   added by this amendment beyond `analytics.refresh_demand_analytics()`
   itself (identified as a distinct write-path in the latest investigation,
   not previously itemized separately).
4. **Grafana contracts**: the live-state/ordering-preference functions
   (`get_grafana_asset_live_state()`, `get_grafana_asset_telemetry_
   context()`, `get_grafana_asset_connectivity_context()`, `v_grafana_
   energy_samples`, `v_grafana_normalized_points`) remain Class A under
   Amendment 4 and are not implicated by this decision — they answer "which
   device's live reading to show," not asset-history ownership. Any Grafana
   contract that *does* depend on the Class B objects above inherits their
   redesign.

No code, schema, configuration, or data was changed in the course of
recording this decision.

---

## Amendment 8 (2026-09-21): Initial Asset History Backfill — 90-Day Limit

Decided product rule, closing the retention-vs-attribution question raised
by the preceding read-only retention investigation. Not implemented —
decision only.

- **Initial Asset commissioning backfill is limited to the telemetry
  retention window of 90 days.** When data points are first assigned to an
  asset (initial commissioning, per decisions 3/5 and Amendment 6), the
  system may backfill retained historical telemetry for those confirmed
  points for up to 90 days prior to the assignment/initial-commissioning
  point — never further back.
- **Telemetry older than 90 days is not required to become part of the
  asset's history.** This is an accepted, deliberate limit, not a defect.
- **`telemetry.normalized_points`'s existing 90-day retention policy is not
  extended to support asset attribution.** Verified this session: that
  policy is already exactly 90 days (`timescaledb_information.jobs`); this
  amendment aligns the product rule to the existing policy rather than
  asking the policy to change.
- **Scope is strictly initial-commissioning backfill.** This does not
  change the retention or availability of existing Energy/aggregate data
  (`energy_measurements`, `ca_energy_*`, `energy_consumption_*`) used by
  other platform functions, which keep their own, longer, unrelated
  retention policies (180 days to 5 years, verified this session) for
  whatever they already serve today.
- **Later assignment changes are unaffected**, restating decisions 6/7/8
  and Amendment 6: additions, removals, replacements, and moves never
  backfill regardless of this window; a new assignment's history starts at
  its effective assignment time.

Evidence: the immediately preceding read-only retention investigation
(staging `timescaledb_information.jobs`: `telemetry.normalized_points`
`drop_after: 90 days`, vs. `ca_energy_*`/`energy_consumption_*` tiers at
180 days–5 years).

No code, schema, configuration, retention policy, or data was changed in
the course of recording this decision.

---

## Amendment 9 (2026-09-21): Demand Continuity Across Source Replacement

Decided product rule, closing the mid-interval source-replacement question
this ADR's Amendment 7 (Option A) and the subsequent Demand-specific
migration-design investigation both left open. Not implemented — decision
only.

- **Demand remains continuous at the Asset level.** A source replacement
  (decision 7's "Move Sensor / Data Point," applied to whichever point a
  demand calculation resolves through) does not by itself interrupt an
  asset's Demand history — this restates decision 7/8's historical-
  attribution model, now applied specifically to Demand's own interval-
  spanning calculation, not only to raw point-level series.
- **`ENERGY_COUNTER_DELTA`**: if the source changes within a fixed 15- or
  30-minute demand interval, calculate each source's contribution over its
  own effective portion of that interval, then combine them into the one
  existing reporting interval — never a fresh, shorter interval and never
  two separate reported rows for what the platform's grid treats as one
  interval.
- **`TIME_WEIGHTED_POWER`**: the same treatment — calculate each source's
  portion independently and combine. **Never interpolate between the
  outgoing and incoming meter's readings** — the boundary between the two
  portions is a real discontinuity between two physical devices, not a
  smooth transition to be trapezoidally blended.
- **`METER_NATIVE`**: a source change creates a calculation boundary.
  Native demand values from two different meters are never combined — a
  meter's own internally-computed demand reading has no meaningful
  "portion" to combine with another meter's.
- **Any calculation-method change is always a boundary**, regardless of
  which two methods are involved (e.g. `METER_NATIVE` → `ENERGY_COUNTER_
  DELTA`). The affected fixed-grid interval is treated as unavailable/
  incomplete rather than producing a synthetic hybrid Demand value — no
  blending is ever attempted across a method change, only across a
  same-method source change.
- **"Incomplete" is an internal calculation/quality state, not a
  customer-facing one by default.** The customer-facing API/UI should
  treat such an interval as Demand unavailable for that interval, unless
  an existing UI convention already established elsewhere in the product
  requires different treatment of an internal quality state — this
  amendment does not itself define or change that UI convention.
- **Historical attribution remains effective-time based**, restating
  decisions 6/7/8 once more in this context: the outgoing source retains
  its historical period exactly as calculated for it; the incoming source
  starts at its own effective/assignment time; no backfill occurs before
  that time.

Evidence: the immediately preceding read-only trace of `analytics.
calculate_demand_window()`'s three method branches (each verified to query
exactly one device, `v_cap.source_device_id`, for the whole interval today
— `METER_NATIVE`'s single latest-sample read, `ENERGY_COUNTER_DELTA`'s
single-device bracketed MIN/MAX register delta, `TIME_WEIGHTED_POWER`'s
single-device `LEAD()`-window trapezoidal integration) and of `analytics.
resolve_demand_capability()`'s single-device-per-call resolution shape.

No code, schema, configuration, or data was changed in the course of
recording this decision.

---

## Amendment 10 (2026-09-21): Demand Source-Boundary — Simplified Rule and Implementation

Finalized and implemented. Supersedes Amendment 9's splice-and-combine
design with a strictly simpler rule: **any** Asset device/source change
within a fixed 15/30-minute interval — same method or not — makes that
interval unavailable. No splicing, ever. The affected interval(s) are
Demand unavailable/incomplete; normal calculation resumes automatically
from the next interval fully covered by one stable source. This removes
Amendment 9's method-sameness branching and its `TIME_WEIGHTED_POWER`
boundary-segment-exclusion complexity entirely — the earlier design's
`source_device_id` schema risk is also fully resolved (a row is always
single-device or absent, never two).

**Quality status**: a new, distinct `'SOURCE_BOUNDARY'` value is used —
not a reuse of `'INCOMPLETE'`. Verified this session that `'INCOMPLETE'`
already carries an inconsistent meaning across the two combinable methods
(`ENERGY_COUNTER_DELTA`'s `INCOMPLETE` rows have `demand_kw = NULL`;
`TIME_WEIGHTED_POWER`'s carry a real, non-null value) — reusing it would
add a third, different meaning to an already-ambiguous label.
`demand_intervals.quality_status` has no `CHECK` constraint (verified),
so this costs no schema change either way. Verified the customer-facing
translation layer (`web/src/routes/demand/DemandOverview.tsx`'s
`DEMAND_STATUS_LABELS`/`DEMAND_STATUS_EXPLANATIONS`) has no entry for
`INCOMPLETE` or `VALID` at all and defensively falls through any
unrecognized `quality_status` to "Data unavailable" — `SOURCE_BOUNDARY`
is covered by this existing fallback with zero frontend change required.

**Implemented** (`postgres/migrations/250_demand_asset_points_source_
boundary.sql`): `analytics.resolve_demand_source_for_interval()` (new) —
finds `metadata.asset_points` bindings whose `effective_range` fully
contains the requested interval (a mid-interval change fails containment
on both the outgoing and incoming binding, which alone implements the
whole boundary rule with no separate change-detection logic), resolves
each candidate device via the unchanged `config.resolve_device_demand_
method`, keeps only methods whose required point was actually confirmed
for that device, and returns at most one row using the unchanged 3-tier
priority as a tie-breaker among multiple fully-covering candidates.
`analytics.calculate_demand_window()`: SITE scope untouched; ASSET scope
resolves policy then source via the new function; all three existing
calculation branches copied verbatim, unchanged. `analytics.refresh_
demand_analytics()`: ASSET-scope stale-state cleanup and scope-
enumeration moved from `PRIMARY_METER`/`asset_devices` to an equivalent,
currently-effective `metadata.asset_points` existence check — no other
line changed.

**Clarification, same day (migration 251)**: the governing rule is more
precisely stated as **"Demand uses the highest-priority calculation
method available among the Demand points confirmed for that Asset"** —
asset-point assignment is authoritative for *which method applies*, not
only *which device*. The initial implementation above had a real gap:
`resolve_demand_source_for_interval()` called `config.resolve_device_
demand_method()` once per candidate device, which returns that device's
single *overall* best method by profile capability alone — a device would
be rejected entirely if its top method's point was unconfirmed, even when
a valid, confirmed, lower-priority point existed on the same device.
Fixed by replicating the three method-matching rules (`config.demand_
register_semantics` for `METER_NATIVE`; `config.energy_register_
semantics` + `ENERGY_IMPORT_TOTAL`/`APPARENT_ENERGY_TOTAL` for `ENERGY_
COUNTER_DELTA`; `ACTIVE_POWER_TOTAL`/`APPARENT_POWER_TOTAL` for `TIME_
WEIGHTED_POWER`) evaluated directly against each confirmed `asset_points`
binding, applying the unchanged 3-tier priority only among the resulting
confirmed matches. `config.resolve_device_demand_method()` itself remains
unmodified and is no longer called by this function. The source-boundary
containment rule, `calculate_demand_window()`, and `refresh_demand_
analytics()` are all unaffected.

No code, schema, configuration, or data was changed in the course of
recording this decision.
