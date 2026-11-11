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
import { formatSiteLocalDate, formatSiteLocalDateTime, siteLocalTicks } from "../time/siteLocalTicks";

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
  /** Optional tooltip lines per bucket, aligned with `buckets` (e.g. a
   *  period's data quality). A bucket with lines is listed in the tooltip
   *  even without a value. */
  notes?: readonly (readonly string[])[];
  /** Colour and pattern; defaults to the series' position. Callers that
   *  want a series to keep its colour across updates pass it. */
  style?: SeriesStyle;
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
  /** Buckets are whole site-local days: the tooltip and range-slider labels
   *  show the date only (no meaningless 00:00). */
  dateOnly?: boolean;
  ariaLabel: string;
  height?: number;
  /** fixed width for tests / non-responsive contexts */
  width?: number;
};

/**
 * Categorical series colours, in this fixed order. A validated set (the
 * dataviz reference palette, with its darker steps for aqua, yellow and
 * magenta): on the white chart panel every hue is at least 3:1 against the
 * background (WCAG 1.4.11 graphical objects; lowest 3.07, yellow), and every
 * adjacent pair is at least ΔE 8.4 apart under simulated colour-vision
 * deficiency and 19.3 under normal vision. The order is part of that
 * guarantee, so keep it. Series are also always named in the legend, the
 * tooltip and the Statistics table -- colour is never the only distinction.
 */
export const SERIES_COLORS = [
  "#2a78d6", // blue
  "#eb6834", // orange
  "#199e70", // aqua
  "#c98500", // yellow
  "#d55181", // magenta
  "#008300", // green
  "#6250d6", // violet
  "#e34948", // red
] as const;

/** Beyond eight series the hues repeat with a second encoding instead of new
 *  colours: 0 solid, then dashed / dotted / dash-dot lines and 45° / 135° /
 *  crossed hatching for bars. */
export type SeriesPattern = 0 | 1 | 2 | 3;
export type SeriesStyle = { color: string; pattern: SeriesPattern };

const LINE_DASH: readonly (string | undefined)[] = [undefined, "6 4", "2 3", "8 3 2 3"];

/** The style of colour slot `slot`: hue `slot mod 8`, pattern `slot div 8`
 *  (capped at the last pattern). */
export function seriesStyleForSlot(slot: number): SeriesStyle {
  const n = SERIES_COLORS.length;
  const s = Math.max(0, Math.floor(slot));
  return { color: SERIES_COLORS[s % n]!, pattern: Math.min(3, Math.floor(s / n)) as SeriesPattern };
}

/** A line's dash pattern for a series style (undefined = solid). */
export const lineDash = (style: SeriesStyle): string | undefined => LINE_DASH[style.pattern];

/** SVG <pattern> for a hatched bar fill (pattern > 0). */
function HatchPattern({ id, style }: { id: string; style: SeriesStyle }) {
  const angle = style.pattern === 2 ? 135 : 45;
  return (
    <pattern id={id} width={6} height={6} patternUnits="userSpaceOnUse" patternTransform={`rotate(${angle})`}>
      <rect width={6} height={6} fill={style.color} fillOpacity={0.25} />
      <line x1={0} y1={0} x2={0} y2={6} stroke={style.color} strokeWidth={3} />
      {style.pattern === 3 ? <line x1={0} y1={0} x2={6} y2={0} stroke={style.color} strokeWidth={3} /> : null}
    </pattern>
  );
}

/** The legend / tooltip / Statistics marker of a series: a small bar block
 *  (solid or hatched) or a line sample (solid or dashed). */
