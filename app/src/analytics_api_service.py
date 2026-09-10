"""Phase 7 -- /api/v1 semantic read API: contract, validation, and data access.

This module is the thin application half of the Phase 7 query boundary. It
holds NO analytics or energy business logic: every value it returns comes from
one of the scoped SECURITY DEFINER functions created by migration 231
(analytics.get_portal_*), or from the pre-existing admin.list_accessible_sites
/ admin.portal_user_can_access_site. Tenant scope is enforced server-side, in
the database, keyed on the authenticated portal_user_id.
"""

from __future__ import annotations

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
