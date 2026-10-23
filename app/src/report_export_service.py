"""Reports tab -- site measurement export (one ZIP, one CSV per asset).

Every value comes from the same portal-scoped Analytics reads the Analytics
page uses (analytics_trends_service: the site's catalogue, the persisted
Energy tiers and the generic point series, migrations 276-292), evaluated for
the requesting portal user -- for a background job, the job's owner. Nothing
here reads a table directly or derives a value of its own: each CSV column is
one series of a data point confirmed for the asset in its Analytics catalogue
(metadata.asset_points through analytics.get_portal_analytics_catalog), and
each row one Analytics bucket.

Columns. Data points in the Analytics chart registry (ANALYTICS_DATA_POINTS:
Energy, Power, Voltage, ...) are exported exactly as the Analytics page
serves them (System, then every phase the asset has fully assigned). Every
OTHER confirmed catalogue point -- environmental and occupancy points such
as Temperature, Relative Humidity, Occupancy Activity and Illuminance, and
electrical points the chart registry does not chart (Apparent Power, Current
THD, Phase Angle, Neutral current, ...) -- is one more column per assigned
qualifier, read through the same portal-scoped generic series read
(analytics.get_portal_asset_point_series, migration 292). The chart registry
bounds what the Analytics page charts, not what belongs to an asset.

Request contract: [from, to) in UTC, resolution auto / 1m / 15m / 30m / 1h /
1d with the ADR-019 maximum windows (the Analytics page's own bounds). Auto
resolves exactly as Analytics Auto does (window-based, then floor-aware).

Size: an export is estimated as buckets x columns over the site's assets.
Up to REPORT_EXPORT immediate_max_cells it is generated in the request;
larger exports run as a background job (report_export_worker.py), up to
max_cells.
"""

from __future__ import annotations

import csv
import io
import math
import re
import zipfile
from dataclasses import dataclass, field, replace
from datetime import datetime, timezone
from typing import Any
from uuid import UUID
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

from pydantic import BaseModel

from src.analytics_api_service import ApiContractError, fetch_site_assets, parse_time_range
from src.analytics_trends_service import (
    ANALYTICS_DATA_POINTS,
    ANALYTICS_RESOLUTION_WINDOWS,
    AUTO_RESOLUTION,
    SOURCE_DELTA,
    SOURCE_ENERGY,
    SOURCE_MEAN,
    AnalyticsSeries,
    PointSpec,
    SeriesRequest,
    Selection,
    apply_floor_aware_auto,
    build_analytics_series_response,
    combined_floors,
    energy_resolution_retained,
    fetch_analytics_as_of,
    fetch_analytics_catalog,
    fetch_analytics_energy_resolution_floors,
    fetch_analytics_energy_series,
    fetch_analytics_point_resolution_floors,
    fetch_analytics_point_series,
    fetch_analytics_site,
    plan_series,
    planned_kinds,
    point_specs,
    resolve_auto_resolution,
)


TIMESTAMP_UTC_HEADER = "Timestamp (UTC)"
TIMESTAMP_LOCAL_HEADER = "Timestamp (Site Local)"
TIMESTAMP_FORMAT = "%Y-%m-%d %H:%M:%S"

RESOLUTION_SECONDS: dict[str, int] = {"1m": 60, "15m": 900, "30m": 1800, "1h": 3600, "1d": 86400}

# Data points per generic-read call: bounded so one call never asks for more
# series than an Analytics page request may (25), whatever the asset has.
POINT_SPECS_PER_READ = 9

# Qualifiers that denote the System (not a phase) series of a point.
SYSTEM_QUALIFIERS: tuple[str | None, ...] = (None, "TOTAL", "AVG")

STATUS_LABELS = {
    "QUEUED": "Queued",
    "PROCESSING": "Processing",
    "COMPLETED": "Completed",
    "FAILED": "Failed",
    "EXPIRED": "Expired",
}


# ---------------------------------------------------------------------------
# Request.
# ---------------------------------------------------------------------------

