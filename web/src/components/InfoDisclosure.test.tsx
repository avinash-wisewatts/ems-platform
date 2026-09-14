import { describe, expect, it } from "vitest";
import { render, screen } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { InfoDisclosure } from "./InfoDisclosure";

describe("InfoDisclosure -- accessible native button+aria-expanded affordance, no library", () => {
  it("renders a keyboard-operable trigger button, collapsed by default", () => {
    render(<InfoDisclosure label="Current" explanation="Data is fresh." testId="freshness" />);
    const trigger = screen.getByRole("button", { name: 'What does "Current" mean?' });
    expect(trigger).toHaveAttribute("aria-expanded", "false");
    expect(screen.getByTestId("freshness-explanation")).toHaveAttribute("hidden");
  });

  it("expands on click, exposing the explanation, and is fully valid phrasing content (no <details>)", async () => {
    const user = userEvent.setup();
    render(<InfoDisclosure label="Outdated" explanation="Data is old." testId="freshness" />);
    const trigger = screen.getByRole("button", { name: 'What does "Outdated" mean?' });

    await user.click(trigger);

    expect(trigger).toHaveAttribute("aria-expanded", "true");
    const explanation = screen.getByTestId("freshness-explanation");
    expect(explanation).not.toHaveAttribute("hidden");
    expect(explanation).toHaveTextContent("Data is old.");
    expect(trigger).toHaveAttribute("aria-controls", explanation.id);
  });

  it("is keyboard-operable via Enter, not just a click event", async () => {
    const user = userEvent.setup();
    render(<InfoDisclosure label="Calculating" explanation="Still working it out." testId="demand-status" />);
    const trigger = screen.getByRole("button", { name: 'What does "Calculating" mean?' });

    trigger.focus();
    await user.keyboard("{Enter}");

    expect(trigger).toHaveAttribute("aria-expanded", "true");
    expect(screen.getByTestId("demand-status-explanation")).not.toHaveAttribute("hidden");
  });

  it("does not render the label itself -- only the caller's visible label text does that", () => {
    render(<InfoDisclosure label="Calculating" explanation="Still working it out." testId="demand-status" />);
    expect(screen.getByTestId("demand-status-info")).not.toHaveTextContent("Calculating");
  });
});
