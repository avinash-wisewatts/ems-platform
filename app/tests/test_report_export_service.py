"""Reports tab -- export request validation, columns, timestamps, CSV
escaping, missing readings, assets without data, asset separation and ZIP
contents (report_export_service.py). The Analytics fetchers are faked
(tests/report_export_fixtures.py); their database reads are covered by the
Analytics read tests.
"""

from __future__ import annotations

import csv
import io
import zipfile
from datetime import datetime, timedelta, timezone
from uuid import UUID

import pytest

from src.analytics_api_service import ApiContractError
from src.report_export_service import (
    TIMESTAMP_LOCAL_HEADER,
    TIMESTAMP_UTC_HEADER,
    AssetTable,
    ExportRequest,
    UniqueNames,
    asset_csv,
    build_export_zip,
    build_job,
    estimate_export,
    export_file_name,
    export_mode,
    format_value,
    parse_export_request,
    prepare_export,
    safe_file_stem,
    site_zone,
)
from tests.report_export_fixtures import (
    ASSET_A,
    ASSET_B,
    CATALOG,
    SITE,
    SITE_ASSETS,
    SITE_ID,
    T0,
    FakeAnalytics,
    value_for,
)


def _zip_tables(content: bytes) -> dict[str, list[list[str]]]:
    with zipfile.ZipFile(io.BytesIO(content)) as archive:
        assert archive.testzip() is None
        return {
            name: list(csv.reader(io.StringIO(archive.read(name).decode("utf-8-sig"))))
            for name in archive.namelist()
        }


async def _export(monkeypatch, fake: FakeAnalytics, *, hours: int = 3, resolution: str = "1h"):
    fake.install(monkeypatch)
    request = ExportRequest(T0, T0 + timedelta(hours=hours), resolution, resolution)
    ctx = await prepare_export(500, UUID(SITE_ID), request)
    assert ctx is not None
    return await build_export_zip(500, UUID(SITE_ID), ctx)


# --- request validation --------------------------------------------------------

def test_auto_resolution_follows_the_analytics_window_rule() -> None:
    assert parse_export_request(range_from="2026-09-20T00:00:00Z", range_to="2026-09-22T00:00:00Z", resolution=None).resolution == "15m"
    assert parse_export_request(range_from="2026-09-01T00:00:00Z", range_to="2026-09-20T00:00:00Z", resolution="auto").resolution == "1h"
    assert parse_export_request(range_from="2026-01-01T00:00:00Z", range_to="2026-09-20T00:00:00Z", resolution="auto").resolution == "1d"


@pytest.mark.parametrize(
    ("range_from", "range_to", "resolution", "code"),
    [
        ("2026-09-20T00:00:00Z", "2026-09-20T00:00:00Z", "1h", "invalid_time_range"),
        ("2026-09-21T00:00:00Z", "2026-09-20T00:00:00Z", "1h", "invalid_time_range"),
        ("2026-09-01T00:00:00Z", "2026-09-05T00:00:00Z", "1m", "time_range_too_large"),
        ("2026-09-20T00:00:00Z", "2026-09-21T00:00:00Z", "5m", "invalid_resolution"),
        ("yesterday", "2026-09-21T00:00:00Z", "1h", "invalid_time_range"),
    ],
)
def test_invalid_requests_are_rejected_before_any_read(range_from, range_to, resolution, code) -> None:
    with pytest.raises(ApiContractError) as exc:
        parse_export_request(range_from=range_from, range_to=range_to, resolution=resolution)
    assert exc.value.code == code


def test_estimate_counts_system_and_phase_columns_per_asset() -> None:
    request = ExportRequest(T0, T0 + timedelta(days=1), "1h", "1h")
    estimate = estimate_export(request, SITE_ASSETS, CATALOG)
    # A: Energy, Power, Power L1-L3, Voltage = 6; B: Energy, Frequency = 2; C: none.
    assert (estimate.asset_count, estimate.column_count, estimate.bucket_count) == (3, 8, 24)
    assert estimate.cells == 192


def test_export_mode_thresholds() -> None:
    assert export_mode(100, immediate_max_cells=100, max_cells=1000) == "immediate"
    assert export_mode(101, immediate_max_cells=100, max_cells=1000) == "background"
    assert export_mode(1001, immediate_max_cells=100, max_cells=1000) == "too_large"


# --- ZIP / CSV contents --------------------------------------------------------

