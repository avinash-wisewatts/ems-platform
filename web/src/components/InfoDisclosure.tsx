/**
 * MVP-5 -- Content & Metric Grammar. The one shared "what does this label
 * mean" affordance for customer-facing quality/status labels (Freshness,
 * Demand Status). Deliberately the simplest accessible pattern available:
 * the standard WAI-ARIA disclosure pattern -- a <button> toggling
 * aria-expanded plus a plain <span> holding the explanation, `hidden` when
 * collapsed. No tooltip/popover library, no positioning logic.
 *
 * (An earlier draft used native <details>/<summary> -- also accessible, but
 * <details> is not phrasing content and several existing call sites render
 * this component inside a <p> (energy-freshness, site-overview-*-freshness,
 * pq-freshness, demand-status), which is invalid nesting for it. A <button>
 * + <span> is phrasing content throughout, so it drops cleanly into those
 * existing <p> wrappers with no change to any consumer.)
 *
 * A native <button> is keyboard-operable by default (Enter/Space), and its
 * aria-expanded state and accessible name are announced by screen readers
 * without any extra ARIA role. It responds to a tap identically to any
 * other button, unlike a hover-only `title` attribute.
 *
 * Presentation-only: it knows nothing about Freshness or Demand's own
 * vocabularies. Callers pass the already-translated customer label and
 * explanation -- this keeps the domain-specific enum-to-label mapping in
 * each domain's own component, matching how StatusBadge takes an already-
 * computed ComparisonResult rather than a raw enum.
 */

import { useId, useState } from "react";

export function InfoDisclosure({
  label,
  explanation,
  testId,
}: {
  /** The customer-facing label this explains, e.g. "Current" -- used only
   *  to word the trigger's accessible name, never rendered as visible text
   *  here (the caller already renders the label itself). */
  label: string;
  /** Plain-language explanation of what the label means. */
  explanation: string;
  testId?: string;
}) {
  const [open, setOpen] = useState(false);
  const explanationId = useId();

  return (
    <span className="info-disclosure" data-testid={testId ? `${testId}-info` : undefined}>
      <button
        type="button"
        className="info-disclosure__trigger"
        aria-expanded={open}
        aria-controls={explanationId}
        aria-label={`What does "${label}" mean?`}
        onClick={() => setOpen((v) => !v)}
      >
        <span aria-hidden="true">ⓘ</span>
      </button>
      <span
        id={explanationId}
        className="info-disclosure__explanation"
        data-testid={testId ? `${testId}-explanation` : undefined}
        hidden={!open}
      >
        {explanation}
      </span>
    </span>
  );
}