@dataclass(frozen=True)
class ExportRequest:
    dt_from: datetime
    dt_to: datetime
    requested_resolution: str
    resolution: str


def parse_export_request(*, range_from: str, range_to: str, resolution: str | None) -> ExportRequest:
    """Validate the request before any database access (HTTP 422 on
    violation): the same resolution vocabulary and ADR-019 maximum windows
    as GET /analytics/series."""

    requested = resolution or AUTO_RESOLUTION
    if requested != AUTO_RESOLUTION and requested not in ANALYTICS_RESOLUTION_WINDOWS:
        raise ApiContractError(
            "invalid_resolution",
            "resolution must be one of: auto, " + ", ".join(ANALYTICS_RESOLUTION_WINDOWS),
        )
    dt_from, dt_to = parse_time_range(
        range_from, range_to, resolution="any", max_window_by_resolution={"any": None}
    )
    resolved = resolve_auto_resolution(dt_to - dt_from) if requested == AUTO_RESOLUTION else requested
    parse_time_range(
        range_from,
        range_to,
        resolution=resolved,
        max_window_by_resolution={k: v[0] for k, v in ANALYTICS_RESOLUTION_WINDOWS.items()},
    )
    return ExportRequest(dt_from=dt_from, dt_to=dt_to, requested_resolution=requested, resolution=resolved)


# ---------------------------------------------------------------------------
# Columns: one per Analytics series an asset's catalogue rows can serve.
# ---------------------------------------------------------------------------

def _asset_points(catalog_rows: list[dict[str, Any]]) -> dict[str, dict[str, set[str | None]]]:
    """asset_id -> data point -> the registry-servable qualifiers assigned
    (any period), in registry order."""

    out: dict[str, dict[str, set[str | None]]] = {}
    for row in catalog_rows:
        definition = ANALYTICS_DATA_POINTS.get(row["data_point"])
        if definition is None or row["qualifier"] not in definition.qualifiers:
            continue
        out.setdefault(str(row["asset_id"]), {}).setdefault(row["data_point"], set()).add(row["qualifier"])
    order = list(ANALYTICS_DATA_POINTS)
    return {
        asset: dict(sorted(points.items(), key=lambda item: order.index(item[0])))
        for asset, points in out.items()
    }


def _phased(data_point: str, qualifiers: set[str | None], resolution: str) -> bool:
    """The asset has every phase of the point assigned, and the resolution
    has a per-phase source (no 1-minute per-phase Energy)."""

    definition = ANALYTICS_DATA_POINTS[data_point]
    return (
        bool(definition.phase_qualifiers)
        and set(definition.phase_qualifiers) <= qualifiers
        and not (definition.energy_direction and resolution == "1m")
    )


def asset_column_count(points: dict[str, set[str | None]], resolution: str) -> int:
    count = 0
    for code, qualifiers in points.items():
        definition = ANALYTICS_DATA_POINTS[code]
        if definition.system_qualifier in qualifiers:
            count += 1
        if _phased(code, qualifiers, resolution):
            count += len(definition.phase_qualifiers)
    return count


@dataclass(frozen=True)
class ExtraColumn:
    """A confirmed catalogue point outside the chart registry's columns."""

    data_point: str
    qualifier: str | None
    label: str
    unit: str | None

    @property
    def header(self) -> str:
        label = self.label if self.qualifier in SYSTEM_QUALIFIERS else f"{self.label} {self.qualifier}"
        return f"{label} ({self.unit})" if self.unit else label


def _registry_columns(points: dict[str, set[str | None]], resolution: str) -> set[tuple[str, str | None]]:
    """(data point, catalogue qualifier) pairs the registry columns serve."""

    covered: set[tuple[str, str | None]] = set()
    for code, qualifiers in points.items():
        definition = ANALYTICS_DATA_POINTS[code]
        if definition.system_qualifier in qualifiers:
            covered.add((code, definition.system_qualifier))
        if _phased(code, qualifiers, resolution):
            covered.update((code, q) for q in definition.phase_qualifiers)
    return covered


