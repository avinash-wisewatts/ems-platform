import { describe, expect, it, vi } from "vitest";
import { render, screen } from "@testing-library/react";
import { Loading } from "./Loading";
import { ErrorState } from "./ErrorState";
import { EmptyState } from "./EmptyState";
import { NoDataYet } from "./NoDataYet";
import { NotAccessibleError } from "../../api/errors";

describe("shared UI states -- loading / error / empty / no-data are distinct", () => {
  it("Loading is a polite status", () => {
    render(<Loading label="Fetching…" />);
    const el = screen.getByTestId("state-loading");
    expect(el).toHaveAttribute("role", "status");
    expect(el).toHaveTextContent("Fetching…");
  });

  it("ErrorState is an alert, surfaces the detail, and can retry", () => {
    const onRetry = vi.fn();
    render(<ErrorState error={new NotAccessibleError("Space not found or not accessible.")} onRetry={onRetry} />);
    const el = screen.getByTestId("state-error");
    expect(el).toHaveAttribute("role", "alert");
    expect(el).toHaveTextContent("Space not found or not accessible.");
    screen.getByRole("button", { name: "Try again" }).click();
    expect(onRetry).toHaveBeenCalledOnce();
  });

  it("EmptyState is for a legitimately empty collection", () => {
    render(<EmptyState title="No accessible sites">Ask an admin.</EmptyState>);
    expect(screen.getByTestId("state-empty")).toHaveTextContent("No accessible sites");
  });

  it("NoDataYet is a calm status, NOT an alert (no data is never a failure)", () => {
    render(<NoDataYet />);
    const el = screen.getByTestId("state-no-data");
    expect(el).toHaveAttribute("role", "status");
    expect(el).not.toHaveAttribute("role", "alert");
    expect(el).toHaveTextContent(/no data/i);
  });
});
