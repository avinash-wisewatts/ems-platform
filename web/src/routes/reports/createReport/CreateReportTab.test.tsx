import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { screen, waitFor, within } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { AppRoutes } from "../../../router";
import type { CurrentUser, SiteReportItem, SiteReportListResponse } from "../../../api/types";
import { ADMIN_USER, SITES_ONE, VIEWER_USER, renderWithProviders } from "../../../test-utils";
import { CREATE_REPORT_MESSAGES, endedPeriods } from "./CreateReportTab";

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
    retrospective_baseline: false,
    ...overrides,
  };
}

type Call = { url: string; method: string; body?: unknown };

function stub(list: Partial<SiteReportListResponse> = {}, generate: { status: number; payload: unknown } | null = null) {
  const calls: Call[] = [];
  const body: SiteReportListResponse = {
    enrolled: true,
    weekly_enabled: true,
    monthly_enabled: false,
    timezone: "Asia/Kolkata",
    can_generate: false,
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
    const method = init?.method ?? "GET";
    calls.push({ url, method, body: init?.body ? JSON.parse(String(init.body)) : undefined });
    const json = (status: number, payload: unknown) =>
      ({ ok: status < 300, status, statusText: "", headers: new Headers(), json: async () => payload }) as unknown as Response;
    if (method === "POST" && url === `/api/v1/sites/${SITE_ID}/site-reports`) {
      const g = generate ?? { status: 202, payload: { report_id: "r-new", attempt_id: "a-1", action: "GENERATE", trigger: "HISTORICAL" } };
      return json(g.status, g.payload);
    }
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

describe("Reports -> Create report (history, view and download)", () => {
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

  it("filters by type and status in the browser (all types are loaded once)", async () => {
    const { calls } = stub();
    render(VIEW_ONLY);
    await screen.findByTestId("create-report-table");
    await userEvent.selectOptions(screen.getByTestId("create-report-status"), "FAILED");
    expect(screen.getAllByTestId("create-report-row")).toHaveLength(1);
    await userEvent.selectOptions(screen.getByTestId("create-report-status"), "");
    await userEvent.selectOptions(screen.getByTestId("create-report-type"), "MONTHLY");
    expect(screen.getAllByTestId("create-report-row")).toHaveLength(1);
    expect(screen.getByText("October 2026")).toBeTruthy();
    expect(calls.some((c) => c.url.includes("type="))).toBe(false);
  });

  it("explains when the site is not enrolled", async () => {
    stub({ enrolled: false, reports: [] });
    render(VIEW_ONLY);
    expect(await screen.findByText(CREATE_REPORT_MESSAGES.notEnrolled)).toBeTruthy();
  });

  it("opens on Create report by default and switches to Export data", async () => {
    stub();
    render(BOTH);
    const tabs = await screen.findByTestId("reports-tabs");
    expect(await screen.findByTestId("page-create-report")).toBeTruthy();
    expect(within(tabs).getAllByRole("tab")[0]!.textContent).toBe("Create report");
    await userEvent.click(screen.getByTestId("reports-tab-export"));
    expect(await screen.findByTestId("page-reports")).toBeTruthy();
  });

  it("opens Export data from the URL, and old ?tab=create links still open Create report", async () => {
    stub();
    const first = render(BOTH, "/reports?tab=export");
    expect(await screen.findByTestId("page-reports")).toBeTruthy();
    first.unmount();
    render(BOTH, "/reports?tab=create");
    expect(await screen.findByTestId("page-create-report")).toBeTruthy();
  });

  it("has no site selector: the site comes from the application sidebar", async () => {
    stub();
    render(VIEW_ONLY);
    await screen.findByTestId("create-report-table");
    expect(screen.queryByTestId("create-report-site")).toBeNull();
    expect(screen.queryByRole("combobox", { name: /site/i })).toBeNull();
    expect(screen.getByTestId("page-create-report").textContent).toContain(SITES_ONE.sites[0]!.site_name);
  });

  it("labels reports that used the retrospective reporting baseline", async () => {
    stub({
      reports: [report({ retrospective_baseline: true, report_id: "r-month", report_type: "MONTHLY", period_start: "2026-10-01" })],
    });
    render(VIEW_ONLY);
    const rows = await screen.findAllByTestId("create-report-row");
    const label = within(rows[0]!).getByTestId("label-retrospective-baseline");
    expect(label.textContent).toBe("Retrospective baseline");
    expect(label.getAttribute("title")).toContain("not verified historical operating practice");
  });
});

describe("Reports -> Create report: on-demand generation", () => {
  afterEach(() => vi.unstubAllGlobals());

  it("is not offered to Operators and Viewers", async () => {
    const { calls } = stub({ can_generate: false });
    render(VIEW_ONLY);
    await screen.findByTestId("create-report-table");
    expect(screen.queryByTestId("create-report-generate")).toBeNull();
    expect(screen.queryByRole("button", { name: /^Generate/ })).toBeNull();
    expect(screen.getByText(new RegExp(CREATE_REPORT_MESSAGES.readOnly.slice(0, 30)))).toBeTruthy();
    expect(calls.every((c) => c.method === "GET")).toBe(true);
  });

  it("lets a Site Admin request an ended period explicitly", async () => {
    const { calls } = stub({ can_generate: true });
    render(BOTH);
    const form = await screen.findByTestId("create-report-generate");
    await userEvent.selectOptions(within(form).getByTestId("create-report-generate-type"), "MONTHLY");
    const period = within(form).getByTestId("create-report-generate-period") as HTMLSelectElement;
    const options = Array.from(period.options).map((o) => o.value);
    expect(options).toHaveLength(3);
    const target = options.find((v) => v !== "2026-10-01") ?? options[0]!;
    await userEvent.selectOptions(period, target);
    await userEvent.click(within(form).getByTestId("create-report-generate-submit"));
    await waitFor(() => expect(calls.some((c) => c.method === "POST")).toBe(true));
    const post = calls.find((c) => c.method === "POST")!;
    expect(post.url).toBe(`/api/v1/sites/${SITE_ID}/site-reports`);
    expect(post.body).toEqual({ report_type: "MONTHLY", period_start: target });
    expect((await screen.findByTestId("create-report-requested")).textContent).toContain("appears below as Pending");
    // Nothing is requested without the explicit click.
    expect(calls.filter((c) => c.method === "POST")).toHaveLength(1);
  });

  it("offers a new version when the period already has a report", async () => {
    const today = new Intl.DateTimeFormat("en-CA", { timeZone: "Asia/Kolkata", year: "numeric", month: "2-digit", day: "2-digit" })
      .format(new Date());
    const latestMonth = endedPeriods("MONTHLY", today)[0]!;
    stub({ can_generate: true, reports: [report({ report_id: "r-m", report_type: "MONTHLY", period_start: latestMonth })] });
    render(BOTH);
    const form = await screen.findByTestId("create-report-generate");
    // Even with the history filtered to Weekly, the form knows the monthly report exists.
    await userEvent.selectOptions(screen.getByTestId("create-report-type"), "WEEKLY");
    expect(within(form).getByTestId("create-report-generate-submit").textContent).toBe("Generate report");
    await userEvent.selectOptions(within(form).getByTestId("create-report-generate-type"), "MONTHLY");
    await waitFor(() =>
      expect((within(form).getByTestId("create-report-generate-period") as HTMLSelectElement).value).toBe(latestMonth),
    );
    expect(within(form).getByTestId("create-report-generate-submit").textContent).toBe("Generate new version");
  });

  it("shows the database's refusal", async () => {
    stub(
      { can_generate: true },
      { status: 409, payload: { error: "site_report_queue_full", detail: "Three requested reports are already waiting." } },
    );
    render(BOTH);
    const form = await screen.findByTestId("create-report-generate");
    await userEvent.click(within(form).getByTestId("create-report-generate-submit"));
    expect((await screen.findByRole("alert")).textContent).toBe("Three requested reports are already waiting.");
  });
});

describe("Reports -> Create report: labels", () => {
  afterEach(() => vi.unstubAllGlobals());

  it("names weekly periods with an en-dash (UTF-8 source)", async () => {
    stub({ can_generate: true });
    render(BOTH);
    const form = await screen.findByTestId("create-report-generate");
    const first = (within(form).getByTestId("create-report-generate-period") as HTMLSelectElement).options[0]!;
    expect(first.textContent).toMatch(/^\d{2} [A-Z][a-z]{2} \d{4} – \d{2} [A-Z][a-z]{2} \d{4}$/);
  });
});

describe("endedPeriods", () => {
  it("offers only ended Sunday-Saturday weeks and calendar months, newest first", () => {
    expect(endedPeriods("WEEKLY", "2026-11-21").slice(0, 2)).toEqual(["2026-11-08", "2026-11-01"]);
    expect(endedPeriods("WEEKLY", "2026-11-22")[0]).toBe("2026-11-15");
    expect(endedPeriods("WEEKLY", "2026-11-22")).toHaveLength(12);
    expect(endedPeriods("MONTHLY", "2026-11-21")).toEqual(["2026-10-01", "2026-09-01", "2026-08-01"]);
    expect(endedPeriods("MONTHLY", "2027-01-01")).toEqual(["2026-12-01", "2026-11-01", "2026-10-01"]);
  });
});
