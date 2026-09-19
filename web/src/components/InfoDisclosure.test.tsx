import { describe, expect, it } from "vitest";
import { render, screen } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { InfoDisclosure } from "./InfoDisclosure";

describe("InfoDisclosure -- accessible hover/focus tooltip affordance, no library", () => {
  it("renders a keyboard-focusable trigger button, collapsed by default", () => {
    render(<InfoDisclosure label="Current" explanation="Data is fresh." testId="freshness" />);
    const trigger = screen.getByRole("button", { name: 'What does "Current" mean?' });
    expect(trigger).toHaveAttribute("aria-expanded", "false");
    expect(screen.getByTestId("freshness-explanation")).toHaveAttribute("hidden");
  });

  it("shows the explanation on hover, and hides it again when the pointer leaves", async () => {
    const user = userEvent.setup();
    render(<InfoDisclosure label="Outdated" explanation="Data is old." testId="freshness" />);
    const wrapper = screen.getByTestId("freshness-info");
    const trigger = screen.getByRole("button", { name: 'What does "Outdated" mean?' });
    const explanation = screen.getByTestId("freshness-explanation");

    await user.hover(wrapper);

    expect(trigger).toHaveAttribute("aria-expanded", "true");
    expect(explanation).not.toHaveAttribute("hidden");
    expect(explanation).toHaveTextContent("Data is old.");
    expect(trigger).toHaveAttribute("aria-controls", explanation.id);

    await user.unhover(wrapper);

    expect(trigger).toHaveAttribute("aria-expanded", "false");
    expect(explanation).toHaveAttribute("hidden");
  });

  it("does not require a click -- clicking the trigger has no toggle effect of its own", async () => {
    const user = userEvent.setup();
    render(<InfoDisclosure label="Calculating" explanation="Still working it out." testId="demand-status" />);
    const trigger = screen.getByRole("button", { name: 'What does "Calculating" mean?' });

    // A click focuses the button (which shows it, same as any focus) but
    // does not leave it "stuck" open independent of hover/focus state --
    // there is no separate open/closed toggle triggered by the click
    // itself, only the focus that comes along with it.
    await user.click(trigger);
    expect(trigger).toHaveAttribute("aria-expanded", "true");

    await user.tab();
    expect(trigger).toHaveAttribute("aria-expanded", "false");
  });

  it("is keyboard-accessible: shows on focus, hides on blur (the accessible equivalent of hover)", async () => {
    const user = userEvent.setup();
    render(<InfoDisclosure label="Calculating" explanation="Still working it out." testId="demand-status" />);
    const trigger = screen.getByRole("button", { name: 'What does "Calculating" mean?' });

    await user.tab();
    expect(trigger).toHaveFocus();
    expect(trigger).toHaveAttribute("aria-expanded", "true");
    expect(screen.getByTestId("demand-status-explanation")).not.toHaveAttribute("hidden");

    await user.tab();
    expect(trigger).toHaveAttribute("aria-expanded", "false");
    expect(screen.getByTestId("demand-status-explanation")).toHaveAttribute("hidden");
  });

  it("does not render the label itself -- only the caller's visible label text does that", () => {
    render(<InfoDisclosure label="Calculating" explanation="Still working it out." testId="demand-status" />);
    expect(screen.getByTestId("demand-status-info")).not.toHaveTextContent("Calculating");
  });
});
