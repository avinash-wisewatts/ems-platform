"""EMS loader (A29, A51-A55; T-MAP-1/4/5/6) with the portal reads faked.

The real reads are the existing, separately tested Analytics functions; this
pins how the loader uses them: classification of each 1-minute energy row,
`bucket_start` -> site time with no shift, 14-day chunks without gaps or
duplicates, Power for HVAC assets only, Temperature for catalogue sensors only.
"""

from __future__ import annotations

from datetime import datetime, timedelta, timezone
from zoneinfo import ZoneInfo

import pandas as pd
import pytest

from src.report_engine import ems_loader
from src.report_engine.metrics import RosterEntry
from src.report_engine.prepare import ENERGY_COL, POWER_COL, RECONSTRUCTED_COL, TEMP_COL

KOLKATA = ZoneInfo("Asia/Kolkata")
ROSTER = [RosterEntry("00000000-0000-0000-0000-00000000c0a1", "Chiller1", "HVAC_CHILLERS"), RosterEntry("00000000-0000-0000-0000-00000000c0a2", "Lobby Area AHU-1", "HVAC_AHU", "LOBBY"),
          RosterEntry("00000000-0000-0000-0000-00000000c0a3", "Kitchen GF Walkin Deep", "KITCHEN")]


@pytest.mark.parametrize("row, expected", [
    ({"import_kwh": 1.5, "import_valid_intervals": 1, "import_invalid_intervals": 0, "import_reconstructed_intervals": 0}, (1.5, False)),
    ({"import_kwh": 1.5, "import_valid_intervals": 0, "import_invalid_intervals": 0, "import_reconstructed_intervals": 1}, (1.5, True)),
    ({"import_kwh": 1.5, "import_valid_intervals": 1, "import_invalid_intervals": 0, "import_reconstructed_intervals": 1}, (1.5, True)),
    ({"import_kwh": None, "import_valid_intervals": 0, "import_invalid_intervals": 1, "import_reconstructed_intervals": 0}, (None, False)),
    ({"import_kwh": 0.2, "import_valid_intervals": 0, "import_invalid_intervals": 1, "import_reconstructed_intervals": 0}, (None, False)),
    ({"import_kwh": None, "import_valid_intervals": None, "import_invalid_intervals": None, "import_reconstructed_intervals": None}, (None, False)),
])
def test_energy_classification(row, expected):
    """T-MAP-6: GOOD -> measured, valid reconstructed -> estimated, invalid / unavailable -> missing."""

    assert ems_loader.classify_energy(row) == expected


@pytest.fixture
def fake_reads(monkeypatch):
    calls = {"energy": [], "measurements": []}
    start = datetime(2026, 9, 30, 18, 30, tzinfo=timezone.utc)   # 1-Oct 00:00 IST

    async def as_of():
        return datetime(2026, 11, 2, tzinfo=timezone.utc)

    async def catalog(uid, site_id):
        return [{"asset_id": "00000000-0000-0000-0000-00000000c0a2", "data_point": "TEMPERATURE"}, {"asset_id": "00000000-0000-0000-0000-00000000c0a1", "data_point": "ACTIVE_POWER"}]

    async def energy(uid, site_id, asset_ids, lo, hi, resolution, as_of_):
        calls["energy"].append((str(asset_ids[0]), lo, hi, resolution))
        out, t = [], lo
        while t < hi:
            out.append({"asset_id": str(asset_ids[0]), "bucket_start": t, "import_kwh": 1.0, "import_valid_intervals": 1,
                        "import_invalid_intervals": 0, "import_reconstructed_intervals": 1 if t == start else 0})
            t += timedelta(minutes=1)
        return out

    async def measurements(uid, site_id, asset_id, columns, lo, hi, as_of_):
        calls["measurements"].append((asset_id, [c.data_point for c in columns], lo, hi))
        rows, t = [], lo
        while t < hi:
            rows.append({"bucket_start": t, "series_indexes": list(range(1, len(columns) + 1)), "vals": [5.0] * len(columns)})
            t += timedelta(minutes=1)
        return set(), rows

    monkeypatch.setattr("src.analytics_trends_service.fetch_analytics_as_of", as_of)
    monkeypatch.setattr("src.analytics_trends_service.fetch_analytics_catalog", catalog)
    monkeypatch.setattr("src.analytics_trends_service.fetch_analytics_energy_series", energy)
    monkeypatch.setattr("src.report_export_service.fetch_asset_measurements_1m", measurements)
    return calls, start


async def test_load_period_maps_ems_rows_to_engine_inputs(fake_reads):
    calls, start = fake_reads
    end = start + timedelta(days=31, minutes=1)
    done = []

    async def tick():
        done.append(1)

    result = await ems_loader.load_period(1, "site", KOLKATA, ROSTER, start, end, on_asset_done=tick)
    assert len(done) == 3
    chiller = result.assets["Chiller1"].source_frame
    # bucket_start 30-Sep 18:30 UTC is 1-Oct 00:00 IST, with no shift (E2.4).
    assert chiller.index[0] == pd.Timestamp("2026-10-01 00:00") and chiller.index[-1] == pd.Timestamp("2026-11-01 00:00")
    assert len(chiller) == 31 * 1440 + 1 and not chiller.index.duplicated().any()
    assert bool(chiller[RECONSTRUCTED_COL].iloc[0]) and not chiller[RECONSTRUCTED_COL].iloc[1:].any()
    assert chiller[POWER_COL].notna().all() and TEMP_COL not in chiller.columns
    lobby = result.assets["Lobby Area AHU-1"]
    assert lobby.temperature_monitored and TEMP_COL in lobby.source_frame.columns
    kitchen = result.assets["Kitchen GF Walkin Deep"].source_frame
    assert kitchen[POWER_COL].isna().all() and kitchen[ENERGY_COL].notna().all()
    # Chunks: at most 14 days, contiguous, covering the whole range (T-MAP-5).
    chiller_chunks = [(lo, hi) for a, lo, hi, res in calls["energy"] if a == "00000000-0000-0000-0000-00000000c0a1"]
    assert all(hi - lo <= timedelta(days=14) for lo, hi in chiller_chunks)
    assert chiller_chunks[0][0] == start and chiller_chunks[-1][1] == end
    assert all(a[1] == b[0] for a, b in zip(chiller_chunks, chiller_chunks[1:]))
    assert all(res == "1m" for *_, res in calls["energy"])
    # Power only for HVAC assets, Temperature only for the catalogue's sensor; nothing for the kitchen meter.
    points = {(a, tuple(p)) for a, p, *_ in calls["measurements"]}
    assert points == {("00000000-0000-0000-0000-00000000c0a1", ("ACTIVE_POWER",)), ("00000000-0000-0000-0000-00000000c0a2", ("ACTIVE_POWER", "TEMPERATURE"))}


async def test_completeness_probe_counts_assets_with_final_minutes(fake_reads, monkeypatch):
    end = datetime(2026, 10, 24, 18, 30, tzinfo=timezone.utc)

    async def energy(uid, site_id, asset_ids, lo, hi, resolution, as_of_):
        return [{"asset_id": "00000000-0000-0000-0000-00000000c0a1", "bucket_start": end - timedelta(minutes=2), "import_kwh": 1.0},
                {"asset_id": "00000000-0000-0000-0000-00000000c0a2", "bucket_start": end - timedelta(minutes=40), "import_kwh": 1.0}]

    monkeypatch.setattr("src.analytics_trends_service.fetch_analytics_energy_series", energy)
    assert await ems_loader.final_hour_completeness(1, "site", ROSTER, end) == (1, 3)
