"""Estimated AHU runtime and working-hours (out-of-hours) energy.

Method unchanged from the reference tool (ems_runtime.py, 02-Nov-2026):

* Operating signal: interval-average power from MEASURED interval energy,
  P_avg = E / interval. Intervals without measured energy (missing,
  gap-filled, EMS-reconstructed or negative) are NO DATA.
* OFF / STANDBY / UNCERTAIN / ON against the AHU's operating thresholds;
  estimated runtime = ON + 50 % of UNCERTAIN.
* An energy reading at t covers (t - dt, t]; energy and runtime are split
  between working and out-of-hours by the share of each interval inside the
  working-hours schedule.

EMS changes (decisions A13, A14, A20, A30): thresholds and schedules are no
longer code constants or a JSON file. They are per-asset, effective-dated
settings maintained by WiseWatts Admins. Each interval uses the version in
force at the interval's start. An interval without operating thresholds is
NO DATA; an interval without a working-hours schedule counts as within hours
(so out-of-hours energy is never overstated).
"""

from __future__ import annotations

import math
from dataclasses import dataclass
from typing import Optional

import numpy as np
import pandas as pd

from src.report_engine.schedules import (  # noqa: F401  (re-exported for the engine and tests)
    DAYS,
    FULL_DAY,
    WEEK_MINUTES,
    describe_schedule,
    every_day,
    normalise_schedule,
    normalise_time,
    parse_time,
    schedule_week_ranges,
    validate_schedule,
    weekly_hours,
)


@dataclass(frozen=True)
class AHUSettings:
    """Operating thresholds for one AHU (kW of interval-average power).

      P <= off_kw                        -> OFF
      off_kw < P <= standby_kw           -> STANDBY (only when standby_kw is set)
      standby_kw (or off_kw) < P < on_kw -> UNCERTAIN
      P >= on_kw                         -> ON
    """

    off_kw: float
    standby_kw: Optional[float]
    on_kw: float
    runtime_enabled: bool = True
    confidence: str = ""


UNCERTAIN_WEIGHT = 0.5
MIN_PERSISTENCE_MINUTES = 2
MAX_RUNTIME_INTERVAL_MINUTES = 5
MAX_UNCERTAIN_SHARE = 0.05
MIN_RUNTIME_COVERAGE = 0.50

OFF, STANDBY, UNCERTAIN, ON, NO_DATA = 0, 1, 2, 3, -1
STATE_NAMES = {OFF: "OFF", STANDBY: "STANDBY", UNCERTAIN: "UNCERTAIN", ON: "ON", NO_DATA: "NO DATA"}


def classify_power(p_avg, settings: AHUSettings) -> np.ndarray:
    p = np.asarray(p_avg, dtype=float)
    states = np.full(p.shape, UNCERTAIN, dtype=int)
    states[p <= settings.off_kw] = OFF
    if settings.standby_kw is not None:
        states[(p > settings.off_kw) & (p <= settings.standby_kw)] = STANDBY
    states[p >= settings.on_kw] = ON
    states[np.isnan(p)] = NO_DATA
    return states


def count_starts(states: np.ndarray, interval_minutes: int, min_minutes: int = MIN_PERSISTENCE_MINUTES) -> int:
    min_len = max(1, math.ceil(min_minutes / interval_minutes))
    sequence: list[str] = []
    i = 0
    while i < len(states):
        j = i
        while j < len(states) and states[j] == states[i]:
            j += 1
        state, length = states[i], j - i
        if state == NO_DATA:
            sequence.append("gap")
        elif state == ON and length >= min_len:
            sequence.append("run")
        elif state in (OFF, STANDBY) and length >= min_len:
            sequence.append("idle")
        i = j
    collapsed = [s for k, s in enumerate(sequence) if k == 0 or s != sequence[k - 1]]
    return sum(1 for a, b in zip(collapsed, collapsed[1:]) if a == "idle" and b == "run")


def in_hours_fraction(interval_end: pd.DatetimeIndex, interval_minutes: int, schedule: Optional[dict]) -> np.ndarray:
    ranges = schedule_week_ranges(schedule)
    if not ranges or len(interval_end) == 0:
        return np.zeros(len(interval_end))
    starts = pd.DatetimeIndex(interval_end) - pd.Timedelta(minutes=interval_minutes)
    week_pos = (((starts.day_of_week + 1) % 7) * 1440 + starts.hour * 60 + starts.minute + starts.second / 60).to_numpy(float)
    ends = week_pos + interval_minutes
    overlap = np.zeros(len(week_pos))
    for a, b in ranges:
        for shift in (0, WEEK_MINUTES):
            overlap += np.clip(np.minimum(ends, b + shift) - np.maximum(week_pos, a + shift), 0, None)
    return np.clip(overlap / interval_minutes, 0, 1)


