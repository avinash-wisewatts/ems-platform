"""Phase 7 -- /api/v1 semantic read API: contract, validation, and data access.

This module is the thin application half of the Phase 7 query boundary. It
holds NO analytics or energy business logic: every value it returns comes from
one of the scoped SECURITY DEFINER functions created by migration 231
(analytics.get_portal_*), or from the pre-existing admin.list_accessible_sites
/ admin.portal_user_can_access_site. Tenant scope is enforced server-side, in
the database, keyed on the authenticated portal_user_id.
"""

from __future__ import annotations

import statistics
from datetime import datetime, timedelta, timezone
from typing import Any
from uuid import UUID

from pydantic import BaseModel, ConfigDict, Field


# ---------------------------------------------------------------------------
# Closed contract vocabulary -- first slice only.
# ---------------------------------------------------------------------------

SUPPORTED_MEASUREMENT_PARAMETERS: tuple[str, ...] = (
    "TEMPERATURE",
    "HUMIDITY",
    "DEW_POINT",
)

MEASUREMENT_PARAMETER_UNITS: dict[str, str] = {
    "TEMPERATURE": "degC",
    "HUMIDITY": "percent",
    "DEW_POINT": "degC",
}

# resolution -> maximum allowed [from, to) span.
MEASUREMENT_RESOLUTION_MAX_WINDOW: dict[str, timedelta] = {
    "raw": timedelta(hours=24),
    "1h": timedelta(days=31),
}

ENERGY_RESOLUTION_MAX_WINDOW: dict[str, timedelta] = {
    "1h": timedelta(days=31),
    "1d": timedelta(days=366),
}

# Slice B -- Demand. analytics.demand_intervals carries no coarser
# persisted tier (native interval grain only, 900s or 1800s per the site's
# config.site_demand_policies), so there is a single flat window cap rather
# than a per-resolution table -- reusing the same 31-day bound already
# established for energy's 1h tier, not an invented new number.
DEMAND_MAX_WINDOW: timedelta = timedelta(days=31)

# Slice B -- Power Quality. telemetry.ca_energy_15min/hourly/daily are the
# three confirmed-live tiers (migrations 51/52/53). 1h and 1d reuse the
# exact energy caps above; 15min gets a conservative, shorter bound in the
# same spirit as the measurement "raw" tier's 24h cap.
POWER_QUALITY_RESOLUTION_MAX_WINDOW: dict[str, timedelta] = {
    "15min": timedelta(days=7),
    "1h": timedelta(days=31),
    "1d": timedelta(days=366),
}

# Slice C -- Energy typical historical reference. Locked product rules from
# the approved "Slice C Historical Comparison Final Implementation
# Specification" -- not provisional, not engineering-chosen defaults.
# period_length_days must be one of these five values (matching the
# TODAY/7D/30D/3M/1Y presets); the comparable-period step and the 8/5/70%
# constants below are enforced identically in migration 236's SQL body.
TYPICAL_REFERENCE_PERIOD_LENGTHS_DAYS: tuple[int, ...] = (1, 7, 30, 90, 365)

# The typical-reference function always requests exactly 8 comparable
# periods (migration 236 hard-codes this via generate_series(1, 8)); this
# constant exists so the response can echo it without a second source of
# truth drifting out of sync.
TYPICAL_REFERENCE_REQUESTED_PERIOD_COUNT: int = 8

# Minimum number of the 8 requested periods that must be eligible (see
# migration 236's eligible column) before a median is reported at all.
TYPICAL_REFERENCE_MIN_ELIGIBLE_PERIODS: int = 5


class ApiContractError(Exception):
    """A request violated the fixed /api/v1 contract (maps to HTTP 422)."""

    def __init__(self, code: str, detail: str) -> None:
        super().__init__(detail)
        self.code = code
        self.detail = detail


# ---------------------------------------------------------------------------
# Response models (the frozen response contract; serialized by alias).
# ---------------------------------------------------------------------------

class SiteSummary(BaseModel):
    model_config = ConfigDict(populate_by_name=True)

    site_id: UUID
    organization_id: UUID
    site_code: str
    site_name: str
    timezone: str | None = None


class SitesResponse(BaseModel):
    sites: list[SiteSummary]


class CurrentUserResponse(BaseModel):
    """Session echo for the frontend shell (GET /api/v1/me).

    Reflects only the already-safe fields of the authenticated portal
    session -- no password material, no session token, no secret. Tenant
    isolation is NOT derived from this payload: every data endpoint
    re-derives scope server-side from the session's portal_user_id.
    """

    portal_user_id: int
    username: str
    display_name: str
    role_code: str
    access_scope_mode: str
    organization_id: UUID | None = None
    site_ids: list[UUID]
    permissions: list[str]


class MeasurementPoint(BaseModel):
    bucket_start: datetime
    value: float
    quality: int | None
    sample_count: int


class MeasurementSeriesResponse(BaseModel):
    model_config = ConfigDict(populate_by_name=True)

    space_id: UUID
    parameter: str
    unit: str
    resolution: str
    range_from: datetime = Field(alias="from")
    range_to: datetime = Field(alias="to")
    no_data: bool
    series: list[MeasurementPoint]


