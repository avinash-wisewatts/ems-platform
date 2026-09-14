import { describe, expect, it } from "vitest";
import { render, screen } from "@testing-library/react";
import { FreshnessIndicator, type FreshnessState } from "./FreshnessIndicator";

const FRESHNESS_LABELS: Record<FreshnessState, string> = {
  FRESH: "Current",
  STALE: "Outdated",
  NO_DATA: "Data unavailable",
  UNKNOWN: "Data unavailable",
};

const FRESHNESS_STATES: readonly FreshnessState[] = ["FRESH", "STALE", "NO_DATA", "UNKNOWN"];

describe("FreshnessIndicator -- separate from QualityIndicator's lattice, MVP-5 customer labels", () => {
  it("renders nothing when state is null (not yet available -- must never read as UNKNOWN)", () => {
    const { container } = render(<FreshnessIndicator state={null} />);
    expect(container).toBeEmptyDOMElement();
  });

  it("renders nothing when state is undefined", () => {
    const { container } = render(<FreshnessIndicator state={undefined} />);
    expect(container).toBeEmptyDOMElement();
  });

  it.each(FRESHNESS_STATES)(
    "renders the approved customer label for %s, while data-freshness/class still carry the real state",
    (state) => {
      render(<FreshnessIndicator state={state} />);
      const el = screen.getByTestId("freshness-indicator");
      expect(el).toHaveAttribute("data-freshness", state);
      expect(el).toHaveClass(`freshness--${state.toLowerCase()}`);
      expect(el).toHaveTextContent(FRESHNESS_LABELS[state]);
    },
  );

  it("never renders the raw technical state name as visible/accessible text", () => {
    for (const state of FRESHNESS_STATES) {
      const { unmount } = render(<FreshnessIndicator state={state} />);
      const el = screen.getByTestId("freshness-indicator");
      // The label span's own text must be exactly the customer label -- not
      // the raw state, and not the raw state appended anywhere in the text.
      expect(el.textContent).not.toContain(state);
      unmount();
    }
  });

  it("NO_DATA and UNKNOWN both display 'Data unavailable' while remaining technically distinct", () => {
    const { unmount: unmountNoData } = render(<FreshnessIndicator state="NO_DATA" />);
    const noData = screen.getByTestId("freshness-indicator");
    expect(noData).toHaveTextContent("Data unavailable");
    expect(noData).toHaveAttribute("data-freshness", "NO_DATA");
    expect(noData).toHaveClass("freshness--no_data");
    unmountNoData();

    render(<FreshnessIndicator state="UNKNOWN" />);
    const unknown = screen.getByTestId("freshness-indicator");
    expect(unknown).toHaveTextContent("Data unavailable");
    expect(unknown).toHaveAttribute("data-freshness", "UNKNOWN");
    expect(unknown).toHaveClass("freshness--unknown");
  });

  it("never shares QualityIndicator's data-quality attribute or quality-- class prefix", () => {
    render(<FreshnessIndicator state="FRESH" />);
    const el = screen.getByTestId("freshness-indicator");
    expect(el).not.toHaveAttribute("data-quality");
    expect(el.className).not.toContain("quality--");
  });

  it("pairs each label with an accessible info disclosure explaining it, in plain language", () => {
    render(<FreshnessIndicator state="STALE" />);
    expect(screen.getByTestId("freshness-info")).toBeInTheDocument();
    expect(screen.getByRole("button", { name: 'What does "Outdated" mean?' })).toBeInTheDocument();
    expect(screen.getByTestId("freshness-explanation")).toHaveTextContent(
      "The latest available data is older than expected and may not reflect current conditions.",
    );
  });
});