# ---------------------------------------------------------------------------
# Effective-dated settings
# ---------------------------------------------------------------------------
# A version list is [(effective_from, value), ...] sorted by effective_from,
# where effective_from is a site-local naive Timestamp (pd.Timestamp.min for
# "always"). The value in force at t is the last version with
# effective_from <= t; before the first version there is no value (None).

def value_at(versions: list, when: pd.Timestamp):
    value = None
    for effective_from, v in versions:
        if effective_from <= when:
            value = v
        else:
            break
    return value


_NEG_INF = np.iinfo(np.int64).min


def _positions(versions: list, when: pd.DatetimeIndex) -> np.ndarray:
    """Index of the version in force at each timestamp (-1 = none)."""

    if not versions or len(when) == 0:
        return np.full(len(when), -1, dtype=np.int64)
    starts = np.array([_NEG_INF if effective_from == pd.Timestamp.min else pd.Timestamp(effective_from).as_unit("ns").value
                       for effective_from, _ in versions], dtype=np.int64)
    stamps = pd.DatetimeIndex(when).as_unit("ns").asi8
    return np.searchsorted(starts, stamps, side="right") - 1


def values_at(versions: list, when: pd.DatetimeIndex) -> list:
    """Value in force at each timestamp."""

    positions = _positions(versions, when)
    return [None if p < 0 else versions[p][1] for p in positions]


def segments(versions: list, when: pd.DatetimeIndex) -> list[tuple[np.ndarray, object]]:
    """[(boolean mask over `when`, value)] for each version in force (None = no version)."""

    positions = _positions(versions, when)
    return [(positions == p, None if p < 0 else versions[p][1]) for p in np.unique(positions)]


def versions_in_period(versions: list, start: pd.Timestamp, end_exclusive: pd.Timestamp) -> list:
    """Values in force at any time in [start, end_exclusive), in order."""

    values = []
    current = value_at(versions, start)
    if current is not None:
        values.append(current)
    for effective_from, v in versions:
        if start < effective_from < end_exclusive and v is not None:
            values.append(v)
    return values


# ---------------------------------------------------------------------------
# Period analysis for one AHU
# ---------------------------------------------------------------------------

def analyse_period(energy: pd.Series, energy_measured: pd.Series, power: pd.Series, interval_minutes: int,
                   threshold_versions: list, schedule_versions: list,
                   start: pd.Timestamp, end: pd.Timestamp) -> dict:
    """Runtime and working-hours split for one AHU over [start, end] (inclusive
    dates): intervals (t - dt, t] whose start falls on those dates.

    threshold_versions: [(effective_from, AHUSettings | None)];
    schedule_versions: [(effective_from, schedule dict | None)].
    """

    step = pd.Timedelta(minutes=interval_minutes)
    index = pd.date_range(pd.Timestamp(start) + step, pd.Timestamp(end) + pd.Timedelta(days=1), freq=step)
    interval_starts = index - step
    e = energy.reindex(index)
    measured = energy_measured.reindex(index).fillna(False).astype(bool).to_numpy()
    p_avg = np.where(measured, e.to_numpy(dtype=float) / (interval_minutes / 60), np.nan)

    states = np.full(len(index), NO_DATA, dtype=int)
    on_kw = np.full(len(index), np.nan)
    active_settings: list[AHUSettings] = []
    for mask, settings in segments(threshold_versions, interval_starts):
        if settings is None or not settings.runtime_enabled:
            continue
        active_settings.append(settings)
        states[mask] = classify_power(p_avg[mask], settings)
        on_kw[mask] = settings.on_kw

    hours = {STATE_NAMES[s].lower().replace(" ", "_"): float((states == s).sum() * interval_minutes / 60)
             for s in (ON, OFF, STANDBY, UNCERTAIN, NO_DATA)}
    classified = int((states != NO_DATA).sum())
    period_h = len(index) * interval_minutes / 60
    classified_h = classified * interval_minutes / 60
    coverage = classified / len(index) if len(index) else 0.0

    on_h, unc_h = hours["on"], hours["uncertain"]
    status = "ok"
    if not active_settings:
        status = "not reported"
    elif interval_minutes > MAX_RUNTIME_INTERVAL_MINUTES:
        status = "interval too coarse"
    elif coverage < MIN_RUNTIME_COVERAGE:
        status = "insufficient data"
    elif classified_h and unc_h / classified_h > MAX_UNCERTAIN_SHARE:
        status = "unreliable classification"
    ok = status == "ok"
    runtime = on_h + UNCERTAIN_WEIGHT * unc_h

    p = power.reindex(index).to_numpy(dtype=float)
    check = ~np.isnan(p) & np.isin(states, (OFF, STANDBY, ON)) & ~np.isnan(on_kw)
    agreement = float(((p[check] >= on_kw[check]) == (states[check] == ON)).mean()) if check.any() else np.nan

    schedule_segments = segments(schedule_versions, interval_starts)
    scheduled = any(s is not None for _, s in schedule_segments)
    frac_in = np.ones(len(index))   # no schedule in force -> within hours (never overstates out-of-hours)
    for mask, schedule in schedule_segments:
        if schedule is not None:
            frac_in[mask] = in_hours_fraction(index[mask], interval_minutes, schedule)
    weight = np.where(states == ON, 1.0, np.where(states == UNCERTAIN, UNCERTAIN_WEIGHT, 0.0))
    energy_values = e.to_numpy(dtype=float)
    finite = ~np.isnan(energy_values)
    total = float(energy_values[finite].sum()) if finite.any() else np.nan
    energy_in = float((energy_values * frac_in)[finite].sum()) if finite.any() else np.nan
    estimated = int((finite & ~measured).sum())
    has_standby = any(s.standby_kw is not None for s in active_settings)
    return {
        "interval_minutes": interval_minutes, "period_h": period_h, "classified_h": classified_h, "hours": hours,
        "coverage": coverage, "status": status,
        "runtime_h": runtime if ok else np.nan,
        "runtime_low_h": on_h if ok else np.nan, "runtime_high_h": on_h + unc_h if ok else np.nan,
        "runtime_pct": runtime / classified_h * 100 if ok and classified_h else np.nan,
        "operating_pct": runtime / period_h * 100 if ok and period_h else np.nan,
        "standby_h": hours["standby"] if has_standby else np.nan,
        "starts": count_starts(states, interval_minutes) if ok else np.nan,
        "power_agreement": agreement,
        "scheduled": scheduled,
        "runtime_in_h": float((weight * frac_in).sum() * interval_minutes / 60) if ok and scheduled else np.nan,
        "runtime_out_h": float((weight * (1 - frac_in)).sum() * interval_minutes / 60) if ok and scheduled else np.nan,
        "energy_total": total,
        "energy_in": energy_in if scheduled else np.nan,
        "energy_out": total - energy_in if scheduled and finite.any() else np.nan,
        "ooh_pct": (total - energy_in) / total * 100 if scheduled and finite.any() and total else np.nan,
        "energy_measured_share": float(measured.mean()) if len(index) else np.nan,
        "energy_estimated_share": estimated / len(index) if len(index) else np.nan,
        "energy_unmeasured_share": float((~finite).mean()) if len(index) else np.nan,
        "low_confidence_standby": any(s.standby_kw is not None and "low" in s.confidence.lower() for s in active_settings),
    }


