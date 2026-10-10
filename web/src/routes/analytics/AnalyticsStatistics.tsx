/**
 * Statistics (F6): one compact table below the chart, one row per charted
 * series -- Series · Total (Energy only) · Average · Minimum · Maximum --
 * grouped by data point (Energy first, then alphabetically), assets in a
 * consistent order within each group (analyticsStatisticsModel.ts). Minimum
 * and Maximum show values only (Product Owner, 2026-10-10: no times), with a
 * short disclosure when that period includes Energy from missing readings
 * (README "Statistics"; ADR-022 Amendment 7). Each series wears its chart
 * colour. Absent when nothing is charted (general rule).
 */
import { useMemo } from "react";
import type { AnalyticsCatalogResponse, AnalyticsSeriesResponse } from "../../api/types";
import { SeriesSwatch, formatValue, seriesStyleForSlot, type SeriesStyle } from "../../components/ChartFrame";
import { DQ_TEXT } from "./analyticsDataQualityModel";
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

function Extreme({ value, afterMissing, unit }: { value: number | null; afterMissing: boolean; unit: string | null }) {
  return (
    <>
      <span className="analytics-stats__value">{valueText(value, unit)}</span>
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
  styles,
}: {
  response: AnalyticsSeriesResponse | null;
  catalog: AnalyticsCatalogResponse | null;
  /** Series colours by series key, shared with the chart. */
  styles?: ReadonlyMap<string, SeriesStyle>;
}) {
  const { groups, rows, showTotal } = useMemo(() => buildStatistics(response, catalog), [response, catalog]);
  if (rows.length === 0) return null;
  const columns = showTotal ? 5 : 4;
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
          {groups.map((group) => (
            <tbody key={group.dataPoint} data-testid="analytics-statistics-group">
              <tr className="analytics-stats__group">
                <th scope="rowgroup" colSpan={columns} data-testid="analytics-statistics-group-label">
                  {group.label}
                </th>
              </tr>
              {group.rows.map((row) => (
                <tr key={row.key} data-testid="analytics-statistics-row">
                  <th scope="row" className="analytics-stats__series">
                    <SeriesSwatch kind={row.kind} style={styles?.get(row.key) ?? seriesStyleForSlot(rows.indexOf(row))} />
                    {row.name}
                  </th>
                  {showTotal ? <td>{row.total === undefined ? "" : valueText(row.total, row.unit)}</td> : null}
                  <td>{valueText(row.average, row.unit)}</td>
                  <td>
                    <Extreme value={row.min} afterMissing={row.minAfterMissing} unit={row.unit} />
                  </td>
                  <td>
                    <Extreme value={row.max} afterMissing={row.maxAfterMissing} unit={row.unit} />
                  </td>
                </tr>
              ))}
            </tbody>
          ))}
        </table>
      </div>
      <p className="analytics-stats__basis" data-testid="analytics-statistics-basis">
        {STATISTICS_NOTE.completedOnly}
        {showTotal ? ` ${STATISTICS_NOTE.totalIncludesCurrent}` : null}
      </p>
    </section>
  );
}
