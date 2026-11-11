import { describe, expect, it } from "vitest";
import { fireEvent, render, screen, within } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import {
  ChartFrame,
  MultiSeriesChartFrame,
  chartRows,
  unitDomains,
  viewDomain,
  viewFromSelection,
  type ChartSeries,
} from "./ChartFrame";

const H = 3_600_000;
const T0 = Date.parse("2026-10-04T18:30:00Z"); // 05 Oct 2026 00:00 IST
const buckets = Array.from({ length: 4 }, (_, i) => ({ start: T0 + i * H, end: T0 + (i + 1) * H }));
const range = { from: T0, to: T0 + 4 * H };

const energy: ChartSeries = { key: "a1:E", name: "Asset 1 · Energy", unit: "kWh", kind: "bar", values: [1, 2, null, 4] };
const energyExport: ChartSeries = { key: "a1:X", name: "Asset 1 · Energy Export", unit: "kWh", kind: "bar", values: [0.5, null, null, 1] };
const power: ChartSeries = { key: "a1:P", name: "Asset 1 · Power", unit: "kW", kind: "line", values: [10, 11, null, 12] };

function renderChart(series: ChartSeries[], props: Partial<Parameters<typeof MultiSeriesChartFrame>[0]> = {}) {
  return render(
    <MultiSeriesChartFrame
      buckets={buckets}
      series={series}
      range={range}
      timeZone="Asia/Kolkata"
      ariaLabel="Test chart"
      width={800}
      height={300}
      {...props}
    />,
  );
}

const subpaths = (el: Element) => (el.getAttribute("d")?.match(/M/g) ?? []).length;
const visibleLines = (container: HTMLElement) =>
  [...container.querySelectorAll(".recharts-line-curve")].filter((p) => p.getAttribute("stroke") !== "none");
const xTickLabels = (container: HTMLElement) =>
  [...container.querySelectorAll(".recharts-xAxis .recharts-cartesian-axis-tick-value")].map((t) => t.textContent);

function drag(container: HTMLElement, fromX: number, toX: number) {
  const wrapper = container.querySelector(".recharts-wrapper")!;
  fireEvent.mouseDown(wrapper, { clientX: fromX, clientY: 100, pageX: fromX, pageY: 100 });
  fireEvent.mouseMove(wrapper, { clientX: toX, clientY: 100, pageX: toX, pageY: 100 });
  fireEvent.mouseUp(wrapper, { clientX: toX, clientY: 100, pageX: toX, pageY: 100 });
}

