import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { screen, waitFor, within } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { AppRoutes } from "../../../router";
import type { CurrentUser, SiteReportItem, SiteReportListResponse } from "../../../api/types";
import { ADMIN_USER, SITES_ONE, VIEWER_USER, renderWithProviders } from "../../../test-utils";
import { CREATE_REPORT_MESSAGES } from "./CreateReportTab";

const SITE_ID = SITES_ONE.sites[0]!.site_id;
const VIEW_ONLY: CurrentUser = { ...VIEWER_USER, permissions: ["dashboard.view", "report.view"] };
const BOTH: CurrentUser = { ...ADMIN_USER, permissions: [...ADMIN_USER.permissions, "report.view"] };

function report(overrides: Partial<SiteReportItem> = {}): SiteReportItem {
  return {
    report_id: "r-week",
    report_type: "WEEKLY",
    period_start: "2026-10-25",
    period_end: "2026-10-31",
    comparison_start: "2026-10-18",
    comparison_end: "2026-10-24",
    status: "GENERATED",
    status_label: "Generated",
    status_reason: null,
    incomplete_data: false,
    comparison_incomplete: false,
    latest_version_no: 1,
    version_count: 1,
    generated_at: "2026-11-01T00:45:00Z",
    expires_at: "2026-12-31T00:45:00Z",
    download_version_id: "v-1",
    coverage_summary: { hvac_available_pct: 99.5, kitchen_available_pct: 97.2 },
    ...overrides,
  };
}

type Call = { url: string; method: string };

function stub(list: Partial<SiteReportListResponse> = {}) {
  const calls: Call[] = [];
  const body: SiteReportListResponse = {
    enrolled: true,
    weekly_enabled: true,
    monthly_enabled: false,
    timezone: "Asia/Kolkata",
    reports: [
      report(),
      report({
        report_id: "r-month",
        report_type: "MONTHLY",
        period_start: "2026-10-01",
        period_end: "2026-10-31",
        comparison_start: "2026-09-01",
        comparison_end: "2026-09-30",
        incomplete_data: true,
        comparison_incomplete: true,
        download_version_id: "v-m",
      }),
      report({
        report_id: "r-failed",
        period_start: "2026-10-18",
        period_end: "2026-10-24",
        status: "FAILED",
        status_label: "Failed",
        status_reason: "Not enough EMS data for a reliable report.",
        latest_version_no: null,
        version_count: 0,
        generated_at: null,
        download_version_id: null,
        coverage_summary: null,
      }),
    ],
    ...list,
  };
  const mock = vi.fn(async (input: RequestInfo | URL, init?: RequestInit) => {
    const url = typeof input === "string" ? input : input.toString();
    calls.push({ url, method: init?.method ?? "GET" });
    const json = (status: number, payload: unknown) =>
      ({ ok: status < 300, status, statusText: "", headers: new Headers(), json: async () => payload }) as unknown as Response;
    if (url.startsWith(`/api/v1/sites/${SITE_ID}/site-reports`)) return json(200, body);
    if (url === "/api/v1/site-reports/r-month/versions") {
      return json(200, {
        report_id: "r-month",
        versions: [
          {
            version_id: "v-m",
            version_no: 1,
            generated_at: "2026-11-01T01:30:00Z",
            trigger: "AUTOMATIC",
            expires_at: "2026-12-31T01:30:00Z",
            available: true,
            incomplete_data: true,
            comparison_incomplete: true,
            coverage: {
              current: {
                hvac: { available_pct: 99.1, measured_pct: 98.0, reconstructed_pct: 0.5, gap_filled_pct: 0.6, missing_pct: 0.9 },
                kitchen: { available_pct: 95.0, measured_pct: 94.0, reconstructed_pct: 0, gap_filled_pct: 1, missing_pct: 5 },
                peak_coverage_pct: 97.0,
              },
              affected_assets: ["Kitchen GF Sandwich Toaster"],
              not_temperature_monitored: ["Banquet 1 AHU"],
              comparison_reasons: ["Kitchen energy 71.4 % available (70.0 % measured)"],
            },
            settings_snapshot: {
              settings: [
                {
                  asset_name: "Lobby Area AHU-1",
                  setting: "TEMPERATURE_SETPOINT",
                  value: { value_c: 24 },
                  effective_from: "2026-10-01T00:00:00+05:30",
                },
              ],
            },
            file_name: "Radisson_Blu_Coimbatore_Monthly_EMS_Report_Oct-2026.pdf",
            file_size_bytes: 900000,
            page_count: 12,
          },
        ],
      });
    }
    if (url.startsWith("/api/v1/site-report-versions/")) {
      return {
        ok: true,
        status: 200,
        statusText: "",
        headers: new Headers({ "Content-Disposition": 'attachment; filename="Radisson_Weekly.pdf"' }),
        blob: async () => new Blob(["%PDF-"], { type: "application/pdf" }),
      } as unknown as Response;
    }
    if (url.includes("/report-exports")) return json(200, { jobs: [] });
    if (url.includes("/analytics/catalog")) return json(200, { site_id: SITE_ID, assets: [], data_points: [] });
    if (url.includes("/alerts")) return json(200, { site_id: SITE_ID, alerts: [], next_cursor: null });
    return json(404, { error: "not_found", detail: "unexpected" });
  });
  vi.stubGlobal("fetch", mock);
  return { calls };
}

