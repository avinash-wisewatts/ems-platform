/**
 * MVP-4 -- Data Quality & Freshness. Renders device connectivity/freshness
 * state, sourced from GET /sites/{id}/telemetry-freshness -- a signal kept
 * deliberately separate from, and never merged into, QualityIndicator's
 * measurement-quality lattice (GOOD/GAP/ESTIMATED/INVALID/PARTIAL) or
 * Demand's own quality_status/coverage_percent. See the approved decision
 * pack: docs/00-governance/decision-packs/
 * mvp-4-data-quality-and-freshness-decision-pack.md, Sec 5/5a/10.
 *
 * Unlike QualityIndicator, all four states render through ONE path -- there
 * is no special-cased "unknown" branch. UNKNOWN is a real, meaningful value
 * this API returns (it means no device could be resolved for this metric,
 * per decision pack Sec 5a), not an absent/degenerate case the way a null
 * quality code is -- so it is never hidden behind an opt-in flag the way
 * QualityIndicator hides its own "not reported" state by default.
 *
 * `state` accepts null/undefined for exactly one reason: the caller has not
 * yet resolved a real value (still loading, or the fetch failed). That is
 * rendered as nothing -- it must NEVER be presented as, or confused with,
 * the API's own explicit "UNKNOWN" value, which means something different
 * (a real answer: no device could be resolved) and always renders.
 *
 * MVP-5 -- Content & Metric Grammar (approved Product decision): the raw
 * API state is translated to a customer-facing label here, in ONE place,
 * via FRESHNESS_LABELS below. NO_DATA and UNKNOWN intentionally share the
 * "Data unavailable" label even though they remain technically distinct --
 * `data-freshness`/the `freshness--*` class still carry the real, distinct
 * API value (for styling/tests/analytics), only the visible text and the
 * accessible name collapse the two. The technical state name is never
 * rendered as visible or accessible text -- see InfoDisclosure for the
 * paired "what does this mean" explanation.
 */

import type { FreshnessState } from "../api/types";
import { InfoDisclosure } from "./InfoDisclosure";

export type { FreshnessState };

const FRESHNESS_LABELS: Record<FreshnessState, string> = {
  FRESH: "Current",
  STALE: "Outdated",
  NO_DATA: "Data unavailable",
  UNKNOWN: "Data unavailable",
};

/** DRAFT wording -- Product approved the underlying meaning, not this exact
 *  copy (see MVP-5 decision record). NO_DATA and UNKNOWN deliberately share
 *  the same explanation, matching their shared customer label. */
const FRESHNESS_EXPLANATIONS: Record<FreshnessState, string> = {
  FRESH: "This data is being received recently enough to reflect current conditions.",
  STALE: "The latest available data is older than expected and may not reflect current conditions.",
  NO_DATA: "We can't currently provide usable data for this metric.",
  UNKNOWN: "We can't currently provide usable data for this metric.",
};

export function FreshnessIndicator({
  state,
}: {
  /** null/undefined = not yet available (loading or fetch failed) --
   *  renders nothing. Never conflate with the real "UNKNOWN" value. */
  state?: FreshnessState | null;
}) {
  if (!state) return null;

  const label = FRESHNESS_LABELS[state];

  return (
    <span
      className={`freshness freshness--${state.toLowerCase()}`}
      data-testid="freshness-indicator"
      data-freshness={state}
    >
      {label}
      <InfoDisclosure label={label} explanation={FRESHNESS_EXPLANATIONS[state]} testId="freshness" />
    </span>
  );
}
