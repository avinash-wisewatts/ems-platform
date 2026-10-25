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
        # An export serves 1 minute for up to 14 days (the Analytics page: 3).
        ("2026-09-01T00:00:00Z", "2026-09-15T00:01:00Z", "1m", "time_range_too_large"),
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
    # A: Energy, Power, Power L1-L3, Voltage + Apparent Power, Current NEUTRAL = 8;
    # B: Energy, Frequency + Temperature, Humidity, Occupancy, Illuminance = 6; C: none.
    assert (estimate.asset_count, estimate.column_count, estimate.bucket_count) == (3, 14, 24)
    assert estimate.cells == 336


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
        "Apparent Power (kVA)", "Current NEUTRAL (A)",
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
    assert ahu[0][2:] == [
        "Energy (kWh)", "Frequency (Hz)",
        "Relative Humidity (%)", "Illuminance (lux)", "Occupancy Activity", "Temperature (degC)",
    ]
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
    points = (("ENERGY_IMPORT", "TOTAL"), ("FREQUENCY", None), ("TEMPERATURE", None), ("HUMIDITY", None),
              ("OCCUPANCY_ACTIVITY", None), ("ILLUMINANCE", None))
    missing = {(ASSET_B, p, q, h) for p, q in points for h in range(3)}
    ahu = _zip_tables((await _export(monkeypatch, FakeAnalytics(missing=missing))).content)["AHU 2.csv"]
    assert ahu == [[
        TIMESTAMP_UTC_HEADER, TIMESTAMP_LOCAL_HEADER, "Energy (kWh)", "Frequency (Hz)",
        "Relative Humidity (%)", "Illuminance (lux)", "Occupancy Activity", "Temperature (degC)",
    ]]


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


# --- every confirmed catalogue point, not only the Analytics chart registry ----

async def test_environmental_and_occupancy_points_are_exported_with_their_values(monkeypatch) -> None:
    ahu = _zip_tables((await _export(monkeypatch, FakeAnalytics())).content)["AHU 2.csv"]
    header = ahu[0]
    for hour, row in enumerate(ahu[1:]):
        cell = dict(zip(header, row))
        assert cell["Temperature (degC)"] == format_value(value_for(ASSET_B, "TEMPERATURE", None, hour))
        assert cell["Relative Humidity (%)"] == format_value(value_for(ASSET_B, "HUMIDITY", None, hour))
        assert cell["Occupancy Activity"] == format_value(value_for(ASSET_B, "OCCUPANCY_ACTIVITY", None, hour))
        assert cell["Illuminance (lux)"] == format_value(value_for(ASSET_B, "ILLUMINANCE", None, hour))
        # Existing electrical columns are unchanged alongside them.
        assert cell["Energy (kWh)"] == format_value(value_for(ASSET_B, "ENERGY_IMPORT", "TOTAL", hour))
        assert cell["Frequency (Hz)"] == format_value(value_for(ASSET_B, "FREQUENCY", None, hour))


async def test_non_registry_points_are_read_through_the_portal_series_for_their_own_asset(monkeypatch) -> None:
    fake = FakeAnalytics()
    await _export(monkeypatch, fake)
    specs = [spec for kind, args in fake.calls if kind == "points" for spec in args[1]]
    assert (ASSET_B, "TEMPERATURE", None) in specs
    assert (ASSET_B, "OCCUPANCY_ACTIVITY", None) in specs
    assert (ASSET_A, "CURRENT", "NEUTRAL") in specs
    # Only the asset's own confirmed points: never another asset's sensors.
    assert (ASSET_A, "TEMPERATURE", None) not in specs
    assert (ASSET_B, "APPARENT_POWER", "TOTAL") not in specs
    assert all(args[0] == 500 for kind, args in fake.calls if kind == "points")


async def test_missing_environmental_readings_stay_empty_never_zero(monkeypatch) -> None:
    fake = FakeAnalytics(missing={(ASSET_B, "TEMPERATURE", None, 1), (ASSET_B, "OCCUPANCY_ACTIVITY", None, 2)})
    ahu = _zip_tables((await _export(monkeypatch, fake)).content)["AHU 2.csv"]
    header = ahu[0]
    assert ahu[2][header.index("Temperature (degC)")] == ""
    assert ahu[3][header.index("Occupancy Activity")] == ""
    assert ahu[3][header.index("Temperature (degC)")] != ""


