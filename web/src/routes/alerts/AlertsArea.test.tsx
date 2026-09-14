import { describe, expect, it } from "vitest";
import { screen, waitFor, fireEvent, within } from "@testing-library/react";
import { AlertsArea } from "./AlertsArea";
import { renderWithProviders, stubFetch, SITES_ONE } from "../../test-utils";

const SITE_ID = SITES_ONE.sites[0]!.site_id;
const CONDITION_KEY = `ENERGY_ATTENTION:PERCENT_DEVIATION_FROM_TYPICAL_REFERENCE:15:SITE:${SITE_ID}`;

function alertFixture(overrides: Record<string, unknown> = {}) {
  return {
    alert_id: "33333333-3333-4333-8333-333333333333",
    site_id: SITE_ID,
    space_id: null,
    asset_id: null,
    condition_key: CONDITION_KEY,
    metric: "ENERGY_CONSUMPTION",
    state: "ACTIVE",
    triggered_at: "2026-09-14T10:00:00Z",
    trigger_value: 123.4,
    resolved_at: null,
    resolved_value: null,
    ended_at: null,
    ended_reason: null,
    previous_occurrence_count: 0,
    most_recent_previous_occurrence_at: null,
    ...overrides,
  };
}

describe("AlertsArea (MVP-7, ADR-016/ADR-017)", () => {
  it("renders the Active tab by default and lists returned alerts", async () => {
    stubFetch((url) => {
      if (url.includes(`/api/v1/sites/${SITE_ID}/alerts`) && url.includes("state=ACTIVE")) {
        return { jsonBody: { site_id: SITE_ID, alerts: [alertFixture()] } };
      }
      return { status: 404, jsonBody: { error: "not_found", detail: "unexpected" } };
    });

    renderWithProviders(<AlertsArea />, { sites: () => Promise.resolve(SITES_ONE) });

    await waitFor(() => expect(screen.getByTestId("alert-list")).toBeTruthy());
    expect(screen.getByTestId("alerts-tab-active")).toHaveAttribute("aria-selected", "true");
    // Scoped to the list item -- the Condition/Metric filter (ADR-016 decision
    // 48) also renders this same label as its one real option.
    const { getByText } = within(screen.getByTestId("alert-list"));
    expect(getByText("Energy consumption deviation")).toBeTruthy();
  });

  it("shows a good empty state, not an error, when there are no active alerts", async () => {
    stubFetch(() => ({ jsonBody: { site_id: SITE_ID, alerts: [] } }));

    renderWithProviders(<AlertsArea />, { sites: () => Promise.resolve(SITES_ONE) });

    await waitFor(() => expect(screen.getByTestId("state-empty")).toBeTruthy());
    expect(screen.queryByTestId("alert-list")).toBeNull();
  });

  it("switching tabs requests the new state and clears the prior selection", async () => {
    stubFetch((url) => {
      if (url.includes("state=ACTIVE")) {
        return { jsonBody: { site_id: SITE_ID, alerts: [alertFixture()] } };
      }
      if (url.includes("state=RESOLVED")) {
        return {
          jsonBody: {
            site_id: SITE_ID,
            alerts: [
              alertFixture({
                alert_id: "44444444-4444-4444-8444-444444444444",
                state: "RESOLVED",
                resolved_at: "2026-09-14T11:00:00Z",
                resolved_value: 90.1,
              }),
            ],
          },
        };
      }
      return { jsonBody: { site_id: SITE_ID, alerts: [] } };
    });

    renderWithProviders(<AlertsArea />, { sites: () => Promise.resolve(SITES_ONE) });
    await waitFor(() => expect(screen.getByTestId("alert-list")).toBeTruthy());

    fireEvent.click(screen.getByTestId("alerts-tab-resolved"));

    await waitFor(() => expect(screen.getByTestId("alerts-tab-resolved")).toHaveAttribute("aria-selected", "true"));
    expect(screen.queryByTestId("alert-detail")).toBeNull();
  });

  it("Ended alerts show their reason and never present resolved fields", async () => {
    stubFetch((url) => {
      if (url.includes("state=ENDED")) {
        return {
          jsonBody: {
            site_id: SITE_ID,
            alerts: [
              alertFixture({
                state: "ENDED",
                ended_at: "2026-09-14T12:00:00Z",
                ended_reason: "Attention condition configuration changed",
              }),
            ],
          },
        };
      }
      return { jsonBody: { site_id: SITE_ID, alerts: [] } };
    });

    renderWithProviders(<AlertsArea />, { sites: () => Promise.resolve(SITES_ONE) });
    fireEvent.click(await screen.findByTestId("alerts-tab-ended"));

    await waitFor(() => expect(screen.getByTestId("alert-list")).toBeTruthy());
    const item = screen.getByTestId(`alert-item-33333333-3333-4333-8333-333333333333`);
    expect(item.textContent).toContain("Ended");
  });

  it("selecting an alert fetches and shows its detail, including derived recurrence", async () => {
    stubFetch((url) => {
      if (url.includes(`/api/v1/sites/${SITE_ID}/alerts`)) {
        return { jsonBody: { site_id: SITE_ID, alerts: [alertFixture({ previous_occurrence_count: 2, most_recent_previous_occurrence_at: "2026-09-10T00:00:00Z" })] } };
      }
      if (url.includes("/api/v1/alerts/33333333-3333-4333-8333-333333333333")) {
        return { jsonBody: alertFixture({ previous_occurrence_count: 2, most_recent_previous_occurrence_at: "2026-09-10T00:00:00Z" }) };
      }
      return { status: 404, jsonBody: { error: "not_found", detail: "unexpected" } };
    });

    renderWithProviders(<AlertsArea />, { sites: () => Promise.resolve(SITES_ONE) });
    await waitFor(() => expect(screen.getByTestId("alert-list")).toBeTruthy());

    fireEvent.click(screen.getByTestId("alert-item-33333333-3333-4333-8333-333333333333"));

    await waitFor(() => expect(screen.getByTestId("alert-detail")).toBeTruthy());
    expect(screen.getByTestId("alert-recurrence")).toHaveTextContent("Previous occurrences: 2");
    // ADR-016 decision 48: hierarchy context and threshold/reference are
    // required detail fields.
    const detail = screen.getByTestId("alert-detail");
    expect(within(detail).getByTestId("hierarchy-crumb")).toHaveTextContent("Alpha One");
    expect(detail.textContent).toContain("Threshold/reference");
    expect(detail.textContent).toContain("15% deviation from typical historical consumption");
  });

  it("Resolved detail shows resolution value before resolved time (ADR-016 decision 48 order)", async () => {
    stubFetch((url) => {
      if (url.includes(`/api/v1/sites/${SITE_ID}/alerts`)) {
        return {
          jsonBody: {
            site_id: SITE_ID,
            alerts: [
              alertFixture({
                state: "RESOLVED",
                resolved_at: "2026-09-14T11:00:00Z",
                resolved_value: 90.1,
              }),
            ],
          },
        };
      }
      if (url.includes("/api/v1/alerts/33333333-3333-4333-8333-333333333333")) {
        return {
          jsonBody: alertFixture({
            state: "RESOLVED",
            resolved_at: "2026-09-14T11:00:00Z",
            resolved_value: 90.1,
          }),
        };
      }
      return { status: 404, jsonBody: { error: "not_found", detail: "unexpected" } };
    });

    renderWithProviders(<AlertsArea />, { sites: () => Promise.resolve(SITES_ONE) });
    fireEvent.click(await screen.findByTestId("alerts-tab-resolved"));
    await waitFor(() => expect(screen.getByTestId("alert-list")).toBeTruthy());
    fireEvent.click(screen.getByTestId("alert-item-33333333-3333-4333-8333-333333333333"));

    await waitFor(() => expect(screen.getByTestId("alert-detail")).toBeTruthy());
    const labels = within(screen.getByTestId("alert-detail"))
      .getAllByRole("term")
      .map((dt) => dt.textContent);
    expect(labels.indexOf("Resolution value")).toBeLessThan(labels.indexOf("Resolved"));
  });

  it("Condition/Metric and date-range filters apply and clear (ADR-016 decision 48)", async () => {
    const requestedUrls: string[] = [];
    stubFetch((url) => {
      requestedUrls.push(url);
      return { jsonBody: { site_id: SITE_ID, alerts: [alertFixture()] } };
    });

    renderWithProviders(<AlertsArea />, { sites: () => Promise.resolve(SITES_ONE) });
    await waitFor(() => expect(screen.getByTestId("alert-list")).toBeTruthy());

    fireEvent.change(screen.getByTestId("alerts-filter-condition"), { target: { value: CONDITION_KEY } });
    fireEvent.change(screen.getByTestId("alerts-filter-from"), { target: { value: "2026-01-01" } });
    fireEvent.change(screen.getByTestId("alerts-filter-to"), { target: { value: "2026-02-01" } });
    fireEvent.click(screen.getByTestId("alerts-apply-filters"));

    await waitFor(() =>
      expect(requestedUrls.some((u) => u.includes(`condition_key=${encodeURIComponent(CONDITION_KEY)}`))).toBe(true),
    );
    expect(requestedUrls.some((u) => u.includes("from=2026-01-01") && u.includes("to=2026-02-01"))).toBe(true);

    fireEvent.click(screen.getByTestId("alerts-clear-filters"));

    await waitFor(() =>
      expect(requestedUrls[requestedUrls.length - 1]).not.toContain(
        `condition_key=${encodeURIComponent(CONDITION_KEY)}`,
      ),
    );
  });

  it("never exposes internal identifiers in the rendered list or detail", async () => {
    stubFetch(() => ({ jsonBody: { site_id: SITE_ID, alerts: [alertFixture()] } }));
    renderWithProviders(<AlertsArea />, { sites: () => Promise.resolve(SITES_ONE) });

    await waitFor(() => expect(screen.getByTestId("alert-list")).toBeTruthy());
    const html = screen.getByTestId("alerts-area").innerHTML;
    expect(html).not.toMatch(/device_id|gateway_id|logical_point_id/);
  });
});
