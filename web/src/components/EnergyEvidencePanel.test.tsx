import { describe, expect, it } from "vitest";
import { render, screen } from "@testing-library/react";
import { EnergyEvidencePanel } from "./EnergyEvidencePanel";
import type { EnergyEvidenceSummary } from "../energy/evidence";

function summary(overrides: Partial<EnergyEvidenceSummary> = {}): EnergyEvidenceSummary {
  return {
    hasData: true,
    totalIntervals: 4,
    validImportIntervals: 4,
    invalidImportIntervals: 0,
    validExportIntervals: 4,
    invalidExportIntervals: 0,
    gapIntervalCount: 0,
    resetIntervalCount: 0,
    rolloverIntervalCount: 0,
    invalidIntervalCount: 0,
    firstSourceBucket: "2026-06-01T00:00:00Z",
    lastSourceBucket: "2026-06-01T00:45:00Z",
    coveragePercent: 100,
    ...overrides,
  };
}

describe("EnergyEvidencePanel -- semantic customer language, never QualityIndicator's lattice", () => {
  it("renders a no-data message when there is no evidence, not a fabricated coverage figure", () => {
    render(<EnergyEvidencePanel summary={summary({ hasData: false, coveragePercent: null })} />);
    expect(screen.getByTestId("energy-evidence-no-data")).toBeTruthy();
    expect(screen.queryByTestId("energy-evidence-panel")).toBeNull();
  });

  it("renders coverage but omits every indicator row and the overlap note when none occurred", () => {
    render(<EnergyEvidencePanel summary={summary()} />);
    expect(screen.getByTestId("energy-evidence-coverage")).toHaveTextContent("100.0%");
    expect(screen.queryByTestId("energy-evidence-gaps")).toBeNull();
    expect(screen.queryByTestId("energy-evidence-resets")).toBeNull();
    expect(screen.queryByTestId("energy-evidence-rollovers")).toBeNull();
    expect(screen.queryByTestId("energy-evidence-invalid")).toBeNull();
    expect(screen.queryByTestId("energy-evidence-indicators-note")).toBeNull();
  });

  it("surfaces data gaps, meter resets, meter rollovers, and invalid intervals by their own semantic names when present, plus an overlap disclaimer", () => {
    render(
      <EnergyEvidencePanel
        summary={summary({
          gapIntervalCount: 2,
          resetIntervalCount: 1,
          rolloverIntervalCount: 3,
          invalidIntervalCount: 1,
          coveragePercent: 50,
        })}
      />,
    );
    expect(screen.getByTestId("energy-evidence-gaps")).toHaveTextContent("Data gaps");
    expect(screen.getByTestId("energy-evidence-gaps")).toHaveTextContent("2 intervals");
    expect(screen.getByTestId("energy-evidence-resets")).toHaveTextContent("Meter resets detected");
    expect(screen.getByTestId("energy-evidence-resets")).toHaveTextContent("1 interval affected by a meter reset");
    expect(screen.getByTestId("energy-evidence-rollovers")).toHaveTextContent("Meter rollovers detected");
    expect(screen.getByTestId("energy-evidence-rollovers")).toHaveTextContent("3 intervals affected by a meter rollover");
    expect(screen.getByTestId("energy-evidence-invalid")).toHaveTextContent("Invalid intervals");
    expect(screen.getByTestId("energy-evidence-invalid")).toHaveTextContent("1 interval flagged invalid");
    // The presentation must never read as "gaps + resets + rollovers +
    // invalid = a partition of all intervals" -- an explicit disclaimer is
    // required whenever any indicator is shown.
    expect(screen.getByTestId("energy-evidence-indicators-note")).toHaveTextContent(
      "independent -- more than one can apply to the same interval",
    );
  });

  it("shows the overlap disclaimer when even a single indicator is present, not only when several co-occur", () => {
    render(<EnergyEvidencePanel summary={summary({ gapIntervalCount: 1 })} />);
    expect(screen.getByTestId("energy-evidence-indicators-note")).toBeTruthy();
  });

  it("never renders device IDs, table/view names, migration numbers, or raw internal flag/identifier names", () => {
    render(
      <EnergyEvidencePanel
        summary={summary({ gapIntervalCount: 1, resetIntervalCount: 1, rolloverIntervalCount: 1, invalidIntervalCount: 1 })}
      />,
    );
    const text = screen.getByTestId("energy-evidence-panel").textContent ?? "";
    expect(text).not.toMatch(
      /device_id|energy_consumption_(hourly|daily)|quality_code|v_energy_semantic_rollup|migration\s*\d|gap_detected|reset_detected|rollover_detected|invalid_detected|SELECT /i,
    );
  });

  it("shows the latest available data timestamp when known", () => {
    render(<EnergyEvidencePanel summary={summary({ lastSourceBucket: "2026-06-05T12:30:00Z" })} />);
    expect(screen.getByTestId("energy-evidence-freshness")).toBeTruthy();
  });
});
