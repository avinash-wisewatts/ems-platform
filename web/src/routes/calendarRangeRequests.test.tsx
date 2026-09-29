/**
 * F1 regression: every screen that uses the shared time-range presets
 * requests calendar ranges in the SITE's timezone (ADR-022 Amendment 5,
 * D61/D62): local midnight of the first day to the exclusive next local
 * midnight. The fixture site is Asia/Kolkata (UTC+05:30) and the clock is
 * fixed at 2026-06-15 17:30 IST, so "today" is 15 Jun IST =
 * [2026-06-14T18:30Z, 2026-06-15T18:30Z).
 *
 * Only the requested windows are asserted here; each screen's rendering is
 * covered by its own test file.
 */
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { EnergyOverview } from "./energy/EnergyOverview";
import { DemandOverview } from "./demand/DemandOverview";
import { PowerQualityOverview } from "./power-quality/PowerQualityOverview";
import { SiteOverview } from "./SiteOverview";
import { MainDashboard } from "./dashboard/MainDashboard";
import { renderWithProviders, stubFetch, SITES_ONE } from "../test-utils";

const FIXED_NOW = new Date("2026-06-15T12:00:00.000Z");
const TODAY_FROM = "2026-06-14T18:30:00.000Z";
const RANGE_TO = "2026-06-15T18:30:00.000Z";
const SEVEN_DAYS_FROM = "2026-06-08T18:30:00.000Z";
const THREE_MONTHS_FROM = "2026-03-14T18:30:00.000Z"; // 15 Mar 00:00 IST
// Comparisons use only the elapsed portion: the last completed UTC hour (1h)
// or today's local midnight for complete days (Typical, 1d).
const LAST_HOUR = "2026-06-15T12:00:00.000Z";
const TODAY_MIDNIGHT = TODAY_FROM;

type Request = { path: string; from: string | null; to: string | null; resolution: string | null };

function recordRequests(): Request[] {
  const requests: Request[] = [];
  stubFetch((url) => {
    const parsed = new URL(url, "http://localhost");
    requests.push({
      path: parsed.pathname.replace(/^\/api\/v1\/sites\/[^/]+/, ""),
      from: parsed.searchParams.get("from"),
      to: parsed.searchParams.get("to"),
      resolution: parsed.searchParams.get("resolution"),
    });
    return { status: 404, jsonBody: { error: "not_found", detail: "not needed by this test" } };
  });
  return requests;
}

const find = (requests: Request[], path: string) => requests.filter((r) => r.path === path);

beforeEach(() => {
  vi.useFakeTimers({ toFake: ["Date"] });
  vi.setSystemTime(FIXED_NOW);
});

afterEach(() => {
  vi.useRealTimers();
});

