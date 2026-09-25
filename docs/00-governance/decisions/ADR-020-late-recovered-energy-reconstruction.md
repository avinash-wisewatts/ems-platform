# ADR-020: Late/Recovered Energy — Measured Totals, Reconstructed Timing

Status: Decided (product + architecture). **PR1 foundations deployed to
staging** (migration 268, PR #79, 2026-09-25: inert columns, pure
allocation functions, switch seeded OFF). **PR2 read-side hardening
implemented** (migration 269; not merged, not deployed). PR3–PR6 not
implemented. Nothing in production.
Date: 2026-09-25
Decision owners: Product + Architecture
Related: [ADR-018](ADR-018-asset-point-assignment-and-commissioning.md)
(`asset_points` attribution; commissioning backfill),
[ADR-019](ADR-019-analytical-backbone-time-basis-and-tiers.md) (UTC tiers;
point-telemetry 15m/1h), migration 218 (uncommissioned telemetry is
recoverable), migration 267 (bounded routing window end).

## Context

Established read-only on staging (2026-09-24/25):

- Only the routing loaders (jobs 1001 energy, 1012 environment) write
  `telemetry.energy_measurements` / `environment_measurements`. They select
  rows by `platform_received_at` from their checkpoint. Rows that reach
  `telemetry.normalized_points` with an older `platform_received_at` — job
  1077 replays of recovered failures (original receipt time preserved), and
  late normalizations with no failure record at all — are never routed.
  Nothing re-routes them.
- COIMBATORE, 2026-08-28: 16 energy meters had minute-level readings from
  12:14 IST normalized 16.7–41.5 h late (6 RECOVERED messages plus 183
  messages with no failure record or a PERMANENT_FAILURE record). None were
  routed. Energy history for those meters starts 22:02–23:55 IST.
- The only place a cumulative register becomes consumption is
  `analytics.refresh_energy_consumption_1min` / `_5min`. A delta whose
  elapsed time exceeds the gap threshold is classified `GAP`, is valid, and
  the whole delta lands in the single bucket that closes the gap. Existing
  2-day sample: 208 GAP rows, 608 interior minutes, ~0.9% of energy.
- The 1-min reconcile never recomputes a successor bucket whose predecessor
  changed; a predecessor with a NULL register makes the next bucket
  `INITIAL` (energy dropped).
- Register delta validity is guarded by `config.energy_register_semantics.
  expected_max_interval_delta` (1,000,000 Wh per native interval, a
  "conservative profile-level maximum plausible interval delta").

## Decision (product rules, approved)

1. Every valid Energy data point from a valid meter must ultimately be
   reflected in Energy history — including data that arrives late, is
   recovered after a processing failure, or was generated before Asset
   commissioning — within the retained historical window.
2. Recovered/late valid telemetry is never discarded merely because it
   missed the normal routing path.
3. When cumulative-meter data establishes energy consumed across a gap:
   include the full measured register delta; distribute it across the gap's
   native slots guided by in-gap `ACTIVE_POWER_TOTAL` where available and by
   elapsed time otherwise; never concentrate a multi-slot delta into one
   later bucket; never imply more timing precision than the telemetry
   supports; the allocation sums **exactly** to the measured delta.
4. UI distinction: the Energy **total** is measured by the meter; the
   **timing** of recovered energy is reconstructed. Disclosed in the
   existing Data quality / information area (wording not final).
5. The existing 1,000,000 Wh plausibility limit stays unchanged and is
   **not** scaled by gap length. A delta above it stays `IMPLAUSIBLE_DELTA`.
6. Reconstructed rows contribute to Energy totals but never inflate
   measured coverage and are never reported as GOOD/measured.
7. Historical repair never refreshes beyond the retained raw Energy
   measurement boundary, recomputes through the next valid register (no
   double counting), and takes the same advisory locks as the forward
   Energy jobs.

## Allocation rule (implemented in PR1 as pure functions)

For one gap of n native slots (slot n = the gap-end bucket):

- `analytics.energy_gap_weights(power[])`: in-gap per-slot average active
  power (W), NULL/NaN/Infinity = no reading, negative clamped to 0. No usable
  power → `TIME_WEIGHTED` (all 1); every slot covered → `ACTIVE_POWER`;
  otherwise `MIXED` (uncovered slots get the covered mean). Power from
  outside the gap is never used.
- `analytics.allocate_energy_delta(delta, weights, scale = 3)`:
  cumulative-difference rounding, `C_k = LEAST(round(delta·W_k/W_n, scale),
  delta)`, `C_n = delta`, `share_k = C_k − C_{k−1}`. Exact sum, no negative
  share, deterministic, n = 1 unchanged.

## Delivery (small, independently testable PRs)

