"""Reading preparation: grid alignment, short energy-gap estimation and coverage.

Ported unchanged in method from the reference tool (app.py, 02-Nov-2026):

* Timestamps are site-local and mark the END of the metered interval
  (Eniscope convention, verified for EMS in the planning evidence E2): an
  Energy reading at t covers (t - interval, t], so a 00:00 reading belongs to
  the previous day.
* Readings are snapped to the asset's interval grid within
  min(40 % of the interval, 1 minute).
* Internal energy gaps of up to 30 minutes are estimated linearly between
  valid neighbouring interval values; longer gaps and edge gaps stay
  unresolved. Negative energy is treated as missing. Power and temperature
  are never estimated.

EMS addition (decisions A51-A55): a valid EMS-reconstructed energy value is
used in totals but classed as ESTIMATED, never measured. The loader marks it
in the source column RECONSTRUCTED_COL; prepare_asset keeps it out of the
measured (observed) flag, so it counts neither toward a full day (90 %
measured) nor toward runtime classification.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Optional

import numpy as np
import pandas as pd

TIMESTAMP_COL = "Timestamp (Site Local)"
ENERGY_COL = "Energy (kWh)"
POWER_COL = "Power (kW)"
TEMP_COL = "Temperature (degC)"
RECONSTRUCTED_COL = "_source_reconstructed"
MAX_GAP_MINUTES = 30
FULL_DAY_COVERAGE = 0.90
ALIGN_TOLERANCE_FRACTION = 0.4
ALIGN_TOLERANCE_MAX = pd.Timedelta(minutes=1)


@dataclass
class AssetData:
    name: str
    source: str
    frame: pd.DataFrame
    interval_minutes: int
    issues: list[str]
    source_rows: int
    valid_rows: int
    duplicate_rows: int
    estimated_energy_points: int = 0
    unresolved_energy_points: int = 0
    reconstructed_energy_points: int = 0
    gap_filled_energy_points: int = 0
    source_frame: Optional[pd.DataFrame] = None
    processing_issues: list[str] = field(default_factory=list)
    temperature_monitored: bool = False
    reconstructed_source_minutes: int = 0


def infer_interval_minutes(ts: pd.Series) -> int:
    diffs = ts.dropna().sort_values().drop_duplicates().diff().dropna().dt.total_seconds().div(60)
    diffs = diffs[(diffs > 0) & (diffs <= 180)]
    if diffs.empty:
        return 1
    return max(1, int(round(float(diffs.median()))))


def asset_from_frame(name: str, raw: pd.DataFrame, source: str = "EMS",
                     temperature_monitored: Optional[bool] = None) -> AssetData:
    """AssetData from a frame with TIMESTAMP_COL, ENERGY_COL, POWER_COL and
    optionally TEMP_COL / RECONSTRUCTED_COL (the reference tool's read_asset
    after CSV parsing). Duplicate timestamps are averaged and flagged."""

    issues: list[str] = []
    source_rows = len(raw)
    raw = raw.dropna(subset=[TIMESTAMP_COL]).copy()
    value_cols = [c for c in (ENERGY_COL, POWER_COL, TEMP_COL) if c in raw.columns]
    for col in value_cols:
        raw[col] = pd.to_numeric(raw[col], errors="coerce")
    if RECONSTRUCTED_COL not in raw.columns:
        raw[RECONSTRUCTED_COL] = False
    raw[RECONSTRUCTED_COL] = raw[RECONSTRUCTED_COL].fillna(False).astype(bool)
    duplicate_rows = int(raw[TIMESTAMP_COL].duplicated(keep="first").sum())
    if duplicate_rows:
        duplicate_mask = raw[TIMESTAMP_COL].duplicated(keep=False)
        distinct = raw.loc[duplicate_mask].groupby(TIMESTAMP_COL)[value_cols].nunique(dropna=False)
        conflicting = int((distinct > 1).any(axis=1).sum())
        issues.append(f"{duplicate_rows} duplicate timestamp row(s) ({conflicting} timestamp(s) with differing values); "
                      "duplicates averaged by timestamp.")
    agg = {c: "mean" for c in value_cols}
    agg[RECONSTRUCTED_COL] = "max"
    frame = raw.groupby(TIMESTAMP_COL, as_index=False).agg(agg).sort_values(TIMESTAMP_COL)
    frame = frame.set_index(TIMESTAMP_COL)
    interval = infer_interval_minutes(frame.index.to_series()) if len(frame) else 1
    if TEMP_COL not in frame.columns:
        issues.append("Temperature column is not present; temperature metrics will be NA.")
    monitored = TEMP_COL in frame.columns if temperature_monitored is None else temperature_monitored
    return AssetData(name, source, frame, interval, issues, source_rows, len(frame), duplicate_rows,
                     source_frame=frame, temperature_monitored=monitored)


def align_tolerance(interval_minutes: int) -> pd.Timedelta:
    return min(pd.Timedelta(minutes=interval_minutes) * ALIGN_TOLERANCE_FRACTION, ALIGN_TOLERANCE_MAX)


def energy_period_day(index: pd.DatetimeIndex, interval_minutes: int) -> pd.DatetimeIndex:
    """Calendar day of the interval each Energy reading covers (interval end -> previous day at 00:00)."""

    return (index - pd.Timedelta(minutes=interval_minutes)).normalize()


def align_to_grid(frame: pd.DataFrame, interval_minutes: int) -> tuple[pd.DataFrame, dict]:
    tolerance = align_tolerance(interval_minutes)
    ts = frame.index.to_series()
    slots = ts.dt.round(f"{interval_minutes}min")
    offset = (ts - slots).abs()
    within = (offset <= tolerance).to_numpy()
    work = frame.loc[within].copy()
    work["_slot"] = slots.to_numpy()[within]
    work["_offset"] = offset.to_numpy()[within]
    work = work.sort_values(["_slot", "_offset"], kind="mergesort")
    collision = work["_slot"].duplicated(keep="first").to_numpy()
    aligned = work.loc[~collision].drop(columns="_offset").set_index("_slot")
    aligned.index.name = TIMESTAMP_COL
    stats = {
        "tolerance_seconds": tolerance.total_seconds(),
        "outside_tolerance": int((~within).sum()),
        "collisions": int(collision.sum()),
        "shifted": int((work.loc[~collision, "_offset"] > pd.Timedelta(0)).sum()),
        "max_shift_seconds": float(work.loc[~collision, "_offset"].max().total_seconds()) if len(aligned) else 0.0,
    }
    return aligned, stats


def estimate_short_gaps(values: np.ndarray, interval_minutes: int) -> tuple[np.ndarray, np.ndarray]:
    """Linearly estimate internal NaN runs of <= MAX_GAP_MINUTES between valid neighbouring values."""

    values = values.copy()
    missing = np.isnan(values)
    estimated = np.zeros(len(values), dtype=bool)
    i = 0
    while i < len(values):
        if not missing[i]:
            i += 1
            continue
        j = i
        while j < len(values) and missing[j]:
            j += 1
        run_len = j - i
        gap_minutes = run_len * interval_minutes
        if i > 0 and j < len(values) and gap_minutes <= MAX_GAP_MINUTES and np.isfinite(values[i - 1]) and np.isfinite(values[j]):
            for k in range(i, j):
                fraction = (k - (i - 1)) / (j - (i - 1))
                values[k] = values[i - 1] + fraction * (values[j] - values[i - 1])
                estimated[k] = True
        i = j
    return values, estimated


def prepare_asset(asset: AssetData, start: pd.Timestamp, end_exclusive: pd.Timestamp) -> AssetData:
    """Align readings to the asset's grid and estimate only internal energy gaps <= 30 minutes.

    Flag columns: _energy_observed (measured: valid, not reconstructed),
    _estimated_energy (gap-filled OR EMS-reconstructed), _gap_filled,
    _reconstructed, _energy_unresolved, _energy_negative, _power_observed,
    _temp_observed (when a temperature column exists).
    """

    if asset.source_frame is None:
        asset.source_frame = asset.frame
    interval = asset.interval_minutes
    issues: list[str] = []
    source = asset.source_frame
    if RECONSTRUCTED_COL not in source.columns:
        source = source.assign(**{RECONSTRUCTED_COL: False})
    aligned, align = align_to_grid(source, interval)
    if align["shifted"]:
        issues.append(f"{align['shifted']} reading(s) were off the {interval}-minute grid by up to "
                      f"{align['max_shift_seconds']:.0f} s and were aligned to the nearest slot.")
    if align["outside_tolerance"]:
        issues.append(f"{align['outside_tolerance']} reading(s) were more than {align['tolerance_seconds']:.0f} s "
                      f"from the {interval}-minute grid and were not used; their slots are treated as missing.")
    if align["collisions"]:
        issues.append(f"{align['collisions']} reading(s) fell in an already-occupied {interval}-minute slot; "
                      "the reading closest to the slot was kept and the others were not used.")
    start_actual = max(start, aligned.index.min()) if len(aligned) else start
    end_actual = min(end_exclusive - pd.Timedelta(minutes=interval), aligned.index.max()) if len(aligned) else start
    grid = (pd.date_range(start_actual, end_actual, freq=f"{interval}min")
            if len(aligned) and start_actual <= end_actual else pd.DatetimeIndex([]))
    frame = aligned.reindex(grid)
    frame.index.name = TIMESTAMP_COL
    for col in (ENERGY_COL, POWER_COL):
        if col not in frame.columns:
            frame[col] = np.nan
    reconstructed_source = frame[RECONSTRUCTED_COL].fillna(False).astype(bool).to_numpy()
    negative = frame[ENERGY_COL].lt(0).to_numpy()
    energy = frame[ENERGY_COL].to_numpy(dtype=float).copy()
    energy[negative] = np.nan
    valid = ~np.isnan(energy)
    reconstructed = valid & reconstructed_source
    energy_observed = valid & ~reconstructed
    values, gap_filled = estimate_short_gaps(energy, interval)
    frame[ENERGY_COL] = values
    frame["_energy_observed"] = energy_observed
    frame["_gap_filled"] = gap_filled
    frame["_reconstructed"] = reconstructed
    frame["_estimated_energy"] = gap_filled | reconstructed
    frame["_energy_unresolved"] = np.isnan(values)
    frame["_energy_negative"] = negative
    frame["_power_observed"] = frame[POWER_COL].notna().to_numpy()
    if TEMP_COL in frame.columns:
        frame["_temp_observed"] = frame[TEMP_COL].notna().to_numpy()
    frame = frame.drop(columns=[RECONSTRUCTED_COL])
    if negative.any():
        issues.append(f"{int(negative.sum())} negative energy reading(s) treated as missing: "
                      f"{int((negative & gap_filled).sum())} estimated under the {MAX_GAP_MINUTES}-minute gap rule, "
                      f"{int((negative & np.isnan(values)).sum())} left unresolved.")
    asset.gap_filled_energy_points = int(gap_filled.sum())
    asset.reconstructed_energy_points = int(reconstructed.sum())
    asset.estimated_energy_points = int((gap_filled | reconstructed).sum())
    asset.unresolved_energy_points = int(np.isnan(values).sum())
    asset.processing_issues = issues
    asset.frame = frame
    return asset


def day_coverage(asset: AssetData, start: Optional[pd.Timestamp] = None, end: Optional[pd.Timestamp] = None) -> pd.DataFrame:
    """Per-day coverage from measured readings (never from the filled grid).

    With start/end (inclusive dates) every calendar day in the range is
    returned, so a day with no readings is "No data" rather than absent.
    Energy counts use the day of the interval each reading covers.
    """

    expected = int(round(24 * 60 / asset.interval_minutes))
    f = asset.frame
    day = f.index.normalize()
    eday = energy_period_day(f.index, asset.interval_minutes)
    has = len(f) > 0
    daily = pd.DataFrame({
        "observed_count": f["_energy_observed"].groupby(eday).sum() if has else pd.Series(dtype=float),
        "estimated_count": f["_estimated_energy"].groupby(eday).sum() if has else pd.Series(dtype=float),
        "reconstructed_count": f["_reconstructed"].groupby(eday).sum() if has else pd.Series(dtype=float),
        "gap_filled_count": f["_gap_filled"].groupby(eday).sum() if has else pd.Series(dtype=float),
        "energy_kwh": f[ENERGY_COL].groupby(eday).sum(min_count=1) if has else pd.Series(dtype=float),
        "power_observed_count": f["_power_observed"].groupby(day).sum() if has else pd.Series(dtype=float),
        "temp_observed_count": f["_temp_observed"].groupby(day).sum() if has and "_temp_observed" in f else np.nan,
        "temperature_c": f[TEMP_COL].groupby(day).mean() if has and TEMP_COL in f else np.nan,
    })
    if start is not None and end is not None:
        daily = daily.reindex(pd.date_range(pd.Timestamp(start).normalize(), pd.Timestamp(end).normalize(), freq="D"))
    for col in ("observed_count", "estimated_count", "reconstructed_count", "gap_filled_count", "power_observed_count"):
        daily[col] = daily[col].fillna(0).astype(int)
    daily["expected_count"] = expected
    daily["unresolved_count"] = (expected - daily["observed_count"] - daily["estimated_count"]).clip(lower=0)
    daily["coverage"] = (daily["observed_count"] / expected).clip(upper=1.0)
    daily["complete"] = daily["coverage"] >= FULL_DAY_COVERAGE
    daily["status"] = np.where(daily["complete"], "Full", np.where(daily["observed_count"] > 0, "Partial", "No data"))
    return daily.rename_axis("date").reset_index()
