"""Report metrics, comparisons and executive-summary rules.

Ported from the reference tool (app.py compute_report_metrics,
build_summary_points and helpers). Calculations are unchanged; the changes
are those approved in the Create report decisions:

* Periods are fixed calendar weeks (Sun-Sat) or calendar months (A24, A25),
  each compared with the preceding period (A26, A27). Wording is
  parameterised by period type.
* The asset list and groups come from the WiseWatts-managed reporting roster
  (Layout, A7, A8) instead of hard-coded file names.
* Setpoints are per asset and effective-dated; each temperature reading is
  compared with the setpoint in force at its timestamp, and an area whose
  sensors (or a change within the period) give different setpoints shows the
  range (A20, A21).
* Monthly kitchen attention: > 10 % AND > 100 kWh (A43); weekly unchanged
  (> 10 % AND > 25 kWh, A42).
* Percentage change is NA when the comparison value is zero or unavailable
  (A40); the absolute change is reported beside it (A35).
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Optional

import numpy as np
import pandas as pd

from src.report_engine import runtime as rt
from src.report_engine.prepare import (
    ENERGY_COL,
    FULL_DAY_COVERAGE,
    POWER_COL,
    TEMP_COL,
    AssetData,
    day_coverage,
)

TEMP_TOLERANCE_C = 1.0
COMPARABLE_MAX_UNMEASURED = 0.005
SMALL_PERCENT = 0.1
PEAK_MIN_COVERAGE = 0.95
TEMP_CHANGE_NEUTRAL_C = 0.05
ATTENTION_BAND_PCT = 50.0
ATTENTION_ASSET_INCREASE_PCT = 10.0
ATTENTION_ASSET_INCREASE_KWH = {"WEEKLY": 25.0, "MONTHLY": 100.0}
DUTY_SHIFT_MIN_SHARE = 0.10

# Roster vocabulary (analytics.site_report_assets.report_group / area).
GROUP_LABELS = {
    "HVAC_CHILLERS": "Chillers",
    "HVAC_PUMPS": "Pumps",
    "HVAC_COOLING_TOWERS": "Cooling towers",
    "HVAC_AHU": "Air handling units",
}
KITCHEN_GROUP = "KITCHEN"
AREA_LABELS = {
    "LOBBY": "Lobby",
    "RESTAURANT": "Restaurant",
    "BANQUET_1": "Banquet 1",
    "BANQUET_2": "Banquet 2",
    "PRE_FUNCTION": "Pre-function",
}
ENERGY_AREAS = {   # report section -> roster areas
    "Lobby": ("LOBBY",),
    "Restaurant": ("RESTAURANT",),
    "Banquet & pre-function": ("BANQUET_1", "BANQUET_2", "PRE_FUNCTION"),
}
TEMPERATURE_AREA_CODES = {"Lobby": ("LOBBY",), "Restaurant": ("RESTAURANT",),
                          "Banquet 1": ("BANQUET_1",), "Banquet 2": ("BANQUET_2",)}
BANQUET_TEMPERATURE_AREAS = ("Banquet 1", "Banquet 2")
DAILY_TEMPERATURE_AREAS = ("Lobby", "Restaurant", *BANQUET_TEMPERATURE_AREAS)


@dataclass(frozen=True)
class RosterEntry:
    asset_id: str
    name: str
    report_group: str
    area: Optional[str] = None
    display_order: int = 0


@dataclass
class Layout:
    """Asset groups of one report, derived from the roster."""

    entries: list[RosterEntry]

    def names(self, group: str) -> list[str]:
        return [e.name for e in self._ordered() if e.report_group == group]

    def _ordered(self) -> list[RosterEntry]:
        return sorted(self.entries, key=lambda e: (e.display_order, e.name))

    @property
    def hvac_names(self) -> list[str]:
        return [e.name for e in self._ordered() if e.report_group in GROUP_LABELS]

    @property
    def kitchen_names(self) -> list[str]:
        return self.names(KITCHEN_GROUP)

    @property
    def hvac_subsystems(self) -> dict[str, list[str]]:
        return {label: self.names(code) for code, label in GROUP_LABELS.items() if self.names(code)}

    @property
    def ahu_names(self) -> list[str]:
        return self.names("HVAC_AHU")

    def area_names(self, codes: tuple[str, ...]) -> list[str]:
        return [e.name for e in self._ordered() if e.area in codes]

    @property
    def energy_areas(self) -> dict[str, list[str]]:
        return {label: self.area_names(codes) for label, codes in ENERGY_AREAS.items()}

    @property
    def temperature_areas(self) -> dict[str, list[str]]:
        return {label: self.area_names(codes) for label, codes in TEMPERATURE_AREA_CODES.items()}

    @property
    def all_names(self) -> list[str]:
        return [e.name for e in self._ordered()]


@dataclass
class ReportSettings:
    """Effective-dated per-asset settings: name -> [(effective_from, value)],
    effective_from a site-local naive Timestamp (pd.Timestamp.min = always)."""

    setpoints: dict[str, list] = field(default_factory=dict)
    schedules: dict[str, list] = field(default_factory=dict)          # value: schedule dict or None
    schedule_confirmed: dict[str, list] = field(default_factory=dict)  # value: bool
    thresholds: dict[str, list] = field(default_factory=dict)         # value: rt.AHUSettings or None


@dataclass(frozen=True)
class PeriodSpec:
    report_type: str              # WEEKLY | MONTHLY
    prev_start: pd.Timestamp      # inclusive dates (site-local midnight)
    prev_end: pd.Timestamp
    curr_start: pd.Timestamp
    curr_end: pd.Timestamp

    @property
    def weekly(self) -> bool:
        return self.report_type == "WEEKLY"

    @property
    def unit(self) -> str:
        return "week" if self.weekly else "month"

    @property
    def curr_noun(self) -> str:
        return "latest week" if self.weekly else "reporting month"

    @property
    def prev_noun(self) -> str:
        return "previous week" if self.weekly else "previous month"

    @property
    def on_period(self) -> str:
        return "week on week" if self.weekly else "month on month"

    @property
    def title(self) -> str:
        return "Weekly EMS Performance Report" if self.weekly else "Monthly EMS Performance Report"


# ---------------------------------------------------------------------------
# Formatting and status
# ---------------------------------------------------------------------------

def fmt_date(value) -> str:
    return pd.Timestamp(value).strftime("%d-%b-%Y")


def pct_change(current: float, previous: float) -> float:
    if current is None or previous is None or pd.isna(current) or pd.isna(previous) or previous == 0:
        return np.nan
    return (current - previous) / abs(previous) * 100.0


def abs_change(current: float, previous: float) -> float:
    if current is None or previous is None or pd.isna(current) or pd.isna(previous):
        return np.nan
    return current - previous


def fmt_pct(value, signed: bool = False) -> str:
    if value is None or pd.isna(value):
        return "NA"
    if 0 < abs(value) < SMALL_PERCENT:
        return f"{('+' if value > 0 else '-') if signed else ''}<{SMALL_PERCENT:g}%"
    return f"{value:+.1f}%" if signed else f"{value:.1f}%"


def fmt_share(fraction) -> str:
    return "NA" if fraction is None or pd.isna(fraction) else fmt_pct(fraction * 100)


def fmt_num(value, decimals=2, suffix="") -> str:
    if value is None or pd.isna(value):
        return "NA"
    return f"{value:,.{decimals}f}{suffix}"


def fmt_delta(value, decimals=1, suffix="") -> str:
    if value is None or pd.isna(value):
        return "NA"
    return f"{value:+,.{decimals}f}{suffix}"


def change_status(current, previous, lower_is_better: bool = True, comparable: bool = True) -> tuple[str, str]:
    """Percentage change text and status: favorable, unfavorable, neutral or indicative (†)."""

    change = pct_change(current, previous)
    if pd.isna(change):
        return "NA", "neutral"
    text = fmt_pct(change, signed=True)
    if not comparable:
        return text + "†", "indicative"
    if round(change, 1) == 0:
        return text, "neutral"
    return text, "favorable" if (change < 0) == lower_is_better else "unfavorable"


def temperature_change_status(current: dict, previous: dict) -> tuple[str, str]:
    if pd.isna(current["mean_abs_deviation"]) or pd.isna(previous["mean_abs_deviation"]):
        return "NA", "neutral"
    delta = current["mean_abs_deviation"] - previous["mean_abs_deviation"]
    text = f"{delta:+.1f} °C"
    if min(current["coverage"], previous["coverage"]) < FULL_DAY_COVERAGE:
        return text + "†", "indicative"
    if abs(delta) < TEMP_CHANGE_NEUTRAL_C:
        return text, "neutral"
    return text, "favorable" if delta < 0 else "unfavorable"


def setpoint_text(values: list[float]) -> str:
    """'24.0 °C' or '23.0–24.0 °C' (A21); 'Not configured' when none."""

    finite = sorted({round(float(v), 2) for v in values if v is not None and np.isfinite(v)})
    if not finite:
        return "Not configured"
    if len(finite) == 1:
        return f"{finite[0]:.1f} °C"
    return f"{finite[0]:.1f}–{finite[-1]:.1f} °C"


# ---------------------------------------------------------------------------
# Group statistics (unchanged method)
# ---------------------------------------------------------------------------

def group_daily_energy(assets: dict[str, AssetData], names: list[str], start: pd.Timestamp, end: pd.Timestamp) -> pd.DataFrame:
    dates = pd.date_range(start, end, freq="D")
    energy = pd.DataFrame(index=dates)
    complete = pd.DataFrame(index=dates)
    for name in names:
        a = assets.get(name)
        if a is None or a.frame.empty:
            energy[name] = np.nan
            complete[name] = False
            continue
        cov = day_coverage(a, start, end).set_index("date")
        energy[name] = cov["energy_kwh"]
        complete[name] = cov["complete"]
    out = pd.DataFrame(index=dates)
    out["total_kwh"] = energy.sum(axis=1, min_count=len(names)) if names else np.nan
    out["available_assets"] = energy.notna().sum(axis=1)
    out["complete"] = complete.all(axis=1) if names else False
    return out


def daily_temp_series(assets: dict[str, AssetData], names: list[str], start: pd.Timestamp, end: pd.Timestamp) -> pd.Series:
    chunks = []
    for name in names:
        if name not in assets:
            continue
        f = assets[name].frame
        if TEMP_COL not in f.columns or f.empty:
            continue
        sub = f.loc[(f.index >= start) & (f.index < end + pd.Timedelta(days=1)), [TEMP_COL]].copy()
        if not sub.empty:
            chunks.append(sub)
    if not chunks:
        return pd.Series(dtype=float)
    alltemps = pd.concat(chunks).sort_index()
    return alltemps[TEMP_COL].groupby(alltemps.index.normalize()).mean().sort_index()


def week_asset_stats(assets: dict[str, AssetData], names: list[str], start: pd.Timestamp, end: pd.Timestamp) -> dict:
    """Period energy for a group: total (measured + estimated), comparable
    daily average/min/max, and measured / estimated / unresolved counts."""

    daily = group_daily_energy(assets, names, start, end)
    total = np.nan
    counts = {"observed": 0, "estimated": 0, "reconstructed": 0, "gap_filled": 0, "unresolved": 0, "expected": 0,
              "partial_asset_days": 0, "no_data_asset_days": 0}
    affected: list[str] = []
    for name in names:
        a = assets.get(name)
        if a is None or a.frame.empty:
            days = len(pd.date_range(start, end, freq="D"))
            counts["expected"] += days * 1440
            counts["unresolved"] += days * 1440
            counts["no_data_asset_days"] += days
            affected.append(name)
            continue
        cov = day_coverage(a, start, end)
        asset_total = cov["energy_kwh"].sum(min_count=1)
        if pd.notna(asset_total):
            total = asset_total if pd.isna(total) else total + asset_total
        counts["observed"] += int(cov["observed_count"].sum())
        counts["estimated"] += int(cov["estimated_count"].sum())
        counts["reconstructed"] += int(cov["reconstructed_count"].sum())
        counts["gap_filled"] += int(cov["gap_filled_count"].sum())
        counts["unresolved"] += int(cov["unresolved_count"].sum())
        counts["expected"] += int(cov["expected_count"].sum())
        partial = int((cov["status"] == "Partial").sum())
        none = int((cov["status"] == "No data").sum())
        counts["partial_asset_days"] += partial
        counts["no_data_asset_days"] += none
        if partial or none:
            affected.append(name)
    vals = daily.loc[daily["complete"], "total_kwh"].dropna()
    return {"total": float(total) if pd.notna(total) else np.nan,
            "avg_day": float(vals.mean()) if len(vals) else np.nan,
            "min_day": float(vals.min()) if len(vals) else np.nan,
            "max_day": float(vals.max()) if len(vals) else np.nan,
            "daily": daily["total_kwh"], "complete_days": int(len(vals)), "days": int(len(daily)),
            "affected_assets": affected, **counts}


def period_complete(s: dict) -> bool:
    """One period of a group: no partial or missing asset-days and at most
    COMPARABLE_MAX_UNMEASURED of expected energy intervals unmeasured."""

    unmeasured = s["unresolved"] / s["expected"] if s["expected"] else 1.0
    return not (s["partial_asset_days"] or s["no_data_asset_days"] or unmeasured > COMPARABLE_MAX_UNMEASURED)


def is_fully_comparable(*stats: dict) -> bool:
    return all(period_complete(s) for s in stats)


def available_share(s: dict) -> float:
    """Measured + estimated (EMS-reconstructed and gap-filled) share of
    expected energy readings (A45, A53)."""

    return (s["observed"] + s["estimated"]) / s["expected"] if s["expected"] else 0.0


def peak_demand(assets: dict[str, AssetData], names: list[str], start: pd.Timestamp, end: pd.Timestamp) -> dict:
    present = [assets[n] for n in names if n in assets and not assets[n].frame.empty]
    result = {"peak_kw": np.nan, "time": None, "coverage": 0.0, "complete_timestamps": 0,
              "expected_timestamps": 0, "asset_power_coverage": {n: 0.0 for n in names},
              "total_kw": pd.Series(dtype=float)}
    if not present:
        return result
    step = min(a.interval_minutes for a in present)
    expected_index = pd.date_range(start, end + pd.Timedelta(days=1), freq=f"{step}min", inclusive="left")
    columns = {}
    for name in names:
        a = assets.get(name)
        if a is None or a.frame.empty:
            columns[name] = pd.Series(np.nan, index=expected_index)
            continue
        columns[name] = a.frame.loc[a.frame["_power_observed"], POWER_COL].reindex(expected_index)
    wide = pd.DataFrame(columns, index=expected_index)
    complete = wide.notna().all(axis=1)
    result.update({"coverage": float(complete.mean()) if len(complete) else 0.0,
                   "complete_timestamps": int(complete.sum()), "expected_timestamps": len(expected_index),
                   "asset_power_coverage": wide.notna().mean().to_dict()})
    if complete.any():
        total = wide.loc[complete].sum(axis=1)
        idx = total.idxmax()
        result.update({"peak_kw": float(total.loc[idx]), "time": idx})
    result["total_kw"] = wide.sum(axis=1).where(complete)
    return result


def _setpoint_array(settings: ReportSettings, name: str, when: pd.DatetimeIndex) -> np.ndarray:
    values = rt.values_at(settings.setpoints.get(name, []), when)
    return np.array([np.nan if v is None else float(v) for v in values], dtype=float)


def area_setpoints_in_period(settings: ReportSettings, names: list[str], start: pd.Timestamp, end: pd.Timestamp) -> list[float]:
    end_exclusive = end + pd.Timedelta(days=1)
    values: list[float] = []
    for name in names:
        values += [float(v) for v in rt.versions_in_period(settings.setpoints.get(name, []), start, end_exclusive)
                   if v is not None]
    return values


def hourly_temperature(assets: dict[str, AssetData], names: list[str], start: pd.Timestamp, end: pd.Timestamp) -> pd.Series:
    hours = pd.date_range(start, end + pd.Timedelta(days=1), freq="h", inclusive="left")
    readings = [assets[n].frame[TEMP_COL].dropna() for n in names
                if n in assets and not assets[n].frame.empty and TEMP_COL in assets[n].frame.columns]
    if not readings:
        return pd.Series(np.nan, index=hours)
    values = pd.concat(readings)
    return values.groupby(values.index.floor("h")).mean().reindex(hours)


def hourly_setpoint_band(settings: ReportSettings, names: list[str], start: pd.Timestamp, end: pd.Timestamp
                         ) -> tuple[pd.Series, pd.Series]:
    """Per hour, the lowest and highest setpoint in force across the area's sensors (NaN when none)."""

    hours = pd.date_range(start, end + pd.Timedelta(days=1), freq="h", inclusive="left")
    arrays = [_setpoint_array(settings, n, hours) for n in names]
    if not arrays:
        empty = pd.Series(np.nan, index=hours)
        return empty, empty
    stacked = np.vstack(arrays)
    with np.errstate(all="ignore"):
        low = np.where(np.isnan(stacked).all(axis=0), np.nan, np.nanmin(np.where(np.isnan(stacked), np.inf, stacked), axis=0))
        high = np.where(np.isnan(stacked).all(axis=0), np.nan, np.nanmax(np.where(np.isnan(stacked), -np.inf, stacked), axis=0))
    return pd.Series(low, index=hours), pd.Series(high, index=hours)


