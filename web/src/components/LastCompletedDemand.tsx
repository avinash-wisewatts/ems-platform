/**
 * The last completed demand interval (T1.3a, revised run 11): the only way
 * the Admin Portal presents calculated demand. Shows the interval's own
 * site-local start-end, its value and its data-quality status. No
 * provisional or in-progress value is shown (D-011), and only a VALID
 * interval's value is presented as demand (components/demandInterval.ts):
 * an INCOMPLETE or unavailable interval shows its status and no value.
 * Calculated demand only -- instantaneous power is not shown here.
 */

import type { DemandIntervalPoint } from "../api/types";
import {
  completedIntervalStatusText,
  demandIntervalLengthLabel,
  formatDemandInterval,
  reliableDemandKw,
} from "./demandInterval";

export function LastCompletedDemand({
  lastCompleted,
  siteTimezone,
  testIdPrefix,
  valueClassName = "value",
  compact = false,
}: {
  lastCompleted: DemandIntervalPoint | null | undefined;
  siteTimezone: string | null;
  /** Test IDs are `${testIdPrefix}` (compact only), `${testIdPrefix}-value`,
   *  `${testIdPrefix}-interval`, `${testIdPrefix}-status` and
   *  `${testIdPrefix}-none`. */
  testIdPrefix: string;
  /** Class of the value line; screens use their own figure style. */
  valueClassName?: string;
  /** One line with the unit, for small KPI cells. */
  compact?: boolean;
}) {
  if (!lastCompleted) {
    return compact ? (
      <span data-testid={`${testIdPrefix}-none`}>No completed interval in the last 7 days</span>
    ) : (
      <p className="hint" data-testid={`${testIdPrefix}-none`}>
        No completed demand interval in the last 7 days.
      </p>
    );
  }

  const kw = reliableDemandKw(lastCompleted);
  const interval = formatDemandInterval(lastCompleted.interval_start, lastCompleted.interval_end, siteTimezone);
  const status = completedIntervalStatusText(lastCompleted);

  if (compact) {
    return (
      <span data-testid={testIdPrefix}>
        {kw !== null ? (
          <span data-testid={`${testIdPrefix}-value`}>{kw.toFixed(1)} kW</span>
        ) : (
          <span data-testid={`${testIdPrefix}-status`}>{status}</span>
        )}
        <span className="hint" data-testid={`${testIdPrefix}-interval`}>
          {" "}
          · {interval}
        </span>
      </span>
    );
  }

  return (
    <>
      <p className={valueClassName} data-testid={`${testIdPrefix}-value`}>
        {kw !== null ? kw.toFixed(1) : "—"}
      </p>
      <p className="hint" data-testid={`${testIdPrefix}-interval`}>
        Last completed {demandIntervalLengthLabel(lastCompleted.interval_start, lastCompleted.interval_end)} interval{" "}
        {interval}
      </p>
      <p className="hint" data-testid={`${testIdPrefix}-status`}>
        {status}
      </p>
    </>
  );
}
