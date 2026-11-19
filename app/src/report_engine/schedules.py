"""Working-hours schedules (standard library only).

A schedule maps each day (Sun..Sat) to a list of (start, end) "HH:MM"
intervals in site-local time. Several intervals per day are allowed; a day
with [] has no working hours; "24:00" may end an interval; ("00:00", "24:00")
is a full day; an end at or before the start is an overnight interval that
continues into the next day (Saturday night continues into Sunday).

Shared by the report engine (runtime) and the Administration App's reporting
settings form, which must not import the engine's heavy dependencies.
"""

from __future__ import annotations

import re
from typing import Optional

DAYS = ("Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat")
FULL_DAY = ("00:00", "24:00")


def every_day(*intervals: tuple[str, str]) -> dict[str, list[tuple[str, str]]]:
    return {day: list(intervals) for day in DAYS}


# ---------------------------------------------------------------------------
_TIME = re.compile(r"^([01]?\d|2[0-3]):([0-5]\d)$")
WEEK_MINUTES = 7 * 1440


def parse_time(text: str, allow_24: bool = False) -> int:
    text = str(text).strip()
    if allow_24 and text == "24:00":
        return 1440
    match = _TIME.match(text)
    if not match:
        raise ValueError(f"'{text}' is not a valid time (use HH:MM, 00:00-23:59{', or 24:00 as an end' if allow_24 else ''})")
    return int(match.group(1)) * 60 + int(match.group(2))


def _interval_minutes(day: str, start: str, end: str) -> tuple[int, int]:
    s, e = parse_time(start), parse_time(end, allow_24=True)
    if s == e:
        raise ValueError("start and end are the same; use 00:00-24:00 for a full day")
    base = DAYS.index(day) * 1440
    return (base + s, base + e) if e > s else (base + s, base + 1440 + e)


def schedule_week_ranges(schedule: Optional[dict]) -> list[tuple[int, int]]:
    if not schedule:
        return []
    pieces = []
    for day in DAYS:
        for start, end in schedule.get(day, []):
            a, b = _interval_minutes(day, start, end)
            if b > WEEK_MINUTES:
                pieces += [(a, WEEK_MINUTES), (0, b - WEEK_MINUTES)]
            else:
                pieces.append((a, b))
    merged: list[list[int]] = []
    for a, b in sorted(pieces):
        if merged and a <= merged[-1][1]:
            merged[-1][1] = max(merged[-1][1], b)
        else:
            merged.append([a, b])
    return [(a, b) for a, b in merged]


def validate_schedule(schedule: Optional[dict]) -> list[str]:
    if schedule is None:
        return []
    errors, pieces = [], []
    for day, intervals in schedule.items():
        if day not in DAYS:
            errors.append(f"Unknown day '{day}' (use {', '.join(DAYS)})")
            continue
        for start, end in intervals:
            try:
                a, b = _interval_minutes(day, start, end)
            except ValueError as exc:
                errors.append(f"{day} {start}-{end}: {exc}")
                continue
            ident = len(pieces)
            label = f"{day} {start}-{end}" + (" (overnight)" if b > DAYS.index(day) * 1440 + 1440 else "")
            pieces.append((a, min(b, WEEK_MINUTES), ident, label))
            if b > WEEK_MINUTES:
                pieces.append((0, b - WEEK_MINUTES, ident, label))
    reported = set()
    for i, (a1, b1, id1, l1) in enumerate(pieces):
        for a2, b2, id2, l2 in pieces[i + 1:]:
            if id1 != id2 and a1 < b2 and a2 < b1 and (id1, id2) not in reported:
                reported.add((id1, id2))
                errors.append(f"{l1} overlaps {l2}")
    return errors


def normalise_time(text: str, allow_24: bool = False) -> str:
    minutes = parse_time(text, allow_24=allow_24)
    return "24:00" if minutes == 1440 else f"{minutes // 60:02d}:{minutes % 60:02d}"


def normalise_schedule(raw: Optional[dict]) -> tuple[Optional[dict], list[str]]:
    """A schedule from {day: [[start, end], ...]}: times normalised, days
    sorted; (None, problems) when anything is invalid."""

    if raw is None:
        return None, []
    schedule: dict[str, list[tuple[str, str]]] = {day: [] for day in DAYS}
    problems = []
    for day, intervals in raw.items():
        if day not in DAYS:
            problems.append(f"Unknown day '{day}'")
            continue
        for interval in intervals:
            try:
                start, end = interval
                schedule[day].append((normalise_time(start), normalise_time(end, allow_24=True)))
            except (ValueError, TypeError) as exc:
                problems.append(f"{day} {interval}: {exc}")
        schedule[day].sort()
    problems += validate_schedule(schedule) if not problems else []
    return (None if problems else schedule), problems


def describe_schedule(schedule: Optional[dict]) -> str:
    if schedule is None:
        return "No schedule"

    def text(intervals):
        if not intervals:
            return "closed"
        if list(map(tuple, intervals)) == [FULL_DAY]:
            return "24 h"
        return ", ".join(f"{s}–{e}" for s, e in intervals)

    labels = [text(schedule.get(day, [])) for day in DAYS]
    if len(set(labels)) == 1:
        return f"Daily {labels[0]}" if labels[0] != "24 h" else "24 h daily"
    groups, start = [], 0
    for i in range(1, 8):
        if i == 7 or labels[i] != labels[start]:
            span = DAYS[start] if i - 1 == start else f"{DAYS[start]}–{DAYS[i - 1]}"
            groups.append(f"{span} {labels[start]}")
            start = i
    return "; ".join(groups)


def weekly_hours(schedule: Optional[dict]) -> float:
    return sum(b - a for a, b in schedule_week_ranges(schedule)) / 60
