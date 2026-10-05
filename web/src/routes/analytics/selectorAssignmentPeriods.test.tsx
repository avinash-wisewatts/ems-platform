import { describe, expect, it, vi } from "vitest";
import { render, screen, within } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import type { AnalyticsAssignmentPeriod, AnalyticsCatalogResponse } from "../../api/types";
import { DataPointSelector } from "./AnalyticsSelectors";
import { catalogFixture } from "./analyticsTestFixtures";
import { assignedDuring, siteDataPoints } from "./selectorGroups";

const period = (assigned_from: string | null, assigned_to: string | null): AnalyticsAssignmentPeriod => ({
  assigned_from,
  assigned_to,
});

const SEP_2_TO_4 = { from: "2026-09-01T18:30:00.000Z", to: "2026-09-03T18:30:00.000Z" }; // 02-03 Sep IST
const OCT_1_TO_2 = { from: "2026-09-30T18:30:00.000Z", to: "2026-10-01T18:30:00.000Z" }; // 01 Oct IST
const SEP_10 = { from: "2026-09-09T18:30:00.000Z", to: "2026-09-10T18:30:00.000Z" };

/** Two assets: a1's Energy is current; a1's Energy Export was assigned only
 *  1-5 Sep, and a2's Energy Export only from 20 Sep. */
function catalogWithHistory(): AnalyticsCatalogResponse {
  const base = catalogFixture();
  const a1 = base.assets[0]!;
  const a2 = base.assets[1]!;
  return {
    ...base,
    assets: [
      {
        ...a1,
        data_points: [
          { ...a1.data_points[0]!, assignment_periods: [period(null, null)] },
          { ...a1.data_points[1]!, assignment_periods: [period("2026-09-01T00:00:00Z", "2026-09-05T00:00:00Z")] },
        ],
      },
      { ...a2, data_points: [{ ...a2.data_points[1]!, assignment_periods: [period("2026-09-20T00:00:00Z", null)] }] },
    ],
  };
}

describe("assignedDuring -- [assigned_from, assigned_to) overlaps [range.from, range.to)", () => {
  it("open periods and an empty list are always assigned", () => {
    expect(assignedDuring([period(null, null)], OCT_1_TO_2)).toBe(true);
    expect(assignedDuring([], OCT_1_TO_2)).toBe(true);
    expect(assignedDuring(undefined, OCT_1_TO_2)).toBe(true);
  });

  it("a closed period overlaps only ranges that intersect it (ends are exclusive)", () => {
    const closed = [period("2026-09-01T00:00:00Z", "2026-09-05T00:00:00Z")];
    expect(assignedDuring(closed, SEP_2_TO_4)).toBe(true);
    expect(assignedDuring(closed, OCT_1_TO_2)).toBe(false);
    expect(assignedDuring(closed, { from: "2026-09-05T00:00:00Z", to: "2026-09-06T00:00:00Z" })).toBe(false);
    expect(assignedDuring(closed, { from: "2026-08-30T00:00:00Z", to: "2026-09-01T00:00:00Z" })).toBe(false);
    expect(assignedDuring(closed, { from: "2026-08-30T00:00:00Z", to: "2026-09-01T00:00:01Z" })).toBe(true);
  });

  it("several periods: any overlapping one counts; a range in the gap does not", () => {
    const two = [period("2026-09-01T00:00:00Z", "2026-09-05T00:00:00Z"), period("2026-09-20T00:00:00Z", null)];
    expect(assignedDuring(two, SEP_2_TO_4)).toBe(true);
    expect(assignedDuring(two, OCT_1_TO_2)).toBe(true);
    expect(assignedDuring(two, SEP_10)).toBe(false);
  });
});

describe("siteDataPoints -- the site catalogue for the selected range (D42, migration 288)", () => {
  it("without a range, every catalogue point (unchanged)", () => {
    expect(siteDataPoints(catalogWithHistory()).map((p) => p.code)).toEqual(["ENERGY_IMPORT", "ENERGY_EXPORT"]);
  });

  it("a closed assignment is offered when the range overlaps it", () => {
    expect(siteDataPoints(catalogWithHistory(), SEP_2_TO_4).map((p) => p.code)).toEqual(["ENERGY_IMPORT", "ENERGY_EXPORT"]);
  });

  it("is not offered when no asset's assignment overlaps the range", () => {
    expect(siteDataPoints(catalogWithHistory(), SEP_10).map((p) => p.code)).toEqual(["ENERGY_IMPORT"]);
  });

  it("is offered when any asset's assignment overlaps (independent of the selected assets)", () => {
    expect(siteDataPoints(catalogWithHistory(), OCT_1_TO_2).map((p) => p.code)).toEqual(["ENERGY_IMPORT", "ENERGY_EXPORT"]);
  });

  it("an already-selected point stays listed outside its periods, so it can be cleared", () => {
    expect(siteDataPoints(catalogWithHistory(), SEP_10, ["ENERGY_EXPORT"]).map((p) => p.code)).toEqual([
      "ENERGY_IMPORT",
      "ENERGY_EXPORT",
    ]);
  });
});

describe("DataPointSelector follows the draft range", () => {
  const props = { selected: [] as string[], maxDataPoints: 5, onToggle: vi.fn(), onSetDataPoints: vi.fn() };
  const exportBoxes = () => screen.queryAllByRole("checkbox", { name: "Energy Export" });

  it("offers Energy Export for an overlapping range, hides it for a range in its gap, current Energy always", async () => {
    const { rerender } = render(<DataPointSelector catalog={catalogWithHistory()} range={SEP_2_TO_4} {...props} />);
    const selector = screen.getByTestId("data-point-selector");
    await userEvent.click(within(selector).getByRole("button", { name: /^Power/ }));
    expect(exportBoxes()).toHaveLength(1);

    rerender(<DataPointSelector catalog={catalogWithHistory()} range={SEP_10} {...props} />);
    expect(exportBoxes()).toHaveLength(0);
    expect(within(selector).getAllByRole("checkbox", { name: "Energy" }).length).toBeGreaterThan(0);
  });
});
