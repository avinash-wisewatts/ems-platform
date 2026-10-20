# Design item: canonical Energy read scans the device's whole native history

Status: PROPOSED (design only; no fix, no migration) · Opened: 2026-10-20 · Owner: Engineering
Verification basis: production read-only diagnosis 2026-10-20 [M]; staging
plan-only `EXPLAIN` 2026-10-20 [M]; migrations 269 and 270 [V]

Evidence labels as in
[production-release-plan-266-301.md](../../09-release-and-deployment/production-release-plan-266-301.md):
[M] measured, [V] verified from code, [E] estimate, [I] inference.

## Problem

`analytics.get_canonical_energy_read` (Grafana `asset-overview`, Asset View
Energy tile; see [aggregation.md](aggregation.md#reading-asset-energy-the-canonical-read-vs-the-persisted-tier-read-migration-279))
aggregates every tier at read time from the raw native rows. For the `1d`
and `1h` resolutions, the requested time range is applied only **after** the
native rows have been rolled up to 15-minute buckets. The scan and the
rollup cover the device's whole retained history, not the requested range.
Read cost therefore grows with history length, up to raw retention. On
staging (verified 2026-09-23, [aggregation.md](aggregation.md)) that is 180
days for `energy_consumption_1min` and 2 years for `energy_consumption_5min`.
Production's retention was not checked for this item.

This predates Release B1. Migration 269 made each aggregated row about 30%
more expensive, which made the effect visible.

## Evidence

### Production, `1d`, 4-day range (2026-10-20, read-only) [M]

Full record: release plan, "B1 execution record" → "Read-path diagnosis".

- Four sample assets; same plan shape before and after 269.
- Chunk scans are bounded by `device_id` only. All 22 chunks of the two
  native hypertables are read; the 1-min table holds 12 chunks,
  2026-07-30 → 10-22.
- For asset `05264ec8` (device `cac37d22`), about 92,600 native rows are
  aggregated into 6,257 15-minute buckets. The join to `metadata.sites`
  then discards 5,923 of them and keeps 334, for 4 days (4 output rows).
  Four days of 1-minute data is about 5,760 rows.
- Time per call, old → new (post-269) chain: execution 204 → 264 ms
  (median of 4).
- Self-time breakdown for `05264ec8`, post-269 (327 ms in total):

  | Stage | Self time |
  |---|---|
  | Native scan | 81 ms |
  | Sort | 108 ms |
  | 15-min aggregate | 102 ms |

  The sort and aggregate run on rows that are thrown away afterwards.
- Planning is not a factor: under 150 ms cold, under 12 ms warm.

### All resolutions on staging (plan-only `EXPLAIN`, no execution) [M]

Staging carries the same 269 view definitions as production. Its function
is migration 270's (Release B2), which adds `device_id = ANY(...)` to every
tier and a `bucket_start` bound to the native tier only. One device; 9
`energy_consumption_1min` chunks, 2026-08-20 → 10-22. "Chunk-scan nodes"
counts plan nodes on `_hyper_*` / `compress_hyper_*` relations. A
compressed chunk can appear as more than one node, so 10 means every
chunk, not 10 chunks.

| Resolution | Predicate as written | Where it lands in the plan | Chunk-scan nodes |
|---|---|---|---|
| native | `n.bucket_start >= … AND < …` | Index condition on `(device_id, bucket_start)`; chunk exclusion | 1 (one chunk) |
| 5m, 15m | `r.bucket_start` (a `date_bin(…)` grouping output) `>= … AND < …` | Row filter `date_bin('15 min', bucket_start, …) >= …` on every chunk scan; rows are dropped before the rollup, but no chunk exclusion and no index range | 10 (all) |
| 1h | `h.bucket_start` (a site-local `date_trunc` of the 15-min rollup) | Join filter after the 15-minute rollup | 10 (all), full history rolled up |
| 1d | `consumption_date AT TIME ZONE site_timezone` | Subquery filter after the 15-minute and daily rollups | 10 (all), full history rolled up |
| (persisted) `energy_consumption_daily` | `consumption_date` range | Index condition; table partitioned on `bucket_start`, key `(device_id, bucket_start)` | 10 small index probes; a `bucket_start` range would exclude chunks |

[V] Migrations 269 (production) and 270 (staging/B2) keep the same
`consumption_date` predicate in the `1d` branch, and the same post-rollup
`bucket_start` predicate in the `1h` branch. B2 does **not** fix this.

### Growth [E]

On production the 1-minute history is 82 days today. If production uses
staging's 180-day retention [I; verified on staging only, 2026-09-23], then
from about 2027-01-26 a `1d` or `1h` read processes about 2.2× today's rows:
roughly 0.5–0.7 s per call against 0.25–0.33 s today. For devices on a
5-minute capture policy (2-year retention on staging), the cost keeps
growing for 2 years.

## Options

### A. Date-bound the canonical read

Make the requested range reach the native rows as a predicate implied by
the existing one, so that no output row can change. This is the same
technique migration 270 used for native and device predicates.

| Variant | What changes | Effect on the scan [E] |
|---|---|---|
| A1: function-level 15-minute source | The `1d` (and `1h`) branch aggregates site-local days or hours from `v_energy_reporting_15min` with `r.bucket_start >= v_effective_from − 1 day AND r.bucket_start < p_to + 1 day`. The padding covers any site-local day or hour boundary and DST; it is implied by the current day and hour overlap test. | Rows are filtered before the rollup, as for 15m today: the sort and aggregate shrink by about 94% (5.8k instead of 92k rows), but every chunk is still read. Estimate about 0.33 s → 0.10 s. |
| A2: range at the native level | Expose the range below the `date_bin` rollup: inlinable SQL range functions in place of (or beside) the semantic views, or rollup views grouping on `time_bucket(…)`. TimescaleDB can turn `time_bucket` comparisons into chunk exclusion [I, unverified for an origin/offset]. | Chunk exclusion and an index range for 5m, 15m, 1h and 1d. Estimate under 50 ms for a 4-day read, independent of history. |

- **Correctness:**
  - Same semantic views and same expressions, so the output is identical
    by construction if the added predicate is truly implied.
  - Risks:
    - padding that is too small, for DST or a non-whole-hour site offset;
    - A1 duplicating the daily view's grouping logic in the function. It
      must stay in step with `v_energy_reporting_daily`, so pin it with a
      golden equality test as 270 did.
- **Tenancy:** unchanged; Grafana scoping stays in the reporting views.
- **Architecture:** semantics stay in the database semantic layer
  (CLAUDE.md §8). A2 reshapes that layer, so it is larger; A1 touches only
  the function.
- **Parity:** exact equality is expected, the same as D3. Proof:
  - local golden tests (old body vs new body, including DST days,
    non-aligned `p_from` and source switches);
  - a production before/after capture with D3 at `1d` and `1h` (and
    `15m` for A2).
- **Sequencing:** must be written on top of 270's body (B2). Its own
  migration after 270 in the manifest, released after B2.

### B. Read the stored daily table

The `1d` branch reads `analytics.energy_consumption_daily`, built by
`refresh_energy_consumption_daily` from `energy_consumption_15min`, with a
`bucket_start` range on its `(device_id, bucket_start)` key. Migration 279's
`get_portal_asset_energy_series` already reads the persisted tiers this way
for the portal (ADR-022 Option B).

- **Cost [E]:** a few index rows per call. Under 10 ms, independent of
  history.
- **Correctness:** a different source. The persisted tier equals the live
  chain only where it has been refreshed and repaired.
  - **Open day:** stale by up to the refresh cadence (1097 every 15
    minutes for 15min, 1103 hourly at :05 for daily).
  - **Late or recovered data:** corrected only inside the forward refresh
    windows (daily `reconcile_window` 21 days) and by the energy
    reconcilers. **The reconcilers 1114–1118 are paused on production**,
    so unrepaired persisted days can differ from the live read.
  - **Output mapping:** `first_source_bucket` / `last_source_bucket` must
    map to `first_native_bucket_start` / `last_native_bucket_start`. The
    269 counters exist on the table. Status priority and coverage must be
    recomputed exactly as the view does.
  - Older history than raw retention becomes readable. That is a
    behaviour change, possibly welcome, but a product decision.
- **Tenancy:** the persisted table has no `grafana_org_id`. The branch must
  join `metadata.grafana_organization_map` / `metadata.devices` the way the
  reporting views do. This must be reviewed as a tenant-isolation change.
- **Parity:** not identical by construction.
  - Closed, repaired days should match exactly; the open day and any
    unrepaired day may not.
  - D3's zero-tolerance rule would have to become "closed days exact,
    open day excluded", plus a deficit check. That needs a product
    decision.
- **Scope:** `1d` only. `1h` would need the hourly table, which is in UTC
  hours; migration 282 shows site-local hours then need 15-minute
  composition. 5m and 15m remain on the live chain.

### Comparison

| | A1 | A2 | B |
|---|---|---|---|
| Output identical by construction | Yes | Yes | No |
| Read cost, 4-day `1d` [E] | about 0.10 s, still reads every chunk | under 50 ms | under 10 ms |
| Grows with history | Scan only | No | No |
| Resolutions fixed | 1d, 1h | 5m, 15m, 1h, 1d | 1d |
| Depends on refresh or reconcilers | No | No | Yes (1114–1118 paused on production) |
| Parity criterion | D3 unchanged | D3 unchanged | New criterion and product decision |
| Size | One function migration | View-layer redesign | Function migration plus tenancy review |

## A1 prototype results (2026-10-20, local test DB, synthetic data)

**These are local measurements on synthetic data, not production
evidence.**
- Local test DB at migration head 306; its live function is migration 270's
  body (md5 `667f9cc2…`). Production still runs 269's body.
- Chunks are uncompressed. Production's older chunks are compressed, so its
  scan cost may be higher.
- Local hardware; plan-cache mode left at the default.
- Spike code: worktree branch `spike/a1-canonical-read-date-bound`,
  `scripts/spike/a1/`. Not committed, not a migration.

**Prototype.** `zz_a1.get_canonical_energy_read` is generated from 270's
body.
- Only the 1h and 1d branches change. Each direction's read of
  `v_energy_reporting_hourly` / `_daily` becomes that view's own body
  (migration 269).
- That body reads `v_energy_reporting_15min` restricted to the direction's
  devices and to `bucket_start` in [`v_effective_from` − 2 days,
  `p_to` + 2 days).
- The native, 5m and 15m branches are byte-identical to 270.

**Golden parity [M local]: exact, 30 of 30 tests passed.**
- The live outputs are captured first, then the prototype is installed and
  compared with exact tuple equality.
- 1,563 case comparisons, 29,620 rows; 504 results are empty by design.
- Time zones: IST, London and New York (spring and fall DST), Lord Howe
  (30-minute DST, both directions), Kiritimati (+14), Pago Pago (−11).
- Session time zones UTC and America/New_York.
- Ranges: full history; middle 2 days; local-midnight aligned; partial days
  with non-aligned bounds; across DST; empty gap day; one hour; before the
  data; after the data.
- Policies native, coarser and strict.
- Data shapes:
  - GAP / RESET / IMPLAUSIBLE_DELTA rows and NULL sample counts;
  - unbound devices with longer history;
  - import and export on different devices;
  - a mid-hour switch to a 5-minute device;
  - missing bindings and a wrong Grafana org;
  - late data: a hole filled after the first read, an ADR-020
    reconstructed gap, and rows 10–20 days before the window. The live
    output changed and A1 still matched.
- Negative control: with padding 0, the partial-day and one-hour cases
  fail, while a midnight-aligned range still matches. So the cases do
  detect a bound that is too small.

**Plan and timing [M local].** 4-day IST read; 4 devices of 1-minute
data; median of 7 warm calls. Rows are summed over the import and export
statements.

| History | Tier | Live (270) | A1 | Native rows aggregated, live → A1 | Rows removed by the `date_bin` filter (A1) | 15-min groups, live → A1 | Chunks scanned |
|---|---|---|---|---|---|---|---|
| 30 d | 1d | 71 ms | 53 ms | 86,400 → 23,040 | 63,360 | 2,880 → 768 | 5 of 5 |
| 30 d | 1h | 84 ms | 48 ms | 86,400 → 23,040 | 63,360 | 2,880 → 768 | 5 of 5 |
| 90 d | 1d | 210 ms | 75 ms | 259,200 → 23,040 | 236,160 | 8,640 → 768 | 14 of 14 |
| 90 d | 1h | 236 ms | 88 ms | 259,200 → 23,040 | 236,160 | 8,640 → 768 | 14 of 14 |
| 90 d | 15m (reference, unchanged) | 49 ms | — | 11,520 | 247,680 | 384 | 14 of 14 |

- **Improved:** the aggregation no longer depends on history length. A1
  aggregates the requested range plus the padding (8 days for a 4-day
  request). From 30 to 90 days of history, the live function's time
  triples; A1's grows from 53 to 75 ms. At 90 days, 1d is 64% faster and
  1h 63% faster.
- **Still unbounded:** every chunk is still read. As for the 15m tier
  today, the bound reaches the chunk scans only as a row filter on
  `date_bin('15 min', bucket_start, …)`: no chunk exclusion and no index
  range. Rows read and then discarded grow linearly with history. This
  is what A2 targets.

**Prototype limitations:**
- 2-day padding doubles the rows aggregated. About 26 h would be enough.
- The prototype copies the hourly and daily view logic. A migration needs a
  test that fails if the views change and the copies do not.
- It uses `#variable_conflict use_column` because the inlined bare column
  names collide with the `RETURNS TABLE` variables. A migration should
  qualify the columns instead.
- Not yet checked on staging or production data.

## Recommendation (not approved)

1. Prefer **A**, starting with **A1** for `1d` and `1h` on top of 270. It
   removes most of the cost, keeps D3 exact, and leaves the semantic views
   alone.
2. Spike **A2** locally first: check whether a `time_bucket`-based rollup
   or inlinable range functions give chunk exclusion through the
   security-barrier reporting views, with plan-only `EXPLAIN` on staging.
   If it does, it fixes 5m and 15m too and stops the growth.
3. Keep **B** for the persisted-tier readers (279 and its successors). Don't
   switch the Grafana canonical read to persisted tiers while the energy
   reconcilers are paused on production.

## Next steps (each needs its own approval)

1. Implement A1 locally behind golden tests: no migration number until the
   approach is accepted. **Done 2026-10-20 (local prototype; results
   above).**
2. Run plan-only checks on staging for A1/A2. Run bounded
   `EXPLAIN (ANALYZE, BUFFERS)` samples only with approval (staging host
   memory limits; see the 2026-10-09 incident).
3. Schedule it in the release plan after B2.

## Open questions

- Is 0.3–0.7 s per `1d`/`1h` call acceptable for the current dashboards
  until a fix ships? That sets the urgency.
- For B: should the canonical read expose history older than raw retention?
- What is the maximum site UTC offset and DST rule set the padding must
  cover? Today's sites are IST; future sites are unknown.