def _extra_columns(
    catalog_rows: list[dict[str, Any]], points_by_asset: dict[str, dict[str, set[str | None]]], resolution: str
) -> dict[str, list[ExtraColumn]]:
    """asset_id -> its confirmed catalogue points the registry columns do not
    serve, ordered by data point then qualifier (System first). Per-phase
    Energy has no 1-minute source, so it is not a 1-minute column."""

    covered = {asset: _registry_columns(points, resolution) for asset, points in points_by_asset.items()}
    seen: dict[str, dict[tuple[str, str | None], ExtraColumn]] = {}
    for row in catalog_rows:
        asset = str(row["asset_id"])
        key = (row["data_point"], row.get("qualifier"))
        if key in covered.get(asset, set()):
            continue
        definition = ANALYTICS_DATA_POINTS.get(key[0])
        if definition is not None and definition.energy_direction and resolution == "1m":
            continue
        seen.setdefault(asset, {}).setdefault(
            key,
            ExtraColumn(
                data_point=key[0],
                qualifier=key[1],
                label=row.get("data_point_name") or key[0],
                unit=row.get("unit"),
            ),
        )
    return {
        asset: sorted(
            columns.values(),
            key=lambda c: (c.data_point, c.qualifier not in SYSTEM_QUALIFIERS, c.qualifier or ""),
        )
        for asset, columns in seen.items()
    }


def bucket_count(request: ExportRequest) -> int:
    return max(1, math.ceil((request.dt_to - request.dt_from).total_seconds() / RESOLUTION_SECONDS[request.resolution]))


@dataclass(frozen=True)
class ExportEstimate:
    asset_count: int
    column_count: int
    bucket_count: int
    cells: int


def estimate_export(
    request: ExportRequest, site_assets: list[dict[str, Any]], catalog_rows: list[dict[str, Any]]
) -> ExportEstimate:
    points = _asset_points(catalog_rows)
    extras = _extra_columns(catalog_rows, points, request.resolution)
    columns = sum(
        asset_column_count(points.get(str(a["asset_id"]), {}), request.resolution)
        + len(extras.get(str(a["asset_id"]), []))
        for a in site_assets
    )
    buckets = bucket_count(request)
    return ExportEstimate(
        asset_count=len(site_assets), column_count=columns, bucket_count=buckets, cells=columns * buckets
    )


def column_header(series: AnalyticsSeries) -> str:
    """"Power (kW)", "Power L1 (kW)", "Line to Line Voltage L12 (V)". The
    System series carries no qualifier (customers never see TOTAL / AVG)."""

    label = series.label or series.data_point
    if series.qualifier in ANALYTICS_DATA_POINTS[series.data_point].phase_qualifiers:
        label = f"{label} {series.qualifier}"
    return f"{label} ({series.unit})" if series.unit else label


# ---------------------------------------------------------------------------
# Data collection (one asset at a time, bounded reads).
# ---------------------------------------------------------------------------

@dataclass
class ExportContext:
    """Per-export state shared by every asset: one as_of, one resolution
    and the retention floors, read once."""

    site: dict[str, Any]
    request: ExportRequest
    series_request: SeriesRequest
    as_of: datetime
    catalog_rows: list[dict[str, Any]]
    site_assets: list[dict[str, Any]]
    energy_floors: dict[str, datetime | None] = field(default_factory=dict)
    point_floors: dict[str, dict[str, datetime | None]] = field(default_factory=dict)
    points_by_asset: dict[str, dict[str, set[str | None]]] = field(default_factory=dict)
    extras_by_asset: dict[str, list[ExtraColumn]] = field(default_factory=dict)


@dataclass
class AssetTable:
    asset_id: str
    asset_name: str
    headers: list[str]
    # bucket_start -> one value per column (None = no reading)
    rows: dict[datetime, list[float | None]]
    has_data: bool


