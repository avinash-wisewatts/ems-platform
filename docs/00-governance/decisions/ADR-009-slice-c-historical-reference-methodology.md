# ADR-009: "Slice C" historical typical-reference methodology

Status: Decided; implemented and merged to `origin/staging`
Date: 2026-09-13 (PR #49, commit `c299f27`)
Decision owners: Product Owner (via the "Slice C Historical Comparison decision pack" — cited by the implementing commit, not itself present as a file in this repository) / Engineering (implementation)
Related requirements: EMS-REQ-021, EMS-REQ-027, Workshop Q54–Q56, Q97
Related features: [Energy](../../07-features/energy/README.md)

## Context

An earlier revision of this ADR, written during the initial documentation
reorganization pass, stated "Slice C" was not established anywhere in the
repository. That was a research error: the search covered `docs/` and
`Audit/` text files and this assistant's own memory, but not the
repository's source code and commit history. `origin/staging` (as of commit
`ddbe5a4`, 2026-09-13) contains a full, real implementation. This revision
corrects the record with the actual evidence.

"Slice C" is the codename for the third of three sequential MVP-2/MVP-3
frontend/backend delivery slices: **Slice 0** (hierarchy foundation, PR
#46), **Slice A** (energy foundation, same PR), **Slice B** (demand and
power quality, PR #48), **Slice C** (Energy Performance / historical
comparison, PR #49) — followed by the MVP-1 closeout and MVP-3 composite
screen (PR #50, commit `ddbe5a4`, which this documentation reorganization
was itself started against an earlier branch point of).

## Decision

Slice C replaces an earlier, **never-shipped** N=4 rolling-average
comparison with the approved **comparable-period historical reference**
("typical historical consumption"), per the "Slice C Historical Comparison
decision pack and its final implementation specification" (cited by commit
`c299f27`; that decision pack itself is not present as a file in this
repository — see "Evidence gap" below).

**Methodology** (migration 236,
`analytics.get_portal_site_energy_typical_reference`):

- Reads **only** `analytics.energy_consumption_daily` + `metadata.sites.timezone`
  — no new telemetry pipeline, no dependency on migration 235.
- Selects **up to 8 comparable historical periods**: step = 7 days for
  sub-week periods, otherwise the period's own length (i.e. comparable
  same-length windows spaced by week or by period).
- Each candidate window is **gated on ≥70% valid-interval coverage** before
  being counted as an eligible comparison period.
- The **typical reference value is the median** of the eligible windows'
  values (computed in Python, `statistics.median`, from the SQL layer's
  per-window eligibility) — not a mean, and not the earlier rolling
  average.
- Exposed via `GET /api/v1/sites/{site_id}/energy/consumption/typical-reference`
  — one bounded request returns the full reference (median, eligibility
  counts, per-window evidence); no frontend N+1 query pattern.
- The frontend (`EnergyOverview.tsx`) surfaces typical vs. current
  consumption, eligible/requested period counts, and explicit "still
  included" notes when an eligible historical period carried a gap/reset/
  rollover/invalid flag — kept as independent, non-partitioning evidence
  counters, never forced into the `GOOD/GAP/ESTIMATED/INVALID/PARTIAL`
  quality lattice.

## Rationale

