/**
 * Asset View -- Demand tile/chart calculation, specific to THIS screen
 * (unlike Site Demand's own "Peak Power" presentation, demand/
 * DemandOverview.tsx's exported findPeak/DemandLastCompletedAndPeak -- the
 * Asset View Demand tile's second figure is labelled "Max Demand" and is
 * demand_kw-based, not peak_power_kw-based "Peak Power". Kept local to this
 * screen rather than added to the shared component, since the two screens'
 * presentations are not the same).
 *
 * T1.3a (revised run 11): only completed intervals are used, and only a
 * VALID interval's demand_kw counts as demand
 * (components/demandInterval.ts#reliableDemandKw), so incomplete or
 * unavailable data is never presented as reliable demand.
 */

import type { DemandIntervalPoint } from "../../api/types";
import type { ChartPoint } from "../../components/ChartFrame";
import { reliableDemandKw } from "../../components/demandInterval";

/**
 * Maximum demand_kw across the series' VALID intervals, with the
 * interval_start it occurred at -- "Max Demand: 112.0 kW (06:00PM)".
 * Evidence (read directly from the deployed schema/functions, not assumed
 * from field names -- postgres/migrations/013_demand_calculation_
 * processor.sql): `demand_kw` is THE calculated demand figure for a
 * 15-minute interval (an energy-delta-derived average kW, a time-weighted
 * average kW, or a native meter register reading, depending on source
 * method) -- exactly what "the max demand (the 15-min intervals
 * calculated)" means. `peak_power_kw` is a DIFFERENT, independent column
 * (the maximum INSTANTANEOUS power sample seen within an interval,
 * entirely NULL for METER_NATIVE-sourced rows) -- deliberately not used
 * here; findMaxDemand only maxes demand_kw.
 */
export function findMaxDemand(series: DemandIntervalPoint[]): { kw: number; at: string } | null {
  let best: { kw: number; at: string } | null = null;
  for (const point of series) {
    const kw = reliableDemandKw(point);
    if (kw !== null && (best === null || kw > best.kw)) {
      best = { kw, at: point.interval_start };
    }
  }
  return best;
}

/**
 * Demand chart points: completed intervals only (GET .../demand,
 * analytics.demand_intervals). A non-VALID interval is a gap (null), not a
 * value. No provisional point for the interval in progress is appended
 * (T1.3a, D-011), so the newest point is the last completed interval: it
 * trails "now" by the interval length plus the finalization delay.
 */
export function buildDemandChartPoints(series: DemandIntervalPoint[]): ChartPoint[] {
  return series.map((point) => ({ t: Date.parse(point.interval_start), value: reliableDemandKw(point) }));
}
