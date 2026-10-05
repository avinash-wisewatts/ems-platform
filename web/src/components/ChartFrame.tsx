/**
 * The single charting foundation for the whole application.
 *
 * Library: **Recharts** (MIT). Rationale (from the Phase 8 readiness audit):
 *   - React-native, declarative, SVG -- renders and is assertable in jsdom,
 *     so component tests are cheap and reliable;
 *   - MIT-licensed, widely used, actively maintained;
 *   - adequate time-series support (line/area, time axis, tooltip, legend)
 *     for the foundation, which has no feature dashboards yet.
 * Known trade-off: SVG rendering is slower than a canvas library (uPlot,
 * ECharts) at very high point counts. That is why every screen goes through
 * THIS component and never imports a chart library directly -- if a later
 * phase hits a real performance wall with real data volumes, swapping the
 * implementation here is a contained change with no call-site churn.
 *
 * No other charting library may be added. No feature-specific charts here.
 *
 * Two modes:
 *   - ChartFrame: one series (line / area / bar) -- the original foundation,
 *     unchanged for its existing callers.
 *   - MultiSeriesChartFrame: several series on one time grid, bars and lines,
 *     one Y axis per unit, legend, drag-to-zoom, range slider and Show all.
 *     Bar series are drawn as ONE SVG path per series (Recharts Customized),
 *     not one element per bucket: measured 2026-10-05, per-bucket SVG bars
 *     took 17-28 s to first paint at 25 series x 30 days of 15-minute
 *     buckets, a path per series well under 1 s. When bars would be narrower
 *     than one pixel they are drawn downsampled -- each series' extreme value
 *     per pixel column (layoutBars) -- because rasterising thousands of
 *     sub-pixel bars made zoom take over 1 s; the data is never changed.
 */

import { useCallback, useId, useMemo, useState, type ReactElement } from "react";
import {
  Area,
  AreaChart,
  Bar,
  BarChart,
  Brush,
  CartesianGrid,
  ComposedChart,
  Customized,
  Line,
  LineChart,
  ReferenceArea,
  ResponsiveContainer,
  Tooltip,
  XAxis,
  YAxis,
} from "recharts";
import type { CategoricalChartState } from "recharts/types/chart/types";
import { formatSiteLocalDateTime, siteLocalTicks } from "../time/siteLocalTicks";

export type ChartPoint = {
  /** epoch milliseconds (UTC) */
  t: number;
  /** the plotted value; null renders a gap, never 0 */
  value: number | null;
};

export type ChartFrameProps = {
  points: ChartPoint[];
  /** axis / tooltip labels */
  valueLabel: string;
  unit?: string;
  height?: number;
  /** fixed width for tests / non-responsive contexts */
  width?: number;
  ariaLabel?: string;
  /** "line" (default, unchanged), a filled "area" rendering, or a "bar"
   *  rendering -- still the same Recharts foundation, same data contract;
   *  purely a presentation choice for screens (e.g. the WiseWatts Main
   *  Dashboard Load Trend card's "area", and its Energy Usage card's "bar")
   *  that want something other than a bare line. No new chart library, no
   *  feature-specific chart component. */
  variant?: "line" | "area" | "bar";
  /** IANA timezone (e.g. a site's own `timezone`) for the X-axis ticks and
   *  the tooltip's timestamp -- omitted (the default) keeps every existing
   *  caller's current UTC-ISO rendering exactly as-is; a caller opts in
   *  only when it has a real site timezone to show data in, rather than
   *  this component guessing one. */
  timeZone?: string | null;
  /** Shows `unit` as a Y-axis label (e.g. "kW") when true. Defaults to
   *  false so existing callers that already pass `unit` for the tooltip
   *  (Demand Overview, Energy, Power Quality, Main Dashboard) keep their
   *  current axis exactly as-is; a caller opts in per chart. */
  axisUnitLabel?: boolean;
};

function formatTick(t: number, timeZone?: string | null): string {
  if (!timeZone) return new Date(t).toISOString().slice(5, 16).replace("T", " ");
  return new Intl.DateTimeFormat("en-GB", {
    timeZone,
    month: "2-digit",
    day: "2-digit",
    hour: "2-digit",
    minute: "2-digit",
    hour12: false,
  }).format(new Date(t));
}

