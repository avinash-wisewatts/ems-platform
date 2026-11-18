/**
 * Alerts (ADR-024) -- display helpers shared by the three Alerts views.
 * Times are always shown in the selected site's timezone.
 */

import type { Alert, AlertComparator, AlertCondition, AlertParameterRef, AlertRule, Weekday } from "../../api/types";
import { formatInTimeZone } from "../../time/format";

export const WEEKDAYS: readonly Weekday[] = ["MON", "TUE", "WED", "THU", "FRI", "SAT", "SUN"];

export const WEEKDAY_LABELS: Record<Weekday, string> = {
  MON: "Mon",
  TUE: "Tue",
  WED: "Wed",
  THU: "Thu",
  FRI: "Fri",
  SAT: "Sat",
  SUN: "Sun",
};

export const COMPARATOR_LABELS: Record<AlertComparator, string> = {
  GT: "Greater than",
  LT: "Less than",
  EQ: "Equal to",
};

export function formatNumber(value: number | null | undefined): string {
  if (value === null || value === undefined || !Number.isFinite(value)) return "—";
  return new Intl.NumberFormat(undefined, { maximumFractionDigits: 3 }).format(value);
}

export function withUnit(value: number | null | undefined, unit: string | null | undefined): string {
  const text = formatNumber(value);
  return text === "—" || !unit ? text : `${text} ${unit}`;
}

export function parameterLabel(parameter: AlertParameterRef): string {
  const q = parameter.qualifier;
  return q && q !== "TOTAL" && q !== "AVG" ? `${parameter.name} (${q})` : parameter.name;
}

/** e.g. "Greater than 50 kW", "Equal to 50 Hz ± 0.1 Hz". */
export function conditionText(condition: AlertCondition, unit: string | null): string {
  const base = `${COMPARATOR_LABELS[condition.comparator]} ${withUnit(condition.threshold, unit)}`;
  return condition.comparator === "EQ" && condition.tolerance !== null
    ? `${base} ± ${withUnit(condition.tolerance, unit)}`
    : base;
}

export function scheduleText(rule: AlertRule): string {
  const days = rule.schedule.every_day ? "Every day" : rule.schedule.weekdays.map((d) => WEEKDAY_LABELS[d]).join(", ");
  return `${days}, ${rule.schedule.start_time}–${rule.schedule.end_time}`;
}

export function formatSiteTime(iso: string | null | undefined, timeZone: string | null | undefined): string {
  if (!iso) return "—";
  return formatInTimeZone(iso, timeZone, { dateStyle: "medium", timeStyle: "short" });
}

export function statusLabel(alert: Alert): string {
  if (alert.state === "ACTIVE") return alert.data_unavailable ? "Active — data unavailable" : "Active";
  if (alert.state === "RESOLVED") return "Resolved";
  return "Ended";
}

export function endedReasonLabel(code: string | null): string {
  return code === "CONFIGURATION_CHANGED" ? "The alert rule was changed, disabled or deleted" : "—";
}
