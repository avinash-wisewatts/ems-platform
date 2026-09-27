"""Analytics v1 (EMS Web App "Analytics" page, ADR-022) -- contract, curated
data-point registry and data access.

Step B1: the catalogue behind GET /api/v1/sites/{site_id}/analytics/catalog.

Every catalogue row comes from analytics.get_portal_analytics_catalog
(migration 272): currently effective metadata.asset_points bindings of ACTIVE
assets on the site, portal-scoped in the database. This module adds only the
curated registry (which semantic parameters Analytics v1 can chart, and how)
and shapes the response. It never derives availability from device
capability or PRIMARY_METER (ADR-018 decision 1), and it never exposes the
read model's internal attribution_basis (ADR-022 decision 4).
"""

from __future__ import annotations

from dataclasses import dataclass
from datetime import timedelta
from typing import Any
from uuid import UUID

from pydantic import BaseModel

from src.analytics_api_service import _read_rows


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


ANALYTICS_DATA_POINTS: dict[str, DataPointDefinition] = {
    "ENERGY_IMPORT": DataPointDefinition(chart_kind="bar", aggregation="sum", qualifiers=(SYSTEM_QUALIFIER,)),
    "ENERGY_EXPORT": DataPointDefinition(chart_kind="bar", aggregation="sum", qualifiers=(SYSTEM_QUALIFIER,)),
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


# ---------------------------------------------------------------------------
# Response models (GET /api/v1/sites/{site_id}/analytics/catalog).
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


# ---------------------------------------------------------------------------
# Response building.
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


def build_analytics_catalog_response(
    *, site: dict[str, Any], rows: list[dict[str, Any]]
) -> AnalyticsCatalogResponse:
    """Group catalogue rows into assets -> registry data points.

    A row whose parameter is not in the registry, or whose qualifier the
    registry cannot serve, is dropped. An asset left with no data point is
    omitted: the catalogue lists only assets the customer can chart.
    Ordering is deterministic: assets by name then id, data points by the
    registry's own order.
    """

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
