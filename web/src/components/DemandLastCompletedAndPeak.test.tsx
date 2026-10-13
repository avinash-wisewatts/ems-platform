import { describe, expect, it } from "vitest";
import { render, screen } from "@testing-library/react";
import type { DemandIntervalPoint } from "../api/types";
import { DemandLastCompletedAndPeak } from "./DemandLastCompletedAndPeak";

/** [16:30, 16:45) IST on 08 Sep. */
function completed(overrides: Partial<DemandIntervalPoint> = {}): DemandIntervalPoint {
  return {
    interval_start: "2026-09-08T11:00:00Z",
    interval_end: "2026-09-08T11:15:00Z",
    demand_kw: 52.4,
    peak_power_kw: 60.2,
    quality_status: "VALID",
    coverage_percent: 100,
    ...overrides,
  };
}

const PEAK = { kw: 68.7, at: "2026-09-18T09:15:00Z" };

describe("DemandLastCompletedAndPeak", () => {
  it("shows a VALID last completed interval: value, site-local start-end and status", () => {
    render(
      <DemandLastCompletedAndPeak
        lastCompleted={completed()}
        peakPower={PEAK}
        siteTimezone="Asia/Kolkata"
        testIdPrefix="demand"
      />,
    );

    expect(screen.getByTestId("demand-last-completed-value")).toHaveTextContent("52.4");
    expect(screen.getByTestId("demand-last-completed-interval")).toHaveTextContent(
      "Last completed 15-min interval 16:30–16:45, 08 Sep",
    );
    expect(screen.getByTestId("demand-last-completed-status")).toHaveTextContent("Complete data");
  });

  it("never shows a current, provisional or in-progress value", () => {
    render(
      <DemandLastCompletedAndPeak
        lastCompleted={completed()}
        peakPower={PEAK}
        siteTimezone="Asia/Kolkata"
        testIdPrefix="demand"
      />,
    );
    expect(document.body).not.toHaveTextContent(/current|provisional|in progress|calculating/i);
  });

  it("does not present an INCOMPLETE interval's value as demand", () => {
    render(
      <DemandLastCompletedAndPeak
        lastCompleted={completed({ quality_status: "INCOMPLETE", demand_kw: 31.7, coverage_percent: 72 })}
        peakPower={PEAK}
        siteTimezone="Asia/Kolkata"
        testIdPrefix="demand"
      />,
    );
    expect(screen.getByTestId("demand-last-completed-value")).toHaveTextContent("—");
    expect(document.body).not.toHaveTextContent("31.7");
    expect(screen.getByTestId("demand-last-completed-status")).toHaveTextContent("Incomplete data (72% coverage)");
    expect(screen.getByTestId("demand-last-completed-interval")).toHaveTextContent("16:30–16:45, 08 Sep");
  });

  it("shows an unavailable interval as 'Data unavailable' with no value", () => {
    render(
      <DemandLastCompletedAndPeak
        lastCompleted={completed({ quality_status: "NO_DATA", demand_kw: null, coverage_percent: 0 })}
        peakPower={null}
        siteTimezone="Asia/Kolkata"
        testIdPrefix="demand"
      />,
    );
    expect(screen.getByTestId("demand-last-completed-value")).toHaveTextContent("—");
    expect(screen.getByTestId("demand-last-completed-status")).toHaveTextContent("Data unavailable");
  });

  it("says so when there is no completed interval", () => {
    render(
      <DemandLastCompletedAndPeak lastCompleted={null} peakPower={null} siteTimezone="UTC" testIdPrefix="demand" />,
    );
    expect(screen.getByTestId("demand-last-completed-none")).toHaveTextContent(
      "No completed demand interval in the last 7 days.",
    );
    expect(screen.queryByTestId("demand-last-completed-value")).toBeNull();
  });

  it("shows Peak Power with its occurrence time in the site timezone", () => {
    render(
      <DemandLastCompletedAndPeak
        lastCompleted={completed()}
        peakPower={PEAK}
        siteTimezone="Asia/Kolkata"
        testIdPrefix="demand"
      />,
    );
    expect(screen.getByText("Peak Power")).toBeTruthy();
    expect(screen.queryByText("Max Demand")).toBeNull();
    // 2026-09-18T09:15:00Z is 14:45 the same day in Asia/Kolkata.
    expect(screen.getByTestId("demand-peak")).toHaveTextContent("68.7 kW");
    expect(screen.getByTestId("demand-peak")).toHaveTextContent("14:45, 18 Sep");
  });

  it("never labels the Peak Power value 'Demand'", () => {
    render(
      <DemandLastCompletedAndPeak lastCompleted={completed()} peakPower={PEAK} siteTimezone="UTC" testIdPrefix="demand" />,
    );
    expect(screen.getByTestId("demand-peak")).not.toHaveTextContent("Demand");
  });

  it("shows an honest 'not recorded' message when there is no Peak Power for the period", () => {
    render(
      <DemandLastCompletedAndPeak lastCompleted={null} peakPower={null} siteTimezone="UTC" testIdPrefix="demand" />,
    );
    expect(screen.getByTestId("demand-peak")).toHaveTextContent("Not recorded for this period yet.");
  });
});