function render(user: CurrentUser, path = "/reports") {
  return renderWithProviders(<AppRoutes />, {
    session: () => Promise.resolve(user),
    sites: () => Promise.resolve(SITES_ONE),
    initialEntries: [path],
  });
}

describe("Reports -> Create report (read-only)", () => {
  let click: ReturnType<typeof vi.spyOn>;

  beforeEach(() => {
    URL.createObjectURL = vi.fn(() => "blob:pdf") as unknown as typeof URL.createObjectURL;
    URL.revokeObjectURL = vi.fn() as unknown as typeof URL.revokeObjectURL;
    click = vi.spyOn(HTMLAnchorElement.prototype, "click").mockImplementation(() => {});
  });

  afterEach(() => {
    click.mockRestore();
    vi.unstubAllGlobals();
  });

  it("shows the history with statuses, labels and coverage, and only read actions", async () => {
    const { calls } = stub();
    render(VIEW_ONLY);
    const table = await screen.findByTestId("create-report-table");
    const rows = within(table).getAllByTestId("create-report-row");
    expect(rows).toHaveLength(3);
    expect(within(rows[0]!).getByText("25 Oct 2026 – 31 Oct 2026")).toBeTruthy();
    expect(within(rows[0]!).getByTestId("create-report-status-pill").textContent).toBe("Generated");
    expect(within(rows[0]!).getByText("HVAC 99.5 % · Kitchen 97.2 %")).toBeTruthy();
    expect(within(rows[1]!).getByText("October 2026")).toBeTruthy();
    expect(within(rows[1]!).getByText("September 2026")).toBeTruthy();
    expect(within(rows[1]!).getByTestId("label-incomplete")).toBeTruthy();
    expect(within(rows[1]!).getByTestId("label-comparison-incomplete")).toBeTruthy();
    expect(within(rows[0]!).queryByTestId("label-comparison-incomplete")).toBeNull();
    expect(within(rows[2]!).getByText("Failed")).toBeTruthy();
    expect(within(rows[2]!).getByText("Not enough EMS data for a reliable report.")).toBeTruthy();
    expect(within(rows[2]!).queryByTestId("create-report-download")).toBeNull();
    expect(screen.getByTestId("create-report-schedule").textContent).toContain("Automatic monthly reports: Paused");
    for (const label of ["Generate", "Regenerate", "Retry", "Delete", "Restore"]) {
      expect(screen.queryByRole("button", { name: new RegExp(`^${label}`) })).toBeNull();
    }
    expect(screen.queryByTestId("reports-tabs")).toBeNull();
    expect(calls.every((c) => c.method === "GET")).toBe(true);
  });

  it("downloads the PDF with a GET", async () => {
    const { calls } = stub();
    render(VIEW_ONLY);
    const rows = await screen.findAllByTestId("create-report-row");
    await userEvent.click(within(rows[0]!).getByTestId("create-report-download"));
    await waitFor(() => expect(calls.some((c) => c.url === "/api/v1/site-report-versions/v-1/download")).toBe(true));
    await waitFor(() => expect(click).toHaveBeenCalled());
  });

  it("shows version details with data coverage and the settings used", async () => {
    stub();
    render(VIEW_ONLY);
    const rows = await screen.findAllByTestId("create-report-row");
    await userEvent.click(within(rows[1]!).getByRole("button", { name: "Version details" }));
    const details = await screen.findByTestId("create-report-versions");
    expect(details.textContent).toContain("99.1 % available · 98.0 % measured · 0.5 % EMS-reconstructed · 0.6 % gap-filled");
    expect(details.textContent).toContain("Kitchen GF Sandwich Toaster");
    expect(details.textContent).toContain("Not temperature-monitored");
    expect(details.textContent).toContain("Incomplete: Kitchen energy 71.4 % available");
    expect(details.textContent).toContain("Lobby Area AHU-1: setpoint 24.0 °C");
  });

  it("filters by type and status", async () => {
    const { calls } = stub();
    render(VIEW_ONLY);
    await screen.findByTestId("create-report-table");
    await userEvent.selectOptions(screen.getByTestId("create-report-status"), "FAILED");
    expect(screen.getAllByTestId("create-report-row")).toHaveLength(1);
    await userEvent.selectOptions(screen.getByTestId("create-report-type"), "MONTHLY");
    await waitFor(() => expect(calls.some((c) => c.url.includes("type=MONTHLY"))).toBe(true));
  });

  it("explains when the site is not enrolled", async () => {
    stub({ enrolled: false, reports: [] });
    render(VIEW_ONLY);
    expect(await screen.findByText(CREATE_REPORT_MESSAGES.notEnrolled)).toBeTruthy();
  });

  it("offers both tabs when the user can export and view, and switches with ?tab=create", async () => {
    stub();
    render(BOTH);
    await screen.findByTestId("reports-tabs");
    expect(await screen.findByTestId("page-reports")).toBeTruthy();
    await userEvent.click(screen.getByTestId("reports-tab-create"));
    expect(await screen.findByTestId("page-create-report")).toBeTruthy();
  });

  it("opens Create report directly from the URL", async () => {
    stub();
    render(BOTH, "/reports?tab=create");
    expect(await screen.findByTestId("page-create-report")).toBeTruthy();
  });
});