function formatTooltipLabel(t: number, timeZone?: string | null): string {
  if (!timeZone) return new Date(t).toISOString();
  return new Intl.DateTimeFormat("en-GB", {
    timeZone,
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
    hour: "2-digit",
    minute: "2-digit",
    hour12: false,
  }).format(new Date(t));
}

/** Rounds a plotted value to 2 decimal places -- universal across every
 *  chart (Y-axis ticks and the hover tooltip), since raw JS floats
 *  (e.g. from an unrounded division upstream) were otherwise showing with
 *  far more precision than any of this app's figures are ever displayed
 *  with elsewhere (KPI tiles, live-parameter readings, etc. all round to a
 *  fixed, small number of decimals). Non-numeric values pass through
 *  unchanged (Recharts can call a tick formatter with a non-numeric axis
 *  value in edge cases). */
export function formatValue(v: unknown): string {
  return typeof v === "number" ? v.toFixed(2) : String(v);
}

export function ChartFrame({
  points,
  valueLabel,
  unit,
  height = 280,
  width,
  ariaLabel,
  variant = "line",
  timeZone,
  axisUnitLabel = false,
}: ChartFrameProps) {
  const label = ariaLabel ?? `${valueLabel}${unit ? ` (${unit})` : ""} over time`;
  const gradientId = `chart-frame-area-fill-${useId()}`;

  const sharedAxes = (
    <>
      <CartesianGrid strokeDasharray="3 3" />
      <XAxis
        dataKey="t"
        type="number"
        domain={["dataMin", "dataMax"]}
        tickFormatter={(t: number) => formatTick(t, timeZone)}
        scale="time"
        minTickGap={40}
      />
      <YAxis
        tickFormatter={formatValue}
        width={56}
        // A "bar" series is always a non-negative magnitude (energy, never
        // negative) -- pinning the domain floor to 0 keeps every bar drawn
        // from a true zero baseline. The ceiling stays "auto" (Recharts'
        // own nice-rounded max from the actual data), so the axis still
        // scales dynamically with whatever range/resolution is selected --
        // never a fixed maximum, never clipped, no more headroom than a
        // "nice" rounding already adds. Line/area keep their prior
        // undefined (fully auto) domain -- unchanged behavior.
        domain={variant === "bar" ? [0, "auto"] : undefined}
        label={
          axisUnitLabel && unit
            ? { value: unit, angle: -90, position: "insideLeft", style: { fontSize: 11, fill: "var(--muted)" } }
            : undefined
        }
      />
      <Tooltip
        labelFormatter={(t) => formatTooltipLabel(Number(t), timeZone)}
        formatter={(v) => [formatValue(v), unit ? `${valueLabel} (${unit})` : valueLabel]}
      />
    </>
  );

  const chart =
    variant === "bar" ? (
      <BarChart data={points} margin={{ top: 8, right: 16, bottom: 8, left: 8 }}>
        {sharedAxes}
        <Bar dataKey="value" fill="currentColor" isAnimationActive={false} />
      </BarChart>
    ) : variant === "area" ? (
      <AreaChart data={points} margin={{ top: 8, right: 16, bottom: 8, left: 8 }}>
        <defs>
          <linearGradient id={gradientId} x1="0" y1="0" x2="0" y2="1">
            <stop offset="5%" stopColor="currentColor" stopOpacity={0.35} />
            <stop offset="95%" stopColor="currentColor" stopOpacity={0.02} />
          </linearGradient>
        </defs>
        {sharedAxes}
        <Area
          type="monotone"
          dataKey="value"
          dot={false}
          isAnimationActive={false}
          connectNulls={false}
          strokeWidth={2}
          stroke="currentColor"
          fill={`url(#${gradientId})`}
        />
      </AreaChart>
    ) : (
      <LineChart data={points} margin={{ top: 8, right: 16, bottom: 8, left: 8 }}>
        {sharedAxes}
        <Line
          type="monotone"
          dataKey="value"
          dot={false}
          isAnimationActive={false}
          connectNulls={false}
          strokeWidth={2}
        />
      </LineChart>
    );

  return (
    <figure className="chart-frame" aria-label={label} data-testid="chart-frame">
      {width ? (
        <LineChartFixed width={width} height={height}>
          {chart}
        </LineChartFixed>
      ) : (
        <ResponsiveContainer width="100%" height={height}>
          {chart}
        </ResponsiveContainer>
      )}
    </figure>
  );
}

