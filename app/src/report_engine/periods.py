"""Reporting periods (A24-A28) in the site timezone.

* Weekly: Sunday 00:00 to Saturday 23:59:59; compared with the preceding
  Sunday-Saturday week.
* Monthly: first to last calendar day; compared with the preceding calendar
  month (December for January).
* Energy readings are labelled at the END of their interval (evidence E2), so
  the reading labelled Sunday 00:00 belongs to the week ending Saturday: the
  load range therefore runs up to and including the 00:00 label that closes
  the reporting period.

Only the standard library here: the web processes use it to validate
requests without importing the report engine's heavy dependencies.
"""

from __future__ import annotations

from dataclasses import dataclass
from datetime import date, datetime, time, timedelta, timezone
from zoneinfo import ZoneInfo

REPORT_TYPES = ("WEEKLY", "MONTHLY")
FIRST_ATTEMPT_DELAY = timedelta(hours=6)    # A64
MAX_WAIT = timedelta(hours=12)              # A66
RECHECK_INTERVAL = timedelta(minutes=30)    # A65


@dataclass(frozen=True)
class ReportPeriod:
    report_type: str
    start: date               # inclusive
    end: date                 # inclusive
    comparison_start: date
    comparison_end: date

    def local_bounds(self, zone: ZoneInfo) -> tuple[datetime, datetime]:
        """[start 00:00, day after end 00:00) as aware datetimes in the site zone."""

        return (datetime.combine(self.start, time(), zone),
                datetime.combine(self.end + timedelta(days=1), time(), zone))

    def end_instant(self, zone: ZoneInfo) -> datetime:
        return self.local_bounds(zone)[1]

    def first_attempt_at(self, zone: ZoneInfo) -> datetime:
        return self.end_instant(zone) + FIRST_ATTEMPT_DELAY

    def deadline(self, zone: ZoneInfo) -> datetime:
        return self.end_instant(zone) + MAX_WAIT

    def load_range_utc(self, zone: ZoneInfo) -> tuple[datetime, datetime]:
        """[comparison_start 00:00, period end 00:00 + 1 minute) in UTC: both
        periods and the closing midnight reading (A28)."""

        start = datetime.combine(self.comparison_start, time(), zone)
        end = datetime.combine(self.end + timedelta(days=1), time(), zone) + timedelta(minutes=1)
        return start.astimezone(timezone.utc), end.astimezone(timezone.utc)


def _month_start(day: date) -> date:
    return day.replace(day=1)


def _previous_month_start(first: date) -> date:
    return (first - timedelta(days=1)).replace(day=1)


def _next_month_start(first: date) -> date:
    return (first.replace(day=28) + timedelta(days=4)).replace(day=1)


def week_start(day: date) -> date:
    """The Sunday on or before `day`."""

    return day - timedelta(days=(day.weekday() + 1) % 7)


def period_for(report_type: str, start: date) -> ReportPeriod:
    """The period starting on `start`, which must be a Sunday (weekly) or the
    1st (monthly); ValueError otherwise."""

    if report_type == "WEEKLY":
        if start.weekday() != 6:
            raise ValueError("A weekly report period starts on a Sunday.")
        end = start + timedelta(days=6)
        return ReportPeriod("WEEKLY", start, end, start - timedelta(days=7), start - timedelta(days=1))
    if report_type == "MONTHLY":
        if start.day != 1:
            raise ValueError("A monthly report period starts on the first day of a month.")
        end = _next_month_start(start) - timedelta(days=1)
        prev = _previous_month_start(start)
        return ReportPeriod("MONTHLY", start, end, prev, start - timedelta(days=1))
    raise ValueError(f"Unknown report type {report_type!r}.")


def latest_closed_period(report_type: str, now: datetime, zone: ZoneInfo) -> ReportPeriod:
    """The most recent period whose end (local midnight) is at or before `now`."""

    today = now.astimezone(zone).date()
    if report_type == "WEEKLY":
        return period_for("WEEKLY", week_start(today) - timedelta(days=7))
    if report_type == "MONTHLY":
        return period_for("MONTHLY", _previous_month_start(_month_start(today)))
    raise ValueError(f"Unknown report type {report_type!r}.")


def period_label(period: ReportPeriod) -> str:
    if period.report_type == "MONTHLY":
        return period.start.strftime("%B %Y")
    return f"{period.start:%d-%b-%Y} – {period.end:%d-%b-%Y}"


def comparison_label(period: ReportPeriod) -> str:
    if period.report_type == "MONTHLY":
        return period.comparison_start.strftime("%B %Y")
    return f"{period.comparison_start:%d-%b-%Y} – {period.comparison_end:%d-%b-%Y}"
