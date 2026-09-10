/**
 * Renders the architecture's quality lattice consistently everywhere.
 *
 * Lattice (frozen architecture): GOOD, GAP, ESTIMATED, INVALID, and PARTIAL
 * (AGGREGATE_CHILDREN only). This component renders those five labels and
 * nothing else -- it never invents a quality value.
 *
 * IMPORTANT -- first-slice reality: the Phase 7 API exposes `quality` as
 * `number | null` on measurement points, and it is CURRENTLY ALWAYS null for
 * TEMPERATURE / HUMIDITY / DEW_POINT (Phase 3 + Phase 6 NULL pass-through, "no
 * lattice"). Energy points carry no per-point quality field yet. So today this
 * component almost always renders the neutral "no quality reported" state.
 *
 * The concrete `number -> lattice label` mapping is deliberately NOT fixed
 * here: no code values are defined by the API yet. When a later phase starts
 * populating `quality` (energy register-semantics quality, aggregate PARTIAL),
 * the mapping is added in ONE place -- `QUALITY_CODE_LABELS` below -- with no
 * change to call sites.
 */

export type QualityLabel = "GOOD" | "GAP" | "ESTIMATED" | "INVALID" | "PARTIAL";

export const QUALITY_LABELS: readonly QualityLabel[] = [
  "GOOD",
  "GAP",
  "ESTIMATED",
  "INVALID",
  "PARTIAL",
];

/**
 * Provisional and intentionally empty. The Phase 7 first slice defines no
 * numeric quality codes. Populate this map (in one place) only when the API
 * begins returning non-null `quality` values with a documented meaning.
 */
export const QUALITY_CODE_LABELS: Readonly<Record<number, QualityLabel>> = {};

export function qualityLabelFor(code: number | null | undefined): QualityLabel | null {
  if (code === null || code === undefined) return null;
  return QUALITY_CODE_LABELS[code] ?? null;
}

export function QualityIndicator({
  /** Either a raw API code (number|null) or an explicit lattice label. */
  code,
  label,
  showWhenUnknown = false,
}: {
  code?: number | null;
  label?: QualityLabel;
  /** Render a neutral marker even when no quality is reported. */
  showWhenUnknown?: boolean;
}) {
  const resolved: QualityLabel | null = label ?? qualityLabelFor(code);

  if (resolved === null) {
    if (!showWhenUnknown) return null;
    return (
      <span
        className="quality quality--unknown"
        data-testid="quality-indicator"
        data-quality="UNKNOWN"
        title="No quality reported"
        aria-label="Quality: not reported"
      >
        —
      </span>
    );
  }

  return (
    <span
      className={`quality quality--${resolved.toLowerCase()}`}
      data-testid="quality-indicator"
      data-quality={resolved}
      title={`Quality: ${resolved}`}
      aria-label={`Quality: ${resolved}`}
    >
      {resolved}
    </span>
  );
}
