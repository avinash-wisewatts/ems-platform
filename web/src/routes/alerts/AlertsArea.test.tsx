import { describe, expect, it } from "vitest";
import { fireEvent, screen, waitFor, within } from "@testing-library/react";
import { AlertsArea } from "./AlertsArea";
import { ADMIN_USER, VIEWER_USER, renderWithProviders, stubFetch, SITES_ONE } from "../../test-utils";
import type { CurrentUser } from "../../api/types";

const SITE_ID = SITES_ONE.sites[0]!.site_id;
const RULE_ID = "55555555-5555-4555-8555-555555555555";
const ALERT_ID = "77777777-7777-4777-8777-777777777777";
const ASSET_ID = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa";

const OPERATOR_USER: CurrentUser = {
  ...VIEWER_USER,
  portal_user_id: 4,
  role_code: "OPERATOR",
  permissions: ["dashboard.view", "alert.acknowledge"],
};

function alertFixture(overrides: Record<string, unknown> = {}) {
  return {
    alert_id: ALERT_ID,
    site_id: SITE_ID,
    rule_id: RULE_ID,
    rule_name: "Chiller overload",
    rule_deleted: false,
    asset: { asset_id: ASSET_ID, name: "Chiller 1" },
    parameter: { code: "ACTIVE_POWER", name: "Active Power", qualifier: "TOTAL", unit: "kW" },
    condition: { comparator: "GT", threshold: 50, tolerance: null, comparison_mode: "FIXED" },
    state: "ACTIVE",
    triggered_at: "2026-11-18T06:00:00Z",
    trigger_value: 61,
    latest_value: 63,
    latest_value_at: "2026-11-18T06:10:00Z",
    data_unavailable: false,
    resolved_at: null,
    resolved_value: null,
    ended_at: null,
    ended_reason_code: null,
    acknowledgement: null,
    previous_occurrence_count: 0,
    most_recent_previous_occurrence_at: null,
    ...overrides,
  };
}

function ruleFixture(overrides: Record<string, unknown> = {}) {
  return {
    rule_id: RULE_ID,
    site_id: SITE_ID,
    name: "Chiller overload",
    asset: { asset_id: ASSET_ID, name: "Chiller 1" },
    parameter: { code: "ACTIVE_POWER", name: "Active Power", qualifier: "TOTAL", unit: "kW" },
    condition: { comparator: "GT", threshold: 50, tolerance: null, comparison_mode: "FIXED" },
    schedule: { start_time: "22:00", end_time: "06:00", weekdays: ["MON", "TUE"], every_day: false, timezone: "Asia/Kolkata" },
    reminder_minutes: null,
    delivery: { email: { requested: false, status: "COMING_SOON" }, whatsapp: { requested: false, status: "COMING_SOON" } },
    enabled: true,
    version: 3,
    active_alert_id: null,
    created_at: "2026-11-18T06:00:00Z",
    updated_at: "2026-11-18T06:00:00Z",
    ...overrides,
  };
}

const PARAMETERS = {
  site_id: SITE_ID,
  parameters: [
    { asset: { asset_id: ASSET_ID, name: "Chiller 1" }, parameter: { code: "ACTIVE_POWER", name: "Active Power", qualifier: "TOTAL", unit: "kW" } },
    { asset: { asset_id: ASSET_ID, name: "Chiller 1" }, parameter: { code: "FREQUENCY", name: "Frequency", qualifier: null, unit: "Hz" } },
  ],
};

type Call = { url: string; method: string; body: unknown };

function backend(extra?: (call: Call) => { status?: number; jsonBody?: unknown } | undefined) {
  const calls: Call[] = [];
  const mock = stubFetch((url, init) => {
    const call = { url, method: init?.method ?? "GET", body: init?.body ? JSON.parse(String(init.body)) : undefined };
    calls.push(call);
    const custom = extra?.(call);
    if (custom) return custom;
    if (url.includes("/acknowledge")) {
      return { jsonBody: alertFixture({ acknowledgement: { acknowledged_at: "2026-11-18T06:20:00Z", acknowledged_by: "Omar" } }) };
    }
    if (url.includes(`/sites/${SITE_ID}/alerts`)) {
      const history = url.includes("state=RESOLVED");
      return {
        jsonBody: {
          site_id: SITE_ID,
          next_before: null,
          alerts: history
            ? [alertFixture({ state: "RESOLVED", resolved_at: "2026-11-18T07:00:00Z", resolved_value: 20, rule_deleted: true, rule_name: "Old rule" })]
            : [alertFixture()],
        },
      };
    }
    if (url.includes(`/alerts/${ALERT_ID}`)) return { jsonBody: alertFixture() };
    if (url.includes("/alert-rules/parameters")) return { jsonBody: PARAMETERS };
    if (url.includes(`/sites/${SITE_ID}/alert-rules`) && call.method === "GET") {
      return { jsonBody: { site_id: SITE_ID, max_active_rules: 25, rules: [ruleFixture()] } };
    }
    if (call.method === "DELETE") return { status: 204 };
    return { jsonBody: ruleFixture() };
  });
  return { calls, mock };
}

