# ADR-014: MVP-6 Export scope, content, format, and behavior (Q75)

Status: Decided; not implemented
Date: 2026-09-14 (MVP-6 Product Decision Workshop)
Decision owners: Product Owner
Related requirements: EMS-REQ-094 through EMS-REQ-099
Related features: Export (no dedicated feature document yet — see
[07-features/README.md](../../07-features/README.md); created once the
underlying capability exists to document)

## Context

Workshop Q75 (`docs/99-archive/superseded-product/ems-product-owner-workshop-baseline.md`
§107) established that MVP includes export of underlying analytical data
and context, explicitly **not** a general-purpose BI/query-builder tool,
and listed illustrative content ("may include": Portfolio/Site/Space/Asset
context, selected time range, relevant energy/demand/PQ measurements,
comparison period/baseline, applicable calculated metrics, data-quality
indicators). `docs/01-product/roadmap.md` classifies this as MVP-6,
depending on MVP-2 (the figures exported) and MVP-3 (the reporting/
overview source). As of the 2026-09-14 MVP-6 discovery pass (see
[requirements-traceability.md §6](../../02-requirements/requirements-traceability.md)),
zero export implementation existed anywhere in the codebase, and every
concrete question below (format, delivery, scope, time-range bounds,
data-gap handling) was `OPEN`, `BLOCKED`, or `UNKNOWN` per that discovery's
workshop brief.

This ADR is the record of the MVP-6 Product Decision Workshop
(2026-09-14) that resolved those Export (Q75) questions. It refines and
narrows Q75's original archived list into a fully specified content and
behavior model; it does not contradict Q75 — the decisions below are a
subset/specification of what Q75's "may include" list already permitted.
Reporting (Q76) is explicitly out of scope for this record — see
[07-features/README.md](../../07-features/README.md) note above and the
Q76 discussion in [requirements-traceability.md](../../02-requirements/requirements-traceability.md);
Q76's format, catalogue, and storage-shape questions remain `OPEN`/
`BLOCKED`, unresolved by this decision.

## Decision

