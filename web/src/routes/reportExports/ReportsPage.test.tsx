import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { screen, waitFor, within } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { AppRoutes } from "../../router";
import type { ReportExportEstimate, ReportExportJob } from "../../api/types";
import { DISMISSED_STORAGE_KEY } from "../../reportExports/ReportExportsProvider";
import { ADMIN_USER, SITES_ONE, VIEWER_USER, renderWithProviders } from "../../test-utils";

const SITE_ID = SITES_ONE.sites[0]!.site_id;

function estimate(overrides: Partial<ReportExportEstimate> = {}): ReportExportEstimate {
  return {
    site_id: SITE_ID,
    range_from: "2026-10-22T18:30:00Z",
    range_to: "2026-10-23T18:30:00Z",
    requested_resolution: "auto",
    resolution: "15m",
    asset_count: 4,
    column_count: 12,
    bucket_count: 96,
    estimated_cells: 1152,
    mode: "immediate",
    ...overrides,
  };
}

function job(overrides: Partial<ReportExportJob> = {}): ReportExportJob {
  return {
    job_id: "job-1",
    site_id: SITE_ID,
    site_name: "Alpha One",
    range_from: "2026-09-30T18:30:00Z",
    range_to: "2026-10-23T18:30:00Z",
    requested_resolution: "auto",
    resolution: "1h",
    status: "QUEUED",
    status_label: "Queued",
    attempts: 0,
    error_code: null,
    error_message: null,
    created_at: "2026-10-23T10:00:00Z",
    started_at: null,
    completed_at: null,
    expires_at: null,
    file_name: null,
    file_size_bytes: null,
    asset_count: null,
    row_count: null,
    download_url: null,
    ...overrides,
  };
}

type Call = { url: string; method: string; body: string | null; contentType: string | null };

/** Scripted fetch for the Reports flow (adds blob() + headers for the ZIP). */
function stubReports(opts: {
  estimate?: ReportExportEstimate | { status: number; error: string; detail: string };
  jobs?: () => ReportExportJob[];
  created?: ReportExportJob;
  zipStatus?: number;
}) {
  const calls: Call[] = [];
  const mock = vi.fn(async (input: RequestInfo | URL, init?: RequestInit) => {
    const url = typeof input === "string" ? input : input.toString();
    const method = init?.method ?? "GET";
    const headers = new Headers(init?.headers);
    calls.push({ url, method, body: (init?.body as string) ?? null, contentType: headers.get("Content-Type") });
    const json = (status: number, body: unknown) =>
      ({ ok: status < 300, status, statusText: "", headers: new Headers(), json: async () => body }) as unknown as Response;
    if (url.startsWith(`/api/v1/sites/${SITE_ID}/report-exports/estimate`)) {
      const e = opts.estimate ?? estimate();
      return "error" in e ? json(e.status, { error: e.error, detail: e.detail }) : json(200, e);
    }
    if (url.startsWith(`/api/v1/sites/${SITE_ID}/report-exports/file`)) {
      if (opts.zipStatus && opts.zipStatus !== 200) {
        return json(opts.zipStatus, { error: "export_requires_background", detail: "Too large." });
      }
      return {
        ok: true,
        status: 200,
        statusText: "",
        headers: new Headers({
          "Content-Disposition": "attachment; filename=\"Alpha One_20261023.zip\"; filename*=UTF-8''Alpha%20One_20261023.zip",
        }),
        blob: async () => new Blob(["PK"], { type: "application/zip" }),
      } as unknown as Response;
    }
    if (url === `/api/v1/sites/${SITE_ID}/report-exports` && method === "POST") {
      return json(202, opts.created ?? job());
    }
    if (url.startsWith("/api/v1/report-exports/") && url.endsWith("/retry")) {
      return json(202, job({ status: "QUEUED" }));
    }
    if (url.startsWith("/api/v1/report-exports")) {
      return json(200, { jobs: opts.jobs ? opts.jobs() : [] });
    }
    if (url.includes("/alerts")) return json(200, { site_id: SITE_ID, alerts: [], next_cursor: null });
    return json(404, { error: "not_found", detail: "unexpected" });
  });
  vi.stubGlobal("fetch", mock);
  return { calls, mock };
}

function renderReports(user = ADMIN_USER) {
  return renderWithProviders(<AppRoutes />, {
    session: () => Promise.resolve(user),
    sites: () => Promise.resolve(SITES_ONE),
    initialEntries: ["/reports"],
  });
}