/** Recharts needs an explicit-size wrapper when not responsive (tests). */
function LineChartFixed({
  width,
  height,
  children,
}: {
  width: number;
  height: number;
  children: ReactElement;
}) {
  return (
    <div style={{ width, height }}>
      <ResponsiveContainer width={width} height={height}>
        {children}
      </ResponsiveContainer>
    </div>
  );
}

// ---- Multi-series mode ---------------------------------------------------------

/** One bucket of the shared time grid, [start, end) in epoch ms. */
export type ChartBucket = { start: number; end: number };

export type ChartSeries = {
  /** Stable identity (React keys, colour order). */
  key: string;
  /** Legend and tooltip name. */
  name: string;
  /** Series sharing a unit share a Y axis. */
  unit: string | null;
  kind: "bar" | "line";
  /** One value per bucket, aligned with `buckets`; null is a gap, never 0. */
  values: readonly (number | null)[];
};

/** Visible window as inclusive bucket indices; null = the whole range. */
export type ChartView = { start: number; end: number };

export type MultiSeriesChartFrameProps = {
  buckets: readonly ChartBucket[];
  series: readonly ChartSeries[];
  /** The X axis covers exactly [from, to] (epoch ms) when not zoomed. */
  range: { from: number; to: number };
  /** IANA timezone for ticks and the tooltip time (UTC when absent). */
  timeZone?: string | null;
  ariaLabel: string;
  height?: number;
  /** fixed width for tests / non-responsive contexts */
  width?: number;
};

/** Series colours, in series order (repeating beyond twelve). */
export const SERIES_COLORS = [
  "#03a9a0",
  "#0f4694",
  "#ff9966",
  "#8e5ea2",
  "#d4a200",
  "#d94f70",
  "#3e9b4f",
  "#6b7a8f",
  "#00a6d6",
  "#b5651d",
  "#7cb342",
  "#c2185b",
] as const;

export const seriesColor = (index: number): string => SERIES_COLORS[index % SERIES_COLORS.length]!;

export type ChartRow = Record<string, number | null> & { t: number; tEnd: number };

/** Recharts data key of the series at `index` (series keys may be any text). */
const dataKeyOf = (index: number) => `s${index}`;
const axisIdOf = (unit: string | null) => `unit:${unit ?? ""}`;
/** A hidden, flat series on a hidden axis: gives the tooltip a payload when
 *  every visible series is a Customized bar path. Never shown, never scaled. */
const ANCHOR_KEY = "__anchor";
const ANCHOR_AXIS = "__anchor";

/** Chart rows: one per bucket, each series under its data key. */
export function chartRows(buckets: readonly ChartBucket[], series: readonly ChartSeries[]): ChartRow[] {
  return buckets.map((bucket, i) => {
    const row = { t: bucket.start, tEnd: bucket.end, [ANCHOR_KEY]: 0 } as ChartRow;
    series.forEach((s, j) => {
      row[dataKeyOf(j)] = s.values[i] ?? null;
    });
    return row;
  });
}

/** The X domain: the whole range, or the zoomed buckets clipped to it. */
export function viewDomain(
  view: ChartView | null,
  buckets: readonly ChartBucket[],
  range: { from: number; to: number },
): [number, number] {
  const first = view ? buckets[view.start] : undefined;
  const last = view ? buckets[view.end] : undefined;
  if (!first || !last) return [range.from, range.to];
  return [Math.max(range.from, first.start), Math.min(range.to, last.end)];
}

/** Index of the bucket starting at `t` (bucket starts are ascending). */
function bucketIndex(buckets: readonly ChartBucket[], t: number): number {
  let lo = 0;
  let hi = buckets.length - 1;
  while (lo <= hi) {
    const mid = (lo + hi) >> 1;
    const start = buckets[mid]!.start;
    if (start === t) return mid;
    if (start < t) lo = mid + 1;
    else hi = mid - 1;
  }
  return -1;
}

