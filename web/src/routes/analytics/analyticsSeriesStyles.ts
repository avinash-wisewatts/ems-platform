/**
 * Series colours for the Analytics page -- pure, no React.
 *
 * A colour follows the series, never its position: a series keeps its colour
 * slot for as long as the page is open on the site, across Updates, and
 * adding, removing or reordering other series never repaints it. A new series
 * takes the lowest slot no other shown series is using. Slots map to the
 * chart palette (components/ChartFrame.tsx): eight validated hues in a fixed
 * order, then the same hues dashed (lines) or hatched (bars).
 *
 * The chart, the legend and the Statistics table all read the same
 * assignment, so a series has one colour everywhere on the page.
 */
import type { AnalyticsSeries } from "../../api/types";
import { seriesStyleForSlot, type SeriesStyle } from "../../components/ChartFrame";

/** The identity of a series on the page (asset, data point, phase). */
export function seriesKey(s: Pick<AnalyticsSeries, "asset_id" | "data_point" | "qualifier">): string {
  return `${s.asset_id}:${s.data_point}:${s.qualifier}`;
}

/**
 * Slots for `keys` (in order), keeping every slot `previous` remembers. A
 * remembered slot is kept unless an earlier key in `keys` already holds it;
 * any other key takes the lowest slot free among `keys`. The result also keeps
 * the slots of series not shown now, so a series that comes back gets its
 * colour back when that slot is free.
 */
export function assignSeriesSlots(previous: ReadonlyMap<string, number>, keys: readonly string[]): Map<string, number> {
  const next = new Map(previous);
  const taken = new Set<number>();
  const unassigned: string[] = [];
  for (const key of new Set(keys)) {
    const slot = previous.get(key);
    if (slot !== undefined && !taken.has(slot)) taken.add(slot);
    else unassigned.push(key);
  }
  for (const key of unassigned) {
    let slot = 0;
    while (taken.has(slot)) slot++;
    taken.add(slot);
    next.set(key, slot);
  }
  return next;
}

/** The style of each key under an assignment (slot 0 if unassigned). */
export function seriesStyles(slots: ReadonlyMap<string, number>, keys: readonly string[]): Map<string, SeriesStyle> {
  return new Map(keys.map((key) => [key, seriesStyleForSlot(slots.get(key) ?? 0)]));
}
