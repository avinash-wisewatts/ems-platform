/**
 * Analytics chart card (F5): the title, the Collapse / Expand toolbar and the
 * multi-series chart of the last successful Update. The chart is drawn from
 * the applied query only -- never the draft -- so it is unchanged while
 * filters have unapplied changes. Toolbar: Export CSV (F7) and Collapse /
 * Expand only (D27); Statistics and Data quality follow the card (F6), and
 * the tooltip carries each period's Data quality lines.
 */
import { useMemo, useState } from "react";
import type { AnalyticsCatalogResponse } from "../../api/types";
import { MultiSeriesChartFrame } from "../../components/ChartFrame";
import { downloadCsv } from "../../export/downloadCsv";
import { analyticsCsvFilename, buildAnalyticsCsv } from "./analyticsCsvModel";
import { buildChartModel, chartTitle } from "./analyticsChartModel";
import type { AppliedQuery } from "./useAnalyticsState";

export function AnalyticsChart({
  applied,
  catalog,
  timeZone,
  siteName,
  width,
}: {
  applied: AppliedQuery;
  catalog: AnalyticsCatalogResponse | null;
  timeZone: string | null | undefined;
  /** for the CSV filename (D31) */
  siteName?: string | null;
  /** fixed chart width for tests */
  width?: number;
}) {
  const [collapsed, setCollapsed] = useState(false);
  const model = useMemo(
    () => buildChartModel(applied.response, applied.range, catalog, timeZone),
    [applied, catalog, timeZone],
  );
  const title = chartTitle(applied, catalog, timeZone);
  const canExport = (applied.response?.series.length ?? 0) > 0;
  // The full applied range, never the zoomed window (D28).
  const exportCsv = () =>
    downloadCsv(
      analyticsCsvFilename(siteName, applied.range, timeZone),
      buildAnalyticsCsv(applied.response, catalog, timeZone),
    );

  return (
    <section className="analytics-chart" data-testid="analytics-chart" aria-label="Chart">
      <header className="analytics-chart__header">
        <h2 className="analytics-chart__title" data-testid="analytics-chart-title">
          {title}
        </h2>
        <div className="analytics-chart__toolbar">
          <button
            type="button"
            className="analytics-chart__tool"
            disabled={!canExport}
            onClick={exportCsv}
            data-testid="analytics-chart-export-csv"
          >
            Export CSV
          </button>
          <button
            type="button"
            className="analytics-chart__tool"
            aria-expanded={!collapsed}
            onClick={() => setCollapsed((c) => !c)}
            data-testid="analytics-chart-collapse"
          >
            {collapsed ? "Expand" : "Collapse"}
          </button>
        </div>
      </header>
      {/* Hidden, not unmounted: collapsing keeps the zoom. */}
      <div className="analytics-chart__body" hidden={collapsed} data-testid="analytics-chart-body">
        <MultiSeriesChartFrame
          buckets={model.buckets}
          series={model.series}
          range={model.range}
          timeZone={timeZone}
          dateOnly={applied.response?.resolution === "1d"}
          ariaLabel={title}
          width={width}
        />
      </div>
    </section>
  );
}
