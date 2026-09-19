/**
 * Asset View -- Demand tile/chart calculation, specific to THIS screen
 * (unlike Site Demand's own "Peak Power" presentation, demand/
 * DemandOverview.tsx's exported findPeak/DemandCurrentAndMax -- the Asset
 * View Demand tile deliberately diverges from that: no status line, no
 * "Latest 15-min interval" caption, and its second figure is labelled
 * "Max Demand" and is demand_kw-based, not peak_power_kw-based "Peak
 * Power". Kept local to this screen rather than added to the shared
 * component, since the two screens' presentations are no longer the same).
 */

import type { AssetCurrentDemandResponse, DemandIntervalPoint } from "../../api/types";
import type { ChartPoint } from "../../components/ChartFrame";

/**
 * Maximum demand_kw across the series, with the interval_start it occurred
 * at -- "Max Demand: 112.0 kW (06:00PM)". Evidence (read directly from the
 * deployed schema/functions, not assumed from field names --
 * postgres/migrations/013_demand_calculation_processor.sql): `demand_kw`
 * is THE calculated demand figure for a 15-minute interval (an
 * energy-delta-derived average kW, a time-weighted average kW, or a native
 * meter register reading, depending on source method) -- exactly what
 * "the max demand (the 15-min intervals calculated)" means. `peak_power_kw`
 * is a DIFFERENT, independent column (the maximum INSTANTANEOUS power
 * sample seen within an interval, entirely NULL for METER_NATIVE-sourced
 * rows) -- deliberately not used here; findMaxDemand only maxes demand_kw.
 */
export function findMaxDemand(series: DemandIntervalPoint[]): { kw: number; at: string } | null {
  let best: { kw: number; at: string } | null = null;
  for (const point of series) {
    if (point.demand_kw !== null && (best === null || point.demand_kw > best.kw)) {
      best = { kw: point.demand_kw, at: point.interval_start };
    }
  }
  return best;
}

/**
 * Demand chart points, with the still-open current interval appended when
 * it falls inside the requested [from, to) window -- fixes an observed lag
 * of ~25-30 minutes on the chart's most recent point versus "now".
 *
 * Root cause (traced in postgres/migrations/013_demand_calculation_
 * processor.sql's analytics.refresh_demand_analytics): GET .../demand only
 * reads analytics.demand_intervals, which is populated exclusively with
 * FINALIZED intervals -- a 15-minute interval is not written there until
 * interval_end + late_arrival_tolerance_seconds (policy-configured, default
 * low tens of seconds) + a further fixed 10-minute processing grace have
 * all elapsed. The chart's newest visible point can therefore lag "now" by
 * up to ~(15 + ~10-11) minutes even though the interval it belongs to
 * finished accumulating readings 10+ minutes ago -- consistent with the
 * observed ~30-minute lag, and with it always trailing Grafana's own
 * demand-profile panel (which, unlike this portal API, also blends in the
 * still-open interval's own provisional row).
 *
 * The frontend already fetches that same provisional value for the
 * "Current Demand" KPI (GET .../demand/current, analytics.demand_state --
 * recalculated every ~1 minute for the still-open interval, see
 * AssetView.tsx's own header). Appending it here to the chart -- but ONLY
 * when its interval_start actually falls within the chart's own requested
 * window -- closes that gap to a plain, unavoidable "an interval isn't
 * final until it's over" without touching analytics.demand_intervals,
 * finalization timing, or any other backend behavior.
 */
export function buildDemandChartPoints(
  series: DemandIntervalPoint[],
  current: AssetCurrentDemandResponse | null,
  requestedRange: { from: string; to: string },
): ChartPoint[] {
  const points: ChartPoint[] = series.map((point) => ({
    t: Date.parse(point.interval_start),
    value: point.demand_kw,
  }));

  if (!current?.has_data || current.current_demand_kw === null || !current.interval_start) {
    return points;
  }

  const currentT = Date.parse(current.interval_start);
  const fromT = Date.parse(requestedRange.from);
  const toT = Date.parse(requestedRange.to);
  const lastFinalizedT = points.length > 0 ? points[points.length - 1]!.t : -Infinity;

  // Only append when the live interval is actually inside the requested
  // window (a closed "Yesterday" window, for example, never includes it)
  // and it isn't already represented by a finalized point.
  if (currentT >= fromT && currentT < toT && currentT > lastFinalizedT) {
    points.push({ t: currentT, value: current.current_demand_kw });
  }

  return points;
}
