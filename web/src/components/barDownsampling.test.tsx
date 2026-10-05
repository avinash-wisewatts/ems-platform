import { describe, expect, it } from "vitest";
import { fireEvent, render, screen } from "@testing-library/react";
import { MultiSeriesChartFrame, chartRows, layoutBars, type ChartBucket, type ChartSeries } from "./ChartFrame";
import { formatSiteLocalDateTime } from "../time/siteLocalTicks";

const Q = 15 * 60_000;
const T0 = Date.parse("2026-09-05T18:30:00Z"); // 06 Sep 2026 00:00 IST

const gridOf = (count: number): ChartBucket[] => Array.from({ length: count }, (_, i) => ({ start: T0 + i * Q, end: T0 + (i + 1) * Q }));
/** x: the grid's first bucket at 0 px, `width` px for the whole grid. */
const xScale = (count: number, width: number) => (t: number) => ((t - T0) / (count * Q)) * width;
const yScale = (v: number) => 300 - v * 10;

type Rect = { left: number; right: number; from: number; to: number };
function rects(d: string): Rect[] {
  return [...d.matchAll(/M([-\d.]+) ([-\d.]+)H([-\d.]+)V([-\d.]+)H[-\d.]+Z/g)].map((m) => ({
    left: Number(m[1]),
    right: Number(m[3]),
    from: Number(m[2]),
    to: Number(m[4]),
  }));
}

function series(key: string, values: (number | null)[], kind: ChartSeries["kind"] = "bar"): ChartSeries {
  return { key, name: key, unit: "kWh", kind, values };
}

describe("layoutBars -- full resolution when every bar is at least one pixel wide", () => {
  it("is exactly the per-bucket geometry: one rectangle per non-null bucket per series, side by side", () => {
    const buckets = gridOf(4);
    const a = series("a", [1, 2, null, 4]);
    const b = series("b", [0.5, null, null, 1]);
    const rows = chartRows(buckets, [a, b]);
    const x = xScale(4, 800); // 200 px per bucket: bars 80 px wide
    const layout = layoutBars(rows, [{ dataKey: "s0", y: yScale }, { dataKey: "s1", y: yScale }], 0, 3, x);
    expect(layout.mode).toBe("full");
    // Independently computed: left = start + 10% + index * width, width = 80% / 2.
    const expected = (index: number, values: (number | null)[]) =>
      values
        .map((v, i) => {
          if (v == null) return "";
          const left = i * 200 + 20 + index * 80;
          return `M${left.toFixed(2)} ${yScale(0).toFixed(2)}H${(left + 80).toFixed(2)}V${yScale(v).toFixed(2)}H${left.toFixed(2)}Z`;
        })
        .join("");
    expect(layout.paths[0]!.d).toBe(expected(0, a.values as (number | null)[]));
    expect(layout.paths[1]!.d).toBe(expected(1, b.values as (number | null)[]));
  });

  it("a bar exactly one pixel wide is still full resolution; just under one pixel is downsampled", () => {
    const rows = chartRows(gridOf(4), [series("a", [1, 2, 3, 4])]);
    const bar = [{ dataKey: "s0", y: yScale }];
    expect(layoutBars(rows, bar, 0, 3, xScale(4, 4 * 1.25)).mode).toBe("full"); // 1.25 px bucket -> 1.0 px bar
    expect(layoutBars(rows, bar, 0, 3, xScale(4, 4 * 1.2)).mode).toBe("downsampled"); // 0.96 px bar
  });
});

describe("layoutBars -- sub-pixel bars are downsampled per pixel column", () => {
  const COUNT = 2880; // 30 days of 15-minute buckets
  const WIDTH = 720;

  it("25 series over 2,880 buckets: a handful of column bars per series instead of 2,880; every bar >= 1 px", () => {
    const all = Array.from({ length: 25 }, (_, k) => series(`k${k}`, Array.from({ length: COUNT }, (_, i) => (i + k) % 7)));
    const rows = chartRows(gridOf(COUNT), all);
    const layout = layoutBars(rows, all.map((_, k) => ({ dataKey: `s${k}`, y: yScale })), 0, COUNT - 1, xScale(COUNT, WIDTH));
    expect(layout.mode).toBe("downsampled");
    const columns = Math.ceil(25 / 0.8); // 32 px: one pixel per series
    for (const path of layout.paths) {
      const r = rects(path.d);
      expect(r.length).toBeLessThanOrEqual(Math.ceil(WIDTH / columns));
      expect(r.length).toBeGreaterThan(0);
      for (const bar of r) expect(bar.right - bar.left).toBeGreaterThanOrEqual(0.999);
    }
  });

  it("each series keeps its own maximum within each pixel column (peaks are not lost)", () => {
    // One series: columns of ceil(1 / 0.8) = 2 px = 8 buckets at 0.25 px per bucket.
    const values = Array.from({ length: COUNT }, () => 1);
    values[5] = 9; // in column 0
    values[100] = 5; // in column 12 (buckets 96..103)
    const rows = chartRows(gridOf(COUNT), [series("a", values)]);
    const r = rects(layoutBars(rows, [{ dataKey: "s0", y: yScale }], 0, COUNT - 1, xScale(COUNT, WIDTH)).paths[0]!.d);
    expect(r).toHaveLength(COUNT / 8);
    expect(r[0]!.to).toBe(yScale(9));
    expect(r[12]!.to).toBe(yScale(5));
    expect(r[1]!.to).toBe(yScale(1));
  });

  it("series sharing a column are not merged: each draws its own maximum in its own slot", () => {
    const a = Array.from({ length: COUNT }, () => 1);
    const b = Array.from({ length: COUNT }, () => 2);
    a[3] = 7; // column 0 for both (column = ceil(2 / 0.8) = 3 px = 12 buckets)
    b[10] = 4;
    const rows = chartRows(gridOf(COUNT), [series("a", a), series("b", b)]);
    const layout = layoutBars(rows, [{ dataKey: "s0", y: yScale }, { dataKey: "s1", y: yScale }], 0, COUNT - 1, xScale(COUNT, WIDTH));
    const [ra, rb] = layout.paths.map((p) => rects(p.d));
    expect(ra![0]!.to).toBe(yScale(7));
    expect(rb![0]!.to).toBe(yScale(4));
    expect(rb![0]!.left).toBeGreaterThanOrEqual(ra![0]!.right - 0.01); // side by side, no overlap
  });

  it("a negative extreme is kept too (the bar spans min(0, lowest)..max(0, highest)); an all-null column draws nothing", () => {
    const values: (number | null)[] = Array.from({ length: COUNT }, () => null);
    values[0] = 2;
    values[1] = -3;
    const rows = chartRows(gridOf(COUNT), [series("a", values)]);
    const r = rects(layoutBars(rows, [{ dataKey: "s0", y: yScale }], 0, COUNT - 1, xScale(COUNT, WIDTH)).paths[0]!.d);
    expect(r).toHaveLength(1);
    expect(r[0]!.from).toBe(yScale(-3));
    expect(r[0]!.to).toBe(yScale(2));
  });

  it("does not change the underlying rows", () => {
    const values = Array.from({ length: COUNT }, (_, i) => i % 13);
    const rows = chartRows(gridOf(COUNT), [series("a", values)]);
    const before = structuredClone(rows);
    rows.forEach((r) => Object.freeze(r));
    Object.freeze(rows);
    layoutBars(rows, [{ dataKey: "s0", y: yScale }], 0, COUNT - 1, xScale(COUNT, WIDTH));
    expect(rows).toEqual(before);
  });
});

