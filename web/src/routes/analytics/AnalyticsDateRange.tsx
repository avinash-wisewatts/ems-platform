/**
 * Analytics date range (F4) -- docs/07-features/analytics/README.md "Date and
 * time range":
 * - quick ranges Today, 7 Days, 30 Days, 3 Months, 1 Year, calendar-based in
 *   the site timezone (D10, D11, D12, D61, D62; F1);
 * - date-first selection on a two-month calendar, weeks starting Sunday
 *   (EMS-REQ-133, D13), dates bounded by data availability;
 * - an optional time-of-day refinement, any minute (D60; PO 2026-09-30);
 *   choosing a quick range resets it;
 * - Apply / Cancel, and click-outside cancels (D1, EMS-REQ-133);
 * - From and To are always shown as inclusive site-local dates (D15), with
 *   the times underneath when refined (D76).
 * Nothing reloads until Update: Apply only changes the draft.
 *
 * Times are shown as HH:MM with 00:00 as the default at both ends. A From
 * time of 00:00 is the start of the From date; a To time of 00:00 is the end
 * of the To date (the next local midnight), so the default 00:00 -> 00:00
 * covers whole days. Both are stored as "no refinement" (null).
 */
import { useEffect, useRef, useState } from "react";
import { CALENDAR_PRESETS, WEEK_START_DAY, addDays, localDateKey, presetStartKey, type CalendarPreset } from "../../time/calendarRanges";
import { PRESET_LABELS } from "../../time/ranges";
import { isValidCustomRange, type AnalyticsRangeSelection } from "./analyticsQuery";

const MONTHS = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];
const MONTH_NAMES = [
  "January",
  "February",
  "March",
  "April",
  "May",
  "June",
  "July",
  "August",
  "September",
  "October",
  "November",
  "December",
];
const WEEKDAYS = ["Su", "Mo", "Tu", "We", "Th", "Fr", "Sa"];
const HOURS = Array.from({ length: 24 }, (_, i) => String(i).padStart(2, "0"));
const MINUTES = Array.from({ length: 60 }, (_, i) => String(i).padStart(2, "0"));
export const DAY_BOUNDARY = "00:00";

/** "2026-09-01" -> "01 Sep 2026" (D15). */
export function formatDateKey(key: string): string {
  return `${key.slice(8, 10)} ${MONTHS[Number(key.slice(5, 7)) - 1]} ${key.slice(0, 4)}`;
}

/** The inclusive local From/To dates and, when refined, the times of a range. */
export function rangeDisplay(
  range: AnalyticsRangeSelection,
  timeZone: string | null | undefined,
  now: Date = new Date(),
): { from: string; to: string; times: string | null } {
  if (range.kind === "preset") {
    const to = localDateKey(now, timeZone);
    return { from: formatDateKey(presetStartKey(range.preset, to)), to: formatDateKey(to), times: null };
  }
  const times =
    range.fromTime || range.toTime ? `${range.fromTime ?? DAY_BOUNDARY} → ${range.toTime ?? DAY_BOUNDARY}` : null;
  return { from: formatDateKey(range.fromDate), to: formatDateKey(range.toDate), times };
}

type Pending =
  | { kind: "preset"; preset: CalendarPreset }
  | { kind: "custom"; fromDate: string; toDate: string | null; fromTime: string | null; toTime: string | null };

function toPending(range: AnalyticsRangeSelection): Pending {
  return range.kind === "preset" ? range : { ...range };
}

function monthKey(year: number, month0: number): string {
  return `${String(year).padStart(4, "0")}-${String(month0 + 1).padStart(2, "0")}-01`;
}

function shiftMonth(key: string, delta: number): string {
  const index = Number(key.slice(0, 4)) * 12 + Number(key.slice(5, 7)) - 1 + delta;
  return monthKey(Math.floor(index / 12), index % 12);
}