| PR | Migration | Scope |
|---|---|---|
| **PR1 Foundations** | **268** | Per-direction reconstruction columns on `energy_consumption_1min/5min` (defaults only; CHECKs NOT VALID); pure `energy_gap_weights` / `allocate_energy_delta`; `config.energy_reconstruction_scope` + `config.energy_reconstruction_enabled()` seeded GLOBAL OFF. **Inert.** |
| PR2 Read-side hardening | 269 | Rollup/reporting views, persisted 15m/hourly/daily, 15-min reconcile and the canonical read exclude reconstructed rows from measured counters and report them distinctly. Behavior-neutral while no reconstructed rows exist. |
| PR3 Consumption engine | 270 | New 1min/5min refresh: per-direction non-NULL predecessor, recompute through the next valid register, gap allocation — behind the switch (OFF). Removes the migration-268 exclusion in `assert_energy_consumption_calculated_at_value_aware.sh`. |
| PR4 API/UI disclosure | 271 | Additive evidence/typical-reference/canonical-read columns; "Reconstructed timing" evidence row and disclosures; CSV. |
| PR5a Routing refactor | 272 | Shared energy routing transformation; body-equality postconditions. |
| PR5b Repair infrastructure | 273 | Repair queue, processor (retention guard, locks, CAgg refresh, span recompute, explicit cascade), detectors — all unscheduled. |
| PR6 Activation | 274 | Only after a COIMBATORE canary and explicit authorization. |

Migrations 249 and 253–263 (uncommitted ADR-018 work) keep their numbers and
land separately. PR2 (migration 269) was built on the deployed
(PRIMARY_METER) `get_canonical_energy_read` because 263 has not landed;
**263 must be rebased onto the migration-269 body before it lands** (a
tripwire test fails otherwise).

## PR1 status (migration 268)

- Columns (both native tiers): `is_reconstructed` (NOT NULL DEFAULT FALSE),
  `import_/export_reconstruction_role` (`GAP_END` | `INTERIOR`),
  `import_/export_reconstruction_method` (`TIME_WEIGHTED` | `ACTIVE_POWER` |
  `MIXED`), `import_/export_gap_start`, `import_/export_gap_end`,
  `import_/export_gap_delta_wh`. Per direction because import and export are
  classified independently and export stays time-weighted until the
  exported-power sign convention is verified.
- CHECK constraints are NOT VALID (every pre-existing row holds defaults;
  avoids a ~277 MB validation scan under the migration lock on staging) and
  are enforced for all new rows.
- Nothing reads or writes the new objects. No reconstructed row exists. No
  job registered or changed. The migration-216 column-completeness guard
  carries an explicit, PR3-scoped exclusion for these columns plus an
  inverse assertion that no refresh function references them yet.

## PR2 status (migration 269) — read-side row contract

Implemented, not deployed. Every Energy read layer now distinguishes
reconstructed timing; with no reconstructed rows (the switch is OFF) every
pre-existing output is identical (golden-tested against the exact pre-269
chain).

- **Measured interval**: `is_measured_interval = NOT is_reconstructed OR
  COALESCE(source_sample_count, 0) > 0`. PR3 writes a *synthetic* row
  (reconstructed, `source_sample_count = 0`, NULL registers) only for a gap
  slot with no measurement. Per direction, `*_reconstruction_role =
  'INTERIOR'` is not a measurement of that direction; `GAP_END` rows are
  measured and keep quality code `GAP`.
- **Measured-only**: `source_interval_count`, `valid_*`/`invalid_*`
  intervals, gap/reset/rollover/invalid counts, register first/last, quality
  code arrays and first/last native bucket (rollups); the canonical read's
  native counters and coverage.
- **Totals include reconstructed energy**; new counters
  `reconstructed_interval_count`, `*_reconstructed_intervals`,
  `*_reconstructed_wh/_kwh` on the rollup/reporting views and (NOT NULL
  DEFAULT 0) on `energy_consumption_15min/hourly/daily`, written and compared
  by their refresh functions (no `calculated_at` churn).
- **Status** `RECONSTRUCTED_TIMING` (internal code; never GOOD). Priority
  INVALID_INTERVALS > RESET_DETECTED > GAPS_DETECTED > RECONSTRUCTED_TIMING >
  ROLLOVER_DETECTED > GOOD — rollup, reporting hourly/daily, every
  canonical-read tier, and the legacy `v_asset_hierarchy_rollup_daily`
  (via a counter carried through `v_energy_consumption_daily` /
  `v_asset_consumption_daily`).
- **Reconcile**: `reconcile_energy_deficits` 15-minute branch counts measured
  native rows only; hourly/daily reconciles already compare persisted sums.
- Unchanged: 1min/5min refresh, jobs, portal site Energy read functions and
  alert materiality (they read the corrected persisted counters/totals).

## Open decisions (before the named PR)

- PR4: customer wording for reconstructed timing; whether the Grafana
  asset-overview panel (plots only `GOOD`, so it hides `GAP` and
  `RECONSTRUCTED_TIMING` energy) shows reconstructed energy. The internal
  status code and priority above were chosen in PR2 and can be revisited.
- PR3: confirm export stays time-weighted.
- Historical recompute of existing ordinary GAP rows (distribution-only).
- Demand/alert re-evaluation for repaired periods (out of scope unless
  decided).
- COIMBATORE canary must run before the 2026-08-28 rows leave the 90-day
  `normalized_points` / `energy_measurements` retention (~2026-11-26).

## Consequences

- Energy totals become complete for late/recovered data within retention;
  timing inside gaps becomes an explicit, disclosed reconstruction.
- Reconstruction is switchable per device/site/global, enabling a single-
  device canary.
- No change to the plausibility guard, Demand, routing identity, or the
  correction deadline.