/** The window between two dragged-over bucket starts (either order); null
 *  for a click without a drag, an unknown bucket, or a selection of every
 *  bucket (that is the whole range, not a zoom). */
export function viewFromSelection(buckets: readonly ChartBucket[], a: number, b: number): ChartView | null {
  const i = bucketIndex(buckets, a);
  const j = bucketIndex(buckets, b);
  if (i < 0 || j < 0 || i === j) return null;
  const view = { start: Math.min(i, j), end: Math.max(i, j) };
  return view.start === 0 && view.end === buckets.length - 1 ? null : view;
}

/** Y domain per unit over the visible buckets. Units with bars start at 0
 *  (a bar is a magnitude from a true zero baseline). */
export function unitDomains(
  series: readonly ChartSeries[],
  view: ChartView | null,
  bucketCount: number,
): Map<string | null, [number, number]> {
  const start = view?.start ?? 0;
  const end = view?.end ?? bucketCount - 1;
  const domains = new Map<string | null, [number, number]>();
  const units = [...new Set(series.map((s) => s.unit))];
  for (const unit of units) {
    let lo = Infinity;
    let hi = -Infinity;
    let hasBar = false;
    for (const s of series) {
      if (s.unit !== unit) continue;
      if (s.kind === "bar") hasBar = true;
      for (let i = start; i <= end; i++) {
        const v = s.values[i];
        if (v == null) continue;
        if (v < lo) lo = v;
        if (v > hi) hi = v;
      }
    }
    if (hasBar) {
      lo = Math.min(lo, 0);
      hi = Math.max(hi, 0);
    }
    if (!Number.isFinite(lo) || !Number.isFinite(hi)) domains.set(unit, [0, 1]);
    else domains.set(unit, lo === hi ? [lo, lo + 1] : [lo, hi]);
  }
  return domains;
}

type BarSpec = { dataKey: string; axisId: string; color: string };
type AxisLike = { scale: (value: number) => number };
type Scale = (value: number) => number;

/** Bars fill 80% of their bucket (10% padding each side), side by side. */
const BAR_FILL = 0.8;
/** Narrower than this many rendered (CSS) pixels, bars are downsampled. */
const MIN_BAR_PX = 1;

export type BarLayout = {
  /** "full": one rectangle per bucket per series. "downsampled": bars would
   *  be narrower than one pixel, so each series keeps its extreme value per
   *  pixel column (visual only -- the data is untouched). */
  mode: "full" | "downsampled";
  paths: { dataKey: string; d: string }[];
};

const rect = (left: number, width: number, from: number, to: number) =>
  `M${left.toFixed(2)} ${from.toFixed(2)}H${(left + width).toFixed(2)}V${to.toFixed(2)}H${left.toFixed(2)}Z`;

/**
 * The bar geometry for the visible buckets `first..last`.
 *
 * Full resolution (every bar at least one pixel wide): per bucket and series
 * a rectangle from zero to the value, the series side by side within the
 * bucket's [start, end) span.
 *
 * Downsampled (some bar would be narrower than one pixel): the plot is cut
 * into columns just wide enough to give every bar series its own one-pixel
 * slot, keeping the grouped layout -- series are never merged. Within a
 * column each series draws ONE bar spanning its most extreme values there
 * (from min(0, lowest) to max(0, highest)), so no peak disappears. Only the
 * drawing changes: the rows, the tooltip and everything else read the data.
 */