function CalendarIcon() {
  return (
    <svg viewBox="0 0 16 16" width="15" height="15" aria-hidden="true" className="analytics-icon">
      <rect x="2" y="3.5" width="12" height="10.5" rx="1.5" fill="none" stroke="currentColor" strokeWidth="1.4" />
      <path d="M2 6.5h12M5 2v3M11 2v3" stroke="currentColor" strokeWidth="1.4" strokeLinecap="round" />
    </svg>
  );
}

function ClockIcon() {
  return (
    <svg viewBox="0 0 16 16" width="14" height="14" aria-hidden="true" className="analytics-icon">
      <circle cx="8" cy="8" r="6" fill="none" stroke="currentColor" strokeWidth="1.4" />
      <path d="M8 4.5V8l2.5 1.5" fill="none" stroke="currentColor" strokeWidth="1.4" strokeLinecap="round" />
    </svg>
  );
}

function TimeSelect({ label, value, onChange }: { label: "From" | "To"; value: string; onChange: (time: string) => void }) {
  const [hours, minutes] = [value.slice(0, 2), value.slice(3, 5)];
  return (
    <div className="analytics-picker__time" role="group" aria-label={`${label} time`} data-testid={`analytics-${label.toLowerCase()}-time`}>
      <ClockIcon />
      <select aria-label={`${label} hour`} value={hours} onChange={(e) => onChange(`${e.target.value}:${minutes}`)}>
        {HOURS.map((h) => (
          <option key={h} value={h}>
            {h}
          </option>
        ))}
      </select>
      <span aria-hidden="true">:</span>
      <select aria-label={`${label} minute`} value={minutes} onChange={(e) => onChange(`${hours}:${e.target.value}`)}>
        {MINUTES.map((m) => (
          <option key={m} value={m}>
            {m}
          </option>
        ))}
      </select>
    </div>
  );
}

function MonthGrid({
  firstOfMonth,
  selectionFrom,
  selectionTo,
  today,
  minDate,
  onPick,
}: {
  firstOfMonth: string;
  selectionFrom: string | null;
  selectionTo: string | null;
  today: string;
  minDate: string | null;
  onPick: (key: string) => void;
}) {
  const year = Number(firstOfMonth.slice(0, 4));
  const month0 = Number(firstOfMonth.slice(5, 7)) - 1;
  const days = new Date(Date.UTC(year, month0 + 1, 0)).getUTCDate();
  const lead = (new Date(Date.UTC(year, month0, 1)).getUTCDay() - WEEK_START_DAY + 7) % 7;
  const cells: (string | null)[] = [
    ...Array.from({ length: lead }, () => null),
    ...Array.from({ length: days }, (_, i) => addDays(firstOfMonth, i)),
  ];
  const label = `${MONTH_NAMES[month0]} ${year}`;
  const end = selectionTo ?? selectionFrom;
  return (
    <div className="analytics-calendar__month" data-testid={`calendar-month-${firstOfMonth.slice(0, 7)}`}>
      <p className="analytics-calendar__month-title">{label}</p>
      <div className="analytics-calendar__grid" role="grid" aria-label={label}>
        {WEEKDAYS.map((d) => (
          <span key={d} className="analytics-calendar__weekday" aria-hidden="true">
            {d}
          </span>
        ))}
        {cells.map((key, i) => {
          if (key === null) return <span key={`blank-${i}`} />;
          const inRange = selectionFrom !== null && end !== null && key >= selectionFrom && key <= end;
          const isEdge = key === selectionFrom || key === end;
          const classes = [
            "analytics-calendar__day",
            inRange ? "is-in-range" : "",
            inRange && isEdge ? "is-edge" : "",
            key === today ? "is-today" : "",
          ]
            .filter(Boolean)
            .join(" ");
          return (
            <button
              key={key}
              type="button"
              className={classes}
              aria-label={formatDateKey(key)}
              aria-pressed={inRange}
              disabled={(minDate !== null && key < minDate) || key > today}
              onClick={() => onPick(key)}
            >
              {Number(key.slice(8, 10))}
            </button>
          );
        })}
      </div>
    </div>
  );
}

