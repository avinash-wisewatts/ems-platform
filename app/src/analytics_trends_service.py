"""Analytics v1 (EMS Web App "Analytics" page, ADR-022) -- contract, curated
data-point registry and data access.

B1  GET /api/v1/sites/{site_id}/analytics/catalog
B1b data availability per catalogue data point (added to the catalogue)
B2  GET /api/v1/sites/{site_id}/analytics/series (Energy data points)

Every value comes from a portal-scoped SECURITY DEFINER read:
analytics.get_portal_analytics_catalog (migration 276),
analytics.get_portal_analytics_energy_availability (277) and
analytics.get_portal_analytics_energy_series (278, which itself reads only
analytics.get_canonical_energy_read). This module adds the curated registry
(which semantic parameters Analytics v1 can chart, and how), request
validation, and response shaping. It never derives availability from device
capability or PRIMARY_METER (ADR-018 decision 1), and it never exposes the
read model's internal attribution_basis (ADR-022 decision 4).
"""

from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from decimal import Decimal
from typing import Any
from uuid import UUID

from pydantic import BaseModel, ConfigDict, Field

from src.analytics_api_service import ApiContractError, _read_rows, parse_time_range


# ---------------------------------------------------------------------------
# Curated data-point registry (ADR-022 decision 2).
#
# A confirmed asset_points binding appears in the customer catalogue only if
# its parameter is listed here AND its qualifier is one this registry can
# serve. v1 is the Energy-only pilot (ADR-022 decision 3): Active Energy
# Import and Export, System (TOTAL) only -- the canonical Energy read that
# serves them resolves only the *_TOTAL logical points, so per-phase Energy
# is not offered even where L1/L2/L3 points exist. Adding a parameter here is
# gated on the open Product Owner questions recorded in
# docs/07-features/analytics/README.md.
# ---------------------------------------------------------------------------

SYSTEM_QUALIFIER = "TOTAL"
THREE_PHASE_QUALIFIERS: tuple[str, ...] = ("L1", "L2", "L3")


@dataclass(frozen=True)
class DataPointDefinition:
    chart_kind: str          # "bar" | "line"
    aggregation: str         # "sum" | "mean"
    qualifiers: tuple[str, ...]
    energy_direction: str | None = None   # "import" | "export" for canonical Energy


ANALYTICS_DATA_POINTS: dict[str, DataPointDefinition] = {
    "ENERGY_IMPORT": DataPointDefinition(
        chart_kind="bar", aggregation="sum", qualifiers=(SYSTEM_QUALIFIER,), energy_direction="import"
    ),
    "ENERGY_EXPORT": DataPointDefinition(
        chart_kind="bar", aggregation="sum", qualifiers=(SYSTEM_QUALIFIER,), energy_direction="export"
    ),
}


# ---------------------------------------------------------------------------
# Limits (ADR-022 decision 7) and resolutions (ADR-019).
# ---------------------------------------------------------------------------

MAX_DATA_POINTS = 5
MAX_ASSETS = 10
MAX_SERIES = 25

# (maximum window, default display window) per resolution -- ADR-019
# "Maximum windows (max / default-display)". 3 years = 1095 days.
ANALYTICS_RESOLUTION_WINDOWS: dict[str, tuple[timedelta, timedelta]] = {
    "1m": (timedelta(days=3), timedelta(hours=36)),
    "15m": (timedelta(days=30), timedelta(days=15)),
    "30m": (timedelta(days=60), timedelta(days=30)),
    "1h": (timedelta(days=180), timedelta(days=90)),
    "1d": (timedelta(days=1095), timedelta(days=547, hours=12)),
}
AUTO_RESOLUTION = "auto"
PHASES: tuple[str, ...] = ("system", "three_phase")


