"""Shared helpers for the report engine tests.

* RADISSON_ROSTER / radisson_layout(): the reporting roster WiseWatts enters
  for Radisson Blu Coimbatore (planning package §4.1).
* reference_settings(): the reference tool's settings (24 °C defaults, the
  tool's provisional hours and evidence-based thresholds), as constant
  effective-dated versions.
* load_reference_csv(): TEST-ONLY adapter for the reference tool's exported
  CSV dataset, used to prove the ported engine reproduces the reference
  figures. The dataset is customer telemetry and is NOT committed: tests that
  need it read EMS_REPORT_REFERENCE_DATA (default: the tool's sibling
  folder) and are skipped when it is absent. The product never reads CSV.
* synthetic_assets(): deterministic 1-minute data for CI.
"""

from __future__ import annotations

import os
from datetime import date
from pathlib import Path

import numpy as np
import pandas as pd

from src.report_engine import runtime as rt
from src.report_engine.metrics import Layout, ReportSettings, RosterEntry
from src.report_engine.prepare import (
    ENERGY_COL,
    POWER_COL,
    RECONSTRUCTED_COL,
    TEMP_COL,
    TIMESTAMP_COL,
    AssetData,
    asset_from_frame,
)

ALWAYS = pd.Timestamp.min

RADISSON_ROSTER = [
    ("Chiller1", "HVAC_CHILLERS", None), ("Chiller2", "HVAC_CHILLERS", None),
    ("Primary Pump-1", "HVAC_PUMPS", None), ("Primary Pump-2", "HVAC_PUMPS", None),
    ("Condenser Pump-1", "HVAC_PUMPS", None), ("Condenser Pump 2", "HVAC_PUMPS", None),
    ("CoolingTower1", "HVAC_COOLING_TOWERS", None), ("CoolingTower2", "HVAC_COOLING_TOWERS", None),
    ("Lobby Area AHU-1", "HVAC_AHU", "LOBBY"), ("Lobby Area AHU-2", "HVAC_AHU", "LOBBY"),
    ("Seasons Restaurant AHU-1", "HVAC_AHU", "RESTAURANT"), ("Seasons Restaurant AHU-2", "HVAC_AHU", "RESTAURANT"),
    ("Banquet 1 AHU", "HVAC_AHU", "BANQUET_1"), ("Banquet 2 AHU", "HVAC_AHU", "BANQUET_2"),
    ("Pre Function Area AHU", "HVAC_AHU", "PRE_FUNCTION"),
    ("Kitchen GF Cold Serving Area", "KITCHEN", None), ("Kitchen GF Hot Food PickUp Ctr", "KITCHEN", None),
    ("Kitchen GF Induction Ctr Tops", "KITCHEN", None), ("Kitchen GF Sandwich Toaster", "KITCHEN", None),
    ("Kitchen GF Under Counter Freezers", "KITCHEN", None), ("Kitchen GF Walkin Deep", "KITCHEN", None),
    ("Kitchen GF WalkIn Freezer Fruits", "KITCHEN", None), ("Kitchen GF WalkIn Freezer", "KITCHEN", None),
]
TEMPERATURE_SENSORS = ("Lobby Area AHU-1", "Seasons Restaurant AHU-1", "Seasons Restaurant AHU-2", "Banquet 2 AHU")
HVAC = [n for n, g, _ in RADISSON_ROSTER if g != "KITCHEN"]
KITCHEN = [n for n, g, _ in RADISSON_ROSTER if g == "KITCHEN"]
AHUS = [n for n, g, _ in RADISSON_ROSTER if g == "HVAC_AHU"]
# Set EMS_REPORT_REFERENCE_DATA to the reference CSV folder to run the
# reference reproduction tests; unset (CI), they are skipped.
REFERENCE_DATA = Path(os.environ.get("EMS_REPORT_REFERENCE_DATA", "/nonexistent-reference-data"))


def radisson_layout() -> Layout:
    return Layout([RosterEntry(asset_id=f"asset-{i}", name=n, report_group=g, area=a, display_order=i)
                   for i, (n, g, a) in enumerate(RADISSON_ROSTER)])


def reference_settings(lobby: float = 24.0, restaurant: float = 24.0, banquet: float = 24.0) -> ReportSettings:
    setpoints = {}
    for name in TEMPERATURE_SENSORS + ("Lobby Area AHU-2", "Banquet 1 AHU"):
        value = lobby if "Lobby" in name else restaurant if "Restaurant" in name else banquet
        setpoints[name] = [(ALWAYS, value)]
    return ReportSettings(
        setpoints=setpoints,
        schedules={n: [(ALWAYS, s)] for n, s in rt.REFERENCE_SCHEDULES.items()},
        schedule_confirmed={n: [(ALWAYS, False)] for n in AHUS},
        thresholds={n: [(ALWAYS, s)] for n, s in rt.REFERENCE_THRESHOLDS.items()},
    )