export function SeriesSwatch({ kind, style }: { kind: "bar" | "line"; style: SeriesStyle }) {
  const id = `swatch-${useId().replace(/[^a-zA-Z0-9_-]/g, "")}`;
  return (
    <svg className={`chart-frame__swatch chart-frame__swatch--${kind}`} width={14} height={10} viewBox="0 0 14 10" aria-hidden="true" focusable="false">
      {kind === "bar" ? (
        <>
          {style.pattern > 0 ? (
            <defs>
              <HatchPattern id={id} style={style} />
            </defs>
          ) : null}
          <rect x={2} y={0} width={10} height={10} rx={2} fill={style.pattern > 0 ? `url(#${id})` : style.color} stroke={style.pattern > 0 ? style.color : "none"} />
        </>
      ) : (
        <line x1={0} y1={5} x2={14} y2={5} stroke={style.color} strokeWidth={2.5} strokeDasharray={lineDash(style)} strokeLinecap="round" />
      )}
    </svg>
  );
}

/**
 * A value axis with "nice" ticks: a step of 1, 2 or 5 × 10^n, about `target`
 * ticks, and the domain widened to whole steps. The label precision follows
 * the step -- whole numbers for a step of 1 or more, one decimal for 0.5 /
 * 0.2 / 0.1, more only when the step is finer (e.g. power factor 0.90-1.00 in
 * 0.02 steps) -- so labels never show meaningless decimals and no two labels
 * read the same.
 */
export type NiceAxis = { domain: [number, number]; ticks: number[]; decimals: number };

export function niceAxis(lo: number, hi: number, target = 5): NiceAxis {
  if (!Number.isFinite(lo) || !Number.isFinite(hi) || hi <= lo) {
    const base = Number.isFinite(lo) ? lo : 0;
    return niceAxis(base, base + 1, target);
  }
  const raw = (hi - lo) / Math.max(1, target - 1);
  const magnitude = 10 ** Math.floor(Math.log10(raw));
  const span = (s: number) => [Math.floor(lo / s + 1e-9), Math.ceil(hi / s - 1e-9)] as const;
  // The 1 / 2 / 5 step whose tick count is closest to the target; on a tie
  // the finer one, which leaves less empty headroom above the data.
  let step = magnitude;
  let best = Infinity;
  for (const m of [1, 2, 5, 10]) {
    const [a, b] = span(m * magnitude);
    const miss = Math.abs(b - a + 1 - target);
    if (miss < best) {
      best = miss;
      step = m * magnitude;
    }
  }
  const decimals = Math.max(0, -Math.floor(Math.log10(step) + 1e-9));
  const round = (v: number) => Number(v.toFixed(decimals));
  const [first, last] = span(step);
  const ticks: number[] = [];
  for (let k = first; k <= last; k++) ticks.push(round(k * step));
  return { domain: [ticks[0]!, ticks[ticks.length - 1]!], ticks, decimals };
}

/** An axis tick label at the axis's precision; never "-0". */
export function formatAxisTick(value: unknown, decimals: number): string {
  if (typeof value !== "number") return String(value);
  const text = value.toFixed(decimals);
  return Number(text) === 0 ? (0).toFixed(decimals) : text;
}

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

type BarSpec = { dataKey: string; axisId: string; style: SeriesStyle };
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

  const hatchId = (dataKey: string) => `${clipId}-hatch-${dataKey}`;
  const styles = new Map(bars.map((b) => [b.dataKey, b.style]));
  const fillOf = (dataKey: string) => {
    const style = styles.get(dataKey);
    if (!style) return undefined;
    return style.pattern > 0 ? `url(#${hatchId(dataKey)})` : style.color;
  };
  return (
    <g className="chart-frame__bars" clipPath={`url(#${clipId})`} data-bar-mode={layout?.mode}>
      <defs>
        {bars
          .filter((b) => b.style.pattern > 0)
          .map((b) => (
            <HatchPattern key={b.dataKey} id={hatchId(b.dataKey)} style={b.style} />
          ))}
      </defs>
      {(layout?.paths ?? []).map((p) => (
        <path key={p.dataKey} className="chart-frame__bar-series" data-series={p.dataKey} d={p.d} fill={fillOf(p.dataKey)} />
      ))}
    </g>
  );
}