describe("F1 -- screens request site-local calendar ranges", () => {
  it("Energy: the 7 Days range at IST midnights; the previous period covers only the same elapsed hours", async () => {
    const requests = recordRequests();
    renderWithProviders(<EnergyOverview />, { sites: () => Promise.resolve(SITES_ONE) });

    await waitFor(() => expect(find(requests, "/energy/consumption")).toHaveLength(2));
    const [current, previous] = find(requests, "/energy/consumption");
    expect(current).toMatchObject({ from: SEVEN_DAYS_FROM, to: RANGE_TO, resolution: "1h" });
    // Same start as the whole previous period; cut at LAST_HOUR - 7 days.
    expect(previous).toMatchObject({ from: "2026-06-01T18:30:00.000Z", to: "2026-06-08T12:00:00.000Z", resolution: "1h" });
    expect(Date.parse(previous!.to!) - Date.parse(previous!.from!)).toBe(Date.parse(LAST_HOUR) - Date.parse(SEVEN_DAYS_FROM));
    expect(find(requests, "/energy/consumption/evidence")[0]).toMatchObject({ from: SEVEN_DAYS_FROM, to: RANGE_TO });
  });

  it("Demand: 7 Days window at IST midnights", async () => {
    const requests = recordRequests();
    renderWithProviders(<DemandOverview />, { sites: () => Promise.resolve(SITES_ONE) });

    await waitFor(() => expect(find(requests, "/demand")).toHaveLength(1));
    expect(find(requests, "/demand")[0]).toMatchObject({ from: SEVEN_DAYS_FROM, to: RANGE_TO });
  });

  it("Power Quality: 7 Days window at IST midnights, 15-minute resolution", async () => {
    const requests = recordRequests();
    renderWithProviders(<PowerQualityOverview />, { sites: () => Promise.resolve(SITES_ONE) });

    await waitFor(() => expect(find(requests, "/power-quality")).toHaveLength(1));
    expect(find(requests, "/power-quality")[0]).toMatchObject({ from: SEVEN_DAYS_FROM, to: RANGE_TO, resolution: "15min" });
  });

  it("Site Overview: energy, typical reference, demand and power quality all use the 7 Days calendar range", async () => {
    const requests = recordRequests();
    renderWithProviders(<SiteOverview />, { sites: () => Promise.resolve(SITES_ONE) });

    await waitFor(() => expect(find(requests, "/energy/consumption/typical-reference")).toHaveLength(1));
    expect(find(requests, "/energy/consumption")[0]).toMatchObject({ from: SEVEN_DAYS_FROM, to: RANGE_TO });
    // The reference window is the 7 x 24 h window ending at the range end.
    expect(find(requests, "/energy/consumption/typical-reference")[0]).toMatchObject({ from: SEVEN_DAYS_FROM, to: RANGE_TO });
    // The actual consumption compared with it: the 6 complete elapsed days, read at 1d.
    expect(find(requests, "/energy/consumption")).toContainEqual(
      expect.objectContaining({ from: SEVEN_DAYS_FROM, to: TODAY_MIDNIGHT, resolution: "1d" }),
    );
    await waitFor(() => expect(find(requests, "/demand")).toHaveLength(1));
    expect(find(requests, "/demand")[0]).toMatchObject({ from: SEVEN_DAYS_FROM, to: RANGE_TO });
    await waitFor(() => expect(find(requests, "/power-quality")).toHaveLength(1));
    expect(find(requests, "/power-quality")[0]).toMatchObject({ from: SEVEN_DAYS_FROM, to: RANGE_TO });
  });

  it("Site Overview, 3 Months: the calendar range for consumption, a 90-day typical-reference window ending at the same instant", async () => {
    const requests = recordRequests();
    renderWithProviders(<SiteOverview />, { sites: () => Promise.resolve(SITES_ONE) });
    await waitFor(() => expect(find(requests, "/energy/consumption/typical-reference")).toHaveLength(1));

    await userEvent.click(screen.getByRole("button", { name: "3 Months" }));

    await waitFor(() => expect(find(requests, "/energy/consumption/typical-reference")).toHaveLength(2));
    expect(find(requests, "/energy/consumption")).toContainEqual(
      expect.objectContaining({ from: THREE_MONTHS_FROM, to: RANGE_TO, resolution: "1d" }),
    );
    expect(find(requests, "/energy/consumption")).toContainEqual(
      expect.objectContaining({ from: THREE_MONTHS_FROM, to: TODAY_MIDNIGHT, resolution: "1d" }),
    );
    const reference = find(requests, "/energy/consumption/typical-reference")[1]!;
    expect(reference.to).toBe(RANGE_TO);
    expect(Date.parse(reference.to!) - Date.parse(reference.from!)).toBe(90 * 86_400_000);
  });

  it("Main Dashboard: today's demand is the whole IST day; the 7-day energy health check uses the calendar range", async () => {
    const requests = recordRequests();
    renderWithProviders(<MainDashboard />, { sites: () => Promise.resolve(SITES_ONE) });

    await waitFor(() => expect(find(requests, "/demand").length).toBeGreaterThanOrEqual(1));
    expect(find(requests, "/demand")).toContainEqual(expect.objectContaining({ from: TODAY_FROM, to: RANGE_TO }));
    await waitFor(() => expect(find(requests, "/energy/consumption/typical-reference")).toHaveLength(1));
    expect(find(requests, "/energy/consumption")).toContainEqual(
      expect.objectContaining({ from: SEVEN_DAYS_FROM, to: RANGE_TO }),
    );
    expect(find(requests, "/energy/consumption/typical-reference")[0]).toMatchObject({ from: SEVEN_DAYS_FROM, to: RANGE_TO });
    // The Energy Attention health check compares only the complete elapsed days.
    expect(find(requests, "/energy/consumption")).toContainEqual(
      expect.objectContaining({ from: SEVEN_DAYS_FROM, to: TODAY_MIDNIGHT, resolution: "1d" }),
    );
  });
});
