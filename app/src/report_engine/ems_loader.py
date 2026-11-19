"""EMS data loader: the report's readings come from EMS, never from files
(A29, A30, A51-A55; planning package §4; evidence E2).

Sources (the same portal-scoped Analytics reads the Analytics page and the
Reports export use, evaluated for the read identity -- the dedicated
automation account or the requesting WiseWatts Admin, A88-A90):

  Energy (kWh)         analytics.get_portal_asset_energy_series(..., '1m') -> import_kwh
  Power (kW)           analytics.get_portal_asset_measurements_1m  ACTIVE_POWER / TOTAL
  Temperature (degC)   analytics.get_portal_asset_measurements_1m  TEMPERATURE (catalogue sensors only)

Timestamps: `bucket_start` converted to the site timezone WITHOUT shifting
(E2.4: EMS labels a minute exactly as Eniscope does, at the end of the
metered minute).

Energy reading classes (A51-A55):
  MEASURED       import_kwh present, valid intervals, no reconstruction
  RECONSTRUCTED  import_kwh present and EMS reconstructed the interval
                 -> included in energy, counted as ESTIMATED (never measured)
  MISSING        no value, or only invalid intervals -> the engine's existing
                 <= 30-minute gap rule may estimate it, nothing else
Temperature is never filled (A16).

Reads are bounded: one asset per call and at most 14 days per call (the
1-minute measurement read refuses more than 15). Power is read for the HVAC
assets only (peak demand), Temperature for the catalogue's sensors only;
kitchen assets need Energy only. `on_asset_done` is awaited after each asset
(lease extension and worker heartbeat).
"""

from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from typing import Any, Awaitable, Callable, Optional
from uuid import UUID
from zoneinfo import ZoneInfo

import pandas as pd

from src.report_engine.metrics import GROUP_LABELS, RosterEntry
from src.report_engine.prepare import (
    ENERGY_COL,
    POWER_COL,
    RECONSTRUCTED_COL,
    TEMP_COL,
    TIMESTAMP_COL,
    AssetData,
    asset_from_frame,
)

CHUNK = timedelta(days=14)
TEMPERATURE_POINT = "TEMPERATURE"
POWER_POINT = ("ACTIVE_POWER", "TOTAL")


class RetentionExceededError(Exception):
    """EMS no longer holds the 1-minute data the period needs (A71, §4.4)."""


@dataclass
class LoadResult:
    assets: dict[str, AssetData]
    temperature_assets: set[str]
    reconstructed_minutes: int


def classify_energy(row: dict[str, Any]) -> tuple[Optional[float], bool]:
    """(value or None, reconstructed) for one 1-minute energy row."""

    value = row.get("import_kwh")
    if value is None:
        return None, False
    valid = int(row.get("import_valid_intervals") or 0)
    invalid = int(row.get("import_invalid_intervals") or 0)
    reconstructed = int(row.get("import_reconstructed_intervals") or 0)
    if reconstructed > 0:
        return float(value), True
    if valid <= 0 and invalid > 0:
        return None, False
    if valid <= 0:
        return None, False
    return float(value), False


def _chunks(start: datetime, end: datetime) -> list[tuple[datetime, datetime]]:
    out = []
    cursor = start
    while cursor < end:
        nxt = min(cursor + CHUNK, end)
        out.append((cursor, nxt))
        cursor = nxt
    return out


def _local(ts: datetime, zone: ZoneInfo) -> pd.Timestamp:
    return pd.Timestamp(ts.astimezone(zone).replace(tzinfo=None))


async def check_retention(site_id: UUID, start_utc: datetime, as_of: datetime, *, needs_measurements: bool = True) -> None:
    """RetentionExceededError when the period starts before a 1-minute floor."""

    from src.analytics_trends_service import (
        fetch_analytics_energy_resolution_floors,
        fetch_analytics_point_resolution_floors,
    )

    energy_floor = (await fetch_analytics_energy_resolution_floors(site_id, as_of)).get("1m")
    if energy_floor is not None and start_utc < energy_floor:
        raise RetentionExceededError("EMS no longer holds the 1-minute energy data needed for this period.")
    if needs_measurements:
        point_floor = (await fetch_analytics_point_resolution_floors(as_of)).get("mean", {}).get("1m")
        if point_floor is not None and start_utc < point_floor:
            raise RetentionExceededError("EMS no longer holds the 1-minute power and temperature data needed for this period.")


async def temperature_assets(portal_user_id: int, site_id: UUID, asset_ids: set[str]) -> set[str]:
    """Asset ids whose EMS catalogue has a TEMPERATURE point (A15)."""

    from src.analytics_trends_service import fetch_analytics_catalog

    rows = await fetch_analytics_catalog(portal_user_id, site_id)
    return {str(r["asset_id"]) for r in rows if r.get("data_point") == TEMPERATURE_POINT and str(r["asset_id"]) in asset_ids}