def _utc(value: datetime | None) -> datetime | None:
    """ADR-019: API transport timestamps are UTC, whatever the database
    session's TimeZone setting is."""

    if value is None or not isinstance(value, datetime):
        return value
    return value.astimezone(timezone.utc) if value.tzinfo else value.replace(tzinfo=timezone.utc)


def resolve_auto_resolution(window: timedelta) -> str:
    """ADR-019 default resolution: < 5 days -> 15m; < 30 days -> 1h; else 1d."""

    if window < timedelta(days=5):
        return "15m"
    if window < timedelta(days=30):
        return "1h"
    return "1d"


# ---------------------------------------------------------------------------
# Response models -- GET /api/v1/sites/{site_id}/analytics/catalog.
# ---------------------------------------------------------------------------

class AnalyticsPhases(BaseModel):
    system: bool
    three_phase: bool


class AnalyticsDataPoint(BaseModel):
    data_point: str
    label: str
    category: str | None = None
    unit: str | None = None
    chart_kind: str
    aggregation: str
    phases: AnalyticsPhases
    available_from: datetime | None = None
    available_to: datetime | None = None


class AnalyticsCatalogAsset(BaseModel):
    asset_id: UUID
    asset_name: str
    asset_type_id: UUID | None = None
    asset_type_name: str | None = None
    building_name: str | None = None
    floor_name: str | None = None
    space_id: UUID | None = None
    space_name: str | None = None
    location_path: str | None = None
    data_points: list[AnalyticsDataPoint]


class AnalyticsLimits(BaseModel):
    max_data_points: int
    max_assets: int
    max_series: int


class AnalyticsResolution(BaseModel):
    resolution: str
    max_window_seconds: int
    default_window_seconds: int


class AnalyticsCatalogResponse(BaseModel):
    site_id: UUID
    site_name: str
    site_timezone: str | None = None
    limits: AnalyticsLimits
    resolutions: list[AnalyticsResolution]
    assets: list[AnalyticsCatalogAsset]


# ---------------------------------------------------------------------------
# Response models -- GET /api/v1/sites/{site_id}/analytics/series.
# ---------------------------------------------------------------------------

class AnalyticsSeriesPoint(BaseModel):
    bucket_start: datetime
    bucket_end: datetime
    value: float | None = None
    min: float | None = None
    max: float | None = None
    coverage_ratio: float | None = None
    # Energy only: the canonical Energy read's evidence status (GOOD,
    # GAPS_DETECTED, RECONSTRUCTED_TIMING, RESET_DETECTED, ROLLOVER_DETECTED,
    # INVALID_INTERVALS); null for an empty bucket. Energy is not mapped onto
    # the five-value quality lattice (MVP-4 decision pack).
    evidence_status: str | None = None
    # Non-Energy only: the GOOD/GAP/ESTIMATED/INVALID/PARTIAL lattice.
    quality: str | None = None
    is_partial: bool


class AnalyticsSeriesSummary(BaseModel):
    total: float | None = None
    average: float | None = None
    min: float | None = None
    min_at: datetime | None = None
    max: float | None = None
    max_at: datetime | None = None
    coverage_ratio: float | None = None


class AnalyticsSeries(BaseModel):
    asset_id: UUID
    asset_name: str | None = None
    data_point: str
    label: str | None = None
    qualifier: str
    unit: str | None = None
    chart_kind: str
    aggregation: str
    status: str
    points: list[AnalyticsSeriesPoint]
    summary: AnalyticsSeriesSummary


class AnalyticsSeriesResponse(BaseModel):
    model_config = ConfigDict(populate_by_name=True)

    site_id: UUID
    site_timezone: str | None = None
    range_from: datetime = Field(alias="from")
    range_to: datetime = Field(alias="to")
    requested_resolution: str
    resolution: str
    phase: str
    series: list[AnalyticsSeries]


# Series status vocabulary.
STATUS_OK = "OK"
STATUS_NO_DATA = "NO_DATA"
STATUS_NOT_AVAILABLE = "NOT_AVAILABLE"
STATUS_RESOLUTION_UNAVAILABLE = "RESOLUTION_UNAVAILABLE"
STATUS_DATA_UNAVAILABLE = "DATA_UNAVAILABLE"