def temperature_stats(assets: dict[str, AssetData], names: list[str], start: pd.Timestamp, end: pd.Timestamp,
                      settings: ReportSettings, tolerance: float = TEMP_TOLERANCE_C) -> dict:
    """Setpoint performance from recorded readings only; each reading is
    compared with its own asset's setpoint in force at the reading time (A20)."""

    readings, deviations, expected, sensors = [], [], 0, []
    end_exclusive = end + pd.Timedelta(days=1)
    for name in names:
        a = assets.get(name)
        if a is None or a.frame.empty or TEMP_COL not in a.frame.columns or not a.temperature_monitored:
            continue
        sensors.append(name)
        expected += len(pd.date_range(start, end_exclusive, freq=f"{a.interval_minutes}min", inclusive="left"))
        f = a.frame.loc[(a.frame.index >= start) & (a.frame.index < end_exclusive)]
        vals = f[TEMP_COL].dropna()
        readings.append(vals)
        sp = _setpoint_array(settings, name, pd.DatetimeIndex(vals.index))
        deviations.append(pd.Series(np.abs(vals.to_numpy(dtype=float) - sp), index=vals.index))
    vals = pd.concat(readings) if readings else pd.Series(dtype=float)
    dev = pd.concat(deviations).dropna() if deviations else pd.Series(dtype=float)
    setpoints = area_setpoints_in_period(settings, sensors, start, end)
    return {"sensors": sensors, "setpoints": setpoints, "setpoint_text": setpoint_text(setpoints),
            "tolerance": tolerance, "observed": int(len(vals)), "expected": expected,
            "coverage": len(vals) / expected if expected else np.nan,
            "mean": float(vals.mean()) if len(vals) else np.nan,
            "mean_abs_deviation": float(dev.mean()) if len(dev) else np.nan,
            "within_band_pct": float((dev <= tolerance).mean() * 100) if len(dev) else np.nan,
            "mean_signed_offset": _signed_offset(readings, settings, sensors)}