describe("MultiSeriesChartFrame -- several series on one time grid", () => {
  it("draws each bar series as ONE path, not one element per bucket; a null bucket draws nothing", () => {
    const { container } = renderChart([energy, energyExport]);
    const paths = container.querySelectorAll(".chart-frame__bar-series");
    expect(paths).toHaveLength(2);
    expect(subpaths(paths[0]!)).toBe(3); // 1, 2, 4 -- the null bucket is a gap
    expect(subpaths(paths[1]!)).toBe(2); // 0.5, 1
    expect(container.querySelectorAll(".recharts-bar-rectangle")).toHaveLength(0);
  });

  it("bars are clipped to the plot area", () => {
    const { container } = renderChart([energy]);
    const clip = container.querySelector(".chart-frame__bars")!.getAttribute("clip-path")!;
    const id = clip.slice("url(#".length, -1);
    expect(container.querySelector(`clipPath[id="${id}"]`)).not.toBeNull();
  });

  it("draws line series as Recharts lines that break at a null (a gap, never 0)", () => {
    const { container } = renderChart([power]);
    const lines = visibleLines(container);
    expect(lines).toHaveLength(1);
    expect(subpaths(lines[0]!)).toBe(2); // 10-11, then 12 after the gap
  });

  it("one Y axis per unit, labelled with the unit", () => {
    const { container } = renderChart([energy, energyExport, power]);
    const axes = container.querySelectorAll(".recharts-yAxis");
    expect(axes).toHaveLength(2);
    expect(container.querySelector(".recharts-yAxis")!.closest("svg")!.textContent).toContain("kWh");
    expect(container.querySelector(".recharts-yAxis")!.closest("svg")!.textContent).toContain("kW");
  });

  it("legend: one entry per series, in order, marked bar or line", () => {
    renderChart([energy, energyExport, power]);
    const items = within(screen.getByTestId("chart-legend")).getAllByRole("listitem");
    expect(items.map((i) => i.textContent)).toEqual(["Asset 1 · Energy", "Asset 1 · Energy Export", "Asset 1 · Power"]);
    expect(items[0]!.querySelector(".chart-frame__swatch--bar")).not.toBeNull();
    expect(items[2]!.querySelector(".chart-frame__swatch--line")).not.toBeNull();
  });

  it("the X axis covers exactly the range, with site-local tick labels", () => {
    const { container } = renderChart([energy]);
    const labels = xTickLabels(container);
    expect(labels[0]).toBe("05 Oct"); // local midnight, not 18:30 UTC
    expect(labels[labels.length - 1]).toBe("04:00");
  });

  it("no series: axes over the range, no bars, no legend", () => {
    const { container } = renderChart([]);
    expect(container.querySelectorAll(".chart-frame__bar-series")).toHaveLength(0);
    expect(screen.queryByTestId("chart-legend")).not.toBeInTheDocument();
    expect(xTickLabels(container)[0]).toBe("05 Oct");
  });

  it("no buckets at all renders without throwing", () => {
    render(<MultiSeriesChartFrame buckets={[]} series={[]} range={range} ariaLabel="Empty" width={400} height={200} />);
    expect(screen.getByTestId("multi-series-chart")).toBeInTheDocument();
  });

  it("drag-to-zoom narrows the visible window only; Show all restores the whole range", async () => {
    const { container } = renderChart([energy]);
    const before = xTickLabels(container);
    expect(screen.queryByTestId("chart-show-all")).not.toBeInTheDocument();
    // Plot x 64..784 for 4 hourly buckets: 300 px is the 01:00 bucket, 650 px the 03:00 one.
    drag(container, 300, 650);
    expect(screen.getByTestId("chart-show-all")).toBeInTheDocument();
    const zoomed = xTickLabels(container);
    expect(zoomed[0]).toBe("01:00");
    expect(zoomed[zoomed.length - 1]).toBe("04:00");
    expect(zoomed).not.toContain("05 Oct");
    await userEvent.click(screen.getByTestId("chart-show-all"));
    expect(screen.queryByTestId("chart-show-all")).not.toBeInTheDocument();
    expect(xTickLabels(container)).toEqual(before);
  });

  it("a click without a drag does not zoom", () => {
    const { container } = renderChart([energy]);
    drag(container, 300, 300);
    expect(screen.queryByTestId("chart-show-all")).not.toBeInTheDocument();
  });

  it("dragging across every bucket is the whole range, not a zoom", () => {
    const { container } = renderChart([energy]);
    drag(container, 70, 780);
    expect(screen.queryByTestId("chart-show-all")).not.toBeInTheDocument();
  });

  it("a new key (remount) starts unzoomed", () => {
    const { container, rerender } = renderChart([energy]);
    drag(container, 300, 650);
    expect(screen.getByTestId("chart-show-all")).toBeInTheDocument();
    rerender(
      <MultiSeriesChartFrame
        key="next-update"
        buckets={buckets}
        series={[energy]}
        range={range}
        timeZone="Asia/Kolkata"
        ariaLabel="Test chart"
        width={800}
        height={300}
      />,
    );
    expect(screen.queryByTestId("chart-show-all")).not.toBeInTheDocument();
  });

  it("has a range slider when there is more than one bucket", () => {
    const { container } = renderChart([energy]);
    expect(container.querySelector(".recharts-brush")).not.toBeNull();
  });
});