class EnergyConsumptionPoint(BaseModel):
    bucket_start: datetime
    import_kwh: float | None
    export_kwh: float | None
    source_interval_count: int


class EnergyConsumptionResponse(BaseModel):
    model_config = ConfigDict(populate_by_name=True)

    site_id: UUID
    resolution: str
    range_from: datetime = Field(alias="from")
    range_to: datetime = Field(alias="to")
    no_data: bool
    series: list[EnergyConsumptionPoint]


class EnergyConsumptionEvidencePoint(BaseModel):
    """Slice C (C2). One bucket's evidence counters, read from the SAME
    analytics.energy_consumption_hourly/daily rows migration 231's
    EnergyConsumptionPoint already reads -- these columns exist there today
    and were simply never selected. No new classification is invented here.

    valid_import_intervals/invalid_import_intervals (and their export
    counterparts) are a genuine complementary pair -- each interval is
    exactly one or the other.

    gap_interval_count/reset_interval_count/rollover_interval_count/
    invalid_interval_count are INDEPENDENT evidence counters, traced (by
    static reading of the migration/ddl files, not a live-catalog query) to
    analytics.v_energy_semantic_rollup_15min (postgres/ddl/
    147_combined_energy_quality_counters.sql), where each is an
    independent COUNT(*) FILTER over its own boolean flag. They are NOT a
    mutually-exclusive classification and are NOT guaranteed to sum to
    source_interval_count -- a single interval can satisfy more than one
    flag at once. No priority-resolved single status is derived here."""

    bucket_start: datetime
    source_interval_count: int
    valid_import_intervals: int
    invalid_import_intervals: int
    valid_export_intervals: int
    invalid_export_intervals: int
    gap_interval_count: int
    reset_interval_count: int
    rollover_interval_count: int
    invalid_interval_count: int
    first_source_bucket: datetime | None
    last_source_bucket: datetime | None


class EnergyConsumptionEvidenceResponse(BaseModel):
    model_config = ConfigDict(populate_by_name=True)

    site_id: UUID
    resolution: str
    range_from: datetime = Field(alias="from")
    range_to: datetime = Field(alias="to")
    no_data: bool
    series: list[EnergyConsumptionEvidencePoint]


class EnergyTypicalReferenceWindow(BaseModel):
    """Slice C. One of the (always exactly 8) requested comparable
    historical periods, as returned by migration 236's
    get_portal_site_energy_typical_reference -- one row per window_index,
    whether or not that window has data.

    total_kwh is the window's own measured total (never a fabricated or
    zero-filled value -- null whenever the window has no data at all).
    eligible is true only when has_data AND coverage_percent >= 70.0 (the
    locked product rule); gap/reset/rollover/invalid counts are independent
    evidence and never determine eligible themselves (see the module-level
    comment on TYPICAL_REFERENCE_MIN_ELIGIBLE_PERIODS)."""

    window_index: int
    range_from: datetime = Field(alias="from")
    range_to: datetime = Field(alias="to")
    has_data: bool
    total_kwh: float | None
    source_interval_count: int
    valid_import_intervals: int
    coverage_percent: float | None
    eligible: bool
    gap_interval_count: int
    reset_interval_count: int
    rollover_interval_count: int
    invalid_interval_count: int


class EnergyTypicalReferenceResponse(BaseModel):
    """Slice C. Comparable-period historical reference for the CURRENT
    window described by [from, to). Does not carry the current period's
    own total -- that remains exclusively the existing, unmodified
    EnergyConsumptionResponse from GET /energy/consumption; this response
    is additive alongside it, never a replacement.

    typical_kwh is the median of the eligible windows' totals, and is null
    whenever eligible_period_count < TYPICAL_REFERENCE_MIN_ELIGIBLE_PERIODS
    -- insufficient history NEVER produces a manufactured or partial
    value."""

    model_config = ConfigDict(populate_by_name=True)

    site_id: UUID
    period_length_days: int
    range_from: datetime = Field(alias="from")
    range_to: datetime = Field(alias="to")
    typical_kwh: float | None
    requested_period_count: int
    windows_with_data_count: int
    eligible_period_count: int
    sufficient: bool
    windows: list[EnergyTypicalReferenceWindow]


class AlertSummary(BaseModel):
    """MVP-7 Basic Alerts (ADR-016/ADR-017). One row per alert occurrence,
    from analytics.get_portal_site_alerts / get_portal_alert_detail
    (migration 239). previous_occurrence_count /
    most_recent_previous_occurrence_at are derived at read time by the SQL
    function -- never a stored counter (ADR-016 decision 25: an expiring
    90-day-old occurrence must silently lower the count on its own).

    Known scope reduction (this pass): does not include a live "latest
    value" re-fetch (ADR-016 decision 34) -- only the persisted
    trigger_value / resolved_value are returned. Flagged in the
    implementation report, not silently omitted."""

    alert_id: UUID
    site_id: UUID
    space_id: UUID | None = None
    asset_id: UUID | None = None
    condition_key: str
    metric: str
    state: str
    triggered_at: datetime
    trigger_value: float
    resolved_at: datetime | None = None
    resolved_value: float | None = None
    ended_at: datetime | None = None
    ended_reason: str | None = None
    previous_occurrence_count: int
    most_recent_previous_occurrence_at: datetime | None = None


