import { describe, expect, it } from "vitest";
import { render, screen } from "@testing-library/react";
import { DemandCurrentAndMax } from "./DemandCurrentAndMax";

describe("DemandCurrentAndMax", () => {
  it("shows the current demand value, the interval caption, and Peak Power with its occurrence time in the site timezone", () => {
    render(
      <DemandCurrentAndMax
        currentDemandKw={52.4}
        peakPower={{ kw: 68.7, at: "2026-09-18T09:15:00Z" }}
        siteTimezone="Asia/Kolkata"
        testIdPrefix="demand"
      />,
    );

    expect(screen.getByTestId("demand-current")).toHaveTextContent("52.4");
    expect(screen.getByText("Latest 15-min interval")).toBeTruthy();
    expect(screen.getByText("Peak Power")).toBeTruthy();
    expect(screen.queryByText("Max Demand")).toBeNull();
    // 2026-09-18T09:15:00Z is 14:45 the same day in Asia/Kolkata.
    expect(screen.getByTestId("demand-peak")).toHaveTextContent("68.7 kW");
    expect(screen.getByTestId("demand-peak")).toHaveTextContent("14:45, 18 Sep");
  });

  it("never labels the Peak Power value 'Demand'", () => {
    render(
      <DemandCurrentAndMax
        currentDemandKw={52.4}
        peakPower={{ kw: 68.7, at: "2026-09-18T09:15:00Z" }}
        siteTimezone="UTC"
        testIdPrefix="demand"
      />,
    );
    const peak = screen.getByTestId("demand-peak");
    expect(peak).not.toHaveTextContent("Demand");
  });

  it("shows an em dash for a null current value, never a fabricated zero", () => {
    render(
      <DemandCurrentAndMax currentDemandKw={null} peakPower={null} siteTimezone="UTC" testIdPrefix="demand" />,
    );
    expect(screen.getByTestId("demand-current")).toHaveTextContent("—");
  });

  it("shows an honest 'not recorded' message when there is no Peak Power for the period", () => {
    render(
      <DemandCurrentAndMax currentDemandKw={10} peakPower={null} siteTimezone="UTC" testIdPrefix="demand" />,
    );
    expect(screen.getByTestId("demand-peak")).toHaveTextContent("Not recorded for this period yet.");
  });
});