# ---------------------------------------------------------------------------
# Request validation -- GET /api/v1/sites/{site_id}/analytics/series.
# ---------------------------------------------------------------------------

@dataclass(frozen=True)
class Selection:
    asset_id: UUID
    data_point: str


@dataclass(frozen=True)
class SeriesRequest:
    dt_from: datetime
    dt_to: datetime
    requested_resolution: str
    resolution: str
    phase: str
    selections: tuple[Selection, ...]


def _series_count(selection: Selection, phase: str) -> int:
    definition = ANALYTICS_DATA_POINTS[selection.data_point]
    if phase == "three_phase" and set(THREE_PHASE_QUALIFIERS) <= set(definition.qualifiers):
        return len(THREE_PHASE_QUALIFIERS)
    return 1


def parse_series_request(
    *,
    range_from: str,
    range_to: str,
    resolution: str | None,
    phase: str | None,
    selections: list[str] | None,
) -> SeriesRequest:
    """Validate the whole request before any database access (the same
    order every /api/v1 route uses). Raises ApiContractError (HTTP 422)."""

    requested = resolution or AUTO_RESOLUTION
    if requested != AUTO_RESOLUTION and requested not in ANALYTICS_RESOLUTION_WINDOWS:
        raise ApiContractError(
            "invalid_resolution",
            "resolution must be one of: auto, " + ", ".join(ANALYTICS_RESOLUTION_WINDOWS),
        )

    resolved_phase = phase or "system"
    if resolved_phase not in PHASES:
        raise ApiContractError("invalid_phase", "phase must be one of: " + ", ".join(PHASES))

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

    if not selections:
        raise ApiContractError(
            "invalid_selection", "at least one selection=<asset_id>:<DATA_POINT> is required"
        )

    parsed: list[Selection] = []
    seen: set[Selection] = set()
    for raw in selections:
        asset_part, sep, point_part = (raw or "").partition(":")
        try:
            asset_id = UUID(asset_part.strip())
        except ValueError:
            asset_id = None
        if not sep or asset_id is None or not point_part.strip():
            raise ApiContractError(
                "invalid_selection", "each selection must be <asset_id>:<DATA_POINT>"
            )
        data_point = point_part.strip()
        if data_point not in ANALYTICS_DATA_POINTS:
            raise ApiContractError(
                "unknown_data_point",
                "data point must be one of: " + ", ".join(ANALYTICS_DATA_POINTS),
            )
        selection = Selection(asset_id=asset_id, data_point=data_point)
        if selection in seen:
            raise ApiContractError("duplicate_selection", "each selection may appear only once")
        seen.add(selection)
        parsed.append(selection)

    if len({s.data_point for s in parsed}) > MAX_DATA_POINTS:
        raise ApiContractError(
            "too_many_data_points", f"at most {MAX_DATA_POINTS} distinct data points per request"
        )
    if len({s.asset_id for s in parsed}) > MAX_ASSETS:
        raise ApiContractError("too_many_assets", f"at most {MAX_ASSETS} distinct assets per request")
    if sum(_series_count(s, resolved_phase) for s in parsed) > MAX_SERIES:
        raise ApiContractError("too_many_series", f"at most {MAX_SERIES} series per request")

    return SeriesRequest(
        dt_from=dt_from,
        dt_to=dt_to,
        requested_resolution=requested,
        resolution=resolved,
        phase=resolved_phase,
        selections=tuple(parsed),
    )


# ---------------------------------------------------------------------------
# Data access.
# ---------------------------------------------------------------------------

async def fetch_analytics_site(portal_user_id: int, site_id: UUID) -> dict[str, Any] | None:
    rows = await _read_rows(
        """
        SELECT id AS site_id, site_name, timezone
        FROM admin.list_accessible_sites(%s)
        WHERE id = %s
        """,
        (portal_user_id, str(site_id)),
    )
    return rows[0] if rows else None


