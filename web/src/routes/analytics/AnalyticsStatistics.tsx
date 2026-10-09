/**
 * Statistics (F6): one compact table below the chart, one row per charted
 * series -- Series · Total (Energy only) · Average · Minimum · Maximum, with
 * the site-local time beneath Minimum and Maximum (README "Statistics").
 * Absent when nothing is charted (general rule).
 */
import { useMemo } from "react";
import type { AnalyticsCatalogResponse, AnalyticsSeriesResponse } from "../../api/types";
import { formatValue, seriesColor } from "../../components/ChartFrame";
import { formatSiteLocalDateTime } from "../../time/siteLocalTicks";
import { buildStatistics } from "./analyticsStatisticsModel";

const NOT_AVAILABLE = "—";

function valueText(value: number | null | undefined, unit: string | null): string {
  if (value == null) return NOT_AVAILABLE;
  return unit ? `${formatValue(value)} ${unit}` : formatValue(value);
}

function Extreme({ value, at, unit, timeZone }: { value: number | null; at: string | null; unit: string | null; timeZone: string | null | undefined }) {
  return (
    <>
      <span className="analytics-stats__value">{valueText(value, unit)}</span>
      {at ? <span className="analytics-stats__time">{formatSiteLocalDateTime(Date.parse(at), timeZone)}</span> : null}
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
            {rows.map((row) => (
              <tr key={row.key} data-testid="analytics-statistics-row">
                <th scope="row" className="analytics-stats__series">
                  <span className="chart-frame__swatch" style={{ background: seriesColor(row.index) }} aria-hidden="true" />
                  {row.name}
                </th>
                {showTotal ? <td>{row.total === undefined ? "" : valueText(row.total, row.unit)}</td> : null}
                <td>{valueText(row.average, row.unit)}</td>
                <td>
                  <Extreme value={row.min} at={row.minAt} unit={row.unit} timeZone={timeZone} />
                </td>
                <td>
                  <Extreme value={row.max} at={row.maxAt} unit={row.unit} timeZone={timeZone} />
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
    </section>
  );
}
