/**
 * Shared plain-language status presentation, derived from a ComparisonResult.
 * Built once here so later slices (Demand, PQ, Attention) reuse it rather
 * than each inventing their own status wording.
 *
 * Deliberately presentation-neutral: the tone reflects only the ARITHMETIC
 * SIGN of the computed delta (strictly positive / strictly negative / exactly
 * zero / not computable) -- it does NOT apply a materiality band (e.g. "+-5%
 * counts as unchanged"). What counts as a meaningful difference is a
 * metric-specific product decision, not invented here; when that decision is
 * made for a given metric, express it explicitly at the call site rather than
 * baking a universal tolerance into this shared component.
 */

import type { ComparisonResult } from "../energy/comparison";
import { COMPARISON_BASIS_LABELS } from "../time/ranges";

export type StatusTone = "higher" | "lower" | "unchanged" | "unknown";

export function deriveStatusTone(deltaPercent: number | null): StatusTone {
  if (deltaPercent === null) return "unknown";
  if (deltaPercent > 0) return "higher";
  if (deltaPercent < 0) return "lower";
  return "unchanged";
}

const TONE_LABEL: Record<StatusTone, string> = {
  higher: "Higher than comparison",
  lower: "Lower than comparison",
  unchanged: "Same as comparison",
  unknown: "Comparison not available",
};

export function StatusBadge({ result }: { result: ComparisonResult }) {
  const tone = deriveStatusTone(result.deltaPercent);
  const basisLabel = COMPARISON_BASIS_LABELS[result.basis];

  return (
    <span
      className={`status-badge status-badge--${tone}`}
      data-testid="status-badge"
      data-tone={tone}
      title={`Compared to: ${basisLabel}`}
    >
      {TONE_LABEL[tone]}
      <span className="status-badge__basis"> · vs. {basisLabel}</span>
    </span>
  );
}