async def fetch_analytics_catalog(portal_user_id: int, site_id: UUID) -> list[dict[str, Any]]:
    # attribution_basis is deliberately not selected: it is internal
    # read-model metadata and never reaches the customer API.
    return await _read_rows(
        """
        SELECT
            asset_id, asset_name, asset_type_id, asset_type_name,
            building_name, floor_name, space_id, space_name, location_path,
            data_point, data_point_name, category, unit, qualifier
        FROM analytics.get_portal_analytics_catalog(%s, %s)
        """,
        (portal_user_id, str(site_id)),
    )


async def fetch_analytics_energy_availability(
    portal_user_id: int, site_id: UUID
) -> list[dict[str, Any]]:
    return await _read_rows(
        """
        SELECT asset_id, data_point, available_from, available_to
        FROM analytics.get_portal_analytics_energy_availability(%s, %s)
        """,
        (portal_user_id, str(site_id)),
    )


async def fetch_analytics_energy_series(
    portal_user_id: int,
    site_id: UUID,
    asset_ids: list[UUID],
    dt_from: datetime,
    dt_to: datetime,
    resolution: str,
) -> list[dict[str, Any]]:
    return await _read_rows(
        """
        SELECT
            asset_id, bucket_start, bucket_end, import_kwh, export_kwh,
            import_status, export_status, import_intervals, export_intervals,
            expected_intervals, is_partial, unavailable_reason
        FROM analytics.get_portal_analytics_energy_series(%s, %s, %s::uuid[], %s, %s, %s)
        """,
        (portal_user_id, str(site_id), [str(a) for a in asset_ids], dt_from, dt_to, resolution),
    )


# ---------------------------------------------------------------------------
# Response building -- catalogue.
# ---------------------------------------------------------------------------

def _resolutions() -> list[AnalyticsResolution]:
    return [
        AnalyticsResolution(
            resolution=code,
            max_window_seconds=int(max_window.total_seconds()),
            default_window_seconds=int(default_window.total_seconds()),
        )
        for code, (max_window, default_window) in ANALYTICS_RESOLUTION_WINDOWS.items()
    ]


def _available_pairs(rows: list[dict[str, Any]]) -> dict[tuple[str, str], dict[str, Any]]:
    """(asset_id, data_point) -> first catalogue row, for registry-served
    rows only (parameter in the registry, qualifier servable)."""

    pairs: dict[tuple[str, str], dict[str, Any]] = {}
    for row in rows:
        definition = ANALYTICS_DATA_POINTS.get(row["data_point"])
        if definition is None or row["qualifier"] not in definition.qualifiers:
            continue
        pairs.setdefault((str(row["asset_id"]), row["data_point"]), row)
    return pairs