def summarise_out_of_hours(per_asset: dict[str, dict]) -> dict:
    out = {}
    for week in ("prev", "curr"):
        rows = [r[week] for r in per_asset.values() if r[week]["scheduled"] and not np.isnan(r[week]["energy_total"])]
        total = sum(r["energy_total"] for r in rows)
        outside = sum(r["energy_out"] for r in rows)
        out[week] = {"assets": len(rows), "energy_total": total if rows else np.nan,
                     "energy_out": outside if rows else np.nan, "energy_in": total - outside if rows else np.nan,
                     "ooh_pct": outside / total * 100 if rows and total else np.nan}
    return out


# ---------------------------------------------------------------------------
# Reference values (the tool's evidence-based thresholds and provisional
# hours, 02-Nov-2026). Used ONLY by tests that reproduce the reference
# report; in EMS every value is entered by a WiseWatts Admin (A9).
# ---------------------------------------------------------------------------
REFERENCE_THRESHOLDS: dict[str, AHUSettings] = {
    "Lobby Area AHU-1": AHUSettings(0.05, None, 0.40, True, "High"),
    "Lobby Area AHU-2": AHUSettings(0.05, None, 0.40, True, "High"),
    "Seasons Restaurant AHU-1": AHUSettings(0.05, None, 0.45, True, "High"),
    "Seasons Restaurant AHU-2": AHUSettings(0.05, None, 0.45, True, "High"),
    "Banquet 1 AHU": AHUSettings(0.005, 0.03, 0.60, True, "High (ON/OFF); Low-Medium (STANDBY)"),
    "Banquet 2 AHU": AHUSettings(0.05, None, 0.85, True, "High"),
    "Pre Function Area AHU": AHUSettings(0.05, None, 0.80, True, "High"),
}
REFERENCE_SCHEDULES: dict[str, dict] = {
    "Lobby Area AHU-1": every_day(("05:00", "23:00")),
    "Lobby Area AHU-2": every_day(("05:00", "23:00")),
    "Seasons Restaurant AHU-1": every_day(("06:00", "22:00")),
    "Seasons Restaurant AHU-2": every_day(("06:00", "22:00")),
    "Banquet 1 AHU": every_day(("06:00", "22:00")),
    "Banquet 2 AHU": every_day(("06:00", "22:00")),
    "Pre Function Area AHU": every_day(("06:00", "22:00")),
}