async def prepare_export(portal_user_id: int, site_id: UUID, request: ExportRequest) -> ExportContext | None:
    """None when the site is not accessible to the portal user."""

    site = await fetch_analytics_site(portal_user_id, site_id)
    if site is None:
        return None
    as_of = await fetch_analytics_as_of()
    catalog_rows = await fetch_analytics_catalog(portal_user_id, site_id)
    site_assets = await fetch_site_assets(portal_user_id, site_id)
    site_assets = sorted(site_assets, key=lambda a: ((a.get("asset_name") or "").casefold(), str(a["asset_id"])))

    series_request = SeriesRequest(
        dt_from=request.dt_from,
        dt_to=request.dt_to,
        requested_resolution=request.requested_resolution,
        resolution=request.resolution,
        phase="system",
        selections=tuple(
            Selection(UUID(asset), code)
            for asset, points in _asset_points(catalog_rows).items()
            for code in points
        ),
    )
    # Every source the export reads (System and per-phase), so floor-aware
    # Auto picks one resolution every column can be served at.
    three_phase = replace(series_request, phase="three_phase")
    kinds = planned_kinds(plan_series(series_request, catalog_rows)) | planned_kinds(
        plan_series(three_phase, catalog_rows)
    )
    if _extra_columns(catalog_rows, _asset_points(catalog_rows), request.resolution):
        # Generic-read columns may be measurements or register deltas.
        kinds |= {SOURCE_MEAN, SOURCE_DELTA}
    energy_floors: dict = {}
    point_floors: dict = {}
    if SOURCE_ENERGY in kinds:
        energy_floors = await fetch_analytics_energy_resolution_floors(site_id, as_of)
    if kinds & {SOURCE_MEAN, SOURCE_DELTA}:
        point_floors = await fetch_analytics_point_resolution_floors(as_of)
    if kinds:
        series_request = apply_floor_aware_auto(series_request, combined_floors(kinds, energy_floors, point_floors))
    resolved = ExportRequest(
        dt_from=request.dt_from,
        dt_to=request.dt_to,
        requested_resolution=request.requested_resolution,
        resolution=series_request.resolution,
    )
    return ExportContext(
        site=site,
        request=resolved,
        series_request=series_request,
        as_of=as_of,
        catalog_rows=catalog_rows,
        site_assets=site_assets,
        energy_floors=energy_floors,
        point_floors=point_floors,
        points_by_asset=_asset_points(catalog_rows),
        extras_by_asset=_extra_columns(catalog_rows, _asset_points(catalog_rows), resolved.resolution),
    )


async def _read_series(
    portal_user_id: int, site_id: UUID, ctx: ExportContext, request: SeriesRequest
) -> list[AnalyticsSeries]:
    """One Analytics series read (the GET /analytics/series data path)."""

    planned = plan_series(request, ctx.catalog_rows)
    energy_assets = sorted({p.selection.asset_id for p in planned if p.kind == SOURCE_ENERGY}, key=str)
    retained = True
    energy_rows: list = []
    if energy_assets:
        retained = energy_resolution_retained(request, ctx.energy_floors)
        if retained:
            energy_rows = await fetch_analytics_energy_series(
                portal_user_id, site_id, energy_assets, request.dt_from, request.dt_to, request.resolution, ctx.as_of
            )
    point_rows = await fetch_analytics_point_series(
        portal_user_id, site_id, point_specs(planned), request.dt_from, request.dt_to, request.resolution, ctx.as_of
    )
    response = build_analytics_series_response(
        site=ctx.site,
        request=request,
        catalog_rows=ctx.catalog_rows,
        energy_rows=energy_rows,
        as_of=ctx.as_of,
        floors=ctx.energy_floors,
        energy_resolution_available=retained,
        point_rows=point_rows,
        point_floors=ctx.point_floors,
    )
    return response.series


def _chunks(items: list, size: int) -> list[list]:
    return [items[i : i + size] for i in range(0, len(items), size)]