export function layoutBars(
  rows: readonly ChartRow[],
  bars: readonly { dataKey: string; y: Scale }[],
  first: number,
  last: number,
  x: Scale,
): BarLayout {
  const n = bars.length;
  if (n === 0 || last < first) return { mode: "full", paths: bars.map((b) => ({ dataKey: b.dataKey, d: "" })) };

  let narrowest = Infinity;
  for (let i = first; i <= last; i++) {
    const row = rows[i];
    if (!row) continue;
    const w = ((x(row.tEnd) - x(row.t)) * BAR_FILL) / n;
    if (w < narrowest) narrowest = w;
  }

  if (narrowest >= MIN_BAR_PX) {
    return {
      mode: "full",
      paths: bars.map((bar, index) => {
        const zero = bar.y(0);
        const parts: string[] = [];
        for (let i = first; i <= last; i++) {
          const row = rows[i];
          const v = row?.[bar.dataKey];
          if (row == null || v == null) continue;
          const x0 = x(row.t);
          const span = x(row.tEnd) - x0;
          const w = (span * BAR_FILL) / n;
          parts.push(rect(x0 + span * 0.1 + index * w, w, zero, bar.y(v)));
        }
        return { dataKey: bar.dataKey, d: parts.join("") };
      }),
    };
  }

  // Column width: one pixel per series inside the 80% fill.
  const column = Math.ceil((n * MIN_BAR_PX) / BAR_FILL);
  const slot = (column * BAR_FILL) / n;
  const origin = x(rows[first]!.t);
  return {
    mode: "downsampled",
    paths: bars.map((bar, index) => {
      const lows = new Map<number, number>();
      const highs = new Map<number, number>();
      for (let i = first; i <= last; i++) {
        const row = rows[i];
        const v = row?.[bar.dataKey];
        if (row == null || v == null) continue;
        const c = Math.floor((x(row.t) - origin) / column);
        lows.set(c, Math.min(lows.get(c) ?? 0, v));
        highs.set(c, Math.max(highs.get(c) ?? 0, v));
      }
      const parts: string[] = [];
      for (const [c, high] of highs) {
        const left = origin + c * column + column * 0.1 + index * slot;
        parts.push(rect(left, slot, bar.y(lows.get(c)!), bar.y(high)));
      }
      return { dataKey: bar.dataKey, d: parts.join("") };
    }),
  };
}

/**
 * Every bar series as ONE path (see layoutBars), rendered through Recharts'
 * Customized, which injects the axis maps; bars are clipped to the plot
 * area. The geometry is memoised on the axis maps, so hover (which leaves
 * them untouched) does not rebuild the paths.
 */
function BarPathsLayer({
  bars,
  rows,
  first,
  last,
  clipId,
  xAxisMap,
  yAxisMap,
}: {
  bars: readonly BarSpec[];
  rows: readonly ChartRow[];
  first: number;
  last: number;
  /** The chart's plot-area clip path (Recharts names it "<chart id>-clip"
   *  but does not pass it to Customized). */
  clipId: string;
  xAxisMap?: Record<string, AxisLike>;
  yAxisMap?: Record<string, AxisLike>;
}) {
  const layout = useMemo<BarLayout | null>(() => {
    const x = xAxisMap ? Object.values(xAxisMap)[0] : undefined;
    if (!x || !yAxisMap) return null;
    const scaled = bars.flatMap((bar) => {
      const y = yAxisMap[bar.axisId];
      return y ? [{ dataKey: bar.dataKey, y: y.scale }] : [];
    });
    return layoutBars(rows, scaled, first, last, x.scale);
  }, [bars, rows, first, last, xAxisMap, yAxisMap]);

  const colours = new Map(bars.map((b) => [b.dataKey, b.color]));
  return (
    <g className="chart-frame__bars" clipPath={`url(#${clipId})`} data-bar-mode={layout?.mode}>
      {(layout?.paths ?? []).map((p) => (
        <path key={p.dataKey} className="chart-frame__bar-series" data-series={p.dataKey} d={p.d} fill={colours.get(p.dataKey)} />
      ))}
    </g>
  );
}

type TooltipEntry = { name: string; unit: string | null; color: string; kind: "bar" | "line"; dataKey: string };

function SeriesTooltip({
  entries,
  rowsByStart,
  timeZone,
  active,
  label,
}: {
  entries: readonly TooltipEntry[];
  rowsByStart: ReadonlyMap<number, ChartRow>;
  timeZone?: string | null;
  // injected by Recharts' Tooltip
  active?: boolean;
  label?: number | string;
}) {
  const row = active && label != null ? rowsByStart.get(Number(label)) : undefined;
  if (!row) return null;
  const values = entries.filter((e) => row[e.dataKey] != null);
  return (
    <div className="chart-frame__tooltip" data-testid="chart-tooltip">
      <p className="chart-frame__tooltip-time">{formatSiteLocalDateTime(row.t, timeZone)}</p>
      {values.length > 0 ? (
        <ul className="chart-frame__tooltip-list">
          {values.map((e) => (
            <li key={e.dataKey}>
              <span className={`chart-frame__swatch chart-frame__swatch--${e.kind}`} style={{ background: e.color }} />
              <span className="chart-frame__tooltip-name">{e.name}</span>
              <span className="chart-frame__tooltip-value">
                {formatValue(row[e.dataKey])}
                {e.unit ? ` ${e.unit}` : ""}
              </span>
            </li>
          ))}
        </ul>
      ) : null}
    </div>
  );
}

