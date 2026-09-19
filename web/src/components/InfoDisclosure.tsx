/**
 * MVP-5 -- Content & Metric Grammar. The one shared "what does this label
 * mean" affordance for customer-facing quality/status labels (Freshness,
 * Demand Status, Energy evidence). A <button> holding the explanation in an
 * adjacent <span>, `hidden` when closed -- no tooltip/popover library.
 *
 * (An earlier draft used native <details>/<summary> -- also accessible, but
 * <details> is not phrasing content and several existing call sites render
 * this component inside a <p> (energy-freshness, site-overview-*-freshness,
 * pq-freshness, demand-status), which is invalid nesting for it. A <button>
 * + <span> is phrasing content throughout, so it drops cleanly into those
 * existing <p> wrappers with no change to any consumer.)
 *
 * Interaction model (revised): shows on hover and hides when the pointer
 * leaves, rather than toggling open/closed on click -- a click no longer
 * does anything, so the explanation can never get stuck open as a
 * persistent/modal-like state. Keyboard users get the exact same show/hide
 * behavior via focus/blur on the trigger (hover has no keyboard equivalent,
 * so this is the accessible substitute, not an afterthought) -- tabbing to
 * the icon reveals the explanation, tabbing away hides it again. The
 * trigger stays a native <button> (keyboard-focusable, accessible name via
 * aria-label) and keeps its existing aria-expanded/aria-controls pair,
 * which remains accurate: `open` still reflects whether the explanation is
 * currently shown, regardless of which of the two equivalent triggers
 * (pointer or keyboard) caused it.
 *
 * Presentation-only: it knows nothing about Freshness or Demand's own
 * vocabularies. Callers pass the already-translated customer label and
 * explanation -- this keeps the domain-specific enum-to-label mapping in
 * each domain's own component, matching how StatusBadge takes an already-
 * computed ComparisonResult rather than a raw enum.
 *
 * The trigger icon is an inline SVG (outlined circle + dot-and-stem "i"),
 * not the "ⓘ" Unicode glyph the original draft used -- that character is a
 * font glyph rendered at a tiny size, which looks soft/distorted depending
 * on the platform's font rendering. An SVG, like layout/NavIcon.tsx's own
 * monochrome currentColor-stroke icons, stays crisp at any size and in any
 * environment.
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

  const show = () => setOpen(true);
  const hide = () => setOpen(false);

  return (
    <span
      className="info-disclosure"
      data-testid={testId ? `${testId}-info` : undefined}
      onMouseEnter={show}
      onMouseLeave={hide}
    >
      <button
        type="button"
        className="info-disclosure__trigger"
        aria-expanded={open}
        aria-controls={explanationId}
        aria-label={`What does "${label}" mean?`}
        onFocus={show}
        onBlur={hide}
      >
        <svg
          className="info-disclosure__icon"
          viewBox="0 0 24 24"
          fill="none"
          stroke="currentColor"
          strokeWidth="1.8"
          strokeLinecap="round"
          aria-hidden="true"
        >
          <circle cx="12" cy="12" r="9" />
          <line x1="12" y1="11" x2="12" y2="16" />
          <circle cx="12" cy="7.5" r="1" fill="currentColor" stroke="none" />
        </svg>
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