def _signed_offset(readings: list[pd.Series], settings: ReportSettings, sensors: list[str]) -> float:
    offsets = []
    for name, vals in zip(sensors, readings):
        sp = _setpoint_array(settings, name, pd.DatetimeIndex(vals.index))
        diff = vals.to_numpy(dtype=float) - sp
        offsets.append(diff[np.isfinite(diff)])
    joined = np.concatenate(offsets) if offsets else np.array([])
    return float(joined.mean()) if len(joined) else np.nan


# ---------------------------------------------------------------------------
# Report metrics
# ---------------------------------------------------------------------------

def ahu_runtime_metrics(assets: dict[str, AssetData], layout: Layout, periods: dict, settings: ReportSettings) -> dict:
    out = {}
    for name in layout.ahu_names:
        a = assets.get(name)
        if a is None or a.frame.empty:
            continue
        f = a.frame
        out[name] = {wk: rt.analyse_period(f[ENERGY_COL], f["_energy_observed"], f[POWER_COL].where(f["_power_observed"]),
                                           a.interval_minutes, settings.thresholds.get(name, []),
                                           settings.schedules.get(name, []), s, e)
                     for wk, (s, e) in periods.items()}
    return out


def compute_report_metrics(assets: dict[str, AssetData], layout: Layout, period: PeriodSpec,
                           settings: ReportSettings) -> dict:
    periods = {"prev": (period.prev_start, period.prev_end), "curr": (period.curr_start, period.curr_end)}
    curr_start, curr_end = periods["curr"]

    def both(names):
        return {wk: week_asset_stats(assets, names, s, e) for wk, (s, e) in periods.items()}

    hvac_names, kitchen_names = layout.hvac_names, layout.kitchen_names
    m: dict = {"weeks": periods, "period": period, "layout": layout}
    m["hvac"] = both(hvac_names)
    m["kitchen"] = both(kitchen_names)
    m["hvac_subsystems"] = {g: both(names) for g, names in layout.hvac_subsystems.items()}
    m["assets"] = {n: both([n]) for n in layout.all_names}
    m["peak"] = {wk: peak_demand(assets, hvac_names, s, e) for wk, (s, e) in periods.items()}
    temperature_areas = layout.temperature_areas
    m["temperature_areas"] = temperature_areas
    m["temperature"] = {area: {wk: temperature_stats(assets, names, s, e, settings) for wk, (s, e) in periods.items()}
                        for area, names in temperature_areas.items()}
    m["not_temperature_monitored"] = [n for n in layout.ahu_names
                                      if not (assets.get(n) and assets[n].temperature_monitored)]
    m["hvac_daily"] = group_daily_energy(assets, hvac_names, curr_start, curr_end)
    energy_areas = layout.energy_areas
    m["energy_areas"] = energy_areas
    daily_groups = {"HVAC": hvac_names, "Kitchen": kitchen_names,
                    **{a: energy_areas[a] for a in ("Lobby", "Restaurant")}}
    m["daily"] = {g: {wk: group_daily_energy(assets, names, s, e) for wk, (s, e) in periods.items()}
                  for g, names in daily_groups.items()}
    m["subsystem_daily"] = {g: group_daily_energy(assets, names, curr_start, curr_end)["total_kwh"]
                            for g, names in layout.hvac_subsystems.items()}
    m["asset_daily"] = {"Banquet & pre-function": {n: group_daily_energy(assets, [n], curr_start, curr_end)
                                                   for n in energy_areas["Banquet & pre-function"]}}
    m["hourly_temperature"] = {a: hourly_temperature(assets, [n for n in energy_areas[a]
                                                            if assets.get(n) and assets[n].temperature_monitored],
                                                     curr_start, curr_end)
                               for a in ("Lobby", "Restaurant")}
    m["hourly_setpoint"] = {a: hourly_setpoint_band(settings, m["temperature"][a]["curr"]["sensors"], curr_start, curr_end)
                            for a in ("Lobby", "Restaurant")}
    m["daily_temperature"] = {a: {wk: daily_temp_series(assets, m["temperature"][a][wk]["sensors"], s, e)
                                  .reindex(pd.date_range(s, e, freq="D"))
                                  for wk, (s, e) in periods.items()}
                              for a in DAILY_TEMPERATURE_AREAS}
    m["comparable"] = {"hvac": is_fully_comparable(*m["hvac"].values()),
                       "kitchen": is_fully_comparable(*m["kitchen"].values()),
                       "peak": min(p["coverage"] for p in m["peak"].values()) >= PEAK_MIN_COVERAGE}
    partial = []
    for name, a in assets.items():
        cov = day_coverage(a, period.prev_start, period.curr_end)
        for _, row in cov[cov["status"] != "Full"].iterrows():
            partial.append({"asset": name, "date": row["date"], "coverage": float(row["coverage"]), "status": row["status"],
                            "week": "curr" if row["date"] >= period.curr_start else "prev"})
    m["partial_days"] = partial
    m["ahu_runtime"] = ahu_runtime_metrics(assets, layout, periods, settings)
    end_exclusive = curr_end + pd.Timedelta(days=1)
    m["ahu_schedules"] = {n: rt.versions_in_period(settings.schedules.get(n, []), curr_start, end_exclusive)
                          for n in m["ahu_runtime"]}
    m["ahu_confirmed"] = {n: bool(rt.value_at(settings.schedule_confirmed.get(n, []), end_exclusive - pd.Timedelta(minutes=1)))
                          for n in m["ahu_runtime"]}
    m["ahu_ooh"] = rt.summarise_out_of_hours(m["ahu_runtime"])
    scheduled = [n for n, r in m["ahu_runtime"].items() if r["curr"]["scheduled"]]
    m["ahu_ooh"]["comparable"] = bool(scheduled) and all(
        is_fully_comparable(m["assets"][n]["curr"], m["assets"][n]["prev"]) for n in scheduled)
    return m


