"""Shared fakes for the Reports export tests: a two-asset site catalogue and
fake portal-scoped Analytics fetchers that record every call.

Values are deterministic per (asset, data point, qualifier, bucket) so a test
can prove which asset and series a CSV cell came from.
"""

from __future__ import annotations

from datetime import datetime, timedelta, timezone
from decimal import Decimal
from typing import Any

SITE_ID = "22222222-2222-4222-8222-222222222222"
OTHER_SITE_ID = "33333333-3333-4333-8333-333333333333"
ASSET_A = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
ASSET_B = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
ASSET_C = "cccccccc-cccc-4ccc-8ccc-cccccccccccc"   # site asset with no assigned data point
SITE = {"site_id": SITE_ID, "site_name": "Coimbatore, Plant \"1\"", "timezone": "Asia/Kolkata"}
T0 = datetime(2026, 9, 20, 0, 0, tzinfo=timezone.utc)
AS_OF = datetime(2026, 9, 28, 12, 0, tzinfo=timezone.utc)
NO_FLOORS = {r: None for r in ("1m", "15m", "30m", "1h", "1d")}

UNITS = {
    "ENERGY_IMPORT": "kWh", "ENERGY_EXPORT": "kWh", "ACTIVE_POWER": "kW", "VOLTAGE_LINE_NEUTRAL": "V",
    "FREQUENCY": "Hz",
}


def catalog_row(asset_id: str, name: str, data_point: str, qualifier: str | None = "TOTAL") -> dict:
    return {
        "asset_id": asset_id, "asset_name": name, "asset_type_id": None, "asset_type_name": "AHU",
        "building_name": None, "floor_name": None, "space_id": None, "space_name": None, "location_path": None,
        "data_point": data_point, "data_point_name": data_point, "category": None,
        "unit": UNITS.get(data_point), "qualifier": qualifier, "assigned_from": None, "assigned_to": None,
    }


CATALOG = [
    catalog_row(ASSET_A, "Chiller/1", "ENERGY_IMPORT"),
    catalog_row(ASSET_A, "Chiller/1", "ACTIVE_POWER"),
    *(catalog_row(ASSET_A, "Chiller/1", "ACTIVE_POWER", q) for q in ("L1", "L2", "L3")),
    catalog_row(ASSET_A, "Chiller/1", "VOLTAGE_LINE_NEUTRAL", "AVG"),
    catalog_row(ASSET_B, "AHU 2", "ENERGY_IMPORT"),
    catalog_row(ASSET_B, "AHU 2", "FREQUENCY", None),
]

SITE_ASSETS = [
    {"asset_id": ASSET_A, "asset_name": "Chiller/1"},
    {"asset_id": ASSET_B, "asset_name": "AHU 2"},
    {"asset_id": ASSET_C, "asset_name": "Spare Pump"},
]

ASSET_OFFSET = {ASSET_A: 1000.0, ASSET_B: 2000.0, ASSET_C: 3000.0}
POINT_OFFSET = {"ACTIVE_POWER": 10.0, "VOLTAGE_LINE_NEUTRAL": 200.0, "FREQUENCY": 50.0}
QUALIFIER_OFFSET = {"TOTAL": 0.0, "AVG": 0.0, None: 0.0, "L1": 0.1, "L2": 0.2, "L3": 0.3}


def value_for(asset_id: str, data_point: str, qualifier: str | None, hour: int) -> float:
    return ASSET_OFFSET[asset_id] + POINT_OFFSET.get(data_point, 0.0) + QUALIFIER_OFFSET[qualifier] + hour


