import { afterEach, describe, expect, it, vi } from "vitest";
import { act, fireEvent, screen, waitFor, within } from "@testing-library/react";
import { ActiveAlertsCard, orderActiveAlerts } from "./ActiveAlertsCard";
import { ALERTS_CHANGED_EVENT } from "../../alerts/useActiveAlertCount";
import { formatSiteTime } from "./alertFormat";
import { activeAlertFixture, renderWithProviders, stubFetch, SITES_ONE } from "../../test-utils";
import type { Alert } from "../../api/types";

const SITE_ID = SITES_ONE.sites[0]!.site_id;
const ASSET_A = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa";
const ASSET_B = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb";

function alert(n: number, overrides: Partial<Alert> = {}): Alert {
  return activeAlertFixture({
    alert_id: `77777777-7777-4777-8777-00000000000${n}`,
    rule_name: `Rule ${n}`,
    triggered_at: `2026-11-18T0${n}:00:00Z`,
    ...overrides,
  });
}

type Responder = (url: string, init?: RequestInit) => { status?: number; jsonBody?: unknown } | undefined;

function backend(alerts: Alert[] | (() => Alert[]), extra?: Responder) {
  return stubFetch((url, init) => {
    const custom = extra?.(url, init);
    if (custom) return custom;
    if (url.includes(`/sites/${SITE_ID}/alerts`)) {
      const list = typeof alerts === "function" ? alerts() : alerts;
      return { jsonBody: { site_id: SITE_ID, alerts: list, next_before: null } };
    }
    return { status: 404, jsonBody: { error: "not_found", detail: "unexpected" } };
  });
}

function render(props: Partial<Parameters<typeof ActiveAlertsCard>[0]> = {}) {
  return renderWithProviders(
    <ActiveAlertsCard siteId={SITE_ID} timeZone="Asia/Kolkata" canAcknowledge={false} {...props} />,
    { sites: () => Promise.resolve(SITES_ONE) },
  );
}

describe("orderActiveAlerts", () => {
  it("puts unacknowledged alerts first, newest trigger first within each group", () => {
    const acked = { acknowledged_at: "2026-11-18T09:00:00Z", acknowledged_by: "Omar" };
    const ordered = orderActiveAlerts([alert(1), alert(3, { acknowledgement: acked }), alert(2), alert(4, { acknowledgement: acked })]);
    expect(ordered.map((a) => a.rule_name)).toEqual(["Rule 2", "Rule 1", "Rule 4", "Rule 3"]);
  });
});