describe("MultiSeriesChartFrame helpers", () => {
  it("chartRows: one row per bucket, values under per-series keys, nulls kept", () => {
    const rows = chartRows(buckets, [energy, power]);
    expect(rows).toHaveLength(4);
    expect(rows[2]).toMatchObject({ t: T0 + 2 * H, tEnd: T0 + 3 * H, s0: null, s1: null });
    expect(rows[3]).toMatchObject({ s0: 4, s1: 12 });
  });

  it("viewFromSelection: either drag direction; a click or an unknown bucket is not a zoom", () => {
    expect(viewFromSelection(buckets, T0 + 3 * H, T0 + H)).toEqual({ start: 1, end: 3 });
    expect(viewFromSelection(buckets, T0 + H, T0 + 3 * H)).toEqual({ start: 1, end: 3 });
    expect(viewFromSelection(buckets, T0 + H, T0 + H)).toBeNull();
    expect(viewFromSelection(buckets, T0 + 1, T0 + 3 * H)).toBeNull();
    expect(viewFromSelection(buckets, T0, T0 + 3 * H)).toBeNull(); // every bucket
  });

  it("viewDomain: the whole range unzoomed; zoomed bucket edges clipped to the range", () => {
    expect(viewDomain(null, buckets, range)).toEqual([range.from, range.to]);
    expect(viewDomain({ start: 1, end: 2 }, buckets, range)).toEqual([T0 + H, T0 + 3 * H]);
    // A first bucket that starts before the range (a refined start time) is clipped.
    expect(viewDomain({ start: 0, end: 1 }, buckets, { from: T0 + 1800_000, to: range.to })).toEqual([T0 + 1800_000, T0 + 2 * H]);
  });

  it("unitDomains: bar units start at 0; line-only units span their values; visible window only; all-null is [0, 1]", () => {
    const domains = unitDomains([energy, power], null, 4);
    expect(domains.get("kWh")).toEqual([0, 4]);
    expect(domains.get("kW")).toEqual([10, 12]);
    expect(unitDomains([energy, power], { start: 0, end: 1 }, 4).get("kWh")).toEqual([0, 2]);
    const empty: ChartSeries = { ...power, values: [null, null, null, null] };
    expect(unitDomains([empty], null, 4).get("kW")).toEqual([0, 1]);
  });
});

describe("ChartFrame (single series) is unchanged for its existing callers", () => {
  const points = buckets.map((b, i) => ({ t: b.start, value: energy.values[i] ?? null }));

  it("the bar variant still draws Recharts bars and none of the multi-series parts", () => {
    const { container } = render(<ChartFrame points={points} valueLabel="Consumption" unit="kWh" variant="bar" width={600} height={240} />);
    expect(screen.getByTestId("chart-frame")).toBeInTheDocument();
    expect(container.querySelectorAll(".recharts-bar-rectangle").length).toBeGreaterThan(0);
    expect(container.querySelector(".chart-frame__bar-series")).toBeNull();
    expect(screen.queryByTestId("chart-legend")).not.toBeInTheDocument();
    expect(container.querySelector(".recharts-brush")).toBeNull();
  });

  it("the line variant has no legend, range slider or Show all", () => {
    const { container } = render(<ChartFrame points={points} valueLabel="Demand" unit="kW" width={600} height={240} />);
    expect(container.querySelectorAll(".recharts-line").length).toBe(1);
    expect(container.querySelector(".recharts-brush")).toBeNull();
    expect(screen.queryByTestId("chart-show-all")).not.toBeInTheDocument();
  });
});

const yTickLabels = (container: HTMLElement) =>
  [...container.querySelectorAll(".recharts-yAxis .recharts-cartesian-axis-tick-value")].map((t) => t.textContent);
const legendToggle = (name: string) =>
  // A string name matches the accessible name exactly.
  within(screen.getByTestId("chart-legend")).getByRole("button", { name });

describe("MultiSeriesChartFrame -- Y axis precision", () => {
  it("whole-number ticks for an Energy axis, never 2 fixed decimals", () => {
    const { container } = renderChart([energy]); // 1, 2, null, 4 kWh
    expect(yTickLabels(container)).toEqual(["0", "1", "2", "3", "4"]);
  });

  it("decimals only where the scale needs them; one precision per axis", () => {
    const pf: ChartSeries = { key: "a1:PF", name: "Asset 1 · Power Factor", unit: null, kind: "line", values: [0.912, 0.95, null, 0.987] };
    const { container } = renderChart([energy, pf]);
    const labels = yTickLabels(container);
    expect(labels).toEqual(expect.arrayContaining(["0", "4", "0.90", "1.00"]));
    expect(labels.filter((l) => l?.startsWith("0.9"))).toEqual(["0.90", "0.92", "0.94", "0.96", "0.98"]);
  });
});