async def _read_extra_columns(
    portal_user_id: int, site_id: UUID, ctx: ExportContext, asset_id: str, columns: list[ExtraColumn]
) -> list[dict[datetime, float | None]]:
    """bucket_start -> value per extra column, through the generic portal
    series read. A column the read reports unavailable (or returns no rows
    for) has no values -- empty cells, never zeros."""

    out: list[dict[datetime, float | None]] = []
    for chunk in _chunks(columns, POINT_SPECS_PER_READ):
        specs = [PointSpec(UUID(asset_id), c.data_point, c.qualifier) for c in chunk]
        rows = await fetch_analytics_point_series(
            portal_user_id,
            site_id,
            specs,
            ctx.series_request.dt_from,
            ctx.series_request.dt_to,
            ctx.series_request.resolution,
            ctx.as_of,
        )
        by_index: dict[int, list[dict[str, Any]]] = {}
        for row in rows:
            by_index.setdefault(int(row["series_index"]), []).append(row)
        for index in range(1, len(chunk) + 1):
            series_rows = by_index.get(index, [])
            values: dict[datetime, float | None] = {}
            if not any(r.get("unavailable_reasons") for r in series_rows):
                for r in series_rows:
                    if r.get("bucket_start") is not None:
                        values[_utc(r["bucket_start"])] = None if r.get("value") is None else float(r["value"])
            out.append(values)
    return out


async def collect_asset_table(
    portal_user_id: int, site_id: UUID, ctx: ExportContext, asset: dict[str, Any]
) -> AssetTable:
    """Every series of one asset: the chart-registry columns (System for
    each assigned data point, then its phases when every phase is assigned,
    in registry order), then every other confirmed catalogue point."""

    asset_id = str(asset["asset_id"])
    name = asset.get("asset_name") or asset_id
    points = ctx.points_by_asset.get(asset_id, {})
    resolution = ctx.series_request.resolution

    system_codes = [c for c, q in points.items() if ANALYTICS_DATA_POINTS[c].system_qualifier in q]
    phased_codes = [c for c, q in points.items() if _phased(c, q, resolution)]

    collected: dict[tuple[str, str], AnalyticsSeries] = {}
    for phase, codes in (("system", system_codes), ("three_phase", phased_codes)):
        per_read = POINT_SPECS_PER_READ if phase == "system" else POINT_SPECS_PER_READ // 3
        for chunk in _chunks(codes, per_read):
            request = replace(
                ctx.series_request,
                phase=phase,
                selections=tuple(Selection(UUID(asset_id), code) for code in chunk),
            )
            for series in await _read_series(portal_user_id, site_id, ctx, request):
                collected[(series.data_point, series.qualifier)] = series

    ordered: list[AnalyticsSeries] = []
    for code in points:
        definition = ANALYTICS_DATA_POINTS[code]
        for qualifier in ("TOTAL", *definition.phase_qualifiers):
            series = collected.get((code, qualifier))
            if series is not None:
                ordered.append(series)

    extras = ctx.extras_by_asset.get(asset_id, [])
    extra_values = await _read_extra_columns(portal_user_id, site_id, ctx, asset_id, extras) if extras else []

    columns: list[dict[datetime, float | None]] = [
        {_utc(p.bucket_start): p.value for p in series.points} for series in ordered
    ] + extra_values
    width = len(columns)
    rows: dict[datetime, list[float | None]] = {}
    has_data = False
    for index, column in enumerate(columns):
        for bucket_start, value in column.items():
            rows.setdefault(bucket_start, [None] * width)[index] = value
            has_data = has_data or value is not None
    if not has_data:
        rows = {}
    return AssetTable(
        asset_id=asset_id,
        asset_name=name,
        headers=_unique_headers([column_header(s) for s in ordered] + [c.header for c in extras]),
        rows=rows,
        has_data=has_data,
    )


