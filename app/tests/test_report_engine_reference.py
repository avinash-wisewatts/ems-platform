"""T-REG-1 / A31 / A44: the ported engine reproduces the reference tool's
pinned figures for the 11-24 Oct 2026 dataset (Radisson Blu Coimbatore), and
renders a validated PDF from it.

The dataset is customer telemetry and is not in the repository. These tests
run where EMS_REPORT_REFERENCE_DATA points at the reference folder (the
local development machine) and are skipped elsewhere (CI). The pinned values
are copied from the reference tool's tests/test_reconciliation.py
(KeyFigureRegressionTests, Lobby 23.0 / Restaurant 22.5 / Banquet 24.0 °C).
"""

from __future__ import annotations

import functools
from datetime import date

import pandas as pd
import pytest

from tests.report_engine_support import REFERENCE_DATA, load_reference_csv, radisson_layout, reference_settings
from src.report_engine.generate import generate_report, period_spec
from src.report_engine.metrics import compute_report_metrics, fmt_date
from src.report_engine.periods import period_for
from src.report_engine.prepare import prepare_asset

pytestmark = pytest.mark.skipif(not (REFERENCE_DATA / "Chiller1.csv").is_file(),
                                reason=f"reference dataset not available at {REFERENCE_DATA}")

PERIOD = period_for("WEEKLY", date(2026, 10, 18))


@functools.lru_cache(maxsize=1)
def reference_metrics():
    assets = load_reference_csv()
    spec = period_spec(PERIOD)
    for a in assets.values():
        prepare_asset(a, spec.prev_start, spec.curr_end + pd.Timedelta(days=1) + pd.Timedelta(minutes=a.interval_minutes))
    return compute_report_metrics(assets, radisson_layout(), spec, reference_settings(23.0, 22.5, 24.0))


def figure(value) -> float:
    return round(value, 1)


def test_reporting_periods():
    assert (PERIOD.comparison_start, PERIOD.comparison_end, PERIOD.start, PERIOD.end) == (
        date(2026, 10, 11), date(2026, 10, 17), date(2026, 10, 18), date(2026, 10, 24))


def test_energy_figures_match_reference():
    m = reference_metrics()
    expected = {("hvac", "prev"): (32583.5, 4654.8, 4221.8, 5053.2, 7), ("hvac", "curr"): (31285.0, 4469.3, 4088.1, 4801.8, 7),
                ("kitchen", "prev"): (1510.3, 215.8, 194.0, 226.5, 7), ("kitchen", "curr"): (1513.6, 219.2, 211.5, 225.5, 6)}
    for (group, week), (total, avg, low, high, days) in expected.items():
        s = m[group][week]
        assert [figure(s[k]) for k in ("total", "avg_day", "min_day", "max_day")] == [total, avg, low, high]
        assert s["complete_days"] == days
    subsystems = {"Chillers": (21677.0, 20270.3), "Pumps": (9632.0, 9713.4), "Cooling towers": (534.2, 556.2),
                  "Air handling units": (740.3, 745.1)}
    for group, (prev, curr) in subsystems.items():
        assert figure(m["hvac_subsystems"][group]["prev"]["total"]) == prev
        assert figure(m["hvac_subsystems"][group]["curr"]["total"]) == curr
    meters = {"Cold Serving Area": (94.9, 83.6), "Hot Food PickUp Ctr": (178.7, 174.1), "Induction Ctr Tops": (77.2, 74.2),
              "Sandwich Toaster": (147.6, 158.9), "Under Counter Freezers": (45.5, 50.7), "Walkin Deep": (489.1, 488.8),
              "WalkIn Freezer Fruits": (167.9, 165.2), "WalkIn Freezer": (309.4, 318.2)}
    for meter, (prev, curr) in meters.items():
        assert figure(m["assets"][f"Kitchen GF {meter}"]["prev"]["total"]) == prev
        assert figure(m["assets"][f"Kitchen GF {meter}"]["curr"]["total"]) == curr


def test_coverage_counts_match_reference():
    m = reference_metrics()
    counts = {(g, w): tuple(m[g][w][k] for k in ("observed", "estimated", "unresolved", "expected", "partial_asset_days"))
              for g in ("hvac", "kitchen") for w in ("prev", "curr")}
    assert counts == {("hvac", "prev"): (150908, 292, 0, 151200, 0), ("hvac", "curr"): (151038, 147, 15, 151200, 0),
                      ("kitchen", "prev"): (52000, 173, 243, 52416, 0), ("kitchen", "curr"): (52275, 25, 116, 52416, 3)}
    assert sorted((d["asset"], fmt_date(d["date"])) for d in m["partial_days"]) == [
        (f"Kitchen GF {n}", "24-Oct-2026") for n in ("Hot Food PickUp Ctr", "Induction Ctr Tops", "Sandwich Toaster")]
    assert m["comparable"] == {"hvac": True, "kitchen": False, "peak": True}


def test_peak_demand_matches_reference():
    m = reference_metrics()
    for week, (value, when, complete) in {"prev": (369.1, "11-Oct-2026 08:45", 10053),
                                          "curr": (317.9, "22-Oct-2026 18:52", 10062)}.items():
        p = m["peak"][week]
        assert figure(p["peak_kw"]) == value
        assert f"{fmt_date(p['time'])} {p['time']:%H:%M}" == when
        assert (p["complete_timestamps"], p["expected_timestamps"]) == (complete, 10080)


def test_temperature_performance_matches_reference():
    m = reference_metrics()
    expected = {("Lobby", "prev"): (25.6, 2.6, 0.0, 9868, 10080), ("Lobby", "curr"): (25.1, 2.1, 2.5, 9896, 10080),
                ("Restaurant", "prev"): (27.0, 4.5, 0.0, 19845, 20160), ("Restaurant", "curr"): (26.6, 4.1, 0.0, 19978, 20160)}
    for (area, week), (mean, deviation, within, observed, slots) in expected.items():
        t = m["temperature"][area][week]
        assert (figure(t["mean"]), figure(t["mean_abs_deviation"]), figure(t["within_band_pct"])) == (mean, deviation, within)
        assert (t["observed"], t["expected"]) == (observed, slots)
    banquet2 = m["temperature"]["Banquet 2"]
    assert (figure(banquet2["prev"]["mean"]), figure(banquet2["curr"]["mean"])) == (25.6, 25.8)
    assert (figure(banquet2["prev"]["within_band_pct"]), figure(banquet2["curr"]["within_band_pct"])) == (10.6, 11.6)
    # A15: Banquet 1 AHU has no temperature sensor -> not temperature-monitored, never estimated.
    assert m["temperature"]["Banquet 1"]["curr"]["sensors"] == []
    assert "Banquet 1 AHU" in m["not_temperature_monitored"]


def test_reference_pdf_generates_and_validates():
    result = generate_report("Radisson Blu Coimbatore", PERIOD, load_reference_csv(), radisson_layout(),
                             reference_settings(23.0, 22.5, 24.0))
    assert result.pdf.startswith(b"%PDF-")
    assert result.check.pages >= 6
    assert result.file_name == "Radisson_Blu_Coimbatore_Weekly_EMS_Report_18-Oct-2026_24-Oct-2026.pdf"
    # The partial final Saturday of three kitchen meters makes the current week incomplete (existing rule).
    assert result.quality.publishable and result.quality.incomplete_data