def _parse_local_timestamps(series: pd.Series) -> pd.Series:
    """The reference tool's parse_local_timestamps: ISO or day-first, never ambiguous."""

    text = series.astype("string").str.strip()
    result = pd.Series(pd.NaT, index=series.index, dtype="datetime64[ns]")
    iso = text.str.match(r"^\d{4}-\d{1,2}-\d{1,2}", na=False)
    if iso.any():
        result.loc[iso] = pd.to_datetime(text.loc[iso], errors="coerce", format="ISO8601")
    other = ~iso
    if other.any():
        result.loc[other] = pd.to_datetime(text.loc[other], errors="coerce", dayfirst=True, format="mixed")
    return result


def load_reference_csv(folder: Path = REFERENCE_DATA) -> dict[str, AssetData]:
    """The reference tool's CSV dataset as AssetData (test-only adapter)."""

    assets = {}
    for name, _, _ in RADISSON_ROSTER:
        raw = pd.read_csv(folder / f"{name}.csv", low_memory=False)
        frame = pd.DataFrame({
            TIMESTAMP_COL: _parse_local_timestamps(raw["Timestamp (Site Local)"]),
            ENERGY_COL: pd.to_numeric(raw["Energy (kWh)"], errors="coerce"),
            POWER_COL: pd.to_numeric(raw["Power (kW)"], errors="coerce"),
        })
        if "Temperature (degC)" in raw.columns:
            frame[TEMP_COL] = pd.to_numeric(raw["Temperature (degC)"], errors="coerce")
        assets[name] = asset_from_frame(name, frame, source=f"{name}.csv")
    return assets


def synthetic_assets(start: date, days: int, *, seed: int = 7, drop: dict[str, list[tuple[str, str]]] | None = None,
                     reconstructed: dict[str, list[tuple[str, str]]] | None = None,
                     closing_reading: bool = True) -> dict[str, AssetData]:
    """Deterministic 1-minute readings for every roster asset over `days` days
    from `start` (labels start+1min .. end 00:00 when closing_reading).

    drop: name -> [(from, to)] label ranges with no reading at all;
    reconstructed: name -> [(from, to)] ranges whose energy is EMS-reconstructed.
    """

    rng = np.random.default_rng(seed)
    first = pd.Timestamp(start)
    last = first + pd.Timedelta(days=days) - (pd.Timedelta(0) if closing_reading else pd.Timedelta(minutes=1))
    index = pd.date_range(first, last, freq="1min")
    hours = index.hour.to_numpy() + index.minute.to_numpy() / 60
    day_factor = 0.6 + 0.4 * np.sin((hours - 6) / 24 * 2 * np.pi).clip(0)
    assets = {}
    for i, (name, group, _area) in enumerate(RADISSON_ROSTER):
        base = {"HVAC_CHILLERS": 100.0, "HVAC_PUMPS": 25.0, "HVAC_COOLING_TOWERS": 3.0,
                "HVAC_AHU": 0.9, "KITCHEN": 0.8}[group]
        power = base * day_factor * (1 + 0.05 * rng.standard_normal(len(index)))
        if group == "HVAC_AHU":
            on = (hours >= 6) & (hours < 22)
            power = np.where(on, power, 0.006)
        frame = pd.DataFrame({TIMESTAMP_COL: index, ENERGY_COL: power / 60, POWER_COL: power})
        if name in TEMPERATURE_SENSORS:
            frame[TEMP_COL] = 24.5 + 1.2 * np.sin(hours / 24 * 2 * np.pi) + 0.2 * rng.standard_normal(len(index))
        frame[RECONSTRUCTED_COL] = False
        for lo, hi in (reconstructed or {}).get(name, []):
            mask = (frame[TIMESTAMP_COL] >= pd.Timestamp(lo)) & (frame[TIMESTAMP_COL] <= pd.Timestamp(hi))
            frame.loc[mask, RECONSTRUCTED_COL] = True
        for lo, hi in (drop or {}).get(name, []):
            mask = (frame[TIMESTAMP_COL] >= pd.Timestamp(lo)) & (frame[TIMESTAMP_COL] <= pd.Timestamp(hi))
            frame = frame.loc[~mask]
        assets[name] = asset_from_frame(name, frame, temperature_monitored=name in TEMPERATURE_SENSORS)
    return assets