async def load_period(portal_user_id: int, site_id: UUID, zone: ZoneInfo, roster: list[RosterEntry],
                      start_utc: datetime, end_utc: datetime,
                      on_asset_done: Optional[Callable[[], Awaitable[None]]] = None) -> LoadResult:
    """Every roster asset's readings over [start_utc, end_utc) as AssetData."""

    from src.analytics_trends_service import fetch_analytics_as_of, fetch_analytics_energy_series
    from src.report_export_service import MeasurementColumn, fetch_asset_measurements_1m

    as_of = await fetch_analytics_as_of()
    sensors = await temperature_assets(portal_user_id, site_id, {e.asset_id for e in roster})
    assets: dict[str, AssetData] = {}
    reconstructed_total = 0
    hvac_groups = set(GROUP_LABELS)
    for entry in roster:
        maps = _Maps()
        columns: list = []
        if entry.report_group in hvac_groups:
            columns.append(MeasurementColumn(POWER_POINT[0], POWER_POINT[1], POWER_COL))
        if entry.asset_id in sensors:
            columns.append(MeasurementColumn(TEMPERATURE_POINT, None, TEMP_COL))
        headers = [c.header for c in columns]
        for lo, hi in _chunks(start_utc, end_utc):   # each chunk is folded into compact maps, then released
            maps.add_energy(await fetch_analytics_energy_series(portal_user_id, site_id, [UUID(entry.asset_id)],
                                                                lo, hi, "1m", as_of), zone)
            if columns:
                _registers, minutes = await fetch_asset_measurements_1m(
                    portal_user_id, site_id, entry.asset_id, columns, lo, hi, as_of)
                maps.add_minutes(minutes, headers, zone)
        asset = maps.asset(entry.name, temperature_monitored=entry.asset_id in sensors)
        reconstructed_total += asset.reconstructed_source_minutes
        assets[entry.name] = asset
        if on_asset_done is not None:
            await on_asset_done()
    return LoadResult(assets=assets, temperature_assets=sensors, reconstructed_minutes=reconstructed_total)



class _Maps:
    """Compact per-minute values of one asset (site-local timestamps)."""

    def __init__(self) -> None:
        self.energy: dict[pd.Timestamp, tuple[Optional[float], bool]] = {}
        self.power: dict[pd.Timestamp, float] = {}
        self.temperature: dict[pd.Timestamp, float] = {}

    def add_energy(self, rows: list[dict[str, Any]], zone: ZoneInfo) -> None:
        for row in rows:
            if row.get("bucket_start") is not None:
                self.energy[_local(row["bucket_start"], zone)] = classify_energy(row)

    def add_minutes(self, rows: list[dict[str, Any]], headers: list[str], zone: ZoneInfo) -> None:
        for row in rows:
            if row.get("bucket_start") is None:
                continue
            stamp = _local(row["bucket_start"], zone)
            for index, value in zip(row.get("series_indexes") or [], row.get("vals") or []):
                if value is not None:
                    (self.power if headers[int(index) - 1] == POWER_COL else self.temperature)[stamp] = float(value)

    def asset(self, name: str, *, temperature_monitored: bool) -> AssetData:
        stamps = sorted(set(self.energy) | set(self.power) | set(self.temperature))
        frame = pd.DataFrame({
            TIMESTAMP_COL: pd.DatetimeIndex(stamps),
            ENERGY_COL: [self.energy.get(t, (None, False))[0] for t in stamps],
            POWER_COL: [self.power.get(t) for t in stamps],
            RECONSTRUCTED_COL: [self.energy.get(t, (None, False))[1] for t in stamps],
        })
        if temperature_monitored:
            frame[TEMP_COL] = [self.temperature.get(t) for t in stamps]
        asset = asset_from_frame(name, frame, source="EMS", temperature_monitored=temperature_monitored)
        if not stamps:   # no readings at all: an empty 1-minute asset (identified as missing)
            asset.interval_minutes = 1
        asset.reconstructed_source_minutes = int(frame[RECONSTRUCTED_COL].sum()) if stamps else 0
        return asset


def asset_from_rows(name: str, energy_rows: list[dict[str, Any]], minute_rows: list[dict[str, Any]],
                    headers: list[str], zone: ZoneInfo, *, temperature_monitored: bool) -> AssetData:
    """AssetData from the portal reads' rows (energy rows; 1-minute measurement
    rows whose index i maps to headers[i - 1]) -- the loader's own mapping."""

    maps = _Maps()
    maps.add_energy(energy_rows, zone)
    maps.add_minutes(minute_rows, headers, zone)
    return maps.asset(name, temperature_monitored=temperature_monitored)


async def final_hour_completeness(portal_user_id: int, site_id: UUID, roster: list[RosterEntry],
                                  period_end_utc: datetime) -> tuple[int, int]:
    """(assets with an energy value in the period's final 15 minutes, roster size):
    the completeness probe of A64/A65 (cheap: 60 minutes per asset)."""

    from src.analytics_trends_service import fetch_analytics_as_of, fetch_analytics_energy_series

    as_of = await fetch_analytics_as_of()
    lo = period_end_utc - timedelta(minutes=60)
    hi = period_end_utc + timedelta(minutes=1)
    rows = await fetch_analytics_energy_series(portal_user_id, site_id, [UUID(e.asset_id) for e in roster],
                                               lo, hi, "1m", as_of)
    recent: set[str] = set()
    cutoff = period_end_utc - timedelta(minutes=15)
    for row in rows:
        start = row.get("bucket_start")
        if start is not None and row.get("import_kwh") is not None and start >= cutoff:
            recent.add(str(row["asset_id"]))
    return len(recent), len(roster)


def utc(ts: datetime) -> datetime:
    return ts.astimezone(timezone.utc)
