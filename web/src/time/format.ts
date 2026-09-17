/** Shared "weekday, day month year, hour:minute" formatter -- used by the
 *  header's live clock (AppLayout) and the Main Dashboard's "Last data
 *  update" timestamp, so the two read consistently. */
export const DATE_TIME_FORMAT = new Intl.DateTimeFormat(undefined, {
  weekday: "short",
  day: "2-digit",
  month: "short",
  year: "numeric",
  hour: "2-digit",
  minute: "2-digit",
});
