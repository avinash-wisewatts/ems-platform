import { describe, expect, it, vi } from "vitest";
import { render, screen, within } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { AnalyticsDateRange, formatDateKey, rangeDisplay } from "./AnalyticsDateRange";
import type { AnalyticsRangeSelection } from "./analyticsQuery";

const TZ = "Asia/Kolkata";
// 15 Sep 2026, 11:30 in IST.
const NOW = new Date("2026-09-15T06:00:00Z");
const now = () => NOW;
const TODAY: AnalyticsRangeSelection = { kind: "preset", preset: "TODAY" };

function setup(value: AnalyticsRangeSelection = TODAY, minDate: string | null = "2026-08-10") {
  const onApply = vi.fn();
  render(
    <div>
      <p>outside</p>
      <AnalyticsDateRange value={value} timeZone={TZ} minDate={minDate} onApply={onApply} now={now} />
    </div>,
  );
  return { onApply };
}

async function openPicker() {
  await userEvent.click(screen.getByRole("button", { name: /From.*To/ }));
  return screen.getByRole("dialog", { name: "Date range" });
}

async function setTime(dialog: HTMLElement, end: "From" | "To", time: string) {
  await userEvent.selectOptions(within(dialog).getByRole("combobox", { name: `${end} hour` }), time.slice(0, 2));
  await userEvent.selectOptions(within(dialog).getByRole("combobox", { name: `${end} minute` }), time.slice(3, 5));
}

function shownTime(dialog: HTMLElement, end: "From" | "To"): string {
  const hour = within(dialog).getByRole("combobox", { name: `${end} hour` }) as HTMLSelectElement;
  const minute = within(dialog).getByRole("combobox", { name: `${end} minute` }) as HTMLSelectElement;
  return `${hour.value}:${minute.value}`;
}

describe("rangeDisplay (D15, D76)", () => {
  it("formats dates as DD Mon YYYY", () => {
    expect(formatDateKey("2026-09-01")).toBe("01 Sep 2026");
  });

  it("always gives both From and To; Today is today at both ends", () => {
    expect(rangeDisplay(TODAY, TZ, NOW)).toEqual({ from: "15 Sep 2026", to: "15 Sep 2026", times: null });
    expect(rangeDisplay({ kind: "preset", preset: "7D" }, TZ, NOW)).toEqual({ from: "09 Sep 2026", to: "15 Sep 2026", times: null });
  });

  it("a refined custom range gives its times, 00:00 standing for an unrefined end", () => {
    expect(
      rangeDisplay({ kind: "custom", fromDate: "2026-09-01", toDate: "2026-09-02", fromTime: "08:15", toTime: null }, TZ, NOW),
    ).toEqual({ from: "01 Sep 2026", to: "02 Sep 2026", times: "08:15 → 00:00" });
  });
});

