/**
 * Reports tab -- the signed-in user's background export jobs, shared by the
 * Reports page (the jobs table) and the shell (the Reports nav badge and the
 * completion notifications), so both read one poll.
 *
 * Polling, not push: the platform has no browser notification channel, and
 * the Alerts badge is poll-based too. GET /api/v1/report-exports is polled
 * every ACTIVE_POLL_MS while a job is Queued/Processing, otherwise every
 * IDLE_POLL_MS (so a job queued in another tab is still picked up).
 *
 * Notifications: a job that finished (Completed and still downloadable, or
 * Failed within the last day) and has not been dismissed. "Dismissed" is a
 * per-browser convenience kept in localStorage (wrapped -- it may be
 * unavailable); the job's status itself always lives on the server.
 */
import { createContext, useCallback, useContext, useEffect, useMemo, useRef, useState } from "react";
import type { ReactNode } from "react";
import { getReportExports } from "../api/endpoints";
import type { ReportExportJob } from "../api/types";

export const ACTIVE_POLL_MS = 5_000;
export const IDLE_POLL_MS = 60_000;
const FAILED_NOTIFY_WINDOW_MS = 24 * 60 * 60 * 1000;
export const DISMISSED_STORAGE_KEY = "ems.reportExports.dismissed.v1";
const DISMISSED_LIMIT = 200;

export type ReportExportsState = {
  jobs: ReportExportJob[];
  /** False until the first poll answered. */
  loaded: boolean;
  error: unknown;
  /** Finished jobs the user has not dismissed, newest first. */
  notifications: ReportExportJob[];
  refresh: () => void;
  dismiss: (jobId: string) => void;
};

const ReportExportsContext = createContext<ReportExportsState | null>(null);

function readDismissed(): string[] {
  try {
    const raw = window.localStorage.getItem(DISMISSED_STORAGE_KEY);
    const parsed: unknown = raw ? JSON.parse(raw) : [];
    return Array.isArray(parsed) ? parsed.filter((v): v is string => typeof v === "string") : [];
  } catch {
    return [];
  }
}

function writeDismissed(ids: string[]): void {
  try {
    window.localStorage.setItem(DISMISSED_STORAGE_KEY, JSON.stringify(ids.slice(-DISMISSED_LIMIT)));
  } catch {
    // storage unavailable: dismissals last for this page only
  }
}

export function isActive(job: ReportExportJob): boolean {
  return job.status === "QUEUED" || job.status === "PROCESSING";
}

export function isNotifiable(job: ReportExportJob, now: number = Date.now()): boolean {
  if (job.status === "COMPLETED") return job.download_url !== null;
  if (job.status === "FAILED") {
    const at = Date.parse(job.completed_at ?? job.created_at);
    return Number.isFinite(at) && now - at <= FAILED_NOTIFY_WINDOW_MS;
  }
  return false;
}

export function ReportExportsProvider({ enabled, children }: { enabled: boolean; children: ReactNode }) {
  const [jobs, setJobs] = useState<ReportExportJob[]>([]);
  const [loaded, setLoaded] = useState(false);
  const [error, setError] = useState<unknown>(null);
  const [dismissed, setDismissed] = useState<string[]>(() => readDismissed());
  const [nonce, setNonce] = useState(0);
  const timer = useRef<number | null>(null);

  useEffect(() => {
    if (!enabled) return;
    let alive = true;
    const controller = new AbortController();
    const schedule = (ms: number) => {
      if (timer.current !== null) window.clearTimeout(timer.current);
      timer.current = window.setTimeout(() => alive && setNonce((n) => n + 1), ms);
    };
    getReportExports({ signal: controller.signal })
      .then((response) => {
        if (!alive) return;
        setJobs(response.jobs);
        setError(null);
        setLoaded(true);
        schedule(response.jobs.some(isActive) ? ACTIVE_POLL_MS : IDLE_POLL_MS);
      })
      .catch((err: unknown) => {
        if (!alive || (err instanceof DOMException && err.name === "AbortError")) return;
        setError(err);
        setLoaded(true);
        schedule(IDLE_POLL_MS);
      });
    return () => {
      alive = false;
      controller.abort();
      if (timer.current !== null) window.clearTimeout(timer.current);
    };
  }, [enabled, nonce]);

  const refresh = useCallback(() => setNonce((n) => n + 1), []);
  const dismiss = useCallback((jobId: string) => {
    setDismissed((current) => {
      if (current.includes(jobId)) return current;
      const next = [...current, jobId];
      writeDismissed(next);
      return next;
    });
  }, []);

  const notifications = useMemo(
    () => jobs.filter((job) => isNotifiable(job) && !dismissed.includes(job.job_id)),
    [jobs, dismissed],
  );

  const value = useMemo<ReportExportsState>(
    () => ({ jobs, loaded, error, notifications, refresh, dismiss }),
    [jobs, loaded, error, notifications, refresh, dismiss],
  );
  return <ReportExportsContext.Provider value={value}>{children}</ReportExportsContext.Provider>;
}

const INERT: ReportExportsState = {
  jobs: [],
  loaded: false,
  error: null,
  notifications: [],
  refresh: () => {},
  dismiss: () => {},
};

/** Outside a provider (e.g. an isolated component test) the state is inert. */
export function useReportExports(): ReportExportsState {
  return useContext(ReportExportsContext) ?? INERT;
}