function render(user: CurrentUser, path = "/features/alerts") {
  return renderWithProviders(<AlertsArea />, {
    session: () => Promise.resolve(user),
    sites: () => Promise.resolve(SITES_ONE),
    initialEntries: [path],
  });
}

describe("AlertsArea (ADR-024)", () => {
  it("opens on Active Alerts with Name, Asset, Status and Action columns", async () => {
    backend();
    render(ADMIN_USER);
    const table = await screen.findByTestId("alerts-table-active");
    expect(screen.getByTestId("alerts-tab-active")).toHaveAttribute("aria-selected", "true");
    expect(within(table).getAllByRole("columnheader").map((h) => h.textContent)).toEqual(["Name", "Asset", "Status", "Action"]);
    expect(within(table).getByText("Chiller overload")).toBeTruthy();
    expect(within(table).getByText("Chiller 1")).toBeTruthy();
  });

  it("lets an operator acknowledge; the alert stays Active", async () => {
    const { calls } = backend();
    render(OPERATOR_USER);
    fireEvent.click(await screen.findByTestId(`acknowledge-${ALERT_ID}`));
    await screen.findByTestId("alert-acknowledged");
    expect(calls.some((c) => c.method === "POST" && c.url.endsWith(`/alerts/${ALERT_ID}/acknowledge`))).toBe(true);
    const row = screen.getByTestId(`alert-row-${ALERT_ID}`);
    expect(within(row).getByText("Active")).toBeTruthy();
    expect(within(row).getByText("Acknowledged by Omar")).toBeTruthy();
  });

  it("gives a viewer no Acknowledge action", async () => {
    backend();
    render(VIEWER_USER);
    await screen.findByTestId("alerts-table-active");
    expect(screen.queryByTestId(`acknowledge-${ALERT_ID}`)).toBeNull();
    expect(screen.getByText("Not acknowledged")).toBeTruthy();
  });

  it("shows detail with data-unavailable and a WiseWatts Support acknowledgement", async () => {
    backend((c) =>
      c.url.endsWith(`/alerts/${ALERT_ID}`)
        ? {
            jsonBody: alertFixture({
              data_unavailable: true,
              acknowledgement: { acknowledged_at: "2026-11-18T06:20:00Z", acknowledged_by: "WiseWatts Support" },
            }),
          }
        : undefined,
    );
    render(VIEWER_USER);
    fireEvent.click(await screen.findByText("Chiller overload"));
    const detail = await screen.findByTestId("alert-detail");
    await waitFor(() => expect(within(detail).getByTestId("alert-detail-latest").textContent).toBe("Unable to evaluate — data unavailable"));
    expect(within(detail).getByTestId("alert-detail-status").textContent).toBe("Active — data unavailable");
    expect(within(detail).getByTestId("alert-detail-ack").textContent).toContain("Acknowledged by WiseWatts Support");
    expect(within(detail).getByText("Greater than 50 kW")).toBeTruthy();
  });

  it("shows rules read-only to a viewer", async () => {
    backend();
    render(VIEWER_USER, "/features/alerts?tab=rules");
    const table = await screen.findByTestId("alert-rules-table");
    expect(within(table).getByText("Mon, Tue, 22:00–06:00")).toBeTruthy();
    expect(screen.getByTestId(`rule-toggle-${RULE_ID}`)).toBeDisabled();
    expect(screen.queryByTestId("create-alert")).toBeNull();
    expect(screen.queryByTestId(`rule-edit-${RULE_ID}`)).toBeNull();
    expect(screen.queryByTestId(`rule-delete-${RULE_ID}`)).toBeNull();
  });

  it("gives an operator no rule configuration", async () => {
    backend();
    render(OPERATOR_USER, "/features/alerts?tab=rules");
    await screen.findByTestId("alert-rules-table");
    expect(screen.queryByTestId("create-alert")).toBeNull();
    expect(screen.getByTestId(`rule-toggle-${RULE_ID}`)).toBeDisabled();
  });

  it("lets an administrator disable a rule", async () => {
    const { calls } = backend();
    render(ADMIN_USER, "/features/alerts?tab=rules");
    const toggle = await screen.findByTestId(`rule-toggle-${RULE_ID}`);
    expect(toggle).toHaveAttribute("aria-checked", "true");
    fireEvent.click(toggle);
    await waitFor(() => expect(calls.some((c) => c.method === "POST" && c.url.endsWith(`/alert-rules/${RULE_ID}/disable`))).toBe(true));
  });

  it("creates an equal-to rule only with an explicit tolerance; delivery is Coming Soon", async () => {
    const { calls } = backend();
    render(ADMIN_USER, "/features/alerts?tab=rules");
    fireEvent.click(await screen.findByTestId("create-alert"));
    const form = await screen.findByTestId("alert-rule-form");
    expect(within(form).getAllByText("Coming Soon").length).toBeGreaterThanOrEqual(3);
    expect(within(form).getByTestId("rule-delivery-note").textContent).toContain("not sent yet");
    fireEvent.change(within(form).getByTestId("rule-name"), { target: { value: "Grid frequency" } });
    fireEvent.change(within(form).getByTestId("rule-asset"), { target: { value: ASSET_ID } });
    fireEvent.change(within(form).getByTestId("rule-parameter"), { target: { value: "FREQUENCY|" } });
    fireEvent.change(within(form).getByTestId("rule-comparator"), { target: { value: "EQ" } });
    fireEvent.change(within(form).getByTestId("rule-threshold"), { target: { value: "50" } });
    fireEvent.click(within(form).getByTestId("rule-save"));
    expect((await within(form).findByTestId("rule-form-error")).textContent).toBe("Equal to needs a tolerance.");
    expect(calls.some((c) => c.method === "POST" && c.url.endsWith(`/sites/${SITE_ID}/alert-rules`))).toBe(false);
    fireEvent.change(within(form).getByTestId("rule-tolerance"), { target: { value: "0.1" } });
    fireEvent.click(within(form).getByTestId("rule-email"));
    fireEvent.change(within(form).getByTestId("rule-reminder"), { target: { value: "15" } });
    fireEvent.click(within(form).getByTestId("rule-save"));
    await waitFor(() => expect(calls.some((c) => c.method === "POST" && c.url.endsWith(`/sites/${SITE_ID}/alert-rules`))).toBe(true));
    const post = calls.find((c) => c.method === "POST" && c.url.endsWith(`/sites/${SITE_ID}/alert-rules`))!;
    expect(post.body).toEqual({
      name: "Grid frequency",
      asset_id: ASSET_ID,
      parameter_code: "FREQUENCY",
      qualifier: null,
      comparator: "EQ",
      threshold: 50,
      tolerance: 0.1,
      schedule: { start_time: "00:00", end_time: "23:59", weekdays: ["MON", "TUE", "WED", "THU", "FRI", "SAT", "SUN"] },
      reminder_minutes: 15,
      delivery: { email: true, whatsapp: false },
      enabled: true,
    });
  });

  it("edits with the rule version and deletes after confirmation", async () => {
    const { calls } = backend();
    render(ADMIN_USER, "/features/alerts?tab=rules");
    fireEvent.click(await screen.findByTestId(`rule-edit-${RULE_ID}`));
    const form = await screen.findByTestId("alert-rule-form");
    fireEvent.change(within(form).getByTestId("rule-threshold"), { target: { value: "55" } });
    fireEvent.click(within(form).getByTestId("rule-save"));
    await waitFor(() => expect(calls.some((c) => c.method === "PATCH")).toBe(true));
    const patch = calls.find((c) => c.method === "PATCH")! as Call & { body: { version: number; threshold: number } };
    expect(patch.body.version).toBe(3);
    expect(patch.body.threshold).toBe(55);

    fireEvent.click(await screen.findByTestId(`rule-delete-${RULE_ID}`));
    expect(calls.some((c) => c.method === "DELETE")).toBe(false);
    fireEvent.click(await screen.findByTestId("delete-confirm-button"));
    await waitFor(() => expect(calls.some((c) => c.method === "DELETE" && c.url.endsWith(`/alert-rules/${RULE_ID}`))).toBe(true));
  });

  it("History lists Resolved/Ended alerts, including those of deleted rules", async () => {
    const { calls } = backend();
    render(VIEWER_USER, "/features/alerts?tab=history");
    const table = await screen.findByTestId("alerts-table-history");
    expect(within(table).getByText("Old rule")).toBeTruthy();
    expect(within(table).getByText("Resolved")).toBeTruthy();
    const req = calls.find((c) => c.url.includes(`/sites/${SITE_ID}/alerts`))!;
    expect(req.url).toContain("state=RESOLVED");
    expect(req.url).toContain("state=ENDED");
  });

  it("shows a good empty state when nothing is active", async () => {
    stubFetch(() => ({ jsonBody: { site_id: SITE_ID, alerts: [], next_before: null } }));
    render(VIEWER_USER);
    expect(await screen.findByText("No active alerts")).toBeTruthy();
  });
});