async def test_a_point_the_read_reports_unavailable_is_an_empty_column(monkeypatch) -> None:
    fake = FakeAnalytics(unavailable={(ASSET_B, "ILLUMINANCE", None)})
    ahu = _zip_tables((await _export(monkeypatch, fake)).content)["AHU 2.csv"]
    column = ahu[0].index("Illuminance (lux)")
    assert [row[column] for row in ahu[1:]] == ["", "", ""]
    assert all(row[ahu[0].index("Temperature (degC)")] for row in ahu[1:])


async def test_one_minute_export_has_no_per_phase_energy_columns(monkeypatch) -> None:
    from tests.report_export_fixtures import catalog_row

    catalog = CATALOG + [catalog_row(ASSET_A, "Chiller/1", "ENERGY_IMPORT", q) for q in ("L1", "L2", "L3")]
    fake = FakeAnalytics()

    async def with_phases(portal_user_id, site_id):
        return list(catalog)

    fake.catalog = with_phases
    fake.install(monkeypatch)
    ctx = await prepare_export(500, UUID(SITE_ID), ExportRequest(T0, T0 + timedelta(hours=1), "1m", "1m"))
    header = _zip_tables((await build_export_zip(500, UUID(SITE_ID), ctx)).content)["Chiller_1.csv"][0]
    assert not any("L1 (kWh)" in h or h.startswith("ENERGY_IMPORT") for h in header)
    ctx = await prepare_export(500, UUID(SITE_ID), ExportRequest(T0, T0 + timedelta(hours=1), "15m", "15m"))
    header = _zip_tables((await build_export_zip(500, UUID(SITE_ID), ctx)).content)["Chiller_1.csv"][0]
    assert {"Energy L1 (kWh)", "Energy L2 (kWh)", "Energy L3 (kWh)"} <= set(header)


def test_duplicate_headers_are_disambiguated() -> None:
    from src.report_export_service import _unique_headers

    assert _unique_headers(["Voltage (V)", "voltage (V)", "Power (kW)"]) == ["Voltage (V)", "voltage (V) (2)", "Power (kW)"]


# --- asset selection (at most 10 assets) ------------------------------------------

def test_one_minute_export_serves_up_to_fourteen_days() -> None:
    request = parse_export_request(range_from="2026-09-01T00:00:00Z", range_to="2026-09-15T00:00:00Z", resolution="1m")
    assert (request.resolution, request.dt_to - request.dt_from) == ("1m", timedelta(days=14))


def test_selected_assets_are_deduplicated_and_bounded() -> None:
    a, b = UUID(ASSET_A), UUID(ASSET_B)
    request = parse_export_request(
        range_from="2026-09-20T00:00:00Z", range_to="2026-09-21T00:00:00Z", resolution="1h",
        asset_ids=[a, b, a], max_assets=2,
    )
    assert request.asset_ids == (a, b)
    with pytest.raises(ApiContractError) as exc:
        parse_export_request(
            range_from="2026-09-20T00:00:00Z", range_to="2026-09-21T00:00:00Z", resolution="1h",
            asset_ids=[UUID(int=i) for i in range(11)], max_assets=10,
        )
    assert exc.value.code == "too_many_assets"
    with pytest.raises(ApiContractError) as exc:
        parse_export_request(
            range_from="2026-09-20T00:00:00Z", range_to="2026-09-21T00:00:00Z", resolution="1h", asset_ids=[], max_assets=10
        )
    assert exc.value.code == "no_assets_selected"


async def test_export_contains_only_the_selected_assets(monkeypatch) -> None:
    fake = FakeAnalytics()
    fake.install(monkeypatch)
    request = ExportRequest(T0, T0 + timedelta(hours=3), "1h", "1h", asset_ids=(UUID(ASSET_B),))
    ctx = await prepare_export(500, UUID(SITE_ID), request)
    result = await build_export_zip(500, UUID(SITE_ID), ctx)
    assert sorted(_zip_tables(result.content)) == ["AHU 2.csv"]
    assert result.asset_count == 1
    read_assets = {a for kind, args in fake.calls if kind == "points" for a, _, _ in args[1]}
    read_assets |= {a for kind, args in fake.calls if kind == "energy" for a in args[1]}
    assert read_assets == {ASSET_B}


async def test_a_selected_asset_outside_the_site_is_refused(monkeypatch) -> None:
    fake = FakeAnalytics()
    fake.install(monkeypatch)
    request = ExportRequest(T0, T0 + timedelta(hours=3), "1h", "1h", asset_ids=(UUID(ASSET_A), UUID(int=7)))
    with pytest.raises(ApiContractError) as exc:
        await prepare_export(500, UUID(SITE_ID), request)
    assert exc.value.code == "invalid_assets"
    assert not [c for c in fake.calls if c[0] in ("energy", "points", "measurements_1m")]