async def test_zip_has_one_csv_per_site_asset_named_by_asset(monkeypatch) -> None:
    result = await _export(monkeypatch, FakeAnalytics())
    tables = _zip_tables(result.content)
    assert sorted(tables) == ["AHU 2.csv", "Chiller_1.csv", "Spare Pump.csv"]
    assert result.asset_count == 3
    assert result.file_name == "Coimbatore, Plant _1__20260920-0530_20260920-0830_1h.zip"


async def test_csv_columns_timestamps_and_values(monkeypatch) -> None:
    tables = _zip_tables((await _export(monkeypatch, FakeAnalytics())).content)
    chiller = tables["Chiller_1.csv"]
    assert chiller[0] == [
        TIMESTAMP_UTC_HEADER, TIMESTAMP_LOCAL_HEADER,
        "Energy (kWh)", "Power (kW)", "Power L1 (kW)", "Power L2 (kW)", "Power L3 (kW)", "Voltage (V)",
    ]
    assert [row[:2] for row in chiller[1:]] == [
        ["2026-09-20 00:00:00", "2026-09-20 05:30:00"],
        ["2026-09-20 01:00:00", "2026-09-20 06:30:00"],
        ["2026-09-20 02:00:00", "2026-09-20 07:30:00"],
    ]
    first = chiller[1]
    assert first[2] == format_value(value_for(ASSET_A, "ENERGY_IMPORT", "TOTAL", 0))
    assert first[4] == format_value(value_for(ASSET_A, "ACTIVE_POWER", "L1", 0))
    assert first[7] == format_value(value_for(ASSET_A, "VOLTAGE_LINE_NEUTRAL", "AVG", 0))


async def test_assets_are_separated(monkeypatch) -> None:
    tables = _zip_tables((await _export(monkeypatch, FakeAnalytics())).content)
    ahu = tables["AHU 2.csv"]
    assert ahu[0][2:] == ["Energy (kWh)", "Frequency (Hz)"]
    for row in ahu[1:]:
        assert all(2000 <= float(v) < 3000 for v in row[2:])
    for row in tables["Chiller_1.csv"][1:]:
        assert all(1000 <= float(v) < 2000 for v in row[2:])


async def test_missing_readings_are_empty_cells(monkeypatch) -> None:
    fake = FakeAnalytics(missing={(ASSET_A, "ACTIVE_POWER", "L2", 1), (ASSET_A, "ENERGY_IMPORT", "TOTAL", 2)})
    chiller = _zip_tables((await _export(monkeypatch, fake)).content)["Chiller_1.csv"]
    assert chiller[2][5] == "" and chiller[2][4] != ""
    assert chiller[3][2] == "" and chiller[3][3] != ""


async def test_asset_with_no_data_is_a_header_only_csv(monkeypatch) -> None:
    tables = _zip_tables((await _export(monkeypatch, FakeAnalytics())).content)
    assert tables["Spare Pump.csv"] == [[TIMESTAMP_UTC_HEADER, TIMESTAMP_LOCAL_HEADER]]


async def test_asset_with_assignments_but_no_readings_in_range_is_header_only(monkeypatch) -> None:
    missing = {(ASSET_B, p, q, h) for p, q in (("ENERGY_IMPORT", "TOTAL"), ("FREQUENCY", None)) for h in range(3)}
    ahu = _zip_tables((await _export(monkeypatch, FakeAnalytics(missing=missing))).content)["AHU 2.csv"]
    assert ahu == [[TIMESTAMP_UTC_HEADER, TIMESTAMP_LOCAL_HEADER, "Energy (kWh)", "Frequency (Hz)"]]


async def test_every_read_uses_the_requested_range_and_portal_user(monkeypatch) -> None:
    fake = FakeAnalytics()
    await _export(monkeypatch, fake, hours=2)
    reads = [args for kind, args in fake.calls if kind in ("energy", "points")]
    assert reads
    for args in reads:
        assert args[0] == 500
        assert (args[-3], args[-2], args[-1]) == (T0, T0 + timedelta(hours=2), "1h")
    # No read for the asset without data points, and per-asset reads never mix assets.
    for kind, args in fake.calls:
        if kind == "points":
            assert len({a for a, _, _ in args[1]}) == 1
        if kind == "energy":
            assert len(args[1]) == 1
    assert all("cccccccc" not in str(args) for kind, args in fake.calls if kind in ("energy", "points"))


async def test_inaccessible_site_prepares_nothing(monkeypatch) -> None:
    fake = FakeAnalytics(accessible=False)
    fake.install(monkeypatch)
    request = ExportRequest(T0, T0 + timedelta(hours=3), "1h", "1h")
    assert await prepare_export(500, UUID(SITE_ID), request) is None
    assert not [c for c in fake.calls if c[0] in ("energy", "points")]


