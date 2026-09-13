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
 * Text content is the raw API state string, unstyled and unworded --
 * placeholder-only. Final customer-facing wording is explicitly MVP-5's
 * scope (decision pack Sec 13, Q1), not decided here.
 */

import type { FreshnessState } from "../api/types";

export type { FreshnessState };

export function FreshnessIndicator({
  state,
}: {
  /** null/undefined = not yet available (loading or fetch failed) --
   *  renders nothing. Never conflate with the real "UNKNOWN" value. */
  state?: FreshnessState | null;
}) {
  if (!state) return null;

  return (
    <span
      className={`freshness freshness--${state.toLowerCase()}`}
      data-testid="freshness-indicator"
      data-freshness={state}
      title={`Freshness: ${state}`}
      aria-label={`Freshness: ${state}`}
    >
      {state}
    </span>
  );
}
