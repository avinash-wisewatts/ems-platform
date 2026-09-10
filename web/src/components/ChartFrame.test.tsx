import { describe, expect, it } from "vitest";
import { render, screen } from "@testing-library/react";
import { ChartFrame } from "./ChartFrame";

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
});
