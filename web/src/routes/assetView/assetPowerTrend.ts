/**
 * Asset View -- Power Trend chart adapter. Pure mapping from an
 * already-fetched GET .../assets/{id}/power-trend response (migration 246)
 * to ChartFrame's point shape. A distinct shape from demand/
 * DemandOverview.tsx#toChartPoints (sample_time/active_power_kw, a point
 * sample series, not interval_start/demand_kw) -- not the same type, so not
 * reused, only mirrored in spirit.
 */

import type { AssetPowerTrendPoint } from "../../api/types";
import type { ChartPoint } from "../../components/ChartFrame";

export function toPowerTrendChartPoints(series: AssetPowerTrendPoint[]): ChartPoint[] {
  return series.map((point) => ({ t: Date.parse(point.sample_time), value: point.active_power_kw }));
}

/** Whether any sample in the series is an estimated reading -- surfaced as
 *  a plain-language caveat under the chart (is_estimated is the only
 *  data-state signal this endpoint returns; see api/types.ts). */
export function hasEstimatedSamples(series: AssetPowerTrendPoint[]): boolean {
  return series.some((point) => point.is_estimated);
}
