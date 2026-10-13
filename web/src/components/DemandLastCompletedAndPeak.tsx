/**
 * The shared Demand (last completed interval) / Peak Power presentation for the
 * Site-level Demand Overview page -- one implementation rather than
 * duplicating this markup (matching how findPeak etc. already have exactly
 * one home). Asset View's Demand tile uses LastCompletedDemand directly
 * with its own "Max Demand" figure (assetView/assetDemand.ts).
 *
 * T1.3a (revised run 11): demand is the last completed interval only
 * (LastCompletedDemand): its site-local start-end, value and data-quality
 * status. No provisional or in-progress value is shown (D-011). Peak Power
 * is shown either way.
 *
 * Peak Power is the caller's already-computed MAX(peak_power_kw) over the
 * selected period (demand/DemandOverview.tsx's exported findPeak -- see its
 * own doc comment) -- a DIFFERENT figure from the interval's demand_kw: the
 * highest INSTANTANEOUS power sample observed within any interval in the
 * period, not a second demand_kw-based figure. Never labelled "Demand" --
 * kept explicitly distinct in both label and value.
 *
 * The value uses the "value" CSS class -- the SAME class the Energy
 * current-value figure uses on Energy Overview, so the demand figure reads
 * with the same visual prominence as the equivalent Energy figure.
 */

import { formatTimeAndDateInTimeZone } from "../time/format";
import type { DemandIntervalPoint } from "../api/types";
import { LastCompletedDemand } from "./LastCompletedDemand";

export function DemandLastCompletedAndPeak({
  lastCompleted,
  peakPower,
  siteTimezone,
  testIdPrefix,
}: {
  lastCompleted: DemandIntervalPoint | null | undefined;
  peakPower: { kw: number; at: string } | null;
  siteTimezone: string | null;
  /** Test IDs are `${testIdPrefix}-last-completed-*` (LastCompletedDemand)
   *  and `${testIdPrefix}-peak`. */
  testIdPrefix: string;
}) {
  return (
    <>
      <LastCompletedDemand
        lastCompleted={lastCompleted}
        siteTimezone={siteTimezone}
        testIdPrefix={`${testIdPrefix}-last-completed`}
      />
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
