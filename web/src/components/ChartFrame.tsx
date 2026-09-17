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
  /** "line" (default, unchanged) or a filled "area" rendering -- still the
   *  same Recharts foundation, same data contract; purely a presentation
   *  choice for screens (e.g. the WiseWatts Main Dashboard Load Trend card)
   *  that want a filled trend instead of a bare line. No new chart library,
   *  no feature-specific chart component. */
  variant?: "line" | "area";
};

function formatTick(t: number): string {
  return new Date(t).toISOString().slice(5, 16).replace("T", " ");
}

export function ChartFrame({
  points,
  valueLabel,
  unit,
  height = 280,
  width,
  ariaLabel,
  variant = "line",
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
        tickFormatter={formatTick}
        scale="time"
        minTickGap={40}
      />
      <YAxis tickFormatter={(v) => String(v)} width={56} />
      <Tooltip
        labelFormatter={(t) => new Date(Number(t)).toISOString()}
        formatter={(v) => [String(v), unit ? `${valueLabel} (${unit})` : valueLabel]}
      />
    </>
  );

  const chart =
    variant === "area" ? (
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