describe("MultiSeriesChartFrame -- interactive legend", () => {
  it("every legend entry is a pressed toggle button named after its series", () => {
    renderChart([energy, energyExport, power]);
    const toggles = within(screen.getByTestId("chart-legend")).getAllByRole("button");
    expect(toggles.map((b) => b.textContent)).toEqual(["Asset 1 · Energy", "Asset 1 · Energy Export", "Asset 1 · Power"]);
    for (const b of toggles) expect(b).toHaveAttribute("aria-pressed", "true");
    expect(toggles[0]).toHaveAttribute("title", "Hide Asset 1 · Energy");
  });

  it("clicking a bar series hides it and clicking again shows it; the other series keep their colour", async () => {
    const { container } = renderChart([energy, energyExport, power]);
    const fills = () => [...container.querySelectorAll(".chart-frame__bar-series")].map((p) => p.getAttribute("fill"));
    const before = fills();
    expect(before).toHaveLength(2);
    await userEvent.click(legendToggle("Asset 1 · Energy"));
    expect(legendToggle("Asset 1 · Energy")).toHaveAttribute("aria-pressed", "false");
    expect(legendToggle("Asset 1 · Energy")).toHaveAttribute("title", "Show Asset 1 · Energy");
    expect(fills()).toEqual([before[1]]);
    expect(visibleLines(container)).toHaveLength(1);
    await userEvent.click(legendToggle("Asset 1 · Energy"));
    expect(fills()).toEqual(before);
  });

  it("hides and shows a line series", async () => {
    const { container } = renderChart([energy, power]);
    expect(visibleLines(container)).toHaveLength(1);
    await userEvent.click(legendToggle("Asset 1 · Power"));
    expect(visibleLines(container)).toHaveLength(0);
    expect(container.querySelectorAll(".chart-frame__bar-series")).toHaveLength(1);
    await userEvent.click(legendToggle("Asset 1 · Power"));
    expect(visibleLines(container)).toHaveLength(1);
  });

  it("hiding every series of a unit removes that unit's axis; the remaining axis rescales", async () => {
    const big: ChartSeries = { ...energyExport, key: "a2:E", name: "Asset 2 · Energy", values: [100, 200, 300, 400] };
    const { container } = renderChart([energy, big, power]);
    expect(container.querySelectorAll(".recharts-yAxis")).toHaveLength(2);
    await userEvent.click(legendToggle("Asset 1 · Power"));
    expect(container.querySelectorAll(".recharts-yAxis")).toHaveLength(1);
    expect(yTickLabels(container).at(-1)).toBe("400");
    await userEvent.click(legendToggle("Asset 2 · Energy"));
    expect(yTickLabels(container).at(-1)).toBe("4");
  });

  it("works from the keyboard (Enter and Space)", async () => {
    const { container } = renderChart([energy, power]);
    legendToggle("Asset 1 · Power").focus();
    await userEvent.keyboard("{Enter}");
    expect(visibleLines(container)).toHaveLength(0);
    await userEvent.keyboard(" ");
    expect(visibleLines(container)).toHaveLength(1);
  });

  it("a hidden series is left out of the tooltip", async () => {
    const { container } = renderChart([energy, power]);
    await userEvent.click(legendToggle("Asset 1 · Power"));
    const wrapper = container.querySelector(".recharts-wrapper")!;
    fireEvent.mouseMove(wrapper, { clientX: 200, clientY: 100, pageX: 200, pageY: 100 });
    const tooltip = screen.getByTestId("chart-tooltip");
    expect(tooltip).toHaveTextContent("Asset 1 · Energy");
    expect(tooltip).not.toHaveTextContent("Asset 1 · Power");
  });

  it("a series' own style wins over its position", () => {
    const styled: ChartSeries = { ...energy, style: { color: "#6250d6", pattern: 0 } };
    const { container } = renderChart([styled]);
    expect(container.querySelector(".chart-frame__bar-series")).toHaveAttribute("fill", "#6250d6");
  });

  it("a hatched style fills bars with a pattern and dashes lines", () => {
    const hatched: ChartSeries = { ...energy, style: { color: "#2a78d6", pattern: 1 } };
    const dashed: ChartSeries = { ...power, style: { color: "#eb6834", pattern: 1 } };
    const { container } = renderChart([hatched, dashed]);
    expect(container.querySelector(".chart-frame__bar-series")!.getAttribute("fill")).toMatch(/^url\(#.+-hatch-/);
    expect(container.querySelector(".chart-frame__bars pattern")).not.toBeNull();
    expect(visibleLines(container)[0]).toHaveAttribute("stroke-dasharray", "6 4");
  });
});
