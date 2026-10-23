import { afterEach, describe, expect, it, vi } from "vitest";
import { act, render, screen } from "@testing-library/react";
import type { ReportExportJob } from "../api/types";
import {
  ACTIVE_POLL_MS,
  DISMISSED_STORAGE_KEY,
  IDLE_POLL_MS,
  ReportExportsProvider,
  isNotifiable,
  useReportExports,
} from "./ReportExportsProvider";

function job(overrides: Partial<ReportExportJob>): ReportExportJob {
  return {
    job_id: "j", site_id: "s", site_name: "S", range_from: "2026-10-01T00:00:00Z", range_to: "2026-10-02T00:00:00Z",
    requested_resolution: "auto", resolution: "1h", status: "QUEUED", status_label: "Queued", attempts: 0,
    error_code: null, error_message: null, created_at: "2026-10-23T00:00:00Z", started_at: null, completed_at: null,
    expires_at: null, file_name: null, file_size_bytes: null, asset_count: null, row_count: null, download_url: null,
    ...overrides,
  };
}

function Probe() {
  const { jobs, notifications } = useReportExports();
  return <p data-testid="probe">{`${jobs.map((j) => j.status).join(",")}|${notifications.map((j) => j.job_id).join(",")}`}</p>;
}

function stubJobs(sequence: ReportExportJob[][]) {
  let call = 0;
  const mock = vi.fn(async () => {
    const jobs = sequence[Math.min(call, sequence.length - 1)];
    call += 1;
    return { ok: true, status: 200, json: async () => ({ jobs }) } as unknown as Response;
  });
  vi.stubGlobal("fetch", mock);
  return mock;
}

async function flush() {
  await act(async () => {
    await Promise.resolve();
    await Promise.resolve();
  });
}

describe("ReportExportsProvider", () => {
  afterEach(() => {
    vi.useRealTimers();
    vi.unstubAllGlobals();
    window.localStorage.clear();
  });

  it("polls quickly while a job is active, then slowly, and notifies on completion", async () => {
    vi.useFakeTimers();
    const done = job({ status: "COMPLETED", download_url: "/api/v1/report-exports/j/file", expires_at: "2099-01-01T00:00:00Z" });
    const mock = stubJobs([[job({ status: "PROCESSING" })], [done]]);
    render(
      <ReportExportsProvider enabled>
        <Probe />
      </ReportExportsProvider>,
    );
    await flush();
    expect(screen.getByTestId("probe")).toHaveTextContent("PROCESSING|");
    expect(mock).toHaveBeenCalledTimes(1);
    await act(async () => {
      vi.advanceTimersByTime(ACTIVE_POLL_MS);
    });
    await flush();
    expect(mock).toHaveBeenCalledTimes(2);
    expect(screen.getByTestId("probe")).toHaveTextContent("COMPLETED|j");
    await act(async () => {
      vi.advanceTimersByTime(ACTIVE_POLL_MS);
    });
    expect(mock).toHaveBeenCalledTimes(2);
    await act(async () => {
      vi.advanceTimersByTime(IDLE_POLL_MS);
    });
    await flush();
    expect(mock).toHaveBeenCalledTimes(3);
  });

  it("does not poll when disabled, and dismissed jobs stay dismissed", async () => {
    window.localStorage.setItem(DISMISSED_STORAGE_KEY, JSON.stringify(["j"]));
    const done = job({ status: "COMPLETED", download_url: "/x", expires_at: "2099-01-01T00:00:00Z" });
    const mock = stubJobs([[done]]);
    const view = render(
      <ReportExportsProvider enabled={false}>
        <Probe />
      </ReportExportsProvider>,
    );
    await flush();
    expect(mock).not.toHaveBeenCalled();
    view.unmount();
    render(
      <ReportExportsProvider enabled>
        <Probe />
      </ReportExportsProvider>,
    );
    await flush();
    expect(screen.getByTestId("probe")).toHaveTextContent("COMPLETED|");
  });

  it("survives unavailable storage", async () => {
    const getItem = vi.spyOn(Storage.prototype, "getItem").mockImplementation(() => {
      throw new Error("blocked");
    });
    stubJobs([[job({ status: "COMPLETED", download_url: "/x", expires_at: "2099-01-01T00:00:00Z" })]]);
    render(
      <ReportExportsProvider enabled>
        <Probe />
      </ReportExportsProvider>,
    );
    await flush();
    expect(screen.getByTestId("probe")).toHaveTextContent("COMPLETED|j");
    getItem.mockRestore();
  });

  it("notifies completed (downloadable) and recently failed jobs only", () => {
    const now = Date.parse("2026-10-24T00:00:00Z");
    expect(isNotifiable(job({ status: "COMPLETED", download_url: "/x" }), now)).toBe(true);
    expect(isNotifiable(job({ status: "COMPLETED", download_url: null }), now)).toBe(false);
    expect(isNotifiable(job({ status: "FAILED", completed_at: "2026-10-23T12:00:00Z" }), now)).toBe(true);
    expect(isNotifiable(job({ status: "FAILED", completed_at: "2026-10-20T00:00:00Z" }), now)).toBe(false);
    expect(isNotifiable(job({ status: "QUEUED" }), now)).toBe(false);
    expect(isNotifiable(job({ status: "EXPIRED" }), now)).toBe(false);
  });
});
