import { describe, expect, it } from "vitest";
import { render, screen } from "@testing-library/react";
import { ChartFrame, formatValue } from "./ChartFrame";

const points = [
  { t: Date.parse("2026-06-01T00:00:00Z"), value: 21.1 },
  { t: Date.parse("2026-06-01T01:00:00Z"), value: 21.4 },
  { t: Date.parse("2026-06-01T02:00:00Z"), value: null }, // a gap, not a zero
  { t: Date.parse("2026-06-01T03:00:00Z"), value: 22.0 },
];

describe("ChartFrame -- the single charting foundation", () => {
  it("renders an accessible SVG chart for a time series", () => {
    const { container } = render(
      <ChartFrame points={points} valueLabel="Temperature" unit="degC" width={600} height={240} />,
    );
    const frame = screen.getByTestId("chart-frame");
    expect(frame).toHaveAttribute("aria-label", expect.stringContaining("Temperature"));
    expect(container.querySelector("svg")).toBeInTheDocument();
    // Recharts renders one <path> for the line series.
    expect(container.querySelector("path.recharts-line-curve")).toBeInTheDocument();
  });

  it("renders with an empty series without throwing", () => {
    const { container } = render(
      <ChartFrame points={[]} valueLabel="Humidity" width={400} height={200} />,
    );
    expect(container.querySelector("svg")).toBeInTheDocument();
  });

  it("renders without a timeZone or axisUnitLabel exactly as before (opt-in, not a behavior change for existing callers)", () => {
    const { container } = render(
      <ChartFrame points={points} valueLabel="Temperature" unit="degC" width={600} height={240} />,
    );
    expect(container.querySelector(".recharts-label")).toBeNull();
  });

  it("shows a Y-axis unit label only when axisUnitLabel is true and a unit is given", () => {
    const { container } = render(
      <ChartFrame points={points} valueLabel="Demand" unit="kW" axisUnitLabel width={600} height={240} />,
    );
    expect(container.querySelector(".recharts-label")).toHaveTextContent("kW");
  });

  it("accepts a timeZone prop without throwing (axis/tooltip formatting is timezone-aware)", () => {
    const { container } = render(
      <ChartFrame points={points} valueLabel="Demand" unit="kW" timeZone="Asia/Kolkata" width={600} height={240} />,
    );
    expect(container.querySelector("svg")).toBeInTheDocument();
  });
});

describe("formatValue -- universal 2-decimal rounding for Y-axis ticks and the hover tooltip", () => {
  it("rounds a number to exactly 2 decimal places", () => {
    expect(formatValue(21.123456)).toBe("21.12");
    expect(formatValue(68.7)).toBe("68.70");
    expect(formatValue(0)).toBe("0.00");
  });

  it("rounds (not truncates) the third decimal", () => {
    expect(formatValue(21.999)).toBe("22.00");
  });

  it("passes non-numeric values through unchanged", () => {
    expect(formatValue("n/a")).toBe("n/a");
  });
});
