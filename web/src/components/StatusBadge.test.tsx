import { describe, expect, it } from "vitest";
import { render, screen } from "@testing-library/react";
import { StatusBadge, deriveStatusTone } from "./StatusBadge";
import type { ComparisonResult } from "../energy/comparison";

function result(deltaPercent: number | null): ComparisonResult {
  return {
    basis: "PREVIOUS_PERIOD",
    currentTotalKwh: 100,
    comparisonTotalKwh: 90,
    deltaKwh: 10,
    deltaPercent,
    currentHasData: true,
    comparisonHasData: true,
  };
}

describe("deriveStatusTone -- strict sign only, no invented materiality band", () => {
  it("null delta% is unknown, never guessed", () => {
    expect(deriveStatusTone(null)).toBe("unknown");
  });
  it("any positive value is higher, any negative value is lower, exactly zero is unchanged", () => {
    expect(deriveStatusTone(20)).toBe("higher");
    expect(deriveStatusTone(0.1)).toBe("higher");
    expect(deriveStatusTone(-20)).toBe("lower");
    expect(deriveStatusTone(-0.1)).toBe("lower");
    expect(deriveStatusTone(0)).toBe("unchanged");
  });
});

describe("StatusBadge", () => {
  it("renders the comparison basis alongside the tone", () => {
    render(<StatusBadge result={result(12)} />);
    const badge = screen.getByTestId("status-badge");
    expect(badge).toHaveTextContent("Higher than comparison");
    expect(badge).toHaveTextContent("Previous period");
    expect(badge.dataset.tone).toBe("higher");
  });

  it("renders the unknown tone honestly when no comparison could be computed", () => {
    render(<StatusBadge result={result(null)} />);
    expect(screen.getByTestId("status-badge")).toHaveTextContent("Comparison not available");
  });
});