This is the concrete implementation of the Workshop's Q54–Q56 comparison-
baseline decision ("historical comparison — previous period / same period
previously / rolling historical average — is the MVP default") using a
median-of-comparable-windows approach rather than a simple rolling average,
after the originally planned rolling-average approach was apparently
abandoned before shipping (commit message: "replaces the earlier,
never-shipped N=4 rolling average").

## Alternatives considered

The commit message names exactly one: an "N=4 rolling average," described
as planned but never shipped. No other alternative is recorded in
available source material.

## Consequences

- MVP-2's Energy Performance / comparison capability (previously
  documented in this reorganization as `PLANNED (MVP-2)`, unbuilt) is now
  **implemented and merged to `origin/staging`**.
- The Energy Attention rule (see [ADR-010](ADR-010-mvp3-attention-materiality-policy.md))
  is built directly on top of this same typical-reference result — "no
  second historical-baseline mechanism."
- Migration 231 (the original `/energy/consumption` contract) is untouched,
  enforced by a postcondition in migration 236 itself.

## Evidence gap — flagged, not resolved

The "Slice C Historical Comparison decision pack" and "its final
implementation specification" are cited by name in both the implementing
commit (`c299f27`) and the materiality-policy source comment (see
[ADR-010](ADR-010-mvp3-attention-materiality-policy.md)), but **no file by
that name, or matching that description, exists anywhere in this
repository** (searched: `docs/`, `Audit/`, full commit history). If this
decision pack exists as an external document or a prior conversation not
committed here, it should be added to the repository (most likely under
[00-governance/decisions/](.) or [99-archive/](../../99-archive/)) so this
ADR's evidence trail is self-contained rather than pointing at a document
nobody reading this repository can open.

## Evidence / references

- Commit `c299f27` ("feat(ems): add comparable historical energy reference
  (#49)") — full commit message quoted above in Decision.
- `postgres/migrations/236_*.sql` (referenced by the commit; not
  independently re-read line-by-line for this ADR).
- Workshop baseline §84–§86 (Q54–Q56) — [../../99-archive/superseded-product/ems-product-owner-workshop-baseline.md](../../99-archive/superseded-product/ems-product-owner-workshop-baseline.md)

## Implementation references

`GET /api/v1/sites/{site_id}/energy/consumption/typical-reference` (live on
`origin/staging`); `web/src/energy/comparison.ts`; `web/src/routes/energy/EnergyOverview.tsx`.

## Validation references

Commit `c299f27` records: 1,277 backend (pytest) + 112 frontend (vitest)
tests passing; typecheck/lint clean; no change to migration 231, the
existing `/energy/consumption` contract, the telemetry/routing/
classification pipeline, or Grafana. See
[../../08-verification/staging-validation.md](../../08-verification/staging-validation.md)
for the subsequent MVP-3 composite-screen staging validation that
consumes this endpoint.

---

## Amendment 1 (2026-09-29): typical reference with calendar ranges

**Context.** The time-range presets became calendar ranges in the site's
timezone, application-wide (ADR-022 Amendment 5, D61/D62): local midnight of
the first day to the exclusive next local midnight. The typical-reference
endpoint accepts only exact spans of 1, 7, 30, 90 or 365 × 24 hours, while a
calendar 3 Months is 90–93 days, a 1 Year 366 days (367 when it contains
29 February), and a range across a DST change is an hour shorter or longer.

**Decision (Product Owner, 2026-09-29).**

1. The customer's selected calendar range remains authoritative for actual
   consumption; it is never changed to fit the reference.
2. The typical reference uses the nearest supported fixed window — 1, 7, 30,
   90 or 365 days for Today, 7 Days, 30 Days, 3 Months and 1 Year — **ending
   at the selected range's end**.
3. When the range's calendar-day count and the reference window's day count
   differ, the comparison uses **normalized average consumption per calendar
   day**, not raw totals.
4. Typical is never shown as unavailable merely because the durations
   differ.
5. **Elapsed portion only** (Product Owner, 2026-09-29). The displayed
   calendar range is unchanged (including its future empty buckets, D16), but
   unelapsed time is excluded from every comparison and from the Energy
   Attention thresholds: actual consumption so far is compared with historical
   or reference periods covering the same elapsed duration. This applies to
   the previous-period, same-period-last-year and Typical comparisons.
6. **Typical compares complete elapsed local days only** (Product Owner,
   2026-09-29). The typical value comes from the site-local daily historian,
   which cannot represent part of a day, so Typical compares the actual
   consumption of the complete elapsed local days (range start to today's
   local midnight) with the typical per day × that number of days. Today has
   no complete day, so it has no Typical comparison until the day is complete.

**Implementation (F1, frontend only).** `planEnergyTypicalReferenceRequest`
(`web/src/time/ranges.ts`) builds the fixed window and the complete-day basis
(`basisRange`, read at 1d); `buildTypicalReferenceResult`
(`web/src/energy/comparison.ts`) compares those days with typical per day ×
their count. Previous-period and same-period-last-year windows are cut at the
same elapsed point on both sides (`planEnergyComparisonRequest`): the last
completed UTC hour for hourly data, today's local midnight for daily data. The
"This period" total still shows everything recorded in the displayed range;
the comparison figure, difference and percentage (and so Energy Attention)
use only the matched elapsed portion, and carry the site-local qualifier
"Compared through {date/time}" (Product Owner, 2026-09-29) on the Energy
comparison, the Site Overview "vs. typical" figure and the Energy Attention
trigger (`web/src/components/ComparedThrough.tsx`). The server-side methodology
above is unchanged.
