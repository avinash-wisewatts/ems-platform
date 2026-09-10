import { describe, expect, it } from "vitest";
import { render, screen } from "@testing-library/react";
import {
  QUALITY_CODE_LABELS,
  QUALITY_LABELS,
  QualityIndicator,
  qualityLabelFor,
} from "./QualityIndicator";

describe("QualityIndicator -- renders the frozen lattice, invents nothing", () => {
  it("exposes exactly the five architecture lattice labels", () => {
    expect([...QUALITY_LABELS]).toEqual(["GOOD", "GAP", "ESTIMATED", "INVALID", "PARTIAL"]);
  });

  it("defines NO numeric quality-code mapping yet (Phase 7 exposes none)", () => {
    expect(Object.keys(QUALITY_CODE_LABELS)).toHaveLength(0);
    expect(qualityLabelFor(1)).toBeNull();
    expect(qualityLabelFor(null)).toBeNull();
    expect(qualityLabelFor(undefined)).toBeNull();
  });

  it("renders nothing for null quality by default (the first-slice reality)", () => {
    const { container } = render(<QualityIndicator code={null} />);
    expect(container).toBeEmptyDOMElement();
  });

  it("renders a neutral marker for null quality when explicitly asked", () => {
    render(<QualityIndicator code={null} showWhenUnknown />);
    const el = screen.getByTestId("quality-indicator");
    expect(el).toHaveAttribute("data-quality", "UNKNOWN");
  });

  it.each(QUALITY_LABELS)("renders the %s lattice state when given an explicit label", (label) => {
    render(<QualityIndicator label={label} />);
    const el = screen.getByTestId("quality-indicator");
    expect(el).toHaveAttribute("data-quality", label);
    expect(el).toHaveTextContent(label);
    expect(el).toHaveClass(`quality--${label.toLowerCase()}`);
  });
});