class AlertListResponse(BaseModel):
    site_id: UUID
    alerts: list[AlertSummary]


class SpaceSummary(BaseModel):
    """Slice 0 (Hierarchy Foundation). Identity + placement only -- no
    environmental snapshot, no comfort-target metadata (both out of scope
    for this increment)."""

    space_id: UUID
    site_id: UUID
    space_code: str
    space_name: str


class SpacesResponse(BaseModel):
    site_id: UUID
    spaces: list[SpaceSummary]


class AssetSummary(BaseModel):
    """Slice 0 (Hierarchy Foundation). Identity + placement only -- NO
    relationship/component-tree data (explicitly deferred; see migration
    232's header). space_id / parent_asset_id are passed through as-is and
    may be null."""

    asset_id: UUID
    site_id: UUID
    space_id: UUID | None = None
    parent_asset_id: UUID | None = None
    external_id: str
    asset_name: str
    lifecycle_status: str


class AssetsResponse(BaseModel):
    site_id: UUID
    assets: list[AssetSummary]


class DemandIntervalPoint(BaseModel):
    """One finalized interval from analytics.demand_intervals -- already
    meter-role-resolved and quality-tagged upstream; passed through as-is."""

    interval_start: datetime
    interval_end: datetime
    demand_kw: float | None
    peak_power_kw: float | None
    quality_status: str
    coverage_percent: float | None


class DemandSeriesResponse(BaseModel):
    model_config = ConfigDict(populate_by_name=True)

    site_id: UUID
    range_from: datetime = Field(alias="from")
    range_to: datetime = Field(alias="to")
    no_data: bool
    series: list[DemandIntervalPoint]


class CurrentDemandResponse(BaseModel):
    """The single most recent analytics.demand_state row for the site, if
    any. has_data distinguishes "no demand_state row yet" from a genuine
    reading -- there is no [from, to) window for a single current-state
    read, so no_data would be misleading here."""

    site_id: UUID
    has_data: bool
    interval_start: datetime | None = None
    interval_end: datetime | None = None
    current_demand_kw: float | None = None
    current_demand_kva: float | None = None
    quality_status: str | None = None
    coverage_percent: float | None = None


class PowerQualityPoint(BaseModel):
    """One bucket from telemetry.ca_energy_15min/hourly/daily for the
    site's resolved SITE_CONSUMPTION meter. current_thd is returned per
    phase (L1/L2/L3) -- no total-THD column exists in these continuous
    aggregates; see migration 234's header."""

    bucket_start: datetime
    power_factor_avg: float | None
    power_factor_min: float | None
    power_factor_max: float | None
    current_thd_l1_avg: float | None
    current_thd_l1_max: float | None
    current_thd_l2_avg: float | None
    current_thd_l2_max: float | None
    current_thd_l3_avg: float | None
    current_thd_l3_max: float | None


class PowerQualityResponse(BaseModel):
    model_config = ConfigDict(populate_by_name=True)

    site_id: UUID
    resolution: str
    range_from: datetime = Field(alias="from")
    range_to: datetime = Field(alias="to")
    no_data: bool
    series: list[PowerQualityPoint]


# MVP-4 -- Data Quality & Freshness. state is one of the four API-semantic
# values FRESH / STALE / NO_DATA / UNKNOWN -- never the internal six-value
# device_telemetry_state vocabulary (NEVER_SEEN/SILENT/RECEIVING/STALE/
# VALIDATED), and never a device_id. This is a signal separate from, and
# independent of, both the measurement-quality lattice (GOOD/GAP/ESTIMATED/
# INVALID/PARTIAL, see web/src/components/QualityIndicator.tsx) and Demand's
# own quality_status/coverage_percent -- neither is read, set, or influenced
# by this response. See docs/00-governance/decision-packs/
# mvp-4-data-quality-and-freshness-decision-pack.md Sec 5/5a.
FRESHNESS_STATES: tuple[str, ...] = ("FRESH", "STALE", "NO_DATA", "UNKNOWN")


class DomainFreshness(BaseModel):
    state: str
    as_of: datetime | None = None


class SiteTelemetryFreshnessResponse(BaseModel):
    """Per-domain freshness only -- deliberately no blended/site-wide
    verdict (decision pack Sec 5a). Energy and Power Quality currently
    resolve the same underlying SITE_CONSUMPTION meter, so their values
    will often match -- they remain three independent fields, not derived
    from one another, so that a future change to either resolution path
    does not silently couple them."""

    site_id: UUID
    energy: DomainFreshness
    demand: DomainFreshness
    power_quality: DomainFreshness


# ---------------------------------------------------------------------------
# Request validation -- deterministic, closed-set, explicit windows.
# ---------------------------------------------------------------------------