**1. Content — aggregated figures, not raw time-series.** Export contains
the aggregated analytical figures already presented in the EMS (e.g. a
period's total consumption, a peak-demand figure, a PF/THD summary value)
— not the raw/underlying time-series measurements behind them. This is a
narrowing of Q75's original "relevant energy/demand/PQ measurements"
wording to the on-screen, already-computed figures specifically.

**2. Context fields.** Every export includes: Site/hierarchy context (see
decision 12), the selected time range, the comparison/baseline basis
(where the metric has one), and the metric's name and unit.

**3. Data-quality/freshness inclusion.** Data-quality/freshness
information is included wherever it is relevant to interpreting the
exported figure — mirroring the on-screen presentation, not a separate
export-only quality model.

**4. Format — CSV.** The export file format is CSV. No other format is
decided for MVP-6 export (distinct from, and not to be confused with,
Q76's still-undecided report output format — see the note added to
`EMS-REQ-091`).

**5. Delivery — size-tiered, no invented threshold.** Smaller exports
support immediate download. Larger exports support background generation
instead. **No specific size/row/byte threshold between the two is decided
here** — that boundary is left open for implementation-time or a future
decision; this ADR records only that both delivery modes are required.

**6. Availability — contextual and dedicated.** Export is available two
ways: contextually, from the relevant analytical screens (Energy, Demand,
Power Quality, and wherever else an exportable figure is already shown),
and through a dedicated Export area.

**7. Dedicated Export area — multi-metric.** The dedicated Export area
supports exporting multiple metrics together, across Energy, Demand, and
Power Quality in one export — unlike the contextual, single-screen export
path.

**8. Comparison/baseline fields mirror on-screen display.** Comparison/
baseline fields in an export follow exactly what is actually displayed
on-screen for that metric — including any displayed difference/delta —
rather than exporting a different or more extensive comparison basis than
the customer already sees.

**9. Time-range bounds — site data availability.** The selectable time
range for an export is constrained to the minimum and maximum dates for
which the specific site actually has data available — not an arbitrary or
universal bound.

**10. Data gaps — retained, not silently omitted.** Data gaps within the
selected, site-specific range are retained in the export with their
applicable EMS data-quality/freshness state, rather than being silently
dropped from the output.

**11. No-usable-data metrics — represented, not fabricated.** A selected
metric that has no usable data for the requested range is still
represented as a row/entry in the export, carrying its applicable
data-quality state and explicitly no usable value — never omitted and
never a fabricated number.

**12. Hierarchy-level scoping.** Contextual export follows whatever
hierarchy level the customer is currently viewing — Site, Space, or Asset.
The dedicated Export area additionally lets the customer select the
desired hierarchy level directly, rather than being limited to whatever
level they last navigated to.

## Rationale

Decision 1 (aggregated, not raw) keeps Export aligned with Q75's own
"not a BI/query-builder tool" constraint — raw time-series export invites
query-builder-style usage patterns the workshop explicitly excluded.
Decisions 10-11 (retain gaps, represent no-data honestly) extend the same
"no data" ≠ "error", never-fabricate-a-value discipline already governing
the rest of the EMS (`interaction-patterns.md`, ADR-011) into the export
surface, rather than inventing export-specific behavior. Decision 5's
refusal to invent a size threshold follows this documentation set's
evidence discipline — no technical threshold was given in this workshop,
so none is recorded as decided.

## Alternatives considered

Not established in available source material. What is established is the
decision itself (decision 1): MVP-6 Export is defined to contain the
aggregated analytical figures presented in EMS, not raw/underlying
time-series measurements. Q75's original archived wording ("relevant
energy/demand/PQ measurements") did not itself distinguish aggregated
figures from raw series, so decision 1 narrows that wording — but whether
a raw-series alternative was explicitly discussed and rejected during this
workshop, as opposed to simply not being the option chosen, is not
recorded, and this ADR does not claim otherwise. No other alternative is
established in available source material for the remaining decisions;
where the workshop specified a single behavior directly, no competing
option was recorded.

## Consequences

- `docs/02-requirements/functional-requirements.md` gains a new `##
  Export` section (`EMS-REQ-094`–`EMS-REQ-099`) recording decisions 1-12
  as testable requirements.
- `docs/02-requirements/requirements-traceability.md` §6 records Q75's
  classification change from its 2026-09-11 `C — NOT LANDED` (decision
  blocker) to decision-resolved-but-still-`C`-for-implementation, per this
  ADR.
- `docs/01-product/roadmap.md`'s MVP-6 entry is updated to reference this
  ADR.
- `docs/03-ux-and-design/information-architecture.md` gains a dedicated
  `## Export (MVP-6)` subsection, separated from `## Reports (MVP-6)` per
  Q76's own "Report = the story, Export = the data" distinction.
- `docs/03-ux-and-design/navigation.md`'s proposed nav tree gains an
  `Export` entry alongside `Reports`, subject to the same ADR-005
  placement caveat already governing that tree.
- **No code, API, or database change is made or implied by this ADR.**
  Implementation remains fully unscheduled; MVP-6's dependency on MVP-2/
  MVP-3 (both DONE) is unaffected.
- Q76 (Reporting) format/catalogue/storage-shape questions remain open —
  not addressed, not implied resolved, by this record.

## Evidence / references

- Workshop baseline §107 (Q75) — [../../99-archive/superseded-product/ems-product-owner-workshop-baseline.md](../../99-archive/superseded-product/ems-product-owner-workshop-baseline.md)
- MVP-6 discovery report and Product Decision Workshop brief — produced
  2026-09-14 in-session (not a separately committed file; this ADR is the
  durable record of the decisions that discovery surfaced as open
  questions and this workshop resolved), per the same evidentiary pattern
  already used by [ADR-009](ADR-009-slice-c-historical-reference-methodology.md)
  and [ADR-010](ADR-010-mvp3-attention-materiality-policy.md) for
  decisions made in an uncommitted decision pack / session record.
- [01-product/roadmap.md](../../01-product/roadmap.md) MVP-6 entry.

## Implementation references

None yet. MVP-6 (Export & Basic Reporting) remains unimplemented — no
frontend, backend, or database code exists for either Export or Reporting
as of this record.

## Validation references

Not yet validated — no implementation exists to validate.
