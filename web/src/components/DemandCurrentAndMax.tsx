/**
 * The shared Current Demand / Peak Power presentation, used identically by
 * both the Asset View Demand tile and the Site-level Demand Overview page
 * -- a single implementation rather than duplicating this markup in both
 * places (matching how findPeak, demandStatusLabel, etc. already have
 * exactly one home). Component name is unchanged even though the second
 * metric is no longer "Max Demand" -- kept as the one shared component
 * per its own product decision, not renamed for this label change.
 *
 * Current Demand is the caller's already-fetched current_demand_kw (the
 * latest calculated 15-minute demand interval, still updating). Peak Power
 * is the caller's already-computed MAX(peak_power_kw) over the selected
 * period (demand/DemandOverview.tsx's exported findPeak -- see its own doc
 * comment) -- a DIFFERENT figure from Current Demand's demand_kw: the
 * highest INSTANTANEOUS power sample observed within any interval in the
 * period, not a second demand_kw-based figure. Never labelled "Demand" --
 * kept explicitly distinct in both label and value.
 *
 * The value uses the "value" CSS class -- the SAME class the Energy
 * current-value figure uses on both Energy Overview and (via
 * kpi-card__value, which shares its rule) the Asset View Energy tile, so
 * Current Demand reads with the same visual prominence as the equivalent
 * Energy figure on each screen, not a separate look invented for Demand.
 */

import { formatTimeAndDateInTimeZone } from "../time/format";

export function DemandCurrentAndMax({
  currentDemandKw,
  peakPower,
  siteTimezone,
  testIdPrefix,
}: {
  currentDemandKw: number | null;
  peakPower: { kw: number; at: string } | null;
  siteTimezone: string | null;
  /** Test IDs are `${testIdPrefix}-current` and `${testIdPrefix}-peak`. */
  testIdPrefix: string;
}) {
  return (
    <>
      <p className="value" data-testid={`${testIdPrefix}-current`}>
        {currentDemandKw?.toFixed(1) ?? "—"}
      </p>
      <p className="hint demand-current-caption">Latest 15-min interval</p>
      <div className="demand-peak" data-testid={`${testIdPrefix}-peak`}>
        <span className="demand-peak__label">Peak Power</span>
        <span className="demand-peak__value">
          {peakPower
            ? `${peakPower.kw.toFixed(1)} kW   ${formatTimeAndDateInTimeZone(peakPower.at, siteTimezone)}`
            : "Not recorded for this period yet."}
        </span>
      </div>
    </>
  );
}