def build_analytics_catalog_response(
    *,
    site: dict[str, Any],
    rows: list[dict[str, Any]],
    availability: list[dict[str, Any]] | None = None,
) -> AnalyticsCatalogResponse:
    """Group catalogue rows into assets -> registry data points.

    A row whose parameter is not in the registry, or whose qualifier the
    registry cannot serve, is dropped. An asset left with no data point is
    omitted: the catalogue lists only assets the customer can chart.
    Ordering is deterministic: assets by name then id, data points by the
    registry's own order. Availability bounds are attached per data point;
    null bounds mean no data yet.
    """

    bounds = {
        (str(r["asset_id"]), r["data_point"]): (r.get("available_from"), r.get("available_to"))
        for r in (availability or [])
    }
    assets: dict[str, dict[str, Any]] = {}
    qualifiers: dict[tuple[str, str], set[str]] = {}
    for row in rows:
        definition = ANALYTICS_DATA_POINTS.get(row["data_point"])
        if definition is None or row["qualifier"] not in definition.qualifiers:
            continue
        asset_key = str(row["asset_id"])
        asset = assets.setdefault(asset_key, {"row": row, "points": {}})
        asset["points"].setdefault(row["data_point"], row)
        qualifiers.setdefault((asset_key, row["data_point"]), set()).add(row["qualifier"])

    registry_order = list(ANALYTICS_DATA_POINTS)
    catalog_assets: list[AnalyticsCatalogAsset] = []
    for asset_key, asset in sorted(
        assets.items(), key=lambda item: (item[1]["row"]["asset_name"].casefold(), item[0])
    ):
        head = asset["row"]
        data_points = []
        for code in sorted(asset["points"], key=registry_order.index):
            point_row = asset["points"][code]
            definition = ANALYTICS_DATA_POINTS[code]
            present = qualifiers[(asset_key, code)]
            available_from, available_to = bounds.get((asset_key, code), (None, None))
            data_points.append(
                AnalyticsDataPoint(
                    data_point=code,
                    label=point_row["data_point_name"],
                    category=point_row.get("category"),
                    unit=point_row.get("unit"),
                    chart_kind=definition.chart_kind,
                    aggregation=definition.aggregation,
                    phases=AnalyticsPhases(
                        system=SYSTEM_QUALIFIER in present,
                        three_phase=set(THREE_PHASE_QUALIFIERS) <= present,
                    ),
                    available_from=_utc(available_from),
                    available_to=_utc(available_to),
                )
            )
        catalog_assets.append(
            AnalyticsCatalogAsset(
                asset_id=head["asset_id"],
                asset_name=head["asset_name"],
                asset_type_id=head.get("asset_type_id"),
                asset_type_name=head.get("asset_type_name"),
                building_name=head.get("building_name"),
                floor_name=head.get("floor_name"),
                space_id=head.get("space_id"),
                space_name=head.get("space_name"),
                location_path=head.get("location_path"),
                data_points=data_points,
            )
        )

    return AnalyticsCatalogResponse(
        site_id=site["site_id"],
        site_name=site["site_name"],
        site_timezone=site.get("timezone"),
        limits=AnalyticsLimits(
            max_data_points=MAX_DATA_POINTS, max_assets=MAX_ASSETS, max_series=MAX_SERIES
        ),
        resolutions=_resolutions(),
        assets=catalog_assets,
    )


# ---------------------------------------------------------------------------
# Response building -- series.
# ---------------------------------------------------------------------------

def energy_asset_ids(request: SeriesRequest, catalog_rows: list[dict[str, Any]]) -> list[UUID]:
    """Assets whose Energy selections the catalogue can serve -- the only
    assets the Energy series read is asked for."""

    pairs = _available_pairs(catalog_rows)
    ids = {
        s.asset_id
        for s in request.selections
        if ANALYTICS_DATA_POINTS[s.data_point].energy_direction
        and (str(s.asset_id), s.data_point) in pairs
    }
    return sorted(ids, key=str)


def _float(value: Any) -> float | None:
    if value is None:
        return None
    return float(value) if isinstance(value, (Decimal, int, float)) else float(value)


def _coverage(measured: Any, expected: Any) -> float | None:
    if not expected:
        return None
    return min(1.0, float(measured or 0) / float(expected))