# ---------------------------------------------------------------------------
# Executive summary
# ---------------------------------------------------------------------------

def _direction(change: float, down: str = "fell", up: str = "rose") -> str:
    return "was unchanged" if round(change, 1) == 0 else (down if change < 0 else up)


def build_summary_points(m: dict) -> tuple[list[str], list[str]]:
    period: PeriodSpec = m["period"]
    layout: Layout = m["layout"]
    observations, attention = [], []
    hv, kt = m["hvac"], m["kitchen"]
    indicative = f" This comparison is indicative because at least one {period.unit} has incomplete data."

    change = pct_change(hv["curr"]["total"], hv["prev"]["total"])
    if pd.notna(change):
        text = (f"HVAC energy {_direction(change)} {fmt_pct(abs(change))} {period.on_period}, from {hv['prev']['total']:,.1f} kWh "
                f"to {hv['curr']['total']:,.1f} kWh.")
        deltas = {g: s["curr"]["total"] - s["prev"]["total"] for g, s in m["hvac_subsystems"].items()
                  if pd.notna(s["curr"]["total"]) and pd.notna(s["prev"]["total"])}
        if deltas:
            g = max(deltas, key=lambda k: abs(deltas[k]))
            s = m["hvac_subsystems"][g]
            text += (f" The largest change was in {g.lower()}: {deltas[g]:+,.1f} kWh "
                     f"({fmt_pct(pct_change(s['curr']['total'], s['prev']['total']), signed=True)}).")
        observations.append(text + ("" if m["comparable"]["hvac"] else indicative))

    for g, names in layout.hvac_subsystems.items():
        deltas = {n: m["assets"][n]["curr"]["total"] - m["assets"][n]["prev"]["total"] for n in names
                  if pd.notna(m["assets"][n]["curr"]["total"]) and pd.notna(m["assets"][n]["prev"]["total"])}
        if len(deltas) < 2:
            continue
        up, down = max(deltas, key=deltas.get), min(deltas, key=deltas.get)
        s = m["hvac_subsystems"][g]
        swing = min(deltas[up], -deltas[down])
        if pd.notna(s["curr"]["total"]) and swing >= DUTY_SHIFT_MIN_SHARE * s["curr"]["total"]:
            observations.append(f"{g} duty changed between {period.unit}s: {up} {deltas[up]:+,.1f} kWh, {down} "
                                f"{deltas[down]:+,.1f} kWh; combined {g.lower()} energy changed "
                                f"{fmt_pct(pct_change(s['curr']['total'], s['prev']['total']), signed=True)}.")

    pc, pp = m["peak"]["curr"], m["peak"]["prev"]
    if pc["time"] is not None:
        text = f"Peak HVAC demand was {pc['peak_kw']:,.1f} kW on {fmt_date(pc['time'])} at {pc['time']:%H:%M}"
        change = pct_change(pc["peak_kw"], pp["peak_kw"])
        if pd.notna(change):
            text += (f", {fmt_pct(abs(change))} {'lower' if change < 0 else 'higher'} than the {period.prev_noun}'s "
                     f"{pp['peak_kw']:,.1f} kW" if round(change, 1) != 0 else f", unchanged from the {period.prev_noun}")
        observations.append(text + ".")

    daily = m["hvac_daily"]
    comparable_days = daily.loc[daily["complete"], "total_kwh"].dropna()
    if len(comparable_days) >= 2:
        hi, lo = comparable_days.idxmax(), comparable_days.idxmin()
        observations.append(f"Daily HVAC energy ranged from {comparable_days[lo]:,.1f} kWh ({fmt_date(lo)}) "
                            f"to {comparable_days[hi]:,.1f} kWh ({fmt_date(hi)}).")

    for area, temps in m["temperature"].items():
        cur, prev = temps["curr"], temps["prev"]
        if pd.isna(cur["mean"]) or pd.isna(cur["mean_abs_deviation"]):
            continue
        offset = cur["mean_signed_offset"]
        side = "above" if offset > 0 else "below"
        sp = cur["setpoint_text"]
        noun = "setpoint" if "–" not in sp else "setpoint range"
        text = (f"{area} temperature averaged {cur['mean']:.1f} °C against a {sp} {noun} "
                f"({abs(offset):.1f} °C {side} on average); {fmt_pct(cur['within_band_pct'])} of readings were within "
                f"±{TEMP_TOLERANCE_C:g} °C")
        if pd.notna(prev["within_band_pct"]):
            text += f" ({period.prev_noun} {fmt_pct(prev['within_band_pct'])})"
        observations.append(text + ".")
        if cur["within_band_pct"] < ATTENTION_BAND_PCT:
            share = ("none of the temperature readings were" if cur["within_band_pct"] == 0
                     else f"only {fmt_pct(cur['within_band_pct'])} of temperature readings were")
            attention.append(f"{area}: {share} within ±{TEMP_TOLERANCE_C:g} °C of the {sp} {noun}, and the "
                             f"space averaged {cur['mean_abs_deviation']:.1f} °C from setpoint. This suggests an "
                             "opportunity to investigate AHU control, setpoint scheduling and sensor location in this area.")

    ooh = m.get("ahu_ooh")
    if ooh and ooh["curr"]["assets"] and pd.notna(ooh["curr"]["energy_out"]):
        c, p = ooh["curr"], ooh["prev"]
        rows = {n: r["curr"] for n, r in m["ahu_runtime"].items() if r["curr"]["scheduled"]}
        text = (f"Scheduled AHUs used {c['energy_out']:,.1f} kWh outside their configured working hours, "
                f"{fmt_pct(c['ooh_pct'])} of their energy ({period.prev_noun} {fmt_pct(p['ooh_pct'])}).")
        top = max(rows, key=lambda n: rows[n]["energy_out"] if pd.notna(rows[n]["energy_out"]) else -1)
        if rows[top]["energy_out"] > 0:
            runtime = (f", an estimated {rows[top]['runtime_out_h']:,.1f} h of operation"
                       if pd.notna(rows[top]["runtime_out_h"]) else "")
            text += f" The largest out-of-hours share was {top} ({rows[top]['energy_out']:,.1f} kWh{runtime})."
        if not all(m["ahu_confirmed"].get(n) for n in rows):
            text += (" Working hours not yet confirmed by the hotel are provisional, and some areas may "
                     "need conditioning outside them.")
        observations.append(text)

    change = pct_change(kt["curr"]["total"], kt["prev"]["total"])
    if pd.notna(change):
        text = f"Kitchen energy {_direction(change)} {fmt_pct(abs(change))} to {kt['curr']['total']:,.1f} kWh."
        deltas = {n: m["assets"][n]["curr"]["total"] - m["assets"][n]["prev"]["total"] for n in layout.kitchen_names
                  if pd.notna(m["assets"][n]["curr"]["total"]) and pd.notna(m["assets"][n]["prev"]["total"])}
        if deltas:
            n = max(deltas, key=lambda k: abs(deltas[k]))
            text += f" The largest change was {n} ({deltas[n]:+,.1f} kWh)."
        observations.append(text + ("" if m["comparable"]["kitchen"] else indicative))

    threshold_kwh = ATTENTION_ASSET_INCREASE_KWH[period.report_type]
    candidates = {**{g: s for g, s in m["hvac_subsystems"].items()}, **{n: m["assets"][n] for n in layout.kitchen_names}}
    for n, stats in candidates.items():
        c, p = stats["curr"], stats["prev"]
        change = pct_change(c["total"], p["total"])
        if (pd.notna(change) and is_fully_comparable(c, p) and change > ATTENTION_ASSET_INCREASE_PCT
                and c["total"] - p["total"] > threshold_kwh):
            attention.append(f"{n}: energy rose {fmt_pct(change)} ({c['total'] - p['total']:+,.1f} kWh) {period.on_period}. "
                             "Reviewing operating schedules and load for this period may help explain the increase.")

    return observations, attention