def validate_measurement_parameter(raw: str | None) -> str:
    if raw is None or raw not in SUPPORTED_MEASUREMENT_PARAMETERS:
        raise ApiContractError(
            "invalid_parameter",
            "parameter must be one of: "
            + ", ".join(SUPPORTED_MEASUREMENT_PARAMETERS),
        )
    return raw


def validate_resolution(raw: str | None, allowed: tuple[str, ...]) -> str:
    if raw is None or raw not in allowed:
        raise ApiContractError(
            "invalid_resolution",
            "resolution must be one of: " + ", ".join(allowed),
        )
    return raw


def _parse_instant(raw: str, field: str) -> datetime:
    if not isinstance(raw, str) or not raw.strip():
        raise ApiContractError(
            "invalid_time_range", f"{field} must be an ISO-8601 timestamp"
        )
    text = raw.strip()
    if text.endswith("Z") or text.endswith("z"):
        text = text[:-1] + "+00:00"
    try:
        parsed = datetime.fromisoformat(text)
    except ValueError:
        raise ApiContractError(
            "invalid_time_range",
            f"{field} must be an ISO-8601 timestamp (e.g. 2026-09-01T00:00:00Z)",
        )
    if parsed.tzinfo is None:
        # Naive timestamps are interpreted as UTC -- the single documented
        # assumption, not an invented resolution/aggregation semantic.
        parsed = parsed.replace(tzinfo=timezone.utc)
    return parsed.astimezone(timezone.utc)


def parse_time_range(
    from_raw: str,
    to_raw: str,
    *,
    resolution: str,
    max_window_by_resolution: dict[str, timedelta],
) -> tuple[datetime, datetime]:
    """Parse and bound a required [from, to) window for one resolution."""

    dt_from = _parse_instant(from_raw, "from")
    dt_to = _parse_instant(to_raw, "to")

    if dt_from >= dt_to:
        raise ApiContractError(
            "invalid_time_range", "from must be strictly before to"
        )

    max_window = max_window_by_resolution[resolution]
    if dt_to - dt_from > max_window:
        raise ApiContractError(
            "time_range_too_large",
            f"the maximum window for resolution '{resolution}' is "
            f"{int(max_window.total_seconds())} seconds",
        )

    return dt_from, dt_to


