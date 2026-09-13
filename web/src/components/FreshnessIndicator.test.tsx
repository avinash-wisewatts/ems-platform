import { describe, expect, it } from "vitest";
import { render, screen } from "@testing-library/react";
import { FreshnessIndicator, type FreshnessState } from "./FreshnessIndicator";

const FRESHNESS_STATES: readonly FreshnessState[] = ["FRESH", "STALE", "NO_DATA", "UNKNOWN"];

describe("FreshnessIndicator -- separate from QualityIndicator's lattice, invents no wording", () => {
  it("renders nothing when state is null (not yet available -- must never read as UNKNOWN)", () => {
    const { container } = render(<FreshnessIndicator state={null} />);
    expect(container).toBeEmptyDOMElement();
  });

  it("renders nothing when state is undefined", () => {
    const { container } = render(<FreshnessIndicator state={undefined} />);
    expect(container).toBeEmptyDOMElement();
  });

  it.each(FRESHNESS_STATES)("renders the %s state, always -- including UNKNOWN, never hidden", (state) => {
    render(<FreshnessIndicator state={state} />);
    const el = screen.getByTestId("freshness-indicator");
    expect(el).toHaveAttribute("data-freshness", state);
    expect(el).toHaveTextContent(state);
    expect(el).toHaveClass(`freshness--${state.toLowerCase()}`);
  });

  it("never shares QualityIndicator's data-quality attribute or quality-- class prefix", () => {
    render(<FreshnessIndicator state="FRESH" />);
    const el = screen.getByTestId("freshness-indicator");
    expect(el).not.toHaveAttribute("data-quality");
    expect(el.className).not.toContain("quality--");
  });
});