type TooltipEntry = {
  name: string;
  unit: string | null;
  style: SeriesStyle;
  kind: "bar" | "line";
  dataKey: string;
  /** bucket start -> tooltip lines */
  notes: ReadonlyMap<number, readonly string[]>;
};

function SeriesTooltip({
  entries,
  rowsByStart,
  timeZone,
  dateOnly,
  active,
  label,
}: {
  entries: readonly TooltipEntry[];
  rowsByStart: ReadonlyMap<number, ChartRow>;
  timeZone?: string | null;
  dateOnly?: boolean;
  // injected by Recharts' Tooltip
  active?: boolean;
  label?: number | string;
}) {
  const row = active && label != null ? rowsByStart.get(Number(label)) : undefined;
  if (!row) return null;
  const values = entries.filter((e) => row[e.dataKey] != null || (e.notes.get(row.t)?.length ?? 0) > 0);
  return (
    <div className="chart-frame__tooltip" data-testid="chart-tooltip">
      <p className="chart-frame__tooltip-time">
        {dateOnly ? formatSiteLocalDate(row.t, timeZone) : formatSiteLocalDateTime(row.t, timeZone)}
      </p>
      {values.length > 0 ? (
        <ul className="chart-frame__tooltip-list">
          {values.map((e) => (
            <li key={e.dataKey}>
              <SeriesSwatch kind={e.kind} style={e.style} />
              <span className="chart-frame__tooltip-name">{e.name}</span>
              {row[e.dataKey] != null ? (
                <span className="chart-frame__tooltip-value">
                  {formatValue(row[e.dataKey])}
                  {e.unit ? ` ${e.unit}` : ""}
                </span>
              ) : null}
              {(e.notes.get(row.t)?.length ?? 0) > 0 ? (
                <ul className="chart-frame__tooltip-notes" data-testid="chart-tooltip-notes">
                  {e.notes.get(row.t)!.map((note, i) => (
                    <li key={i}>{note}</li>
                  ))}
                </ul>
              ) : null}
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
 * one Y axis per unit, with nice ticks labelled at the precision the step
 * needs (niceAxis). Drag across the plot to zoom, use the range slider,
 * or Show all to return to the whole range -- zooming changes only what is
 * visible. Each legend entry shows or hides its series, also visual only (a
 * unit with no shown series loses its axis). Remount (change `key`) to reset
 * the zoom and the hidden series.
 */
export function MultiSeriesChartFrame({
  buckets,
  series,
  range,
  timeZone,
  dateOnly = false,
  ariaLabel,
  height = 360,
  width,
}: MultiSeriesChartFrameProps) {
  const [view, setView] = useState<ChartView | null>(null);
  const [drag, setDrag] = useState<{ a: number; b: number } | null>(null);
  // Series hidden from the legend, by key: visual only, like the zoom.
  const [hidden, setHidden] = useState<ReadonlySet<string>>(() => new Set());
  const chartId = `multi-series-chart-${useId().replace(/[^a-zA-Z0-9_-]/g, "")}`;

  const toggleSeries = useCallback((key: string) => {
    setHidden((current) => {
      const next = new Set(current);
      if (!next.delete(key)) next.add(key);
      return next;
    });
  }, []);
  const styles = useMemo(() => series.map((s, i) => s.style ?? seriesStyleForSlot(i)), [series]);
  // Visible series keep their position in `series`, which names their data key.
  const visible = useMemo(
    () => series.map((s, i) => ({ s, i })).filter(({ s }) => !hidden.has(s.key)),
    [series, hidden],
  );
  const visibleSeries = useMemo(() => visible.map(({ s }) => s), [visible]);

  const rows = useMemo(() => chartRows(buckets, series), [buckets, series]);
  const rowsByStart = useMemo(() => new Map(rows.map((r) => [r.t, r])), [rows]);
  const units = useMemo(() => [...new Set(visibleSeries.map((s) => s.unit))], [visibleSeries]);
  const domains = useMemo(() => unitDomains(visibleSeries, view, buckets.length), [visibleSeries, view, buckets.length]);
  const axes = useMemo(
    () => new Map([...domains].map(([unit, [lo, hi]]) => [unit, niceAxis(lo, hi)] as const)),
    [domains],
  );
  const xDomain = useMemo(() => viewDomain(view, buckets, range), [view, buckets, range]);
  const ticks = useMemo(() => siteLocalTicks(xDomain[0], xDomain[1], timeZone), [xDomain, timeZone]);
  const tickValues = useMemo(() => ticks.map((t) => t.t), [ticks]);
  const tickLabels = useMemo(() => new Map(ticks.map((t) => [t.t, t.label])), [ticks]);
  const formatTickLabel = useCallback((t: number) => tickLabels.get(t) ?? "", [tickLabels]);
  const formatBrushLabel = useCallback(
    (t: number) => (dateOnly ? formatSiteLocalDate(t, timeZone) : formatSiteLocalDateTime(t, timeZone)),
    [timeZone, dateOnly],
  );

  const bars = useMemo<BarSpec[]>(
    () =>
      visible.flatMap(({ s, i }) =>
        s.kind === "bar" ? [{ dataKey: dataKeyOf(i), axisId: axisIdOf(s.unit), style: styles[i]! }] : [],
      ),
    [visible, styles],
  );
  const entries = useMemo<TooltipEntry[]>(
    () =>
      visible.map(({ s, i }) => {
        const notes = new Map<number, readonly string[]>();
        s.notes?.forEach((lines, b) => {
          if (lines.length > 0 && buckets[b]) notes.set(buckets[b]!.start, lines);
        });
        return { name: s.name, unit: s.unit, style: styles[i]!, kind: s.kind, dataKey: dataKeyOf(i), notes };
      }),
    [visible, styles, buckets],
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
    () => <SeriesTooltip entries={entries} rowsByStart={rowsByStart} timeZone={timeZone} dateOnly={dateOnly} />,
    [entries, rowsByStart, timeZone, dateOnly],
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
          domain={axes.get(unit)?.domain}
          ticks={axes.get(unit)?.ticks}
          interval={0}
          tickFormatter={(v: unknown) => formatAxisTick(v, axes.get(unit)?.decimals ?? 0)}
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
      {visible.map(({ s, i }) =>
        s.kind === "line" ? (
          <Line
            key={dataKeyOf(i)}
            dataKey={dataKeyOf(i)}
            yAxisId={axisIdOf(s.unit)}
            name={s.name}
            stroke={styles[i]!.color}
            strokeDasharray={lineDash(styles[i]!)}
            type="linear"
            dot={false}
            strokeWidth={2}
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
        // Each entry is a toggle: pressed = shown. Hiding a series is visual
        // only -- the data, Statistics and CSV are unchanged.
        <ul className="chart-frame__legend" data-testid="chart-legend" aria-label="Series (select to show or hide)">
          {series.map((s, i) => {
            const shown = !hidden.has(s.key);
            return (
              <li key={s.key} className="chart-frame__legend-item">
                <button
                  type="button"
                  className={`chart-frame__legend-toggle${shown ? "" : " chart-frame__legend-toggle--hidden"}`}
                  aria-pressed={shown}
                  title={shown ? `Hide ${s.name}` : `Show ${s.name}`}
                  onClick={() => toggleSeries(s.key)}
                  data-testid="chart-legend-toggle"
                >
                  <SeriesSwatch kind={s.kind} style={styles[i]!} />
                  <span className="chart-frame__legend-name">{s.name}</span>
                </button>
              </li>
            );
          })}
        </ul>
      ) : null}
    </figure>
  );
}
