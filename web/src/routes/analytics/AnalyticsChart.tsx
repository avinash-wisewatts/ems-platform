/**
 * Analytics chart card (F5): the title, the toolbar and the multi-series chart
 * of the last successful Update. The chart is drawn from the applied query
 * only -- never the draft -- so it is unchanged while filters have unapplied
 * changes. Toolbar: Export CSV (F7) and Collapse / Expand only (D27), as icon
 * buttons with an accessible name and a tooltip; Statistics and Data quality
 * follow the card (F6), and the tooltip carries each period's Data quality
 * lines. Series colours come from the page (analyticsSeriesStyles.ts); the
 * legend shows and hides series, which changes neither the CSV nor the
 * Statistics.
 */
import { useId, useMemo, useState } from "react";
import type { AnalyticsCatalogResponse } from "../../api/types";
import { MultiSeriesChartFrame, type SeriesStyle } from "../../components/ChartFrame";
import { downloadCsv } from "../../export/downloadCsv";
import { analyticsCsvFilename, buildAnalyticsCsv } from "./analyticsCsvModel";
import { buildChartModel, chartTitle } from "./analyticsChartModel";
import type { AppliedQuery } from "./useAnalyticsState";

export const TOOLBAR_LABELS = {
  exportCsv: "Export CSV",
  collapse: "Collapse chart",
  expand: "Expand chart",
} as const;

function DownloadIcon() {
  return (
    <svg viewBox="0 0 16 16" aria-hidden="true" focusable="false">
      <path d="M8 2v8M4.5 6.5 8 10l3.5-3.5M2.5 12.5v1h11v-1" fill="none" stroke="currentColor" strokeWidth="1.6" strokeLinecap="round" strokeLinejoin="round" />
    </svg>
  );
}

/** Up: the body is shown and the button collapses it; down: it expands it. */
function ChevronIcon({ direction }: { direction: "up" | "down" }) {
  return (
    <svg viewBox="0 0 16 16" aria-hidden="true" focusable="false" data-direction={direction}>
      <path
        d={direction === "up" ? "M3.5 10 8 5.5l4.5 4.5" : "M3.5 6 8 10.5 12.5 6"}
        fill="none"
        stroke="currentColor"
        strokeWidth="1.8"
        strokeLinecap="round"
        strokeLinejoin="round"
      />
    </svg>
  );
}

export function AnalyticsChart({
  applied,
  catalog,
  timeZone,
  siteName,
  styles,
  width,
}: {
  applied: AppliedQuery;
  catalog: AnalyticsCatalogResponse | null;
  timeZone: string | null | undefined;
  /** for the CSV filename (D31) */
  siteName?: string | null;
  /** Series colours by series key, shared with Statistics. */
  styles?: ReadonlyMap<string, SeriesStyle>;
  /** fixed chart width for tests */
  width?: number;
}) {
  const [collapsed, setCollapsed] = useState(false);
  const bodyId = `analytics-chart-body-${useId().replace(/[^a-zA-Z0-9_-]/g, "")}`;
  const model = useMemo(
    () => buildChartModel(applied.response, applied.range, catalog, timeZone, styles),
    [applied, catalog, timeZone, styles],
  );
  const title = chartTitle(applied, catalog, timeZone);
  const canExport = (applied.response?.series.length ?? 0) > 0;
  // The full applied range and every series, never the zoomed window or only
  // the series shown in the legend (D28).
  const exportCsv = () =>
    downloadCsv(
      analyticsCsvFilename(siteName, applied.range, timeZone),
      buildAnalyticsCsv(applied.response, catalog, timeZone),
    );
  const toggleLabel = collapsed ? TOOLBAR_LABELS.expand : TOOLBAR_LABELS.collapse;

  return (
    <section className="analytics-chart" data-testid="analytics-chart" aria-label="Chart">
      <header className="analytics-chart__header">
        <h2 className="analytics-chart__title" data-testid="analytics-chart-title">
          {title}
        </h2>
        <div className="analytics-chart__toolbar" role="group" aria-label="Chart options">
          <button
            type="button"
            className="analytics-chart__tool"
            aria-label={TOOLBAR_LABELS.exportCsv}
            title={TOOLBAR_LABELS.exportCsv}
            disabled={!canExport}
            onClick={exportCsv}
            data-testid="analytics-chart-export-csv"
          >
            <DownloadIcon />
          </button>
          <button
            type="button"
            className="analytics-chart__tool"
            aria-label={toggleLabel}
            title={toggleLabel}
            aria-expanded={!collapsed}
            aria-controls={bodyId}
            onClick={() => setCollapsed((c) => !c)}
            data-testid="analytics-chart-collapse"
          >
            <ChevronIcon direction={collapsed ? "down" : "up"} />
          </button>
        </div>
      </header>
      {/* Hidden, not unmounted: collapsing keeps the zoom and hidden series. */}
      <div id={bodyId} className="analytics-chart__body" hidden={collapsed} data-testid="analytics-chart-body">
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