def _energy_series(
    selection: Selection,
    catalog_row: dict[str, Any],
    definition: DataPointDefinition,
    rows: list[dict[str, Any]],
) -> AnalyticsSeries:
    direction = definition.energy_direction
    base = dict(
        asset_id=selection.asset_id,
        asset_name=catalog_row["asset_name"],
        data_point=selection.data_point,
        label=catalog_row["data_point_name"],
        qualifier=SYSTEM_QUALIFIER,
        unit=catalog_row.get("unit"),
        chart_kind=definition.chart_kind,
        aggregation=definition.aggregation,
    )

    reasons = {r["unavailable_reason"] for r in rows if r.get("unavailable_reason")}
    if reasons:
        status = (
            STATUS_RESOLUTION_UNAVAILABLE
            if reasons == {"RESOLUTION_UNAVAILABLE"}
            else STATUS_DATA_UNAVAILABLE
        )
        return AnalyticsSeries(**base, status=status, points=[], summary=AnalyticsSeriesSummary())

    points: list[AnalyticsSeriesPoint] = []
    measured_total = 0
    expected_total = 0
    for row in rows:
        value = _float(row[f"{direction}_kwh"])
        measured = row[f"{direction}_intervals"] or 0
        expected = row["expected_intervals"] or 0
        measured_total += measured
        expected_total += expected
        points.append(
            AnalyticsSeriesPoint(
                bucket_start=_utc(row["bucket_start"]),
                bucket_end=_utc(row["bucket_end"]),
                value=value,
                coverage_ratio=_coverage(measured, expected),
                evidence_status=row[f"{direction}_status"],
                is_partial=bool(row["is_partial"]),
            )
        )

    valued = [p for p in points if p.value is not None]
    if not valued:
        return AnalyticsSeries(
            **base,
            status=STATUS_NO_DATA,
            points=points,
            summary=AnalyticsSeriesSummary(coverage_ratio=_coverage(measured_total, expected_total)),
        )

    total = sum(p.value for p in valued)
    lowest = min(valued, key=lambda p: (p.value, p.bucket_start))
    highest = max(valued, key=lambda p: (p.value, -p.bucket_start.timestamp()))
    summary = AnalyticsSeriesSummary(
        total=total,
        average=total / len(valued),
        min=lowest.value,
        min_at=lowest.bucket_start,
        max=highest.value,
        max_at=highest.bucket_start,
        coverage_ratio=_coverage(measured_total, expected_total),
    )
    return AnalyticsSeries(**base, status=STATUS_OK, points=points, summary=summary)


def build_analytics_series_response(
    *,
    site: dict[str, Any],
    request: SeriesRequest,
    catalog_rows: list[dict[str, Any]],
    energy_rows: list[dict[str, Any]],
) -> AnalyticsSeriesResponse:
    """One series per selection, in request order. A selection the
    catalogue cannot serve (asset not an ACTIVE asset of this site, or data
    point not assigned to it) is returned as NOT_AVAILABLE -- never dropped,
    and never distinguishable from an asset that does not exist."""

    pairs = _available_pairs(catalog_rows)
    energy_by_asset: dict[str, list[dict[str, Any]]] = {}
    for row in energy_rows:
        energy_by_asset.setdefault(str(row["asset_id"]), []).append(row)

    series: list[AnalyticsSeries] = []
    for selection in request.selections:
        definition = ANALYTICS_DATA_POINTS[selection.data_point]
        catalog_row = pairs.get((str(selection.asset_id), selection.data_point))
        if catalog_row is None or definition.energy_direction is None:
            series.append(
                AnalyticsSeries(
                    asset_id=selection.asset_id,
                    data_point=selection.data_point,
                    qualifier=SYSTEM_QUALIFIER,
                    chart_kind=definition.chart_kind,
                    aggregation=definition.aggregation,
                    status=STATUS_NOT_AVAILABLE,
                    points=[],
                    summary=AnalyticsSeriesSummary(),
                )
            )
            continue
        rows = sorted(
            energy_by_asset.get(str(selection.asset_id), []),
            key=lambda r: (r["bucket_start"] is not None, r["bucket_start"] or datetime.min),
        )
        series.append(_energy_series(selection, catalog_row, definition, rows))

    return AnalyticsSeriesResponse(
        site_id=site["site_id"],
        site_timezone=site.get("timezone"),
        range_from=request.dt_from,
        range_to=request.dt_to,
        requested_resolution=request.requested_resolution,
        resolution=request.resolution,
        phase=request.phase,
        series=series,
    )
