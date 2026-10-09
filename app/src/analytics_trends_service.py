"""Analytics v1 (EMS Web App "Analytics" page, ADR-022) -- contract, curated
data-point registry and data access.

B1  GET /api/v1/sites/{site_id}/analytics/catalog
B1b data availability per catalogue data point (added to the catalogue)
B2  GET /api/v1/sites/{site_id}/analytics/series (Energy data points)
B3  measurements and per-phase Energy in the catalogue and the series
    (analytics.get_portal_asset_point_series and its availability and floor
    reads, migration 292)

Every value comes from a portal-scoped SECURITY DEFINER read:
analytics.get_portal_analytics_catalog (migration 276),
analytics.get_portal_analytics_energy_availability (277, aligned with the
persisted Energy tiers by 280), the site-aware
analytics.get_analytics_energy_resolution_floors (282) and
analytics.get_portal_asset_energy_series (282, values as 279/281: the
persisted Energy tiers, portal/organization scoped, never keyed on the Grafana
organization mapping -- ADR-022 Option B -- with the Data Quality contract:
site-local 30m/1h grid, interval counts, data state, data bounds and stale,
all evaluated at one as_of). This module adds the curated registry
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
# Curated data-point registry (ADR-022 decision 2, B3 scope decided by the
# Product Owner 2026-10-09: Energy, active and reactive power, voltage,
# current, power factor and frequency).
#
# A confirmed asset_points binding appears in the customer catalogue only if
# its parameter is listed here AND its qualifier is one this registry can
# serve. `qualifiers[0]` is the System qualifier (the canonical system-level
# logical point: TOTAL, the AVG voltage, or None for an unqualified point
# such as Frequency); the rest are the phase qualifiers 3 Phase expands into.
# The API always reports a System series with qualifier "TOTAL" (D83 -- the
# customer never sees qualifiers) and a phase series with its own qualifier.
#
# Energy System keeps the persisted Energy tiers (migrations 279-286);
# per-phase Energy (L1-L3) is read from the register-delta tier (migration
# 290) and has no 1-minute source. Measurements are read through
# analytics.get_portal_asset_point_series (migration 292). A phase value is
# that phase's own measurement: phase series never claim to add up to the
# System series (Current TOTAL and the voltage AVG are averages, and phase
# register deltas are separate registers).
# ---------------------------------------------------------------------------

SYSTEM_QUALIFIER = "TOTAL"
THREE_PHASE_QUALIFIERS: tuple[str, ...] = ("L1", "L2", "L3")
LINE_LINE_QUALIFIERS: tuple[str, ...] = ("L12", "L23", "L31")


@dataclass(frozen=True)
class DataPointDefinition:
    chart_kind: str          # "bar" | "line"
    aggregation: str         # "sum" | "mean"
    # qualifiers[0] = System qualifier (None = unqualified point); the rest
    # are the phase qualifiers.
    qualifiers: tuple[str | None, ...]
    energy_direction: str | None = None   # "import" | "export" for the Energy tiers
    # Customer-facing label. None falls back to the parameter name.
    label: str | None = None

    @property
    def system_qualifier(self) -> str | None:
        return self.qualifiers[0]

    @property
    def phase_qualifiers(self) -> tuple[str, ...]:
        return tuple(q for q in self.qualifiers[1:] if q is not None)


# Labels: platform-wide Energy terminology (Analytics UI decision D73):
# "Energy" is consumed/imported energy, "Energy Export" is exported energy.
# Measurement labels follow the D67 data-point list ("Power" is active power,
# "Voltage" line-to-neutral, "Line to Line Voltage").
ANALYTICS_DATA_POINTS: dict[str, DataPointDefinition] = {
    "ENERGY_IMPORT": DataPointDefinition(
        chart_kind="bar", aggregation="sum", qualifiers=(SYSTEM_QUALIFIER, *THREE_PHASE_QUALIFIERS),
        energy_direction="import", label="Energy",
    ),
    "ENERGY_EXPORT": DataPointDefinition(
        chart_kind="bar", aggregation="sum", qualifiers=(SYSTEM_QUALIFIER, *THREE_PHASE_QUALIFIERS),
        energy_direction="export", label="Energy Export",
    ),
    "ACTIVE_POWER": DataPointDefinition(
        chart_kind="line", aggregation="mean", qualifiers=(SYSTEM_QUALIFIER, *THREE_PHASE_QUALIFIERS),
        label="Power",
    ),
    "REACTIVE_POWER": DataPointDefinition(
        chart_kind="line", aggregation="mean", qualifiers=(SYSTEM_QUALIFIER, *THREE_PHASE_QUALIFIERS),
        label="Reactive Power",
    ),
    "CURRENT": DataPointDefinition(
        chart_kind="line", aggregation="mean", qualifiers=(SYSTEM_QUALIFIER, *THREE_PHASE_QUALIFIERS),
        label="Current",
    ),
    "VOLTAGE_LINE_NEUTRAL": DataPointDefinition(
        chart_kind="line", aggregation="mean", qualifiers=("AVG", *THREE_PHASE_QUALIFIERS),
        label="Voltage",
    ),
    "VOLTAGE_LINE_LINE": DataPointDefinition(
        chart_kind="line", aggregation="mean", qualifiers=("AVG", *LINE_LINE_QUALIFIERS),
        label="Line to Line Voltage",
    ),
    "POWER_FACTOR": DataPointDefinition(
        chart_kind="line", aggregation="mean", qualifiers=(SYSTEM_QUALIFIER, *THREE_PHASE_QUALIFIERS),
        label="Power Factor",
    ),
    "FREQUENCY": DataPointDefinition(
        chart_kind="line", aggregation="mean", qualifiers=(None,),
        label="Frequency",
    ),
}


def data_point_label(code: str, fallback: str | None) -> str | None:
    definition = ANALYTICS_DATA_POINTS.get(code)
    return definition.label if definition is not None and definition.label else fallback


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


# Coarser resolutions Auto may fall back to when its choice starts before
# that resolution's retention floor (floor-aware Auto, Data Quality decision 3).
AUTO_FALLBACKS: dict[str, tuple[str, ...]] = {"15m": ("1h", "1d"), "1h": ("1d",), "1d": ()}


# ---------------------------------------------------------------------------
# Response models -- GET /api/v1/sites/{site_id}/analytics/catalog.
# ---------------------------------------------------------------------------

class AnalyticsPhases(BaseModel):
    system: bool
    three_phase: bool


class AnalyticsAssignmentPeriod(BaseModel):
    # [assigned_from, assigned_to); None = unbounded at that end.
    assigned_from: datetime | None = None
    assigned_to: datetime | None = None


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
    # When the data point is assigned to the asset (migration 288): current,
    # closed and future assignments, in time order. Data outside every
    # period is NOT_ASSIGNED.
    assignment_periods: list[AnalyticsAssignmentPeriod] = Field(default_factory=list)


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
    # Earliest instant this resolution can serve for the site (retention
    # floor; for 1h at a site whose local hours are not UTC hours, the
    # 15-minute floor). None = no floor.
    available_from: datetime | None = None


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
    # COMPLETE / IN_PROGRESS / FUTURE, relative to the response's as_of.
    bucket_state: str
    # MEASURED / GAP / NOT_ASSIGNED / BEFORE_DATA / AFTER_LATEST_DATA / FUTURE.
    data_state: str | None = None
    # Interval counts at the site's capture interval. assigned_expected
    # covers only assigned, elapsed time between first and last data, less
    # the device's first-ever (INITIAL) reading; invalid excludes it too.
    expected_intervals: int | None = None
    assigned_expected_intervals: int | None = None
    valid_intervals: int = 0
    invalid_intervals: int = 0
    reconstructed_intervals: int = 0
    # Every evidence condition present in the bucket.
    evidence_flags: list[str] = Field(default_factory=list)
    # Kept for compatibility: the most severe Energy evidence status (GOOD,
    # GAPS_DETECTED, RECONSTRUCTED_TIMING, RESET_DETECTED, ROLLOVER_DETECTED,
    # INVALID_INTERVALS); null for an empty bucket. Energy is not mapped onto
    # the five-value quality lattice (MVP-4 decision pack).
    evidence_status: str | None = None
    # Non-Energy only: the GOOD/GAP/ESTIMATED/INVALID/PARTIAL lattice.
    quality: str | None = None
    # Kept for compatibility: bucket_state != COMPLETE.
    is_partial: bool


class AnalyticsSeriesSummary(BaseModel):
    total: float | None = None
    average: float | None = None
    min: float | None = None
    min_at: datetime | None = None
    max: float | None = None
    max_at: datetime | None = None


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
    status_reasons: list[str] = Field(default_factory=list)
    resolution_available_from: datetime | None = None
    first_data_at: datetime | None = None
    last_data_at: datetime | None = None
    stale: bool | None = None
    points: list[AnalyticsSeriesPoint]
    summary: AnalyticsSeriesSummary


class AnalyticsSeriesResponse(BaseModel):
    model_config = ConfigDict(populate_by_name=True)

    site_id: UUID
    site_timezone: str | None = None
    as_of: datetime
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

# Unavailability reasons that mean the resolution (not the data) cannot serve
# the request; any other reason makes the series DATA_UNAVAILABLE.
RESOLUTION_REASONS = frozenset({"BEFORE_RETENTION_FLOOR", "CAPTURE_INTERVAL_TOO_COARSE"})

# Evidence flags, in the Energy evidence precedence (migration 269).
EVIDENCE_FLAG_COUNTERS: tuple[tuple[str, str], ...] = (
    ("INVALID_INTERVALS", "invalid"),
    ("RESET_DETECTED", "reset"),
    ("GAPS_DETECTED", "gap"),
    ("RECONSTRUCTED_TIMING", "reconstructed"),
    ("ROLLOVER_DETECTED", "rollover"),
)


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
    """Series a selection can expand into (the registry's phases; an asset
    without per-phase values returns fewer, never more)."""

    definition = ANALYTICS_DATA_POINTS[selection.data_point]
    if phase == "three_phase" and definition.phase_qualifiers:
        return len(definition.phase_qualifiers)
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
            data_point, data_point_name, category, unit, qualifier,
            assigned_from, assigned_to
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


async def fetch_analytics_as_of() -> datetime:
    """The request's single "now" (database clock). Every read in the
    request is evaluated at this instant."""

    rows = await _read_rows("SELECT now() AS as_of", ())
    return rows[0]["as_of"]


async def fetch_analytics_energy_series(
    portal_user_id: int,
    site_id: UUID,
    asset_ids: list[UUID],
    dt_from: datetime,
    dt_to: datetime,
    resolution: str,
    as_of: datetime,
) -> list[dict[str, Any]]:
    return await _read_rows(
        """
        SELECT
            asset_id, bucket_start, bucket_end, import_kwh, export_kwh,
            import_status, export_status,
            import_valid_intervals, import_invalid_intervals, import_reconstructed_intervals,
            import_gap_intervals, import_reset_intervals, import_rollover_intervals,
            export_valid_intervals, export_invalid_intervals, export_reconstructed_intervals,
            export_gap_intervals, export_reset_intervals, export_rollover_intervals,
            expected_intervals, import_assigned_expected_intervals, export_assigned_expected_intervals,
            import_data_state, export_data_state, is_partial, unavailable_reasons,
            import_first_data_at, import_last_data_at, export_first_data_at, export_last_data_at,
            import_assigned_in_range, export_assigned_in_range, import_stale, export_stale
        FROM analytics.get_portal_asset_energy_series(%s, %s, %s::uuid[], %s, %s, %s, %s)
        """,
        (portal_user_id, str(site_id), [str(a) for a in asset_ids], dt_from, dt_to, resolution, as_of),
    )


async def fetch_analytics_energy_resolution_floors(
    site_id: UUID, as_of: datetime | None = None
) -> dict[str, datetime | None]:
    """Earliest instant each resolution's Energy source retains at as_of
    (None = no retention policy); for 1h at a site whose local hours are not
    UTC hours, the 15-minute floor. From the site-aware
    analytics.get_analytics_energy_resolution_floors (migration 282)."""

    rows = await _read_rows(
        "SELECT resolution, earliest_available FROM analytics.get_analytics_energy_resolution_floors(%s, %s)",
        (str(site_id), as_of),
    )
    return {row["resolution"]: row["earliest_available"] for row in rows}


# Source kinds of the generic read (migration 292): "mean" = measurements,
# "delta" = per-phase Energy register deltas. "energy" = the Energy System
# tiers (above).
SOURCE_ENERGY = "energy"
SOURCE_MEAN = "mean"
SOURCE_DELTA = "delta"


@dataclass(frozen=True)
class PointSpec:
    """One series of the generic read: asset, parameter code and the
    qualifier of the logical point (None = unqualified)."""

    asset_id: UUID
    data_point: str
    qualifier: str | None


async def fetch_analytics_point_availability(
    portal_user_id: int, site_id: UUID, points: list[tuple[str, str | None]]
) -> list[dict[str, Any]]:
    """First / last data per (asset, parameter, qualifier) for the requested
    registry points, from analytics.get_portal_analytics_point_availability
    (migration 292). Null bounds = assigned, no data yet."""

    if not points:
        return []
    return await _read_rows(
        """
        SELECT asset_id, data_point, qualifier, available_from, available_to
        FROM analytics.get_portal_analytics_point_availability(%s, %s, %s::text[], %s::text[])
        """,
        (portal_user_id, str(site_id), [p for p, _ in points], [q for _, q in points]),
    )


async def fetch_analytics_point_series(
    portal_user_id: int,
    site_id: UUID,
    specs: list[PointSpec],
    dt_from: datetime,
    dt_to: datetime,
    resolution: str,
    as_of: datetime,
) -> list[dict[str, Any]]:
    """Generic series rows (migration 292), series_index = 1-based position
    in `specs`."""

    if not specs:
        return []
    return await _read_rows(
        """
        SELECT
            series_index, asset_id, data_point, qualifier, source_kind,
            bucket_start, bucket_end, value, min_value, max_value,
            valid_intervals, invalid_intervals, gap_intervals, reset_intervals, rollover_intervals,
            expected_intervals, assigned_expected_intervals, data_state, quality,
            unavailable_reasons, first_data_at, last_data_at, assigned_in_range
        FROM analytics.get_portal_asset_point_series(
            %s, %s, %s::uuid[], %s::text[], %s::text[], %s, %s, %s, %s)
        """,
        (
            portal_user_id,
            str(site_id),
            [str(s.asset_id) for s in specs],
            [s.data_point for s in specs],
            [s.qualifier for s in specs],
            dt_from,
            dt_to,
            resolution,
            as_of,
        ),
    )


async def fetch_analytics_point_resolution_floors(
    as_of: datetime | None = None,
) -> dict[str, dict[str, datetime | None]]:
    """source kind -> resolution -> earliest instant its source retains
    (migration 292). A missing resolution means the source cannot serve it
    (per-phase Energy has no 1m)."""

    rows = await _read_rows(
        "SELECT source_kind, resolution, earliest_available FROM analytics.get_analytics_point_resolution_floors(%s)",
        (as_of,),
    )
    floors: dict[str, dict[str, datetime | None]] = {}
    for row in rows:
        floors.setdefault(row["source_kind"], {})[row["resolution"]] = row["earliest_available"]
    return floors


def apply_floor_aware_auto(request: SeriesRequest, floors: dict[str, datetime | None]) -> SeriesRequest:
    """Auto never lands on a resolution that cannot serve the range: when the
    window-based choice starts before its retention floor, the next coarser
    resolution whose floor allows it is used (1d as the last resort). An
    explicitly requested resolution is never changed."""

    if request.requested_resolution != AUTO_RESOLUTION:
        return request

    def serves(resolution: str) -> bool:
        floor = floors.get(resolution)
        return floor is None or request.dt_from >= floor

    if serves(request.resolution):
        return request
    fallbacks = AUTO_FALLBACKS.get(request.resolution, ())
    chosen = next((r for r in fallbacks if serves(r)), fallbacks[-1] if fallbacks else request.resolution)
    return SeriesRequest(
        dt_from=request.dt_from,
        dt_to=request.dt_to,
        requested_resolution=request.requested_resolution,
        resolution=chosen,
        phase=request.phase,
        selections=request.selections,
    )


def energy_resolution_retained(request: SeriesRequest, floors: dict[str, datetime | None]) -> bool:
    """False when the request starts before the resolved resolution's Energy
    tier retention floor: that series is RESOLUTION_UNAVAILABLE rather than
    a run of silently empty buckets."""

    floor = floors.get(request.resolution)
    return floor is None or request.dt_from >= floor


# ---------------------------------------------------------------------------
# Response building -- catalogue.
# ---------------------------------------------------------------------------

def _resolutions(floors: dict[str, datetime | None] | None = None) -> list[AnalyticsResolution]:
    return [
        AnalyticsResolution(
            resolution=code,
            max_window_seconds=int(max_window.total_seconds()),
            default_window_seconds=int(default_window.total_seconds()),
            available_from=_utc((floors or {}).get(code)),
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


def _catalog_qualifiers(rows: list[dict[str, Any]]) -> dict[tuple[str, str], set[str | None]]:
    """(asset_id, data_point) -> the registry-servable qualifiers the asset
    has an assignment of (any period)."""

    present: dict[tuple[str, str], set[str | None]] = {}
    for row in rows:
        definition = ANALYTICS_DATA_POINTS.get(row["data_point"])
        if definition is None or row["qualifier"] not in definition.qualifiers:
            continue
        present.setdefault((str(row["asset_id"]), row["data_point"]), set()).add(row["qualifier"])
    return present


def point_availability_requests() -> list[tuple[str, str | None]]:
    """(parameter, System qualifier) of every registry point that is not
    served by the Energy System tiers -- the bounds the catalogue needs from
    analytics.get_portal_analytics_point_availability."""

    return [
        (code, definition.system_qualifier)
        for code, definition in ANALYTICS_DATA_POINTS.items()
        if definition.energy_direction is None
    ]


def _merge_periods(
    periods: set[tuple[datetime | None, datetime | None]],
) -> list[AnalyticsAssignmentPeriod]:
    """Union of [from, to) periods (None = unbounded), in time order;
    overlapping or touching periods become one."""

    lowest = datetime.min.replace(tzinfo=timezone.utc)
    highest = datetime.max.replace(tzinfo=timezone.utc)
    ordered = sorted(
        ((_utc(start) or lowest, _utc(end) or highest) for start, end in periods),
    )
    merged: list[list[datetime]] = []
    for start, end in ordered:
        if merged and start <= merged[-1][1]:
            merged[-1][1] = max(merged[-1][1], end)
        else:
            merged.append([start, end])
    return [
        AnalyticsAssignmentPeriod(
            assigned_from=None if start == lowest else start,
            assigned_to=None if end == highest else end,
        )
        for start, end in merged
    ]


def build_analytics_catalog_response(
    *,
    site: dict[str, Any],
    rows: list[dict[str, Any]],
    availability: list[dict[str, Any]] | None = None,
    floors: dict[str, datetime | None] | None = None,
) -> AnalyticsCatalogResponse:
    """Group catalogue rows into assets -> registry data points.

    A row whose parameter is not in the registry, or whose qualifier the
    registry cannot serve, is dropped. An asset left with no data point is
    omitted: the catalogue lists only assets the customer can chart.
    Ordering is deterministic: assets by name then id, data points by the
    registry's own order. Availability bounds are attached per data point;
    null bounds mean no data yet. Each data point carries its assignment
    periods (one catalogue row per period since migration 288).
    """

    bounds: dict[tuple[str, str], tuple[datetime | None, datetime | None]] = {}
    for r in availability or []:
        key = (str(r["asset_id"]), r["data_point"])
        low, high = bounds.get(key, (None, None))
        start, end = _utc(r.get("available_from")), _utc(r.get("available_to"))
        bounds[key] = (
            start if low is None else (low if start is None else min(low, start)),
            end if high is None else (high if end is None else max(high, end)),
        )
    assets: dict[str, dict[str, Any]] = {}
    qualifiers: dict[tuple[str, str], set[str]] = {}
    periods: dict[tuple[str, str], set[tuple[datetime | None, datetime | None]]] = {}
    for row in rows:
        definition = ANALYTICS_DATA_POINTS.get(row["data_point"])
        if definition is None or row["qualifier"] not in definition.qualifiers:
            continue
        asset_key = str(row["asset_id"])
        asset = assets.setdefault(asset_key, {"row": row, "points": {}})
        asset["points"].setdefault(row["data_point"], row)
        qualifiers.setdefault((asset_key, row["data_point"]), set()).add(row["qualifier"])
        periods.setdefault((asset_key, row["data_point"]), set()).add(
            (row.get("assigned_from"), row.get("assigned_to"))
        )

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
                    label=data_point_label(code, point_row["data_point_name"]),
                    category=point_row.get("category"),
                    unit=point_row.get("unit"),
                    chart_kind=definition.chart_kind,
                    aggregation=definition.aggregation,
                    phases=AnalyticsPhases(
                        system=definition.system_qualifier in present,
                        three_phase=bool(definition.phase_qualifiers)
                        and set(definition.phase_qualifiers) <= present,
                    ),
                    available_from=_utc(available_from),
                    available_to=_utc(available_to),
                    assignment_periods=_merge_periods(periods[(asset_key, code)]),
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
        resolutions=_resolutions(floors),
        assets=catalog_assets,
    )


# ---------------------------------------------------------------------------
# Response building -- series.
# ---------------------------------------------------------------------------

@dataclass(frozen=True)
class PlannedSeries:
    """One response series: which source serves it, and with what qualifier.

    kind: SOURCE_ENERGY (Energy System tiers), SOURCE_MEAN (measurements),
    SOURCE_DELTA (per-phase Energy) or None (NOT_AVAILABLE)."""

    selection: Selection
    kind: str | None
    qualifier: str                     # API qualifier: "TOTAL" for System
    spec: PointSpec | None = None      # generic-read spec (mean / delta)
    catalog_row: dict[str, Any] | None = None


def plan_series(request: SeriesRequest, catalog_rows: list[dict[str, Any]]) -> list[PlannedSeries]:
    """Expand the selections into response series, in request order.

    A selection the catalogue cannot serve is one NOT_AVAILABLE series.
    System: one series. 3 Phase: one series per phase when the asset has
    every phase of the point assigned (per-phase Energy only from 15m:
    there is no 1-minute per-phase source); otherwise the System series is
    returned (the 3-phase fallback, qualifier TOTAL)."""

    pairs = _available_pairs(catalog_rows)
    present = _catalog_qualifiers(catalog_rows)
    planned: list[PlannedSeries] = []
    for selection in request.selections:
        definition = ANALYTICS_DATA_POINTS[selection.data_point]
        key = (str(selection.asset_id), selection.data_point)
        row = pairs.get(key)
        qualifiers = present.get(key, set())
        if row is None:
            planned.append(PlannedSeries(selection, None, SYSTEM_QUALIFIER))
            continue

        phased = (
            request.phase == "three_phase"
            and bool(definition.phase_qualifiers)
            and set(definition.phase_qualifiers) <= qualifiers
            and not (definition.energy_direction and request.resolution == "1m")
        )
        if phased:
            kind = SOURCE_DELTA if definition.energy_direction else SOURCE_MEAN
            for qualifier in definition.phase_qualifiers:
                planned.append(
                    PlannedSeries(
                        selection, kind, qualifier,
                        PointSpec(selection.asset_id, selection.data_point, qualifier), row,
                    )
                )
        elif definition.system_qualifier not in qualifiers:
            planned.append(PlannedSeries(selection, None, SYSTEM_QUALIFIER))
        elif definition.energy_direction:
            planned.append(PlannedSeries(selection, SOURCE_ENERGY, SYSTEM_QUALIFIER, None, row))
        else:
            planned.append(
                PlannedSeries(
                    selection, SOURCE_MEAN, SYSTEM_QUALIFIER,
                    PointSpec(selection.asset_id, selection.data_point, definition.system_qualifier), row,
                )
            )
    return planned


def planned_kinds(planned: list[PlannedSeries]) -> set[str]:
    return {p.kind for p in planned if p.kind is not None}


def energy_asset_ids(planned: list[PlannedSeries]) -> list[UUID]:
    """Assets with an Energy System series -- the only assets the Energy
    series read is asked for."""

    return sorted({p.selection.asset_id for p in planned if p.kind == SOURCE_ENERGY}, key=str)


def point_specs(planned: list[PlannedSeries]) -> list[PointSpec]:
    """Generic-read specs, in response order (series_index = position + 1)."""

    return [p.spec for p in planned if p.spec is not None]


def combined_floors(
    kinds: set[str],
    energy_floors: dict[str, datetime | None],
    point_floors: dict[str, dict[str, datetime | None]],
) -> dict[str, datetime | None]:
    """Per resolution, the latest retention floor across the sources the
    request uses -- what floor-aware Auto must respect so every series can
    be served. A source that cannot serve a resolution at all (per-phase
    Energy at 1m) does not constrain it: that series falls back to System."""

    combined: dict[str, datetime | None] = {code: None for code in ANALYTICS_RESOLUTION_WINDOWS}
    maps = ([energy_floors] if SOURCE_ENERGY in kinds else []) + [
        point_floors.get(kind, {}) for kind in (SOURCE_MEAN, SOURCE_DELTA) if kind in kinds
    ]
    for code in combined:
        values = [_utc(m[code]) for m in maps if m.get(code) is not None]
        combined[code] = max(values) if values else None
    return combined


def _float(value: Any) -> float | None:
    if value is None:
        return None
    return float(value) if isinstance(value, (Decimal, int, float)) else float(value)


def _int(value: Any) -> int:
    return int(value) if value is not None else 0


def _bucket_state(start: datetime, end: datetime, as_of: datetime) -> str:
    if end <= as_of:
        return "COMPLETE"
    if start <= as_of:
        return "IN_PROGRESS"
    return "FUTURE"


def _evidence_flags(counts: dict[str, int]) -> list[str]:
    return [flag for flag, counter in EVIDENCE_FLAG_COUNTERS if counts.get(counter, 0) > 0]


def _no_data_reason(
    request: SeriesRequest,
    as_of: datetime,
    assigned_in_range: bool | None,
    first_data_at: datetime | None,
    last_data_at: datetime | None,
) -> str:
    """Why a valid, served selection has no value in range (first match)."""

    if assigned_in_range is False:
        return "NOT_ASSIGNED_IN_RANGE"
    if last_data_at is None:
        return "NO_DATA_EVER"
    if request.dt_from >= as_of:
        return "RANGE_IN_FUTURE"
    if first_data_at is not None and request.dt_to <= first_data_at:
        return "RANGE_BEFORE_DATA"
    if request.dt_from >= last_data_at:
        return "RANGE_AFTER_LATEST_DATA"
    return "NO_DATA_IN_RANGE"


def _summary(points: list[AnalyticsSeriesPoint], *, summed: bool) -> AnalyticsSeriesSummary:
    """Total (summed points only): every period with a value in the range,
    the in-progress period included -- the Energy recorded so far. Average /
    min / max: completed periods only, so a period still filling up is never
    reported as the minimum or pulls the average down (Product Owner,
    2026-10-09). With no completed period they are null. A measurement has no
    Total (its periods are averages)."""

    valued = [p for p in points if p.value is not None]
    total = sum(p.value for p in valued) if summed and valued else None
    complete = [p for p in valued if p.bucket_state == "COMPLETE"]
    if not complete:
        return AnalyticsSeriesSummary(total=total)
    lowest = min(complete, key=lambda p: (p.value, p.bucket_start))
    highest = max(complete, key=lambda p: (p.value, -p.bucket_start.timestamp()))
    return AnalyticsSeriesSummary(
        total=total,
        average=sum(p.value for p in complete) / len(complete),
        min=lowest.value,
        min_at=lowest.bucket_start,
        max=highest.value,
        max_at=highest.bucket_start,
    )


def _unavailable(base: dict[str, Any], reasons: list[str], available_from: datetime | None) -> AnalyticsSeries:
    status = STATUS_RESOLUTION_UNAVAILABLE if set(reasons) <= RESOLUTION_REASONS else STATUS_DATA_UNAVAILABLE
    return AnalyticsSeries(
        **base,
        status=status,
        status_reasons=reasons,
        resolution_available_from=available_from if "BEFORE_RETENTION_FLOOR" in reasons else None,
        points=[],
        summary=AnalyticsSeriesSummary(),
    )


def _finish(
    base: dict[str, Any],
    points: list[AnalyticsSeriesPoint],
    *,
    request: SeriesRequest,
    as_of: datetime,
    first_data_at: datetime | None,
    last_data_at: datetime | None,
    assigned_in_range: bool | None,
    stale: bool | None,
    summed: bool,
) -> AnalyticsSeries:
    series_fields = dict(first_data_at=first_data_at, last_data_at=last_data_at, stale=stale)
    if not any(p.value is not None for p in points):
        return AnalyticsSeries(
            **base,
            **series_fields,
            status=STATUS_NO_DATA,
            status_reasons=[_no_data_reason(request, as_of, assigned_in_range, first_data_at, last_data_at)],
            points=points,
            summary=AnalyticsSeriesSummary(),
        )
    return AnalyticsSeries(
        **base, **series_fields, status=STATUS_OK, points=points, summary=_summary(points, summed=summed)
    )


def _series_base(plan: PlannedSeries, definition: DataPointDefinition) -> dict[str, Any]:
    row = plan.catalog_row or {}
    return dict(
        asset_id=plan.selection.asset_id,
        asset_name=row.get("asset_name"),
        data_point=plan.selection.data_point,
        label=data_point_label(plan.selection.data_point, row.get("data_point_name")),
        qualifier=plan.qualifier,
        unit=row.get("unit"),
        chart_kind=definition.chart_kind,
        aggregation=definition.aggregation,
    )


def _energy_series(
    plan: PlannedSeries,
    definition: DataPointDefinition,
    rows: list[dict[str, Any]],
    *,
    request: SeriesRequest,
    as_of: datetime,
    floors: dict[str, datetime | None],
) -> AnalyticsSeries:
    direction = definition.energy_direction
    base = _series_base(plan, definition)

    reasons: list[str] = []
    for row in rows:
        for reason in row.get("unavailable_reasons") or []:
            if reason not in reasons:
                reasons.append(reason)
    if reasons:
        return _unavailable(base, reasons, _utc(floors.get(request.resolution)))

    head = rows[0] if rows else {}
    points: list[AnalyticsSeriesPoint] = []
    for row in rows:
        start, end = _utc(row["bucket_start"]), _utc(row["bucket_end"])
        counts = {
            "valid": _int(row[f"{direction}_valid_intervals"]),
            "invalid": _int(row[f"{direction}_invalid_intervals"]),
            "reconstructed": _int(row[f"{direction}_reconstructed_intervals"]),
            "gap": _int(row[f"{direction}_gap_intervals"]),
            "reset": _int(row[f"{direction}_reset_intervals"]),
            "rollover": _int(row[f"{direction}_rollover_intervals"]),
        }
        expected = row.get("expected_intervals")
        assigned_expected = row.get(f"{direction}_assigned_expected_intervals")
        points.append(
            AnalyticsSeriesPoint(
                bucket_start=start,
                bucket_end=end,
                value=_float(row[f"{direction}_kwh"]),
                bucket_state=_bucket_state(start, end, as_of),
                data_state=row.get(f"{direction}_data_state"),
                expected_intervals=None if expected is None else int(expected),
                assigned_expected_intervals=None if assigned_expected is None else int(assigned_expected),
                valid_intervals=counts["valid"],
                invalid_intervals=counts["invalid"],
                reconstructed_intervals=counts["reconstructed"],
                evidence_flags=_evidence_flags(counts),
                evidence_status=row[f"{direction}_status"],
                is_partial=end > as_of,
            )
        )

    return _finish(
        base,
        points,
        request=request,
        as_of=as_of,
        first_data_at=_utc(head.get(f"{direction}_first_data_at")),
        last_data_at=_utc(head.get(f"{direction}_last_data_at")),
        assigned_in_range=head.get(f"{direction}_assigned_in_range"),
        stale=head.get(f"{direction}_stale"),
        summed=True,
    )


def _point_series(
    plan: PlannedSeries,
    definition: DataPointDefinition,
    rows: list[dict[str, Any]],
    *,
    request: SeriesRequest,
    as_of: datetime,
    point_floors: dict[str, dict[str, datetime | None]],
) -> AnalyticsSeries:
    """A series of the generic read (migration 292). Measurements carry
    the bucket mean with its min / max and the GOOD/PARTIAL/GAP quality;
    per-phase Energy carries the summed register deltas with the Energy
    evidence flags. stale is not evaluated for these sources (null)."""

    base = _series_base(plan, definition)
    summed = plan.kind == SOURCE_DELTA

    reasons: list[str] = []
    for row in rows:
        for reason in row.get("unavailable_reasons") or []:
            if reason not in reasons:
                reasons.append(reason)
    if reasons:
        floor = point_floors.get(plan.kind or "", {}).get(request.resolution)
        return _unavailable(base, reasons, _utc(floor))

    head = rows[0] if rows else {}
    points: list[AnalyticsSeriesPoint] = []
    for row in rows:
        start, end = _utc(row["bucket_start"]), _utc(row["bucket_end"])
        counts = {
            "valid": _int(row.get("valid_intervals")),
            "invalid": _int(row.get("invalid_intervals")),
            "gap": _int(row.get("gap_intervals")),
            "reset": _int(row.get("reset_intervals")),
            "rollover": _int(row.get("rollover_intervals")),
        }
        value = _float(row.get("value"))
        flags = _evidence_flags(counts)
        expected = row.get("expected_intervals")
        assigned_expected = row.get("assigned_expected_intervals")
        points.append(
            AnalyticsSeriesPoint(
                bucket_start=start,
                bucket_end=end,
                value=value,
                min=None if summed else _float(row.get("min_value")),
                max=None if summed else _float(row.get("max_value")),
                bucket_state=_bucket_state(start, end, as_of),
                data_state=row.get("data_state"),
                expected_intervals=None if expected is None else int(expected),
                assigned_expected_intervals=None if assigned_expected is None else int(assigned_expected),
                valid_intervals=counts["valid"],
                invalid_intervals=counts["invalid"],
                evidence_flags=flags,
                evidence_status=(flags[0] if flags else "GOOD") if summed and value is not None else None,
                quality=None if summed else row.get("quality"),
                is_partial=end > as_of,
            )
        )

    return _finish(
        base,
        points,
        request=request,
        as_of=as_of,
        first_data_at=_utc(head.get("first_data_at")),
        last_data_at=_utc(head.get("last_data_at")),
        assigned_in_range=head.get("assigned_in_range"),
        stale=None,
        summed=summed,
    )


def build_analytics_series_response(
    *,
    site: dict[str, Any],
    request: SeriesRequest,
    catalog_rows: list[dict[str, Any]],
    energy_rows: list[dict[str, Any]],
    as_of: datetime,
    floors: dict[str, datetime | None] | None = None,
    energy_resolution_available: bool = True,
    point_rows: list[dict[str, Any]] | None = None,
    point_floors: dict[str, dict[str, datetime | None]] | None = None,
) -> AnalyticsSeriesResponse:
    """Series in request order (a selection expands to its phases under 3
    Phase). A selection the catalogue cannot serve (asset not an ACTIVE
    asset of this site, or data point not assigned to it) is returned as
    NOT_AVAILABLE -- never dropped, and never distinguishable from an asset
    that does not exist. So is a generic-read series the database returned
    no rows for (an asset the portal user cannot access)."""

    as_of = _utc(as_of)
    floors = floors or {}
    point_floors = point_floors or {}
    planned = plan_series(request, catalog_rows)

    energy_by_asset: dict[str, list[dict[str, Any]]] = {}
    for row in energy_rows:
        energy_by_asset.setdefault(str(row["asset_id"]), []).append(row)
    point_by_index: dict[int, list[dict[str, Any]]] = {}
    for row in point_rows or []:
        point_by_index.setdefault(int(row["series_index"]), []).append(row)

    def by_bucket(rows: list[dict[str, Any]]) -> list[dict[str, Any]]:
        return sorted(rows, key=lambda r: (r["bucket_start"] is not None, r["bucket_start"] or datetime.min))

    series: list[AnalyticsSeries] = []
    spec_index = 0
    for plan in planned:
        definition = ANALYTICS_DATA_POINTS[plan.selection.data_point]
        not_available = AnalyticsSeries(
            asset_id=plan.selection.asset_id,
            data_point=plan.selection.data_point,
            qualifier=plan.qualifier,
            chart_kind=definition.chart_kind,
            aggregation=definition.aggregation,
            status=STATUS_NOT_AVAILABLE,
            points=[],
            summary=AnalyticsSeriesSummary(),
        )
        if plan.kind is None:
            series.append(not_available)
        elif plan.kind == SOURCE_ENERGY:
            if not energy_resolution_available:
                rows = [{"unavailable_reasons": ["BEFORE_RETENTION_FLOOR"]}]
            else:
                rows = by_bucket(energy_by_asset.get(str(plan.selection.asset_id), []))
            series.append(_energy_series(plan, definition, rows, request=request, as_of=as_of, floors=floors))
        else:
            spec_index += 1
            rows = point_by_index.get(spec_index)
            if not rows:
                series.append(not_available)
            else:
                series.append(
                    _point_series(
                        plan, definition, by_bucket(rows), request=request, as_of=as_of, point_floors=point_floors
                    )
                )

    return AnalyticsSeriesResponse(
        site_id=site["site_id"],
        site_timezone=site.get("timezone"),
        as_of=as_of,
        range_from=request.dt_from,
        range_to=request.dt_to,
        requested_resolution=request.requested_resolution,
        resolution=request.resolution,
        phase=request.phase,
        series=series,
    )