async def test_one_minute_export_keeps_measurement_phases(monkeypatch) -> None:
    fake = FakeAnalytics()
    fake.install(monkeypatch)
    request = ExportRequest(T0, T0 + timedelta(hours=1), "1m", "1m")
    ctx = await prepare_export(500, UUID(SITE_ID), request)
    result = await build_export_zip(500, UUID(SITE_ID), ctx)
    assert "Power L1 (kW)" in _zip_tables(result.content)["Chiller_1.csv"][0]


# --- CSV escaping, timestamps, names --------------------------------------------

def test_csv_escapes_commas_quotes_newlines_and_formulas() -> None:
    table = AssetTable(
        asset_id="x", asset_name="x",
        headers=['Power, "net" (kW)', "=HYPERLINK(1)", "line\nbreak"],
        rows={T0: [1.5, None, -0.0000001]},
        has_data=True,
    )
    text = asset_csv(table, timezone.utc)
    parsed = list(csv.reader(io.StringIO(text)))
    assert parsed[0][2:] == ['Power, "net" (kW)', "'=HYPERLINK(1)", "line\nbreak"]
    assert parsed[1] == ["2026-09-20 00:00:00", "2026-09-20 00:00:00", "1.5", "", "0"]
    assert text.endswith("\r\n")


def test_site_local_timestamps_follow_daylight_saving() -> None:
    zone = site_zone("Europe/London")
    table = AssetTable(
        asset_id="x", asset_name="x", headers=["Power (kW)"],
        rows={
            datetime(2026, 10, 25, 0, 30, tzinfo=timezone.utc): [1.0],   # BST (+01:00)
            datetime(2026, 10, 25, 1, 30, tzinfo=timezone.utc): [2.0],   # GMT (+00:00), after the change
        },
        has_data=True,
    )
    rows = list(csv.reader(io.StringIO(asset_csv(table, zone))))[1:]
    assert [r[:2] for r in rows] == [
        ["2026-10-25 00:30:00", "2026-10-25 01:30:00"],
        ["2026-10-25 01:30:00", "2026-10-25 01:30:00"],
    ]


def test_unknown_or_missing_site_timezone_falls_back_to_utc() -> None:
    assert site_zone(None) is timezone.utc
    assert site_zone("Not/AZone") is timezone.utc


@pytest.mark.parametrize(
    ("name", "stem"),
    [
        ("Chiller/1", "Chiller_1"),
        ('AHU: "North" <2>', "AHU_ _North_ _2_"),
        ("..\\..\\etc\\passwd", "_.._etc_passwd"),
        ("   ", "asset"),
        ("CON", "CON_asset"),
        ("x" * 150, "x" * 100),
    ],
)
def test_safe_file_stem(name, stem) -> None:
    assert safe_file_stem(name) == stem


def test_duplicate_asset_names_get_numbered_case_insensitively() -> None:
    names = UniqueNames()
    assert [names.claim(s, ".csv") for s in ("Pump", "pump", "Pump")] == ["Pump.csv", "pump (2).csv", "Pump (3).csv"]


def test_export_file_name_uses_site_local_range() -> None:
    request = ExportRequest(T0, T0 + timedelta(days=1), "auto", "1h")
    assert export_file_name(SITE, request) == "Coimbatore, Plant _1__20260920-0530_20260921-0530_1h.zip"


# --- job model ------------------------------------------------------------------

def _job_row(**overrides):
    row = {
        "id": UUID("99999999-9999-4999-8999-999999999999"), "site_id": UUID(SITE_ID),
        "range_from": T0, "range_to": T0 + timedelta(days=1), "requested_resolution": "auto",
        "resolution": "1h", "status": "COMPLETED", "attempts": 1, "error_code": None, "error_message": None,
        "created_at": T0, "started_at": T0, "completed_at": T0, "expires_at": T0 + timedelta(hours=24),
        "file_name": "a.zip", "file_size_bytes": 10, "asset_count": 3, "row_count": 72,
    }
    row.update(overrides)
    return row


def test_download_url_only_while_completed_and_unexpired() -> None:
    now = T0 + timedelta(hours=1)
    assert build_job(_job_row(), now=now).download_url == "/api/v1/report-exports/99999999-9999-4999-8999-999999999999/file"
    assert build_job(_job_row(expires_at=T0), now=now).download_url is None
    assert build_job(_job_row(status="FAILED", expires_at=None), now=now).download_url is None
    assert build_job(_job_row(status="PROCESSING", expires_at=None), now=now).status_label == "Processing"