class FakeAnalytics:
    """Fake fetchers. `missing` = set of (asset, data_point, qualifier, hour)
    with no reading (value None, GAP)."""

    def __init__(self, *, accessible: bool = True, missing: set | None = None, hours: int = 3) -> None:
        self.accessible = accessible
        self.missing = missing or set()
        self.hours = hours
        self.calls: list[tuple[str, Any]] = []

    async def site(self, portal_user_id, site_id):
        self.calls.append(("site", (portal_user_id, str(site_id))))
        return SITE if self.accessible and str(site_id) == SITE_ID else None

    async def as_of(self):
        return AS_OF

    async def catalog(self, portal_user_id, site_id):
        self.calls.append(("catalog", (portal_user_id, str(site_id))))
        return list(CATALOG) if self.accessible else []

    async def site_assets(self, portal_user_id, site_id):
        self.calls.append(("site_assets", (portal_user_id, str(site_id))))
        return list(SITE_ASSETS) if self.accessible else []

    async def energy_floors(self, site_id, as_of=None):
        return dict(NO_FLOORS)

    async def point_floors(self, as_of=None):
        return {"mean": dict(NO_FLOORS), "delta": dict(NO_FLOORS)}

    def _hours(self, dt_from, dt_to):
        start = max(dt_from, T0)
        n = int((dt_to - start).total_seconds() // 3600)
        return [int((start - T0).total_seconds() // 3600) + i for i in range(min(n, self.hours))]

    async def energy_series(self, portal_user_id, site_id, asset_ids, dt_from, dt_to, resolution, as_of):
        self.calls.append(("energy", (portal_user_id, [str(a) for a in asset_ids], dt_from, dt_to, resolution)))
        rows = []
        for asset in asset_ids:
            for hour in self._hours(dt_from, dt_to):
                start = T0 + timedelta(hours=hour)
                missing = (str(asset), "ENERGY_IMPORT", "TOTAL", hour) in self.missing
                kwh = None if missing else Decimal(str(value_for(str(asset), "ENERGY_IMPORT", "TOTAL", hour)))
                row = {"asset_id": asset, "bucket_start": start, "bucket_end": start + timedelta(hours=1),
                       "expected_intervals": 4, "is_partial": False, "unavailable_reasons": None}
                for prefix in ("import", "export"):
                    row.update({
                        f"{prefix}_kwh": kwh if prefix == "import" else None,
                        f"{prefix}_status": "GOOD", f"{prefix}_valid_intervals": 4,
                        f"{prefix}_invalid_intervals": 0, f"{prefix}_reconstructed_intervals": 0,
                        f"{prefix}_gap_intervals": 0, f"{prefix}_reset_intervals": 0,
                        f"{prefix}_rollover_intervals": 0, f"{prefix}_assigned_expected_intervals": 4,
                        f"{prefix}_data_state": "MEASURED", f"{prefix}_first_data_at": T0 - timedelta(days=9),
                        f"{prefix}_last_data_at": AS_OF, f"{prefix}_assigned_in_range": True, f"{prefix}_stale": False,
                    })
                rows.append(row)
        return rows

    async def point_series(self, portal_user_id, site_id, specs, dt_from, dt_to, resolution, as_of):
        self.calls.append(
            ("points", (portal_user_id, [(str(s.asset_id), s.data_point, s.qualifier) for s in specs], dt_from, dt_to, resolution))
        )
        rows = []
        for index, spec in enumerate(specs, start=1):
            for hour in self._hours(dt_from, dt_to):
                start = T0 + timedelta(hours=hour)
                missing = (str(spec.asset_id), spec.data_point, spec.qualifier, hour) in self.missing
                value = None if missing else value_for(str(spec.asset_id), spec.data_point, spec.qualifier, hour)
                rows.append({
                    "series_index": index, "asset_id": spec.asset_id, "data_point": spec.data_point,
                    "qualifier": spec.qualifier, "source_kind": "mean", "bucket_start": start,
                    "bucket_end": start + timedelta(hours=1), "value": value, "min_value": value, "max_value": value,
                    "valid_intervals": 0 if missing else 4, "invalid_intervals": 0, "gap_intervals": 0,
                    "reset_intervals": 0, "rollover_intervals": 0, "expected_intervals": 4,
                    "assigned_expected_intervals": 4, "data_state": "GAP" if missing else "MEASURED",
                    "quality": "GAP" if missing else "GOOD", "unavailable_reasons": None,
                    "first_data_at": T0 - timedelta(days=9), "last_data_at": AS_OF, "assigned_in_range": True,
                })
        return rows

    def install(self, monkeypatch, *modules: str) -> None:
        mapping = {
            "fetch_analytics_site": self.site,
            "fetch_analytics_as_of": self.as_of,
            "fetch_analytics_catalog": self.catalog,
            "fetch_site_assets": self.site_assets,
            "fetch_analytics_energy_resolution_floors": self.energy_floors,
            "fetch_analytics_point_resolution_floors": self.point_floors,
            "fetch_analytics_energy_series": self.energy_series,
            "fetch_analytics_point_series": self.point_series,
        }
        for module in ("src.report_export_service", *modules):
            for name, fake in mapping.items():
                monkeypatch.setattr(f"{module}.{name}", fake, raising=False)