# --- 1 minute: one device-keyed read per asset (migration 312) -----------------------

async def _one_minute(monkeypatch, fake: FakeAnalytics, hours: int = 2):
    fake.install(monkeypatch)
    ctx = await prepare_export(500, UUID(SITE_ID), ExportRequest(T0, T0 + timedelta(hours=hours), "1m", "1m"))
    return _zip_tables((await build_export_zip(500, UUID(SITE_ID), ctx)).content)


async def test_one_minute_measurements_come_from_one_read_per_asset(monkeypatch) -> None:
    fake = FakeAnalytics()
    await _one_minute(monkeypatch, fake)
    # Never the per-point generic read at 1 minute (System Energy's read asks
    # it for no point, which reads nothing); one 312 read per asset with columns.
    assert not [c for c in fake.calls if c[0] == "points" and c[1][1]]
    reads = [args for kind, args in fake.calls if kind == "measurements_1m"]
    assert sorted(args[1] for args in reads) == sorted([ASSET_A, ASSET_B])
    chiller = next(args for args in reads if args[1] == ASSET_A)
    assert chiller[2] == [
        ("ACTIVE_POWER", "TOTAL"), ("ACTIVE_POWER", "L1"), ("ACTIVE_POWER", "L2"), ("ACTIVE_POWER", "L3"),
        ("VOLTAGE_LINE_NEUTRAL", "AVG"), ("APPARENT_POWER", "TOTAL"), ("CURRENT", "NEUTRAL"),
    ]
    assert (chiller[0], chiller[3], chiller[4]) == (500, T0, T0 + timedelta(hours=2))


async def test_one_minute_columns_match_the_generic_export(monkeypatch) -> None:
    tables = await _one_minute(monkeypatch, FakeAnalytics())
    chiller, ahu = tables["Chiller_1.csv"], tables["AHU 2.csv"]
    assert chiller[0] == [
        TIMESTAMP_UTC_HEADER, TIMESTAMP_LOCAL_HEADER,
        "Energy (kWh)", "Power (kW)", "Power L1 (kW)", "Power L2 (kW)", "Power L3 (kW)", "Voltage (V)",
        "Apparent Power (kVA)", "Current NEUTRAL (A)",
    ]
    assert ahu[0][2:] == [
        "Energy (kWh)", "Frequency (Hz)", "Relative Humidity (%)", "Illuminance (lux)", "Occupancy Activity",
        "Temperature (degC)",
    ]
    # One row per minute; each minute carries its own reading.
    assert len(chiller) - 1 == 120
    assert chiller[1][:2] == ["2026-09-20 00:00:00", "2026-09-20 05:30:00"]
    assert chiller[62][:2] == ["2026-09-20 01:01:00", "2026-09-20 06:31:00"]
    assert chiller[62][4] == format_value(value_for(ASSET_A, "ACTIVE_POWER", "L1", 1))
    column = ahu[0].index("Temperature (degC)")
    assert ahu[1][column] == format_value(value_for(ASSET_B, "TEMPERATURE", None, 0))


async def test_one_minute_register_points_are_not_columns(monkeypatch) -> None:
    from tests.report_export_fixtures import catalog_row

    catalog = CATALOG + [catalog_row(ASSET_A, "Chiller/1", "APPARENT_ENERGY", "TOTAL")]
    fake = FakeAnalytics()

    async def with_register(portal_user_id, site_id):
        return list(catalog)

    fake.catalog = with_register
    header = (await _one_minute(monkeypatch, fake))["Chiller_1.csv"][0]
    assert not any(h.startswith("APPARENT_ENERGY") for h in header)
    assert "Apparent Power (kVA)" in header


async def test_one_minute_missing_readings_stay_empty_and_every_minute_is_a_row(monkeypatch) -> None:
    fake = FakeAnalytics(missing={(ASSET_A, "ACTIVE_POWER", "L2", 0)}, hours=1)
    chiller = (await _one_minute(monkeypatch, fake))["Chiller_1.csv"]
    column = chiller[0].index("Power L2 (kW)")
    assert [row[column] for row in chiller[1:61]] == [""] * 60
    # The second hour has no reading at all, yet its minutes are rows.
    assert len(chiller) - 1 == 120
    assert all(cell == "" for row in chiller[61:] for cell in row[2:])


async def test_one_minute_asset_without_readings_is_header_only(monkeypatch) -> None:
    tables = await _one_minute(monkeypatch, FakeAnalytics())
    assert len(tables["Spare Pump.csv"]) == 1
