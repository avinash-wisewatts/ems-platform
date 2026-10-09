/**
 * Statistics (F6): one compact table below the chart, one row per charted
 * series -- Series · Total (Energy only) · Average · Minimum · Maximum, with
 * the site-local time beneath Minimum and Maximum (the date only at daily
 * resolution) and a short disclosure when that period includes Energy from
 * missing readings (README "Statistics"; ADR-022 Amendment 7). Absent when
 * nothing is charted (general rule).
 */
import { useMemo } from "react";
import type { AnalyticsCatalogResponse, AnalyticsSeriesResponse } from "../../api/types";
import { formatValue, seriesColor } from "../../components/ChartFrame";
import { DQ_TEXT, periodTime } from "./analyticsDataQualityModel";
import { buildStatistics } from "./analyticsStatisticsModel";

const NOT_AVAILABLE = "—";

/** The summary's basis (ADR-022 Amendment 7, wording approved 2026-10-09):
 *  the API computes Average / Minimum / Maximum over completed periods and
 *  Total over every period with a value, the in-progress one included. The
 *  Total sentence is shown only when the Total column is. */
export const STATISTICS_NOTE = {
  completedOnly: "Average, Minimum and Maximum use completed periods only.",
  totalIncludesCurrent: "Total includes the current, in-progress period.",
} as const;

function valueText(value: number | null | undefined, unit: string | null): string {
  if (value == null) return NOT_AVAILABLE;
  return unit ? `${formatValue(value)} ${unit}` : formatValue(value);
}

function Extreme({
  value,
  at,
  afterMissing,
  unit,
  timeZone,
  dateOnly,
}: {
  value: number | null;
  at: string | null;
  afterMissing: boolean;
  unit: string | null;
  timeZone: string | null | undefined;
  dateOnly: boolean;
}) {
  return (
    <>
      <span className="analytics-stats__value">{valueText(value, unit)}</span>
      {at ? <span className="analytics-stats__time">{periodTime(Date.parse(at), timeZone, dateOnly)}</span> : null}
      {afterMissing ? (
        <span className="analytics-stats__note" data-testid="analytics-statistics-after-missing">
          {DQ_TEXT.tipAfterMissing}
        </span>
      ) : null}
    </>
  );
}

export function AnalyticsStatistics({
  response,
  catalog,
  timeZone,
}: {
  response: AnalyticsSeriesResponse | null;
  catalog: AnalyticsCatalogResponse | null;
  timeZone: string | null | undefined;
}) {
  const { rows, showTotal, dateOnly } = useMemo(() => buildStatistics(response, catalog), [response, catalog]);
  if (rows.length === 0) return null;
  return (
    <section className="analytics-card analytics-stats" data-testid="analytics-statistics" aria-labelledby="analytics-stats-heading">
      <h2 id="analytics-stats-heading" className="analytics-card__title">
        Statistics
      </h2>
      <div className="analytics-stats__scroll">
        <table className="analytics-stats__table">
          <thead>
            <tr>
              <th scope="col">Series</th>
              {showTotal ? <th scope="col">Total</th> : null}
              <th scope="col">Average</th>
              <th scope="col">Minimum</th>
              <th scope="col">Maximum</th>
            </tr>
          </thead>
          <tbody>
            {rows.map((row) => (
              <tr key={row.key} data-testid="analytics-statistics-row">
                <th scope="row" className="analytics-stats__series">
                  <span className="chart-frame__swatch" style={{ background: seriesColor(row.index) }} aria-hidden="true" />
                  {row.name}
                </th>
                {showTotal ? <td>{row.total === undefined ? "" : valueText(row.total, row.unit)}</td> : null}
                <td>{valueText(row.average, row.unit)}</td>
                <td>
                  <Extreme value={row.min} at={row.minAt} afterMissing={row.minAfterMissing} unit={row.unit} timeZone={timeZone} dateOnly={dateOnly} />
                </td>
                <td>
                  <Extreme value={row.max} at={row.maxAt} afterMissing={row.maxAfterMissing} unit={row.unit} timeZone={timeZone} dateOnly={dateOnly} />
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
      <p className="analytics-stats__basis" data-testid="analytics-statistics-basis">
        {STATISTICS_NOTE.completedOnly}
        {showTotal ? ` ${STATISTICS_NOTE.totalIncludesCurrent}` : null}
      </p>
    </section>
  );
}