def _unique_headers(headers: list[str]) -> list[str]:
    """Two different points never share a header: a repeat gets " (2)"."""

    out: list[str] = []
    used: set[str] = set()
    for header in headers:
        candidate, n = header, 1
        while candidate.casefold() in used:
            n += 1
            candidate = f"{header} ({n})"
        used.add(candidate.casefold())
        out.append(candidate)
    return out


# ---------------------------------------------------------------------------
# CSV / ZIP.
# ---------------------------------------------------------------------------

_FORMULA_PREFIXES = ("=", "+", "-", "@", "\t", "\r")


def _safe_text(value: str) -> str:
    """Spreadsheet formula-injection guard for text cells (headers come from
    catalogue labels and units)."""

    return "'" + value if value.startswith(_FORMULA_PREFIXES) else value


def format_value(value: float | None) -> str:
    if value is None or (isinstance(value, float) and not math.isfinite(value)):
        return ""
    text = f"{value:.6f}".rstrip("0").rstrip(".")
    return "0" if text in ("-0", "") else text


def site_zone(timezone_name: str | None) -> ZoneInfo | timezone:
    if not timezone_name:
        return timezone.utc
    try:
        return ZoneInfo(timezone_name)
    except (ZoneInfoNotFoundError, ValueError):
        return timezone.utc


def asset_csv(table: AssetTable, zone: ZoneInfo | timezone) -> str:
    buffer = io.StringIO()
    writer = csv.writer(buffer, lineterminator="\r\n")
    writer.writerow([TIMESTAMP_UTC_HEADER, TIMESTAMP_LOCAL_HEADER, *(_safe_text(h) for h in table.headers)])
    for bucket_start in sorted(table.rows):
        utc = bucket_start.astimezone(timezone.utc)
        writer.writerow(
            [
                utc.strftime(TIMESTAMP_FORMAT),
                utc.astimezone(zone).strftime(TIMESTAMP_FORMAT),
                *(format_value(v) for v in table.rows[bucket_start]),
            ]
        )
    return buffer.getvalue()


_UNSAFE_FILENAME = re.compile(r'[\x00-\x1f<>:"/\\|?*\x7f]+')
_RESERVED_NAMES = {"CON", "PRN", "AUX", "NUL", *(f"COM{i}" for i in range(1, 10)), *(f"LPT{i}" for i in range(1, 10))}


def safe_file_stem(name: str, fallback: str = "asset") -> str:
    """A file name stem that is valid on Windows, macOS and Linux and
    cannot escape the ZIP root."""

    stem = _UNSAFE_FILENAME.sub("_", name or "").strip().strip(".").strip()
    stem = re.sub(r"\s+", " ", stem)[:100].rstrip(". ")
    if not stem or stem.upper() in _RESERVED_NAMES:
        stem = f"{stem}_{fallback}" if stem else fallback
    return stem


class UniqueNames:
    """Case-insensitive de-duplication: "Pump", "Pump (2)", "Pump (3)"."""

    def __init__(self) -> None:
        self._used: set[str] = set()

    def claim(self, stem: str, extension: str) -> str:
        candidate = f"{stem}{extension}"
        n = 1
        while candidate.casefold() in self._used:
            n += 1
            candidate = f"{stem} ({n}){extension}"
        self._used.add(candidate.casefold())
        return candidate


def export_file_name(site: dict[str, Any], request: ExportRequest) -> str:
    zone = site_zone(site.get("timezone"))
    start = request.dt_from.astimezone(zone).strftime("%Y%m%d-%H%M")
    end = request.dt_to.astimezone(zone).strftime("%Y%m%d-%H%M")
    return f"{safe_file_stem(site.get('site_name') or 'site', 'site')}_{start}_{end}_{request.resolution}.zip"


@dataclass
class ExportResult:
    file_name: str
    content: bytes
    asset_count: int
    row_count: int


