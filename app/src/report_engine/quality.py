"""Publication gate, labels and the per-version coverage record (A45-A60, A109).

Gate, current reporting period only (A45, A56):
  * HVAC: measured + estimated (EMS-reconstructed and <= 30-minute gap-filled)
    energy readings >= 80 % of expected (A53);
  * Kitchen: the same;
  * at least one timestamp at which every HVAC meter has an observed Power
    reading (peak HVAC demand).
Failing any -> the attempt FAILS with `insufficient_data` and a clear
explanation (A48). An individual asset's missing data never fails the report
by itself; affected assets are identified (A46, A47).

Labels:
  * incomplete_data -- the CURRENT period is incomplete under the existing
    rules (partial or missing asset-days, > 0.5 % unmeasured, peak coverage
    < 95 %, temperature coverage < 90 %) -> "Incomplete data" label and the
    PDF "Data completeness" note (A49, A59).
  * comparison_incomplete -- the COMPARISON period is incomplete under the
    same rules -> never fails the report, never sets the "Incomplete data"
    label by itself; the PDF marks affected comparisons with a dagger and
    adds a note beneath affected tables; history shows "Comparison
    incomplete" (A57, A109).
"""

from __future__ import annotations

from dataclasses import dataclass, field

import numpy as np
import pandas as pd

from src.report_engine.metrics import (
    PEAK_MIN_COVERAGE,
    available_share,
    period_complete,
)
from src.report_engine.prepare import FULL_DAY_COVERAGE

MIN_AVAILABLE_SHARE = 0.80


@dataclass
class QualityResult:
    publishable: bool
    failure_reasons: list[str] = field(default_factory=list)
    incomplete_data: bool = False
    incomplete_reasons: list[str] = field(default_factory=list)
    comparison_incomplete: bool = False
    comparison_reasons: list[str] = field(default_factory=list)
    # Subset of comparison_reasons: reporting settings not in force throughout
    # the comparison period (never back-dated, A17/A23); disclosed like A109.
    comparison_config_reasons: list[str] = field(default_factory=list)
    affected_assets: list[str] = field(default_factory=list)
    coverage: dict = field(default_factory=dict)

    @property
    def failure_message(self) -> str:
        return ("Not enough EMS data for a reliable report: " + "; ".join(self.failure_reasons)
                + ". No values were estimated or invented beyond the approved 30-minute energy gap rule.")


def _pct(value: float) -> float:
    return round(float(value) * 100, 1) if value is not None and np.isfinite(value) else None


def _group_coverage(s: dict) -> dict:
    expected = s["expected"] or 0

    def share(n):
        return _pct(n / expected) if expected else None

    return {
        "expected_readings": int(expected),
        "measured_pct": share(s["observed"]),
        "estimated_pct": share(s["estimated"]),
        "reconstructed_pct": share(s["reconstructed"]),
        "gap_filled_pct": share(s["gap_filled"]),
        "missing_pct": share(s["unresolved"]),
        "available_pct": _pct(available_share(s)) if expected else 0.0,
        "partial_days": int(s["partial_asset_days"]),
        "no_data_days": int(s["no_data_asset_days"]),
        "complete": bool(period_complete(s)),
    }


def _period_issues(m: dict, wk: str) -> tuple[list[str], list[str]]:
    """(reasons, affected assets) for one period under the existing incompleteness rules."""

    reasons, affected = [], []
    for label, key in (("HVAC", "hvac"), ("Kitchen", "kitchen")):
        s = m[key][wk]
        if not period_complete(s):
            reasons.append(f"{label} energy {_pct(available_share(s))} % available "
                           f"({_pct(s['observed'] / s['expected']) if s['expected'] else 0} % measured)")
            affected += s["affected_assets"]
    if m["peak"][wk]["coverage"] < PEAK_MIN_COVERAGE:
        reasons.append(f"peak HVAC demand coverage {_pct(m['peak'][wk]['coverage'])} % (below 95 %)")
    for area, temps in m["temperature"].items():
        t = temps[wk]
        if t["sensors"] and (pd.isna(t["coverage"]) or t["coverage"] < FULL_DAY_COVERAGE):
            reasons.append(f"{area} temperature readings {_pct(t['coverage']) if pd.notna(t['coverage']) else 0} % of expected")
    return reasons, sorted(set(affected))


def _names(names: list[str], noun: str) -> str:
    return ", ".join(names) if len(names) <= 3 else f"{len(names)} {noun}"


def config_gap_reason(gaps: dict) -> str:
    """'reporting settings in force only from 19 Nov 2026 08:13 (...)' or ''."""

    parts = []
    if gaps.get("setpoints"):
        parts.append("temperature setpoints: " + _names(gaps["setpoints"], "sensors"))
    if gaps.get("schedules"):
        parts.append("AHU operating schedules: " + _names(gaps["schedules"], "AHUs"))
    if gaps.get("thresholds"):
        parts.append("AHU operating thresholds: " + _names(gaps["thresholds"], "AHUs"))
    if not parts:
        return ""
    since = gaps.get("from")
    when = f" from {since:%d %b %Y %H:%M}" if since is not None else ""
    return f"reporting settings in force only{when} ({'; '.join(parts)})"


def assess(m: dict) -> QualityResult:
    result = QualityResult(publishable=True)
    curr = "curr"
    for label, key in (("HVAC", "hvac"), ("Kitchen", "kitchen")):
        s = m[key][curr]
        share = available_share(s)
        if share < MIN_AVAILABLE_SHARE:
            result.failure_reasons.append(f"{label} energy readings available {_pct(share)} % of expected (minimum 80 %)")
    if m["peak"][curr]["complete_timestamps"] == 0:
        result.failure_reasons.append("no timestamp with every HVAC meter reporting, so peak HVAC demand cannot be determined")
    result.publishable = not result.failure_reasons

    result.incomplete_reasons, result.affected_assets = _period_issues(m, "curr")
    result.incomplete_data = bool(result.incomplete_reasons)
    result.comparison_reasons, _ = _period_issues(m, "prev")
    config = config_gap_reason(m.get("comparison_config_gaps") or {})
    if config:
        result.comparison_config_reasons = [config]
        result.comparison_reasons.append(config)
    result.comparison_incomplete = bool(result.comparison_reasons)

    def period_block(wk: str) -> dict:
        return {
            "hvac": _group_coverage(m["hvac"][wk]),
            "kitchen": _group_coverage(m["kitchen"][wk]),
            "peak_coverage_pct": _pct(m["peak"][wk]["coverage"]),
            "peak_timestamps": int(m["peak"][wk]["complete_timestamps"]),
            "temperature": {area: {"sensors": t[wk]["sensors"],
                                   "coverage_pct": _pct(t[wk]["coverage"]) if pd.notna(t[wk]["coverage"]) else None}
                            for area, t in m["temperature"].items()},
            "assets": {name: _group_coverage(stats[wk]) for name, stats in m["assets"].items()},
        }

    result.coverage = {
        "current": period_block("curr"),
        "comparison": period_block("prev"),
        "incomplete_data": result.incomplete_data,
        "incomplete_reasons": result.incomplete_reasons,
        "comparison_incomplete": result.comparison_incomplete,
        "comparison_reasons": result.comparison_reasons,
        "comparison_config_reasons": result.comparison_config_reasons,
        "affected_assets": result.affected_assets,
        "not_temperature_monitored": m.get("not_temperature_monitored", []),
    }
    return result