describe("AnalyticsDateRange", () => {
  it("defaults to Today: today's site-local date as both From and To, no times line", () => {
    setup();
    expect(screen.getByTestId("analytics-date-range-from")).toHaveTextContent("15 Sep 2026");
    expect(screen.getByTestId("analytics-date-range-to")).toHaveTextContent("15 Sep 2026");
    expect(screen.queryByRole("dialog")).not.toBeInTheDocument();
    expect(screen.queryByTestId("analytics-date-range-times")).not.toBeInTheDocument();
  });

  it("the picker shows From and To with 00:00 → 00:00 by default", async () => {
    setup();
    const dialog = await openPicker();
    expect(within(dialog).getByTestId("analytics-picker-from")).toHaveTextContent("15 Sep 2026");
    expect(within(dialog).getByTestId("analytics-picker-to")).toHaveTextContent("15 Sep 2026");
    expect(shownTime(dialog, "From")).toBe("00:00");
    expect(shownTime(dialog, "To")).toBe("00:00");
  });

  it("offers the five quick ranges; choosing one then Apply sets it (D10, D11)", async () => {
    const { onApply } = setup();
    const dialog = await openPicker();
    const quick = within(dialog).getByRole("group", { name: "Quick ranges" });
    expect(within(quick).getAllByRole("button").map((b) => b.textContent)).toEqual(["Today", "7 Days", "30 Days", "3 Months", "1 Year"]);
    expect(within(quick).getByRole("button", { name: "Today" })).toHaveAttribute("aria-pressed", "true");
    await userEvent.click(within(quick).getByRole("button", { name: "30 Days" }));
    expect(within(dialog).getByTestId("analytics-picker-from")).toHaveTextContent("17 Aug 2026");
    expect(onApply).not.toHaveBeenCalled();
    await userEvent.click(within(dialog).getByRole("button", { name: "Apply" }));
    expect(onApply).toHaveBeenCalledWith({ kind: "preset", preset: "30D" });
    expect(screen.queryByRole("dialog")).not.toBeInTheDocument();
  });

  it("applying with the default 00:00 → 00:00 keeps a quick range", async () => {
    const { onApply } = setup();
    const dialog = await openPicker();
    await setTime(dialog, "From", "00:00");
    await userEvent.click(within(dialog).getByRole("button", { name: "Apply" }));
    expect(onApply).toHaveBeenCalledWith(TODAY);
  });

  it("two calendar clicks choose an inclusive custom range, weeks starting Sunday (D13)", async () => {
    const { onApply } = setup();
    const dialog = await openPicker();
    const september = within(dialog).getByRole("grid", { name: "September 2026" });
    expect(within(dialog).getByRole("grid", { name: "August 2026" })).toBeInTheDocument();
    // 1 Sep 2026 is a Tuesday: two leading blanks after Su/Mo.
    expect(september.children[7]?.textContent).toBe("");
    expect(september.children[9]?.textContent).toBe("1");
    const apply = within(dialog).getByRole("button", { name: "Apply" });
    await userEvent.click(within(dialog).getByRole("button", { name: "03 Sep 2026" }));
    expect(within(dialog).getByTestId("analytics-picker-to")).toHaveTextContent("Select a date");
    expect(apply).toBeDisabled();
    await userEvent.click(within(dialog).getByRole("button", { name: "05 Sep 2026" }));
    expect(within(dialog).getByRole("button", { name: "04 Sep 2026" })).toHaveAttribute("aria-pressed", "true");
    await userEvent.click(apply);
    expect(onApply).toHaveBeenCalledWith({ kind: "custom", fromDate: "2026-09-03", toDate: "2026-09-05", fromTime: null, toTime: null });
  });

  it("a second click before the first swaps them", async () => {
    const { onApply } = setup();
    const dialog = await openPicker();
    await userEvent.click(within(dialog).getByRole("button", { name: "05 Sep 2026" }));
    await userEvent.click(within(dialog).getByRole("button", { name: "03 Sep 2026" }));
    await userEvent.click(within(dialog).getByRole("button", { name: "Apply" }));
    expect(onApply).toHaveBeenCalledWith(expect.objectContaining({ fromDate: "2026-09-03", toDate: "2026-09-05" }));
  });

  it("dates are bounded by data availability and today; no month after the current one", async () => {
    setup();
    const dialog = await openPicker();
    expect(within(dialog).getByRole("button", { name: "09 Aug 2026" })).toBeDisabled();
    expect(within(dialog).getByRole("button", { name: "10 Aug 2026" })).toBeEnabled();
    expect(within(dialog).getByRole("button", { name: "15 Sep 2026" })).toBeEnabled();
    expect(within(dialog).getByRole("button", { name: "16 Sep 2026" })).toBeDisabled();
    expect(within(dialog).getByRole("button", { name: "Next month" })).toBeDisabled();
    await userEvent.click(within(dialog).getByRole("button", { name: "Previous month" }));
    expect(within(dialog).getByRole("grid", { name: "July 2026" })).toBeInTheDocument();
    expect(within(dialog).getByRole("button", { name: "Next month" })).toBeEnabled();
  });

  it("time-of-day refinement to any minute turns a quick range into its dates (D60)", async () => {
    const { onApply } = setup();
    const dialog = await openPicker();
    await setTime(dialog, "From", "08:17");
    expect(within(dialog).getByRole("button", { name: "Today" })).toHaveAttribute("aria-pressed", "false");
    await setTime(dialog, "To", "10:43");
    await userEvent.click(within(dialog).getByRole("button", { name: "Apply" }));
    expect(onApply).toHaveBeenCalledWith({ kind: "custom", fromDate: "2026-09-15", toDate: "2026-09-15", fromTime: "08:17", toTime: "10:43" });
  });

  it("a To time of 00:00 is the end of the To date", async () => {
    const { onApply } = setup();
    const dialog = await openPicker();
    await setTime(dialog, "From", "08:00");
    expect(shownTime(dialog, "To")).toBe("00:00");
    await userEvent.click(within(dialog).getByRole("button", { name: "Apply" }));
    expect(onApply).toHaveBeenCalledWith({ kind: "custom", fromDate: "2026-09-15", toDate: "2026-09-15", fromTime: "08:00", toTime: null });
  });

  it("an end time not after the start time cannot be applied", async () => {
    setup();
    const dialog = await openPicker();
    await setTime(dialog, "From", "10:00");
    await setTime(dialog, "To", "09:00");
    expect(within(dialog).getByRole("button", { name: "Apply" })).toBeDisabled();
  });

  it("choosing a quick range resets the time refinement to 00:00", async () => {
    setup({ kind: "custom", fromDate: "2026-09-01", toDate: "2026-09-01", fromTime: "08:00", toTime: null });
    const dialog = await openPicker();
    expect(shownTime(dialog, "From")).toBe("08:00");
    await userEvent.click(within(dialog).getByRole("button", { name: "7 Days" }));
    expect(shownTime(dialog, "From")).toBe("00:00");
  });

  it("shows the refined times under the dates (D76)", () => {
    setup({ kind: "custom", fromDate: "2026-09-01", toDate: "2026-09-01", fromTime: "08:00", toTime: "18:30" });
    expect(screen.getByTestId("analytics-date-range-from")).toHaveTextContent("01 Sep 2026");
    expect(screen.getByTestId("analytics-date-range-to")).toHaveTextContent("01 Sep 2026");
    expect(screen.getByTestId("analytics-date-range-times")).toHaveTextContent("08:00 → 18:30");
  });

  it("Cancel, Escape and click-outside close without applying; reopening starts from the applied range", async () => {
    const { onApply } = setup();
    let dialog = await openPicker();
    await userEvent.click(within(dialog).getByRole("button", { name: "1 Year" }));
    await userEvent.click(within(dialog).getByRole("button", { name: "Cancel" }));
    expect(screen.queryByRole("dialog")).not.toBeInTheDocument();

    dialog = await openPicker();
    expect(within(dialog).getByRole("button", { name: "Today" })).toHaveAttribute("aria-pressed", "true");
    await userEvent.click(within(dialog).getByRole("button", { name: "1 Year" }));
    await userEvent.click(screen.getByText("outside"));
    expect(screen.queryByRole("dialog")).not.toBeInTheDocument();

    await openPicker();
    await userEvent.keyboard("{Escape}");
    expect(screen.queryByRole("dialog")).not.toBeInTheDocument();
    expect(onApply).not.toHaveBeenCalled();
  });
});