describe("Reports tab", () => {
  let createObjectURL: ReturnType<typeof vi.fn>;
  let click: ReturnType<typeof vi.spyOn>;

  beforeEach(() => {
    window.localStorage.clear();
    createObjectURL = vi.fn(() => "blob:zip");
    URL.createObjectURL = createObjectURL as unknown as typeof URL.createObjectURL;
    URL.revokeObjectURL = vi.fn() as unknown as typeof URL.revokeObjectURL;
    click = vi.spyOn(HTMLAnchorElement.prototype, "click").mockImplementation(() => {});
  });

  afterEach(() => {
    click.mockRestore();
    vi.unstubAllGlobals();
  });

  it("sits directly below Alerts in the primary navigation", async () => {
    stubReports({});
    renderReports();
    const nav = await screen.findByRole("navigation", { name: "Primary" });
    const labels = within(nav)
      .getAllByRole("link")
      .map((a) => a.textContent?.trim());
    expect(labels.indexOf("Reports")).toBe(labels.indexOf("Alerts") + 1);
    expect(within(nav).getByRole("link", { name: /Reports/ })).toHaveAttribute("href", "/reports");
  });

  it("shows the site selector, the Analytics date range, resolution and the estimate", async () => {
    const { calls } = stubReports({});
    renderReports();
    expect(await screen.findByTestId("reports-site-select")).toHaveValue(SITE_ID);
    expect(screen.getByTestId("analytics-date-range")).toBeInTheDocument();
    expect(screen.getByTestId("reports-resolution-select")).toHaveValue("auto");
    await waitFor(() => expect(screen.getByTestId("reports-estimate")).toHaveTextContent("4 assets"));
    expect(screen.getByTestId("reports-estimate")).toHaveTextContent("This export will download now.");
    const estimateCall = calls.find((c) => c.url.includes("/report-exports/estimate"))!;
    const params = new URL(estimateCall.url, "http://localhost").searchParams;
    expect(params.get("resolution")).toBe("auto");
    // Today in the site timezone (Asia/Kolkata): local midnight to the next local midnight.
    expect(Date.parse(params.get("to")!) - Date.parse(params.get("from")!)).toBe(24 * 3600 * 1000);
    // The date range is bounded by the site's data availability (ADR-014 decision 9).
    expect(calls.some((c) => c.url === `/api/v1/sites/${SITE_ID}/analytics/catalog`)).toBe(true);
  });

  it("downloads a small export immediately as a ZIP", async () => {
    const { calls } = stubReports({});
    renderReports();
    await waitFor(() => expect(screen.getByTestId("reports-export-button")).toBeEnabled());
    await userEvent.click(screen.getByTestId("reports-export-button"));
    await waitFor(() => expect(screen.getByTestId("reports-notice")).toHaveTextContent("Downloaded Alpha One_20261023.zip."));
    expect(createObjectURL).toHaveBeenCalledTimes(1);
    expect(click).toHaveBeenCalledTimes(1);
    expect(calls.some((c) => c.method === "POST")).toBe(false);
  });

  it("queues a large export as a background job (JSON POST) and lists it", async () => {
    let listed: ReportExportJob[] = [];
    const { calls } = stubReports({ estimate: estimate({ mode: "background" }), jobs: () => listed });
    renderReports();
    await waitFor(() => expect(screen.getByTestId("reports-estimate")).toHaveTextContent("run in the background"));
    listed = [job()];
    await userEvent.click(screen.getByTestId("reports-export-button"));
    await waitFor(() => expect(screen.getByTestId("reports-notice")).toHaveTextContent("Export queued."));
    const post = calls.find((c) => c.method === "POST")!;
    expect(post.contentType).toBe("application/json");
    expect(JSON.parse(post.body!)).toMatchObject({ resolution: "auto" });
    await waitFor(() => expect(screen.getByTestId("reports-job-job-1")).toBeInTheDocument());
    expect(within(screen.getByTestId("reports-job-job-1")).getByTestId("reports-job-status")).toHaveTextContent("Queued");
  });

  it("falls back to a background job when the immediate download is refused as too large", async () => {
    const { calls } = stubReports({ zipStatus: 422 });
    renderReports();
    await waitFor(() => expect(screen.getByTestId("reports-export-button")).toBeEnabled());
    await userEvent.click(screen.getByTestId("reports-export-button"));
    await waitFor(() => expect(screen.getByTestId("reports-notice")).toHaveTextContent("Export queued."));
    expect(calls.some((c) => c.method === "POST")).toBe(true);
  });

  it("refuses an export over the limit and explains a resolution/range violation", async () => {
    stubReports({ estimate: estimate({ mode: "too_large" }) });
    const view = renderReports();
    await waitFor(() => expect(screen.getByTestId("reports-estimate")).toHaveTextContent("too large"));
    expect(screen.getByTestId("reports-export-button")).toBeDisabled();
    view.unmount();

    stubReports({ estimate: { status: 422, error: "time_range_too_large", detail: "max" } });
    renderReports();
    await waitFor(() =>
      expect(screen.getByTestId("reports-estimate")).toHaveTextContent("not available for the selected range"),
    );
    expect(screen.getByTestId("reports-export-button")).toBeDisabled();
  });

  it("shows every job status, the download link of a completed job, and retries a failed one", async () => {
    const jobs = [
      job({ job_id: "q", status: "QUEUED" }),
      job({ job_id: "p", status: "PROCESSING" }),
      job({
        job_id: "c", status: "COMPLETED", asset_count: 4, file_size_bytes: 2048,
        completed_at: "2026-10-23T10:05:00Z", expires_at: "2099-01-01T00:00:00Z",
        download_url: "/api/v1/report-exports/c/file",
      }),
      job({ job_id: "f", status: "FAILED", error_message: "The site is no longer accessible to you.", completed_at: new Date().toISOString() }),
    ];
    const { calls } = stubReports({ jobs: () => jobs });
    renderReports();
    await waitFor(() => expect(screen.getByTestId("reports-job-f")).toBeInTheDocument());
    const statuses = ["q", "p", "c", "f"].map(
      (id) => within(screen.getByTestId(`reports-job-${id}`)).getByTestId("reports-job-status").textContent,
    );
    expect(statuses).toEqual(["Queued", "Processing", "Completed", "Failed"]);
    expect(within(screen.getByTestId("reports-job-c")).getByTestId("reports-job-download")).toHaveAttribute(
      "href",
      "/api/v1/report-exports/c/file",
    );
    expect(screen.getByTestId("reports-job-c")).toHaveTextContent("4 assets · 2.0 KB");
    expect(screen.getByTestId("reports-job-f")).toHaveTextContent("The site is no longer accessible to you.");
    await userEvent.click(within(screen.getByTestId("reports-job-f")).getByTestId("reports-job-retry"));
    await waitFor(() => expect(calls.some((c) => c.url === "/api/v1/report-exports/f/retry" && c.method === "POST")).toBe(true));
    expect(calls.find((c) => c.url.endsWith("/retry"))!.contentType).toBe("application/json");
  });

  it("notifies in the app when an export completes, with the download link, until dismissed", async () => {
    const done = job({
      job_id: "done", status: "COMPLETED", completed_at: "2026-10-23T10:05:00Z",
      expires_at: "2099-01-01T00:00:00Z", download_url: "/api/v1/report-exports/done/file",
    });
    stubReports({ jobs: () => [done] });
    renderReports();
    const toast = await screen.findByTestId("export-notification-done");
    expect(toast).toHaveTextContent("Your export is ready");
    expect(within(toast).getByRole("link", { name: "Download ZIP" })).toHaveAttribute("href", "/api/v1/report-exports/done/file");
    expect(screen.getByTestId("shell-nav-reports-badge")).toHaveTextContent("1");
    await userEvent.click(within(toast).getByRole("button", { name: "Dismiss" }));
    expect(screen.queryByTestId("export-notification-done")).not.toBeInTheDocument();
    expect(screen.queryByTestId("shell-nav-reports-badge")).not.toBeInTheDocument();
    expect(JSON.parse(window.localStorage.getItem(DISMISSED_STORAGE_KEY)!)).toEqual(["done"]);
  });

  it("notifies a failure with its message", async () => {
    stubReports({
      jobs: () => [job({ job_id: "bad", status: "FAILED", error_message: "The export is too large.", completed_at: new Date().toISOString() })],
    });
    renderReports();
    const toast = await screen.findByTestId("export-notification-bad");
    expect(toast).toHaveTextContent("Export failed");
    expect(toast).toHaveTextContent("The export is too large.");
  });

  it("is not offered to a user without report.export", async () => {
    const { calls } = stubReports({});
    renderReports({ ...VIEWER_USER, permissions: ["dashboard.view"] });
    expect(await screen.findByText("Reports are not available for your account.")).toBeInTheDocument();
    const nav = screen.getByRole("navigation", { name: "Primary" });
    expect(within(nav).queryByRole("link", { name: /Reports/ })).not.toBeInTheDocument();
    expect(calls.some((c) => c.url.includes("report-exports"))).toBe(false);
  });
});