def parse_typical_reference_range(
    from_raw: str, to_raw: str
) -> tuple[datetime, datetime, int]:
    """Parse a [from, to) window for the Slice C typical-reference
    endpoint and derive period_length_days from it. Unlike
    parse_time_range, there is no resolution parameter -- the "resolution"
    here is entirely implied by the span, which must be a whole number of
    days matching one of TYPICAL_REFERENCE_PERIOD_LENGTHS_DAYS (the same
    five values migration 236's SQL body validates independently)."""

    dt_from = _parse_instant(from_raw, "from")
    dt_to = _parse_instant(to_raw, "to")

    if dt_from >= dt_to:
        raise ApiContractError(
            "invalid_time_range", "from must be strictly before to"
        )

    span_seconds = (dt_to - dt_from).total_seconds()
    if span_seconds % 86400 != 0:
        raise ApiContractError(
            "invalid_time_range",
            "the requested window must be a whole number of days",
        )

    period_length_days = int(span_seconds // 86400)
    if period_length_days not in TYPICAL_REFERENCE_PERIOD_LENGTHS_DAYS:
        raise ApiContractError(
            "invalid_period_length",
            "period length must be one of: "
            + ", ".join(
                f"{d} day{'s' if d != 1 else ''}"
                for d in TYPICAL_REFERENCE_PERIOD_LENGTHS_DAYS
            ),
        )

    return dt_from, dt_to, period_length_days


# ---------------------------------------------------------------------------
# Data access -- scoped SECURITY DEFINER functions only. Read-only.
# ---------------------------------------------------------------------------

async def _read_rows(sql: str, params: tuple[Any, ...]) -> list[dict[str, Any]]:
    from src.database import database_connection

    async with database_connection() as connection:
        async with connection.cursor() as cursor:
            await cursor.execute(sql, params)
            rows = await cursor.fetchall()
        # Every /api/v1 read is read-only; discard the snapshot explicitly.
        await connection.rollback()
    return rows


async def _read_scalar(sql: str, params: tuple[Any, ...]) -> Any:
    rows = await _read_rows(sql, params)
    if not rows:
        return None
    first = rows[0]
    return next(iter(first.values()))


async def fetch_accessible_sites(portal_user_id: int) -> list[dict[str, Any]]:
    return await _read_rows(
        """
        SELECT
            id            AS site_id,
            organization_id,
            site_code,
            site_name,
            timezone
        FROM admin.list_accessible_sites(%s)
        """,
        (portal_user_id,),
    )


async def portal_user_can_access_site(
    portal_user_id: int, site_id: UUID
) -> bool:
    result = await _read_scalar(
        "SELECT admin.portal_user_can_access_site(%s, %s) AS allowed",
        (portal_user_id, str(site_id)),
    )
    return bool(result)


async def portal_user_can_access_space(
    portal_user_id: int, space_id: UUID
) -> bool:
    result = await _read_scalar(
        "SELECT analytics.portal_user_can_access_space(%s, %s) AS allowed",
        (portal_user_id, str(space_id)),
    )
    return bool(result)


async def fetch_space_measurement_series(
    *,
    portal_user_id: int,
    space_id: UUID,
    parameter: str,
    dt_from: datetime,
    dt_to: datetime,
    resolution: str,
) -> list[dict[str, Any]]:
    return await _read_rows(
        """
        SELECT bucket_start, numeric_value, quality_code, sample_count
        FROM analytics.get_portal_space_measurement_series(
            %s, %s, %s, %s, %s, %s
        )
        ORDER BY bucket_start
        """,
        (
            portal_user_id,
            str(space_id),
            parameter,
            dt_from,
            dt_to,
            resolution,
        ),
    )


async def fetch_site_energy_consumption(
    *,
    portal_user_id: int,
    site_id: UUID,
    dt_from: datetime,
    dt_to: datetime,
    resolution: str,
) -> list[dict[str, Any]]:
    return await _read_rows(
        """
        SELECT
            bucket_start,
            import_consumption_kwh,
            export_consumption_kwh,
            source_interval_count
        FROM analytics.get_portal_site_energy_consumption(
            %s, %s, %s, %s, %s
        )
        ORDER BY bucket_start
        """,
        (
            portal_user_id,
            str(site_id),
            dt_from,
            dt_to,
            resolution,
        ),
    )


async def fetch_site_energy_consumption_evidence(
    *,
    portal_user_id: int,
    site_id: UUID,
    dt_from: datetime,
    dt_to: datetime,
    resolution: str,
) -> list[dict[str, Any]]:
    """Slice C (C2). Reads analytics.get_portal_site_energy_consumption_evidence
    (migration 235) -- an additive parallel read of the same two historians
    migration 231's fetch_site_energy_consumption reads. Does not call or
    modify that function."""

    return await _read_rows(
        """
        SELECT
            bucket_start,
            source_interval_count,
            valid_import_intervals,
            invalid_import_intervals,
            valid_export_intervals,
            invalid_export_intervals,
            gap_interval_count,
            reset_interval_count,
            rollover_interval_count,
            invalid_interval_count,
            first_source_bucket,
            last_source_bucket
        FROM analytics.get_portal_site_energy_consumption_evidence(
            %s, %s, %s, %s, %s
        )
        ORDER BY bucket_start
        """,
        (
            portal_user_id,
            str(site_id),
            dt_from,
            dt_to,
            resolution,
        ),
    )


async def fetch_site_energy_typical_reference(
    *,
    portal_user_id: int,
    site_id: UUID,
    dt_from: datetime,
    dt_to: datetime,
) -> list[dict[str, Any]]:
    """Slice C. Reads analytics.get_portal_site_energy_typical_reference
    (migration 236) -- an additive read of analytics.energy_consumption_daily
    only. Does not call, modify, or depend on migration 231's
    fetch_site_energy_consumption or migration 235's
    fetch_site_energy_consumption_evidence in any way."""

    return await _read_rows(
        """
        SELECT
            window_index,
            window_from,
            window_to,
            has_data,
            total_import_kwh,
            source_interval_count,
            valid_import_intervals,
            coverage_percent,
            eligible,
            gap_interval_count,
            reset_interval_count,
            rollover_interval_count,
            invalid_interval_count
        FROM analytics.get_portal_site_energy_typical_reference(
            %s, %s, %s, %s
        )
        ORDER BY window_index
        """,
        (portal_user_id, str(site_id), dt_from, dt_to),
    )


async def fetch_site_alerts(
    *,
    portal_user_id: int,
    site_id: UUID,
    state: str | None = None,
    condition_key: str | None = None,
    dt_from: datetime | None = None,
    dt_to: datetime | None = None,
    limit: int = 50,
    before: datetime | None = None,
) -> list[dict[str, Any]]:
    """MVP-7. Reads analytics.get_portal_site_alerts (migration 239)."""

    return await _read_rows(
        """
        SELECT
            alert_id, site_id, space_id, asset_id, condition_key, metric, state,
            triggered_at, trigger_value, resolved_at, resolved_value, ended_at, ended_reason,
            previous_occurrence_count, most_recent_previous_triggered_at
        FROM analytics.get_portal_site_alerts(%s, %s, %s, %s, %s, %s, %s, %s)
        """,
        (
            portal_user_id,
            str(site_id),
            state,
            condition_key,
            dt_from,
            dt_to,
            limit,
            before,
        ),
    )


async def fetch_alert_detail(
    *, portal_user_id: int, alert_id: UUID
) -> list[dict[str, Any]]:
    """MVP-7. Reads analytics.get_portal_alert_detail (migration 239)."""

    return await _read_rows(
        """
        SELECT
            alert_id, site_id, space_id, asset_id, condition_key, metric, state,
            triggered_at, trigger_value, resolved_at, resolved_value, ended_at, ended_reason,
            previous_occurrence_count, most_recent_previous_triggered_at
        FROM analytics.get_portal_alert_detail(%s, %s)
        """,
        (portal_user_id, str(alert_id)),
    )


def build_alert_summary(row: dict[str, Any]) -> AlertSummary:
    return AlertSummary(
        alert_id=row["alert_id"],
        site_id=row["site_id"],
        space_id=row["space_id"],
        asset_id=row["asset_id"],
        condition_key=row["condition_key"],
        metric=row["metric"],
        state=row["state"],
        triggered_at=row["triggered_at"],
        trigger_value=float(row["trigger_value"]),
        resolved_at=row["resolved_at"],
        resolved_value=(
            float(row["resolved_value"]) if row["resolved_value"] is not None else None
        ),
        ended_at=row["ended_at"],
        ended_reason=row["ended_reason"],
        previous_occurrence_count=int(row["previous_occurrence_count"] or 0),
        most_recent_previous_occurrence_at=row["most_recent_previous_triggered_at"],
    )


async def fetch_site_spaces(
    portal_user_id: int, site_id: UUID
) -> list[dict[str, Any]]:
    return await _read_rows(
        """
        SELECT space_id, site_id, space_code, space_name
        FROM analytics.list_portal_site_spaces(%s, %s)
        """,
        (portal_user_id, str(site_id)),
    )


async def fetch_site_assets(
    portal_user_id: int, site_id: UUID
) -> list[dict[str, Any]]:
    return await _read_rows(
        """
        SELECT
            asset_id, site_id, space_id, parent_asset_id,
            external_id, asset_name, lifecycle_status
        FROM analytics.list_portal_site_assets(%s, %s)
        """,
        (portal_user_id, str(site_id)),
    )


async def fetch_site_demand_series(
    *,
    portal_user_id: int,
    site_id: UUID,
    dt_from: datetime,
    dt_to: datetime,
) -> list[dict[str, Any]]:
    return await _read_rows(
        """
        SELECT interval_start, interval_end, demand_kw, peak_power_kw,
               quality_status, coverage_percent
        FROM analytics.get_portal_site_demand_series(%s, %s, %s, %s)
        ORDER BY interval_start
        """,
        (portal_user_id, str(site_id), dt_from, dt_to),
    )


async def fetch_site_current_demand(
    portal_user_id: int, site_id: UUID
) -> dict[str, Any] | None:
    rows = await _read_rows(
        """
        SELECT interval_start, interval_end, current_demand_kw,
               current_demand_kva, quality_status, coverage_percent
        FROM analytics.get_portal_site_current_demand(%s, %s)
        """,
        (portal_user_id, str(site_id)),
    )
    return rows[0] if rows else None


async def fetch_site_power_quality_series(
    *,
    portal_user_id: int,
    site_id: UUID,
    resolution: str,
    dt_from: datetime,
    dt_to: datetime,
) -> list[dict[str, Any]]:
    return await _read_rows(
        """
        SELECT bucket_start,
               power_factor_avg, power_factor_min, power_factor_max,
               current_thd_l1_avg, current_thd_l1_max,
               current_thd_l2_avg, current_thd_l2_max,
               current_thd_l3_avg, current_thd_l3_max
        FROM analytics.get_portal_site_power_quality_series(%s, %s, %s, %s, %s)
        ORDER BY bucket_start
        """,
        (portal_user_id, str(site_id), resolution, dt_from, dt_to),
    )


async def fetch_site_telemetry_freshness(
    portal_user_id: int, site_id: UUID
) -> dict[str, Any] | None:
    rows = await _read_rows(
        """
        SELECT site_id, energy_state, energy_as_of,
               demand_state, demand_as_of,
               power_quality_state, power_quality_as_of
        FROM analytics.get_portal_site_telemetry_freshness(%s, %s)
        """,
        (portal_user_id, str(site_id)),
    )
    return rows[0] if rows else None


# ---------------------------------------------------------------------------
# Row -> response-model mapping.
# ---------------------------------------------------------------------------

def build_sites_response(rows: list[dict[str, Any]]) -> SitesResponse:
    return SitesResponse(
        sites=[
            SiteSummary(
                site_id=row["site_id"],
                organization_id=row["organization_id"],
                site_code=row["site_code"],
                site_name=row["site_name"],
                timezone=row.get("timezone"),
            )
            for row in rows
        ]
    )


def build_measurement_series_response(
    *,
    space_id: UUID,
    parameter: str,
    resolution: str,
    dt_from: datetime,
    dt_to: datetime,
    rows: list[dict[str, Any]],
) -> MeasurementSeriesResponse:
    points = [
        MeasurementPoint(
            bucket_start=row["bucket_start"],
            value=float(row["numeric_value"]),
            quality=(
                int(row["quality_code"])
                if row["quality_code"] is not None
                else None
            ),
            sample_count=int(row["sample_count"]),
        )
        for row in rows
        if row["numeric_value"] is not None
    ]
    return MeasurementSeriesResponse(
        space_id=space_id,
        parameter=parameter,
        unit=MEASUREMENT_PARAMETER_UNITS[parameter],
        resolution=resolution,
        **{"from": dt_from, "to": dt_to},
        no_data=len(points) == 0,
        series=points,
    )


def build_energy_consumption_response(
    *,
    site_id: UUID,
    resolution: str,
    dt_from: datetime,
    dt_to: datetime,
    rows: list[dict[str, Any]],
) -> EnergyConsumptionResponse:
    points = [
        EnergyConsumptionPoint(
            bucket_start=row["bucket_start"],
            import_kwh=(
                float(row["import_consumption_kwh"])
                if row["import_consumption_kwh"] is not None
                else None
            ),
            export_kwh=(
                float(row["export_consumption_kwh"])
                if row["export_consumption_kwh"] is not None
                else None
            ),
            source_interval_count=int(row["source_interval_count"] or 0),
        )
        for row in rows
    ]
    return EnergyConsumptionResponse(
        site_id=site_id,
        resolution=resolution,
        **{"from": dt_from, "to": dt_to},
        no_data=len(points) == 0,
        series=points,
    )


def build_energy_consumption_evidence_response(
    *,
    site_id: UUID,
    resolution: str,
    dt_from: datetime,
    dt_to: datetime,
    rows: list[dict[str, Any]],
) -> EnergyConsumptionEvidenceResponse:
    points = [
        EnergyConsumptionEvidencePoint(
            bucket_start=row["bucket_start"],
            source_interval_count=int(row["source_interval_count"] or 0),
            valid_import_intervals=int(row["valid_import_intervals"] or 0),
            invalid_import_intervals=int(row["invalid_import_intervals"] or 0),
            valid_export_intervals=int(row["valid_export_intervals"] or 0),
            invalid_export_intervals=int(row["invalid_export_intervals"] or 0),
            gap_interval_count=int(row["gap_interval_count"] or 0),
            reset_interval_count=int(row["reset_interval_count"] or 0),
            rollover_interval_count=int(row["rollover_interval_count"] or 0),
            invalid_interval_count=int(row["invalid_interval_count"] or 0),
            first_source_bucket=row["first_source_bucket"],
            last_source_bucket=row["last_source_bucket"],
        )
        for row in rows
    ]
    return EnergyConsumptionEvidenceResponse(
        site_id=site_id,
        resolution=resolution,
        **{"from": dt_from, "to": dt_to},
        no_data=len(points) == 0,
        series=points,
    )


def build_energy_typical_reference_response(
    *,
    site_id: UUID,
    period_length_days: int,
    dt_from: datetime,
    dt_to: datetime,
    rows: list[dict[str, Any]],
) -> EnergyTypicalReferenceResponse:
    """Slice C. All eligibility (per-window `eligible`) and evidence
    counters come from migration 236's SQL verbatim -- this function's
    only computed value is the median itself (statistics.median implements
    exactly the approved specification's even/odd-count definition: the
    middle value for an odd count, the mean of the two middle values for
    an even count)."""

    windows = [
        EnergyTypicalReferenceWindow(
            window_index=int(row["window_index"]),
            **{"from": row["window_from"], "to": row["window_to"]},
            has_data=bool(row["has_data"]),
            total_kwh=(
                float(row["total_import_kwh"])
                if row["total_import_kwh"] is not None
                else None
            ),
            source_interval_count=int(row["source_interval_count"] or 0),
            valid_import_intervals=int(row["valid_import_intervals"] or 0),
            coverage_percent=(
                float(row["coverage_percent"])
                if row["coverage_percent"] is not None
                else None
            ),
            eligible=bool(row["eligible"]),
            gap_interval_count=int(row["gap_interval_count"] or 0),
            reset_interval_count=int(row["reset_interval_count"] or 0),
            rollover_interval_count=int(row["rollover_interval_count"] or 0),
            invalid_interval_count=int(row["invalid_interval_count"] or 0),
        )
        for row in rows
    ]

    windows_with_data_count = sum(1 for w in windows if w.has_data)
    # eligible_period_count reflects migration 236's own `eligible` column
    # verbatim -- the "5 of 8" the customer sees is always this count, even
    # in the structurally-unreachable edge case where an eligible window's
    # total_kwh is somehow null (see the defensive filter below, which only
    # affects the median's OWN input list, never this reported count).
    eligible_period_count = sum(1 for w in windows if w.eligible)
    sufficient = eligible_period_count >= TYPICAL_REFERENCE_MIN_ELIGIBLE_PERIODS

    eligible_totals = [
        w.total_kwh for w in windows if w.eligible and w.total_kwh is not None
    ]
    typical_kwh = (
        float(statistics.median(eligible_totals))
        if sufficient and eligible_totals
        else None
    )

    return EnergyTypicalReferenceResponse(
        site_id=site_id,
        period_length_days=period_length_days,
        **{"from": dt_from, "to": dt_to},
        typical_kwh=typical_kwh,
        requested_period_count=TYPICAL_REFERENCE_REQUESTED_PERIOD_COUNT,
        windows_with_data_count=windows_with_data_count,
        eligible_period_count=eligible_period_count,
        sufficient=sufficient,
        windows=windows,
    )


def build_spaces_response(
    *, site_id: UUID, rows: list[dict[str, Any]]
) -> SpacesResponse:
    return SpacesResponse(
        site_id=site_id,
        spaces=[
            SpaceSummary(
                space_id=row["space_id"],
                site_id=row["site_id"],
                space_code=row["space_code"],
                space_name=row["space_name"],
            )
            for row in rows
        ],
    )


def build_assets_response(
    *, site_id: UUID, rows: list[dict[str, Any]]
) -> AssetsResponse:
    return AssetsResponse(
        site_id=site_id,
        assets=[
            AssetSummary(
                asset_id=row["asset_id"],
                site_id=row["site_id"],
                space_id=row.get("space_id"),
                parent_asset_id=row.get("parent_asset_id"),
                external_id=row["external_id"],
                asset_name=row["asset_name"],
                lifecycle_status=row["lifecycle_status"],
            )
            for row in rows
        ],
    )


def build_demand_series_response(
    *,
    site_id: UUID,
    dt_from: datetime,
    dt_to: datetime,
    rows: list[dict[str, Any]],
) -> DemandSeriesResponse:
    points = [
        DemandIntervalPoint(
            interval_start=row["interval_start"],
            interval_end=row["interval_end"],
            demand_kw=(
                float(row["demand_kw"]) if row["demand_kw"] is not None else None
            ),
            peak_power_kw=(
                float(row["peak_power_kw"])
                if row["peak_power_kw"] is not None
                else None
            ),
            quality_status=row["quality_status"],
            coverage_percent=(
                float(row["coverage_percent"])
                if row["coverage_percent"] is not None
                else None
            ),
        )
        for row in rows
    ]
    return DemandSeriesResponse(
        site_id=site_id,
        **{"from": dt_from, "to": dt_to},
        no_data=len(points) == 0,
        series=points,
    )


def build_current_demand_response(
    *, site_id: UUID, row: dict[str, Any] | None
) -> CurrentDemandResponse:
    if row is None:
        return CurrentDemandResponse(site_id=site_id, has_data=False)
    return CurrentDemandResponse(
        site_id=site_id,
        has_data=True,
        interval_start=row["interval_start"],
        interval_end=row["interval_end"],
        current_demand_kw=(
            float(row["current_demand_kw"])
            if row["current_demand_kw"] is not None
            else None
        ),
        current_demand_kva=(
            float(row["current_demand_kva"])
            if row["current_demand_kva"] is not None
            else None
        ),
        quality_status=row["quality_status"],
        coverage_percent=(
            float(row["coverage_percent"])
            if row["coverage_percent"] is not None
            else None
        ),
    )


def build_power_quality_response(
    *,
    site_id: UUID,
    resolution: str,
    dt_from: datetime,
    dt_to: datetime,
    rows: list[dict[str, Any]],
) -> PowerQualityResponse:
    def _f(row: dict[str, Any], key: str) -> float | None:
        return float(row[key]) if row[key] is not None else None

    points = [
        PowerQualityPoint(
            bucket_start=row["bucket_start"],
            power_factor_avg=_f(row, "power_factor_avg"),
            power_factor_min=_f(row, "power_factor_min"),
            power_factor_max=_f(row, "power_factor_max"),
            current_thd_l1_avg=_f(row, "current_thd_l1_avg"),
            current_thd_l1_max=_f(row, "current_thd_l1_max"),
            current_thd_l2_avg=_f(row, "current_thd_l2_avg"),
            current_thd_l2_max=_f(row, "current_thd_l2_max"),
            current_thd_l3_avg=_f(row, "current_thd_l3_avg"),
            current_thd_l3_max=_f(row, "current_thd_l3_max"),
        )
        for row in rows
    ]
    return PowerQualityResponse(
        site_id=site_id,
        resolution=resolution,
        **{"from": dt_from, "to": dt_to},
        no_data=len(points) == 0,
        series=points,
    )


def build_site_telemetry_freshness_response(
    *, site_id: UUID, row: dict[str, Any] | None
) -> SiteTelemetryFreshnessResponse:
    # The router already gates this call on portal_user_can_access_site, and
    # analytics.get_portal_site_telemetry_freshness always returns exactly
    # one row once access is confirmed -- row is None is therefore an
    # unreachable defense-in-depth case, not a real "no data yet" state
    # (that is expressed per-domain via state="UNKNOWN", not row absence).
    # If it is ever hit, never fabricate a positive state.
    if row is None:
        unknown = DomainFreshness(state="UNKNOWN")
        return SiteTelemetryFreshnessResponse(
            site_id=site_id, energy=unknown, demand=unknown, power_quality=unknown
        )
    return SiteTelemetryFreshnessResponse(
        site_id=site_id,
        energy=DomainFreshness(
            state=row["energy_state"], as_of=row["energy_as_of"]
        ),
        demand=DomainFreshness(
            state=row["demand_state"], as_of=row["demand_as_of"]
        ),
        power_quality=DomainFreshness(
            state=row["power_quality_state"], as_of=row["power_quality_as_of"]
        ),
    )