async def build_export_zip(
    portal_user_id: int,
    site_id: UUID,
    ctx: ExportContext,
    *,
    on_asset_done: Any = None,
) -> ExportResult:
    """One CSV per site asset (header-only when the asset has no data in the
    range). Assets are read one at a time; on_asset_done (async, optional)
    is awaited after each -- the background worker extends its lease there."""

    zone = site_zone(ctx.site.get("timezone"))
    names = UniqueNames()
    buffer = io.BytesIO()
    rows = 0
    with zipfile.ZipFile(buffer, "w", compression=zipfile.ZIP_DEFLATED) as archive:
        for asset in ctx.site_assets:
            table = await collect_asset_table(portal_user_id, site_id, ctx, asset)
            entry = names.claim(safe_file_stem(table.asset_name), ".csv")
            archive.writestr(entry, asset_csv(table, zone).encode("utf-8-sig"))
            rows += len(table.rows)
            if on_asset_done is not None:
                await on_asset_done()
    return ExportResult(
        file_name=export_file_name(ctx.site, ctx.request),
        content=buffer.getvalue(),
        asset_count=len(ctx.site_assets),
        row_count=rows,
    )


# ---------------------------------------------------------------------------
# API models.
# ---------------------------------------------------------------------------

class ReportExportEstimateResponse(BaseModel):
    site_id: UUID
    range_from: datetime
    range_to: datetime
    requested_resolution: str
    resolution: str
    asset_count: int
    column_count: int
    bucket_count: int
    estimated_cells: int
    # "immediate" (GET .../report-exports/file) or "background" (POST a job);
    # "too_large" when the export exceeds the background limit as well.
    mode: str


class ReportExportJob(BaseModel):
    job_id: UUID
    site_id: UUID
    site_name: str | None = None
    range_from: datetime
    range_to: datetime
    requested_resolution: str
    resolution: str
    status: str
    status_label: str
    attempts: int
    error_code: str | None = None
    error_message: str | None = None
    created_at: datetime
    started_at: datetime | None = None
    completed_at: datetime | None = None
    expires_at: datetime | None = None
    file_name: str | None = None
    file_size_bytes: int | None = None
    asset_count: int | None = None
    row_count: int | None = None
    # Same-origin, session-authenticated; present only while downloadable.
    download_url: str | None = None


class ReportExportJobListResponse(BaseModel):
    jobs: list[ReportExportJob]


def _utc(value: datetime | None) -> datetime | None:
    if value is None:
        return None
    return value.astimezone(timezone.utc) if value.tzinfo else value.replace(tzinfo=timezone.utc)


def build_job(row: dict[str, Any], site_names: dict[str, str] | None = None, now: datetime | None = None) -> ReportExportJob:
    now = now or datetime.now(timezone.utc)
    expires_at = _utc(row.get("expires_at"))
    downloadable = row["status"] == "COMPLETED" and expires_at is not None and expires_at > now
    return ReportExportJob(
        job_id=row["id"],
        site_id=row["site_id"],
        site_name=(site_names or {}).get(str(row["site_id"])),
        range_from=_utc(row["range_from"]),
        range_to=_utc(row["range_to"]),
        requested_resolution=row["requested_resolution"],
        resolution=row["resolution"],
        status=row["status"],
        status_label=STATUS_LABELS.get(row["status"], row["status"]),
        attempts=int(row.get("attempts") or 0),
        error_code=row.get("error_code"),
        error_message=row.get("error_message"),
        created_at=_utc(row["created_at"]),
        started_at=_utc(row.get("started_at")),
        completed_at=_utc(row.get("completed_at")),
        expires_at=expires_at,
        file_name=row.get("file_name"),
        file_size_bytes=row.get("file_size_bytes"),
        asset_count=row.get("asset_count"),
        row_count=row.get("row_count"),
        download_url=f"/api/v1/report-exports/{row['id']}/file" if downloadable else None,
    )


def export_mode(cells: int, *, immediate_max_cells: int, max_cells: int) -> str:
    if cells <= immediate_max_cells:
        return "immediate"
    if cells <= max_cells:
        return "background"
    return "too_large"
