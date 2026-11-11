/**
 * Statistics (F6): one compact table below the chart, one row per charted
 * series -- Series · Total (Energy only) · Average · Minimum · Maximum --
 * ordered by data point (Energy first, then alphabetically) with assets in a
 * consistent order within each (analyticsStatisticsModel.ts), without group
 * headings. Minimum and Maximum show values only (Product Owner, 2026-10-10:
 * no times and no data-quality notes; Data quality covers those). Each series
 * wears its chart colour. Absent when nothing is charted (general rule).
 */
import { useMemo } from "react";
import type { AnalyticsCatalogResponse, AnalyticsSeriesResponse } from "../../api/types";
import { SeriesSwatch, formatValue, seriesStyleForSlot, type SeriesStyle } from "../../components/ChartFrame";
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

export function AnalyticsStatistics({
  response,
  catalog,
  styles,
}: {
  response: AnalyticsSeriesResponse | null;
  catalog: AnalyticsCatalogResponse | null;
  /** Series colours by series key, shared with the chart. */
  styles?: ReadonlyMap<string, SeriesStyle>;
}) {
  const { rows, showTotal } = useMemo(() => buildStatistics(response, catalog), [response, catalog]);
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
            {rows.map((row, index) => (
              <tr key={row.key} data-testid="analytics-statistics-row">
                <th scope="row" className="analytics-stats__series">
                  <SeriesSwatch kind={row.kind} style={styles?.get(row.key) ?? seriesStyleForSlot(index)} />
                  {row.name}
                </th>
                {showTotal ? <td>{row.total === undefined ? "" : valueText(row.total, row.unit)}</td> : null}
                <td>{valueText(row.average, row.unit)}</td>
                <td>{valueText(row.min, row.unit)}</td>
                <td>{valueText(row.max, row.unit)}</td>
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