describe("ActiveAlertsCard (site)", () => {
  it("reads only ACTIVE alerts for the site and lists name, asset, latest value, since and status", async () => {
    const fetchMock = backend([alert(1)]);
    render();
    const table = await screen.findByTestId("active-alerts-table");
    expect(within(table).getAllByRole("columnheader").map((h) => h.textContent)).toEqual([
      "Name",
      "Asset",
      "Latest value",
      "Since",
      "Status",
      "Action",
    ]);
    const row = screen.getByTestId("active-alert-77777777-7777-4777-8777-000000000001");
    expect(row).toHaveTextContent("Rule 1");
    expect(row).toHaveTextContent("Chiller 1");
    expect(row).toHaveTextContent("63 kW");
    expect(row).toHaveTextContent("Active");
    expect(screen.getByTestId("active-alerts-count")).toHaveTextContent("1");
    expect(screen.getByTestId("active-alerts-summary")).toHaveTextContent("1 active · 1 not acknowledged");
    const url = String(fetchMock.mock.calls[0]![0]);
    expect(url).toContain(`/sites/${SITE_ID}/alerts`);
    expect(url).toContain("state=ACTIVE");
    expect(url).not.toContain("state=RESOLVED");
  });

  it("shows when the alert started in the site's timezone, not the browser's or UTC", async () => {
    backend([alert(1, { triggered_at: "2026-11-18T06:00:00Z" })]);
    render({ timeZone: "Asia/Kolkata" });
    const row = await screen.findByTestId("active-alert-77777777-7777-4777-8777-000000000001");
    const siteLocal = formatSiteTime("2026-11-18T06:00:00Z", "Asia/Kolkata");
    expect(siteLocal).not.toEqual(formatSiteTime("2026-11-18T06:00:00Z", "UTC"));
    expect(row).toHaveTextContent(siteLocal);
  });

  it("falls back to the trigger value when no latest value is known, and shows data unavailable", async () => {
    backend([alert(1, { latest_value: null, data_unavailable: true })]);
    render();
    const row = await screen.findByTestId("active-alert-77777777-7777-4777-8777-000000000001");
    expect(row).toHaveTextContent("61 kW");
    expect(row).toHaveTextContent("Active — data unavailable");
  });

  it("links every alert and the header to the Alerts area", async () => {
    backend([alert(1)]);
    render();
    await screen.findByTestId("active-alerts-table");
    expect(screen.getByRole("link", { name: "Rule 1" })).toHaveAttribute("href", "/features/alerts");
    expect(screen.getByTestId("active-alerts-view-all")).toHaveAttribute("href", "/features/alerts");
    expect(screen.getByTestId("active-alerts-view-all")).toHaveTextContent("Open Alerts");
  });

  it("shows at most five alerts and offers View all with the total", async () => {
    backend([1, 2, 3, 4, 5, 6, 7].map((n) => alert(n)));
    render();
    const table = await screen.findByTestId("active-alerts-table");
    expect(within(table).getAllByRole("row")).toHaveLength(1 + 5);
    expect(screen.getByTestId("active-alerts-view-all")).toHaveTextContent("View all 7");
    expect(screen.getByTestId("active-alerts-count")).toHaveTextContent("7");
  });

  it("shows a calm empty state and no count when nothing is active", async () => {
    backend([]);
    render();
    expect(await screen.findByTestId("active-alerts-empty")).toHaveTextContent("No active alerts");
    expect(screen.queryByTestId("active-alerts-count")).toBeNull();
    expect(screen.queryByTestId("active-alerts-table")).toBeNull();
  });

  it("contains a failed read inside the card and recovers on Retry", async () => {
    let fail = true;
    backend(
      () => [alert(1)],
      (url) => (fail && url.includes("/alerts") ? { status: 500, jsonBody: { error: "internal", detail: "boom" } } : undefined),
    );
    render();
    expect(await screen.findByTestId("active-alerts-error")).toHaveTextContent("Active alerts could not be loaded.");
    fail = false;
    fireEvent.click(screen.getByTestId("active-alerts-retry"));
    expect(await screen.findByTestId("active-alerts-table")).toBeInTheDocument();
  });

  it("treats a malformed response as an error instead of breaking the page", async () => {
    stubFetch(() => ({ jsonBody: { error: "not_found", detail: "unexpected" } }));
    render();
    expect(await screen.findByTestId("active-alerts-error")).toBeInTheDocument();
  });

  it("refreshes when another view signals an alerts change", async () => {
    let list = [alert(1)];
    backend(() => list);
    render();
    await screen.findByTestId("active-alerts-table");
    list = [alert(1), alert(2)];
    act(() => {
      window.dispatchEvent(new Event(ALERTS_CHANGED_EVENT));
    });
    await waitFor(() => expect(screen.getByTestId("active-alerts-count")).toHaveTextContent("2"));
  });
});

