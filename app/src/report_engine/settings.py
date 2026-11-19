"""Reporting roster and effective-dated settings from EMS (migration 328) for
the engine, and the settings snapshot stored with each PDF version (A80).

effective_from is converted to site-local naive time, the engine's time base;
each reading / interval uses the version in force at its own timestamp (A20).
"""

from __future__ import annotations

from datetime import datetime
from typing import Any
from zoneinfo import ZoneInfo

import pandas as pd

from src.report_engine.metrics import Layout, ReportSettings, RosterEntry
from src.report_engine.runtime import AHUSettings
from src.report_engine.schedules import describe_schedule, normalise_schedule


def roster_and_settings(rows: list[dict[str, Any]], zone: ZoneInfo) -> tuple[Layout, ReportSettings]:
    """From analytics.get_site_report_worker_settings rows (one per roster
    asset x setting version, or one per asset without settings)."""

    entries: dict[str, RosterEntry] = {}
    settings = ReportSettings()
    for row in rows:
        asset_id = str(row["asset_id"])
        name = row["asset_name"]
        if asset_id not in entries:
            entries[asset_id] = RosterEntry(asset_id=asset_id, name=name, report_group=row["report_group"],
                                            area=row.get("area"), display_order=int(row.get("display_order") or 0))
        key = row.get("setting_key")
        if not key:
            continue
        when = pd.Timestamp(row["effective_from"].astimezone(zone).replace(tzinfo=None))
        value = row["value"] or {}
        if key == "TEMPERATURE_SETPOINT":
            settings.setpoints.setdefault(name, []).append((when, float(value["value_c"])))
        elif key == "OPERATING_SCHEDULE":
            schedule, problems = normalise_schedule(value.get("schedule"))
            if problems or not value.get("calculate_out_of_hours", True):
                schedule = None
            settings.schedules.setdefault(name, []).append((when, schedule))
            settings.schedule_confirmed.setdefault(name, []).append((when, bool(value.get("confirmed_by_hotel"))))
        elif key == "OPERATING_THRESHOLDS":
            settings.thresholds.setdefault(name, []).append((when, AHUSettings(
                off_kw=float(value["off_kw"]),
                standby_kw=None if value.get("standby_kw") is None else float(value["standby_kw"]),
                on_kw=float(value["on_kw"]),
                runtime_enabled=bool(value.get("runtime_enabled", True)),
                confidence=str(value.get("confidence") or ""),
            )))
    for versions in (settings.setpoints, settings.schedules, settings.schedule_confirmed, settings.thresholds):
        for name in versions:
            versions[name].sort(key=lambda item: item[0])
    return Layout(sorted(entries.values(), key=lambda e: (e.display_order, e.name))), settings


def settings_snapshot(rows: list[dict[str, Any]], period_start_local: datetime, period_end_exclusive_local: datetime,
                      comparison_start_local: datetime) -> dict:
    """The roster and every setting version in force at any time in the
    comparison or reporting period (immutable record kept with the PDF)."""

    roster = {}
    versions: dict[tuple[str, str], list[dict]] = {}
    for row in rows:
        asset_id = str(row["asset_id"])
        roster[asset_id] = {"asset_name": row["asset_name"], "report_group": row["report_group"], "area": row.get("area")}
        if row.get("setting_key"):
            versions.setdefault((asset_id, row["setting_key"]), []).append(row)
    selected = []
    for (asset_id, key), items in versions.items():
        items.sort(key=lambda r: (r["effective_from"], r["version_id"]))
        start = comparison_start_local
        in_force_at_start = [r for r in items if r["effective_from"] <= start]
        chosen = ([in_force_at_start[-1]] if in_force_at_start else []) + [
            r for r in items if start < r["effective_from"] < period_end_exclusive_local]
        for r in chosen:
            value = r["value"]
            entry = {"asset_id": asset_id, "asset_name": roster[asset_id]["asset_name"], "setting": key,
                     "version_id": r["version_id"], "effective_from": r["effective_from"].isoformat(), "value": value}
            if key == "OPERATING_SCHEDULE":
                schedule, _ = normalise_schedule(value.get("schedule"))
                entry["description"] = describe_schedule(schedule)
            selected.append(entry)
    return {"roster": [{"asset_id": k, **v} for k, v in roster.items()], "settings": selected,
            "period_start": period_start_local.isoformat()}
