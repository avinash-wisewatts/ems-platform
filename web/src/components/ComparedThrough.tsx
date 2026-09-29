/**
 * Site-local qualifier for a comparison that covers only the matched elapsed
 * portion of the selected range (Product Owner decisions, 2026-09-29): the
 * "This period" total shows everything recorded so far, while the comparison
 * value, difference and percentage stop at `comparedUntil`. Renders nothing
 * when the whole period is compared (comparedUntil null).
 */
import { formatTimeAndDateInTimeZone } from "../time/format";

/** "Compared through {site-local date/time}", or null when no cut applies. */
export function comparedThroughText(comparedUntil: string | null, timeZone: string | null | undefined): string | null {
  if (comparedUntil === null) return null;
  return `Compared through ${formatTimeAndDateInTimeZone(comparedUntil, timeZone)}`;
}

export function ComparedThrough({
  comparedUntil,
  timeZone,
}: {
  comparedUntil: string | null;
  timeZone: string | null | undefined;
}) {
  const text = comparedThroughText(comparedUntil, timeZone);
  if (text === null) return null;
  return (
    <span className="compared-through" data-testid="compared-through">
      {text}
    </span>
  );
}