const CHART_MARGIN = { top: 8, right: 16, bottom: 8, left: 8 };

/**
 * Several series on one time grid. The X axis shows exactly `range` in the
 * site timezone; bar series are one path each, line series Recharts lines;
 * one Y axis per unit. Drag across the plot to zoom, use the range slider,
 * or Show all to return to the whole range -- zooming changes only what is
 * visible. Remount (change `key`) to reset the zoom.
 */
export function MultiSeriesChartFrame({
  buckets,
  series,
  range,
  timeZone,
  ariaLabel,
  height = 360,
  width,
}: MultiSeriesChartFrameProps) {
  const [view, setView] = useState<ChartView | null>(null);
  const [drag, setDrag] = useState<{ a: number; b: number } | null>(null);
  const chartId = `multi-series-chart-${useId().replace(/[^a-zA-Z0-9_-]/g, "")}`;

  const rows = useMemo(() => chartRows(buckets, series), [buckets, series]);
  const rowsByStart = useMemo(() => new Map(rows.map((r) => [r.t, r])), [rows]);
  const units = useMemo(() => [...new Set(series.map((s) => s.unit))], [series]);
  const domains = useMemo(() => unitDomains(series, view, buckets.length), [series, view, buckets.length]);
  const xDomain = useMemo(() => viewDomain(view, buckets, range), [view, buckets, range]);
  const ticks = useMemo(() => siteLocalTicks(xDomain[0], xDomain[1], timeZone), [xDomain, timeZone]);
  const tickValues = useMemo(() => ticks.map((t) => t.t), [ticks]);
  const tickLabels = useMemo(() => new Map(ticks.map((t) => [t.t, t.label])), [ticks]);
  const formatTickLabel = useCallback((t: number) => tickLabels.get(t) ?? "", [tickLabels]);
  const formatBrushLabel = useCallback((t: number) => formatSiteLocalDateTime(t, timeZone), [timeZone]);

  const bars = useMemo<BarSpec[]>(
    () =>
      series.flatMap((s, i) =>
        s.kind === "bar" ? [{ dataKey: dataKeyOf(i), axisId: axisIdOf(s.unit), color: seriesColor(i) }] : [],
      ),
    [series],
  );
  const entries = useMemo<TooltipEntry[]>(
    () => series.map((s, i) => ({ name: s.name, unit: s.unit, color: seriesColor(i), kind: s.kind, dataKey: dataKeyOf(i) })),
    [series],
  );
  const first = view?.start ?? 0;
  const last = view?.end ?? rows.length - 1;
  // Stable elements: Recharts recomputes its axis maps whenever a child's
  // props change, which would rebuild every bar path on each hover.
  const barsLayer = useMemo(
    () => <BarPathsLayer bars={bars} rows={rows} first={first} last={last} clipId={`${chartId}-clip`} />,
    [bars, rows, first, last, chartId],
  );
  const tooltipContent = useMemo(
    () => <SeriesTooltip entries={entries} rowsByStart={rowsByStart} timeZone={timeZone} />,
    [entries, rowsByStart, timeZone],
  );

  const onBrushChange = useCallback(
    ({ startIndex, endIndex }: { startIndex?: number; endIndex?: number }) => {
      if (startIndex == null || endIndex == null) return;
      setView(startIndex <= 0 && endIndex >= rows.length - 1 ? null : { start: startIndex, end: endIndex });
    },
    [rows.length],
  );
  const labelOf = (state: CategoricalChartState | null | undefined) =>
    state?.activeLabel != null ? Number(state.activeLabel) : null;
  const onMouseDown = (state: CategoricalChartState) => {
    const t = labelOf(state);
    if (t != null) setDrag({ a: t, b: t });
  };
  const onMouseMove = (state: CategoricalChartState) => {
    if (!drag) return;
    const t = labelOf(state);
    if (t != null && t !== drag.b) setDrag({ a: drag.a, b: t });
  };
  const onMouseUp = () => {
    if (!drag) return;
    const next = viewFromSelection(buckets, drag.a, drag.b);
    setDrag(null);
    if (next) setView(next);
  };

  const dragArea = drag && drag.a !== drag.b ? (() => {
    const lo = Math.min(drag.a, drag.b);
    const hiStart = Math.max(drag.a, drag.b);
    return { x1: lo, x2: rowsByStart.get(hiStart)?.tEnd ?? hiStart };
  })() : null;

  const chart = (
    <ComposedChart
      id={chartId}
      data={rows}
      margin={CHART_MARGIN}
      onMouseDown={onMouseDown}
      onMouseMove={onMouseMove}
      onMouseUp={onMouseUp}
      onMouseLeave={() => setDrag(null)}
    >
      <CartesianGrid strokeDasharray="3 3" />
      <XAxis
        dataKey="t"
        type="number"
        scale="linear"
        domain={xDomain}
        allowDataOverflow
        ticks={tickValues}
        tickFormatter={formatTickLabel}
        minTickGap={16}
      />
      {units.map((unit, i) => (
        <YAxis
          key={axisIdOf(unit)}
          yAxisId={axisIdOf(unit)}
          orientation={i % 2 === 0 ? "left" : "right"}
          domain={domains.get(unit)}
          tickFormatter={formatValue}
          width={56}
          label={
            unit
              ? {
                  value: unit,
                  angle: -90,
                  position: i % 2 === 0 ? "insideLeft" : "insideRight",
                  style: { fontSize: 11, fill: "var(--muted)" },
                }
              : undefined
          }
        />
      ))}
      <YAxis yAxisId={ANCHOR_AXIS} hide domain={[0, 1]} />
      <Tooltip content={tooltipContent} isAnimationActive={false} />
      <Customized component={barsLayer} />
      {series.map((s, i) =>
        s.kind === "line" ? (
          <Line
            key={dataKeyOf(i)}
            dataKey={dataKeyOf(i)}
            yAxisId={axisIdOf(s.unit)}
            name={s.name}
            stroke={seriesColor(i)}
            type="linear"
            dot={false}
            strokeWidth={1.5}
            isAnimationActive={false}
            connectNulls={false}
            legendType="none"
          />
        ) : null,
      )}
      <Line
        dataKey={ANCHOR_KEY}
        yAxisId={ANCHOR_AXIS}
        stroke="none"
        dot={false}
        activeDot={false}
        isAnimationActive={false}
        legendType="none"
      />
      {dragArea ? (
        <ReferenceArea yAxisId={ANCHOR_AXIS} x1={dragArea.x1} x2={dragArea.x2} className="chart-frame__zoom-area" />
      ) : null}
      {rows.length > 1 ? (
        <Brush
          dataKey="t"
          height={24}
          travellerWidth={8}
          stroke="var(--ww-navy-600)"
          startIndex={first}
          endIndex={last}
          onChange={onBrushChange}
          tickFormatter={formatBrushLabel}
        />
      ) : null}
    </ComposedChart>
  );

  return (
    <figure className="chart-frame chart-frame--multi" aria-label={ariaLabel} data-testid="multi-series-chart">
      {view ? (
        <div className="chart-frame__zoom-bar">
          <button type="button" className="chart-frame__reset" onClick={() => setView(null)} data-testid="chart-show-all">
            Show all
          </button>
        </div>
      ) : null}
      {width ? (
        <LineChartFixed width={width} height={height}>
          {chart}
        </LineChartFixed>
      ) : (
        <ResponsiveContainer width="100%" height={height}>
          {chart}
        </ResponsiveContainer>
      )}
      {series.length > 0 ? (
        <ul className="chart-frame__legend" data-testid="chart-legend">
          {series.map((s, i) => (
            <li key={s.key} className="chart-frame__legend-item">
              <span className={`chart-frame__swatch chart-frame__swatch--${s.kind}`} style={{ background: seriesColor(i) }} />
              {s.name}
            </li>
          ))}
        </ul>
      ) : null}
    </figure>
  );
}
