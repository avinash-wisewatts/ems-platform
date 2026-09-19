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
 */

import { useId, type ReactElement } from "react";
import {
  Area,
  AreaChart,
  Bar,
  BarChart,
  CartesianGrid,
  Line,
  LineChart,
  ResponsiveContainer,
  Tooltip,
  XAxis,
  YAxis,
} from "recharts";

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