describe("MultiSeriesChartFrame -- zoom and the range slider use the same visual optimisation", () => {
  const COUNT = 2880;
  const buckets = gridOf(COUNT);
  const range = { from: T0, to: T0 + COUNT * Q };
  const many = Array.from({ length: 25 }, (_, k) => series(`k${k}`, Array.from({ length: COUNT }, (_, i) => ((i + k) % 9) + 1)));
  const mode = (container: HTMLElement) => container.querySelector(".chart-frame__bars")!.getAttribute("data-bar-mode");

  function renderMany(s: ChartSeries[] = many) {
    return render(
      <MultiSeriesChartFrame buckets={buckets} series={s} range={range} timeZone="Asia/Kolkata" ariaLabel="Many" width={800} height={300} />,
    );
  }
  function drag(container: HTMLElement, fromX: number, toX: number) {
    const wrapper = container.querySelector(".recharts-wrapper")!;
    fireEvent.mouseDown(wrapper, { clientX: fromX, clientY: 100, pageX: fromX, pageY: 100 });
    fireEvent.mouseMove(wrapper, { clientX: toX, clientY: 100, pageX: toX, pageY: 100 });
    fireEvent.mouseUp(wrapper, { clientX: toX, clientY: 100, pageX: toX, pageY: 100 });
  }

  it("the whole 30 days is downsampled; Show all returns to it", () => {
    const { container } = renderMany();
    expect(mode(container)).toBe("downsampled");
  });

  it("drag-to-zoom: a wide window stays downsampled, a narrow one is drawn at full resolution", () => {
    const { container } = renderMany();
    drag(container, 200, 600); // ~1,600 buckets: still sub-pixel
    expect(screen.getByTestId("chart-show-all")).toBeInTheDocument();
    expect(mode(container)).toBe("downsampled");
    fireEvent.click(screen.getByTestId("chart-show-all"));
    drag(container, 300, 305); // ~20 buckets: bars over a pixel wide
    expect(mode(container)).toBe("full");
    fireEvent.click(screen.getByTestId("chart-show-all"));
    expect(mode(container)).toBe("downsampled");
  });

  it("the range slider: narrowing it to a few buckets switches to full resolution, through the same layout", () => {
    const { container } = renderMany();
    const traveller = container.querySelectorAll(".recharts-brush-traveller")[0]!;
    fireEvent.mouseDown(traveller, { clientX: 64, clientY: 290, pageX: 64, pageY: 290 });
    fireEvent.mouseMove(window, { clientX: 776, clientY: 290, pageX: 776, pageY: 290 });
    fireEvent.mouseUp(window, { clientX: 776, clientY: 290, pageX: 776, pageY: 290 });
    expect(screen.getByTestId("chart-show-all")).toBeInTheDocument();
    expect(mode(container)).toBe("full");
  });

  it("the tooltip shows the hovered bucket's own value, not the downsampled column maximum", () => {
    // Value = bucket index, so every column's maximum is its last bucket.
    const indexed = [series("idx", Array.from({ length: COUNT }, (_, i) => i))];
    const { container } = renderMany(indexed);
    expect(mode(container)).toBe("downsampled");
    const wrapper = container.querySelector(".recharts-wrapper")!;
    fireEvent.mouseMove(wrapper, { clientX: 301, clientY: 100, pageX: 301, pageY: 100 });
    const tooltip = screen.getByTestId("chart-tooltip");
    const value = Number(tooltip.querySelector(".chart-frame__tooltip-value")!.textContent!.replace(/[^\d.]/g, ""));
    expect(tooltip.querySelector(".chart-frame__tooltip-time")!.textContent).toBe(formatSiteLocalDateTime(T0 + value * Q, "Asia/Kolkata"));
  });
});