export function AnalyticsDateRange({
  value,
  timeZone,
  minDate,
  onApply,
  now = () => new Date(),
}: {
  value: AnalyticsRangeSelection;
  timeZone: string | null | undefined;
  /** Earliest site-local date with data (catalogue availability); null = unbounded. */
  minDate: string | null;
  onApply: (range: AnalyticsRangeSelection) => void;
  now?: () => Date;
}) {
  const today = localDateKey(now(), timeZone);
  const currentMonth = monthKey(Number(today.slice(0, 4)), Number(today.slice(5, 7)) - 1);
  const [open, setOpen] = useState(false);
  const [pending, setPending] = useState<Pending>(toPending(value));
  const [viewEnd, setViewEnd] = useState(currentMonth);
  const rootRef = useRef<HTMLDivElement>(null);

  const openPicker = () => {
    setPending(toPending(value));
    setViewEnd(currentMonth);
    setOpen(true);
  };
  const cancel = () => setOpen(false);

  // Click-outside and Escape close without applying (EMS-REQ-133).
  useEffect(() => {
    if (!open) return;
    const onDown = (event: MouseEvent) => {
      if (rootRef.current && !rootRef.current.contains(event.target as Node)) setOpen(false);
    };
    const onKey = (event: KeyboardEvent) => {
      if (event.key === "Escape") setOpen(false);
    };
    document.addEventListener("mousedown", onDown);
    document.addEventListener("keydown", onKey);
    return () => {
      document.removeEventListener("mousedown", onDown);
      document.removeEventListener("keydown", onKey);
    };
  }, [open]);

  // The dates the calendar highlights for the pending choice.
  const highlight =
    pending.kind === "preset"
      ? { from: presetStartKey(pending.preset, today), to: today as string | null }
      : { from: pending.fromDate, to: pending.toDate };

  const pickDate = (key: string) => {
    if (pending.kind === "custom" && pending.toDate === null && key >= pending.fromDate) {
      setPending({ ...pending, toDate: key });
    } else if (pending.kind === "custom" && pending.toDate === null) {
      setPending({ ...pending, fromDate: key, toDate: pending.fromDate });
    } else {
      const times = pending.kind === "custom" ? { fromTime: pending.fromTime, toTime: pending.toTime } : { fromTime: null, toTime: null };
      setPending({ kind: "custom", fromDate: key, toDate: null, ...times });
    }
  };

  const setTime = (which: "fromTime" | "toTime", time: string) => {
    const refined = time === DAY_BOUNDARY ? null : time;
    // 00:00 on a quick range is the quick range itself.
    if (pending.kind === "preset" && refined === null) return;
    const base =
      pending.kind === "custom"
        ? pending
        : { kind: "custom" as const, fromDate: highlight.from, toDate: highlight.to, fromTime: null, toTime: null };
    setPending({ ...base, [which]: refined });
  };

  const applicable: AnalyticsRangeSelection | null =
    pending.kind === "preset"
      ? pending
      : pending.toDate !== null
        ? { kind: "custom", fromDate: pending.fromDate, toDate: pending.toDate, fromTime: pending.fromTime, toTime: pending.toTime }
        : null;
  const canApply = applicable !== null && (applicable.kind === "preset" || isValidCustomRange(applicable, timeZone));

  const display = rangeDisplay(value, timeZone, now());
  const pendingTimes = pending.kind === "custom" ? pending : { fromTime: null, toTime: null };
  const pickingTo = pending.kind === "custom" && pending.toDate === null;

  return (
    <div className="analytics-date-range" ref={rootRef} data-testid="analytics-date-range">
      <button
        type="button"
        className="analytics-date-range__trigger"
        aria-expanded={open}
        aria-haspopup="dialog"
        onClick={() => (open ? cancel() : openPicker())}
      >
        <CalendarIcon />
        <span className="analytics-date-range__end">
          <span className="analytics-date-range__label">From</span>
          <span className="analytics-date-range__value" data-testid="analytics-date-range-from">
            {display.from}
          </span>
        </span>
        <span className="analytics-date-range__arrow" aria-hidden="true">
          →
        </span>
        <span className="analytics-date-range__end">
          <span className="analytics-date-range__label">To</span>
          <span className="analytics-date-range__value" data-testid="analytics-date-range-to">
            {display.to}
          </span>
        </span>
      </button>
      {display.times ? (
        <p className="analytics-date-range__times" data-testid="analytics-date-range-times">
          {display.times}
        </p>
      ) : null}
      {open ? (
        <div className="analytics-picker" role="dialog" aria-label="Date range">
          <div className="analytics-picker__main">
            <div className="analytics-picker__ends">
              <div className="analytics-picker__end">
                <div className={`analytics-picker__field${!pickingTo ? " is-active" : ""}`} data-testid="analytics-picker-from">
                  <CalendarIcon />
                  <span className="analytics-picker__field-label">From</span>
                  <span>{formatDateKey(highlight.from)}</span>
                </div>
                <TimeSelect label="From" value={pendingTimes.fromTime ?? DAY_BOUNDARY} onChange={(t) => setTime("fromTime", t)} />
              </div>
              <div className="analytics-picker__end">
                <div className={`analytics-picker__field${pickingTo ? " is-active" : ""}`} data-testid="analytics-picker-to">
                  <CalendarIcon />
                  <span className="analytics-picker__field-label">To</span>
                  <span>{highlight.to ? formatDateKey(highlight.to) : "Select a date"}</span>
                </div>
                <TimeSelect label="To" value={pendingTimes.toTime ?? DAY_BOUNDARY} onChange={(t) => setTime("toTime", t)} />
              </div>
            </div>
            <div className="analytics-calendar">
              <div className="analytics-calendar__nav">
                <button type="button" className="analytics-icon-button" aria-label="Previous month" onClick={() => setViewEnd((v) => shiftMonth(v, -1))}>
                  ‹
                </button>
                <button
                  type="button"
                  className="analytics-icon-button"
                  aria-label="Next month"
                  disabled={viewEnd >= currentMonth}
                  onClick={() => setViewEnd((v) => shiftMonth(v, 1))}
                >
                  ›
                </button>
              </div>
              <div className="analytics-calendar__months">
                {[shiftMonth(viewEnd, -1), viewEnd].map((first) => (
                  <MonthGrid
                    key={first}
                    firstOfMonth={first}
                    selectionFrom={highlight.from}
                    selectionTo={highlight.to}
                    today={today}
                    minDate={minDate}
                    onPick={pickDate}
                  />
                ))}
              </div>
            </div>
          </div>
          <div className="analytics-picker__side">
            <div className="analytics-picker__presets" role="group" aria-label="Quick ranges">
              {CALENDAR_PRESETS.map((preset) => (
                <button
                  key={preset}
                  type="button"
                  className="analytics-picker__preset"
                  aria-pressed={pending.kind === "preset" && pending.preset === preset}
                  onClick={() => setPending({ kind: "preset", preset })}
                >
                  {PRESET_LABELS[preset]}
                </button>
              ))}
            </div>
            <div className="analytics-picker__actions">
              <button type="button" className="analytics-button" onClick={cancel}>
                Cancel
              </button>
              <button
                type="button"
                className="analytics-button analytics-button--primary"
                disabled={!canApply}
                onClick={() => {
                  if (applicable) onApply(applicable);
                  setOpen(false);
                }}
              >
                Apply
              </button>
            </div>
          </div>
        </div>
      ) : null}
    </div>
  );
}
