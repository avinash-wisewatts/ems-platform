/** Reports tab -- display helpers for export jobs. */
import type { ReportExportStatus } from "../api/types";
import { formatInTimeZone } from "../time/format";

const RANGE_FORMAT: Intl.DateTimeFormatOptions = {
  day: "2-digit",
  month: "short",
  year: "numeric",
  hour: "2-digit",
  minute: "2-digit",
  hourCycle: "h23",
};

/** "[from] – [to]" in the site's timezone (to is exclusive, shown as-is). */
export function formatExportRange(from: string, to: string, timeZone: string | null | undefined): string {
  return `${formatInTimeZone(from, timeZone, RANGE_FORMAT)} – ${formatInTimeZone(to, timeZone, RANGE_FORMAT)}`;
}

export function formatRequestedAt(iso: string): string {
  return formatInTimeZone(iso, undefined, RANGE_FORMAT);
}

export function formatBytes(bytes: number | null): string {
  if (bytes === null) return "";
  if (bytes < 1024) return `${bytes} B`;
  if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(1)} KB`;
  return `${(bytes / (1024 * 1024)).toFixed(1)} MB`;
}

export const STATUS_TONES: Record<ReportExportStatus, "neutral" | "info" | "good" | "bad"> = {
  QUEUED: "neutral",
  PROCESSING: "info",
  COMPLETED: "good",
  FAILED: "bad",
  EXPIRED: "neutral",
};

export const STATUS_LABELS: Record<ReportExportStatus, string> = {
  QUEUED: "Queued",
  PROCESSING: "Processing",
  COMPLETED: "Completed",
  FAILED: "Failed",
  EXPIRED: "Expired",
};
