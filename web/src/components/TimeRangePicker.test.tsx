import { describe, expect, it, vi } from "vitest";
import { render, screen } from "@testing-library/react";
import { TimeRangePicker } from "./TimeRangePicker";

const NOW = new Date("2026-06-15T12:00:00.000Z");

describe("TimeRangePicker", () => {
  it("shows user-facing labels only -- no database/CAGG terms", () => {
    render(<TimeRangePicker value="7D" onChange={() => {}} />);
    for (const label of ["Today", "7 Days", "30 Days", "3 Months", "1 Year"]) {
      expect(screen.getByRole("button", { name: label })).toBeInTheDocument();
    }
    expect(screen.queryByText(/resolution|CAGG|1h|raw|bucket/i)).not.toBeInTheDocument();
  });

  it("marks the current selection pressed and reports changes", () => {
    const onChange = vi.fn();
    render(<TimeRangePicker value="30D" onChange={onChange} />);
    expect(screen.getByRole("button", { name: "30 Days" })).toHaveAttribute("aria-pressed", "true");
    screen.getByRole("button", { name: "Today" }).click();
    expect(onChange).toHaveBeenCalledWith("TODAY");
  });

  it("disables presets the API cannot serve for the given data kind", () => {
    render(<TimeRangePicker value="7D" onChange={() => {}} dataKind="measurement" now={NOW} />);
    expect(screen.getByRole("button", { name: "3 Months" })).toBeDisabled();
    expect(screen.getByRole("button", { name: "1 Year" })).toBeDisabled();
    expect(screen.getByRole("button", { name: "30 Days" })).toBeEnabled();
  });

  it("enables every preset for energy", () => {
    render(<TimeRangePicker value="7D" onChange={() => {}} dataKind="energy" now={NOW} />);
    expect(screen.getByRole("button", { name: "1 Year" })).toBeEnabled();
  });
});