describe("ActiveAlertsCard refresh", () => {
  afterEach(() => {
    vi.useRealTimers();
  });

  it("re-reads active alerts every 60 seconds and stops when unmounted", async () => {
    vi.useFakeTimers({ toFake: ["setInterval", "clearInterval"] });
    const fetchMock = backend([alert(1)]);
    const { unmount } = render();
    await screen.findByTestId("active-alerts-table");
    const reads = () => fetchMock.mock.calls.filter((c) => String(c[0]).includes("/alerts")).length;
    expect(reads()).toBe(1);
    act(() => {
      vi.advanceTimersByTime(59_000);
    });
    expect(reads()).toBe(1);
    act(() => {
      vi.advanceTimersByTime(1_000);
    });
    await waitFor(() => expect(reads()).toBe(2));
    unmount();
    act(() => {
      vi.advanceTimersByTime(120_000);
    });
    expect(reads()).toBe(2);
  });
});

describe("ActiveAlertsCard (asset)", () => {
  it("shows only the selected asset's alerts, without an Asset column", async () => {
    backend([alert(1), alert(2, { asset: { asset_id: ASSET_B, name: "AHU 2" } })]);
    render({ assetId: ASSET_A });
    const table = await screen.findByTestId("active-alerts-table");
    expect(screen.getByText("Active Alerts for this Asset")).toBeInTheDocument();
    expect(within(table).queryByRole("columnheader", { name: "Asset" })).toBeNull();
    expect(within(table).getByText("Rule 1")).toBeInTheDocument();
    expect(within(table).queryByText("Rule 2")).toBeNull();
    expect(screen.getByTestId("active-alerts-count")).toHaveTextContent("1");
  });

  it("says so when the site has alerts but none for this asset", async () => {
    backend([alert(2, { asset: { asset_id: ASSET_B, name: "AHU 2" } })]);
    render({ assetId: ASSET_A });
    expect(await screen.findByTestId("active-alerts-empty")).toHaveTextContent("No active alerts for this asset.");
  });
});

describe("ActiveAlertsCard acknowledgement", () => {
  it("offers no Acknowledge action without alert.acknowledge", async () => {
    backend([alert(1)]);
    render({ canAcknowledge: false });
    const row = await screen.findByTestId("active-alert-77777777-7777-4777-8777-000000000001");
    expect(within(row).queryByRole("button", { name: "Acknowledge" })).toBeNull();
    expect(row).toHaveTextContent("Not acknowledged");
  });

  it("acknowledges in place, keeps the alert Active and signals the change", async () => {
    const id = "77777777-7777-4777-8777-000000000001";
    const fetchMock = backend([alert(1)], (url, init) =>
      url.includes(`/alerts/${id}/acknowledge`) && init?.method === "POST"
        ? { jsonBody: alert(1, { acknowledgement: { acknowledged_at: "2026-11-18T06:20:00Z", acknowledged_by: "Omar" } }) }
        : undefined,
    );
    let signalled = 0;
    const onChange = () => (signalled += 1);
    window.addEventListener(ALERTS_CHANGED_EVENT, onChange);
    try {
      render({ canAcknowledge: true });
      fireEvent.click(await screen.findByTestId(`active-alert-acknowledge-${id}`));
      const row = screen.getByTestId(`active-alert-${id}`);
      await waitFor(() => expect(row).toHaveTextContent("Acknowledged by Omar"));
      expect(row).toHaveTextContent("Active");
      expect(signalled).toBeGreaterThanOrEqual(1);
      expect(fetchMock.mock.calls.some((c) => String(c[0]).includes(`/alerts/${id}/acknowledge`))).toBe(true);
    } finally {
      window.removeEventListener(ALERTS_CHANGED_EVENT, onChange);
    }
  });

  it("shows the server's refusal when acknowledgement fails", async () => {
    const id = "77777777-7777-4777-8777-000000000001";
    backend([alert(1)], (url) =>
      url.includes("/acknowledge")
        ? { status: 403, jsonBody: { error: "forbidden", detail: "You cannot acknowledge alerts on this site." } }
        : undefined,
    );
    render({ canAcknowledge: true });
    fireEvent.click(await screen.findByTestId(`active-alert-acknowledge-${id}`));
    expect(await screen.findByRole("alert")).toHaveTextContent("You cannot acknowledge alerts on this site.");
  });
});
