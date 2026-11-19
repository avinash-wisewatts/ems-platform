"""Report engine rules on deterministic synthetic 1-minute data (runs in CI).

Covers: reporting calendar and boundaries (T-TS), the closing midnight
reading (A28), monthly content rules (T-MO: current-month-only daily charts,
no day-of-month pairing, no month-length text, 100 kWh kitchen threshold),
reading classes and the publication gate (T-DQ, A45-A57: measured /
EMS-reconstructed / gap-filled / missing, 80 % on the current period only,
an asset's missing data never fails the report, comparison incompleteness
disclosed without the "Incomplete data" label), effective-dated settings
(T-SET-1/8/9: per-reading setpoint, ranges, save-time and 00:00 boundaries),
temperature never estimated (T-DQ-8), and PDF generation / validation
(T-PDF-1..5).
"""

from __future__ import annotations

import functools
import io
from datetime import date, datetime, timedelta, timezone
from zoneinfo import ZoneInfo

import numpy as np
import pandas as pd
import pytest

from tests.report_engine_support import (
    AHUS,
    ALWAYS,
    KITCHEN,
    TEMPERATURE_SENSORS,
    radisson_layout,
    reference_settings,
    synthetic_assets,
)
from src.report_engine import runtime as rt
from src.report_engine.charts import build_report_charts
from src.report_engine.generate import InsufficientDataError, generate_report, period_spec
from src.report_engine.metrics import (
    ReportSettings,
    abs_change,
    build_summary_points,
    change_status,
    compute_report_metrics,
    pct_change,
    setpoint_text,
    temperature_change_status,
)
from src.report_engine.periods import latest_closed_period, period_for, week_start
from src.report_engine.prepare import ENERGY_COL, prepare_asset
from src.report_engine.quality import assess
from src.report_engine.validate_pdf import PdfValidationError, validate_report_pdf

KOLKATA = ZoneInfo("Asia/Kolkata")
WEEK = period_for("WEEKLY", date(2026, 10, 18))          # 18-24 Oct, compared with 11-17 Oct
MONTH = period_for("MONTHLY", date(2026, 10, 1))          # October, compared with September


def metrics_for(period, assets, settings=None):
    spec = period_spec(period)
    for a in assets.values():
        prepare_asset(a, spec.prev_start, spec.curr_end + pd.Timedelta(days=1) + pd.Timedelta(minutes=a.interval_minutes))
    return compute_report_metrics(assets, radisson_layout(), spec, settings or reference_settings())


@functools.lru_cache(maxsize=None)
def weekly_clean():
    return metrics_for(WEEK, synthetic_assets(WEEK.comparison_start, 14))


@functools.lru_cache(maxsize=None)
def monthly_clean():
    days = (MONTH.end - MONTH.comparison_start).days + 1
    return metrics_for(MONTH, synthetic_assets(MONTH.comparison_start, days))


# ---------------------------------------------------------------------------
# Periods and timestamps (A24-A29, T-TS)
# ---------------------------------------------------------------------------

def test_weekly_period_is_sunday_to_saturday_with_previous_week():
    assert (WEEK.start, WEEK.end, WEEK.comparison_start, WEEK.comparison_end) == (
        date(2026, 10, 18), date(2026, 10, 24), date(2026, 10, 11), date(2026, 10, 17))
    with pytest.raises(ValueError):
        period_for("WEEKLY", date(2026, 10, 19))
    assert week_start(date(2026, 10, 21)) == date(2026, 10, 18)


@pytest.mark.parametrize("start, end, cmp_start, cmp_end", [
    (date(2026, 10, 1), date(2026, 10, 31), date(2026, 9, 1), date(2026, 9, 30)),     # 31 vs 30 days
    (date(2026, 12, 1), date(2026, 12, 31), date(2026, 11, 1), date(2026, 11, 30)),
    (date(2027, 1, 1), date(2027, 1, 31), date(2026, 12, 1), date(2026, 12, 31)),     # year end
    (date(2027, 3, 1), date(2027, 3, 31), date(2027, 2, 1), date(2027, 2, 28)),
    (date(2028, 3, 1), date(2028, 3, 31), date(2028, 2, 1), date(2028, 2, 29)),       # leap year
])
def test_monthly_periods_and_previous_month(start, end, cmp_start, cmp_end):
    p = period_for("MONTHLY", start)
    assert (p.start, p.end, p.comparison_start, p.comparison_end) == (start, end, cmp_start, cmp_end)


def test_period_instants_in_site_timezone():
    # Sunday 25-Oct 00:00 IST = Saturday 24-Oct 18:30 UTC; +6 h first attempt, +12 h deadline (A64, A66).
    assert WEEK.end_instant(KOLKATA) == datetime(2026, 10, 24, 18, 30, tzinfo=timezone.utc)
    assert WEEK.first_attempt_at(KOLKATA) == datetime(2026, 10, 25, 0, 30, tzinfo=timezone.utc)
    assert WEEK.deadline(KOLKATA) == datetime(2026, 10, 25, 6, 30, tzinfo=timezone.utc)
    # Load range includes the closing midnight reading (A28): up to 25-Oct 00:00 IST inclusive.
    lo, hi = WEEK.load_range_utc(KOLKATA)
    assert lo == datetime(2026, 10, 10, 18, 30, tzinfo=timezone.utc)
    assert hi == datetime(2026, 10, 24, 18, 31, tzinfo=timezone.utc)


def test_latest_closed_period():
    now = datetime(2026, 11, 2, 3, 0, tzinfo=timezone.utc)   # Mon 2-Nov 08:30 IST
    assert latest_closed_period("WEEKLY", now, KOLKATA).start == date(2026, 10, 25)
    assert latest_closed_period("MONTHLY", now, KOLKATA).start == date(2026, 10, 1)


def test_closing_midnight_reading_belongs_to_the_preceding_week():
    """T-TS-1: the reading labelled Sun 25-Oct 00:00 covers Sat 23:59-24:00 and counts in the week ending Saturday."""

    with_close = metrics_for(WEEK, synthetic_assets(WEEK.comparison_start, 14))
    without = metrics_for(WEEK, synthetic_assets(WEEK.comparison_start, 14, closing_reading=False))
    a, b = with_close["assets"]["Chiller1"]["curr"], without["assets"]["Chiller1"]["curr"]
    assert a["observed"] == b["observed"] + 1 and a["unresolved"] == b["unresolved"] - 1
    assert a["total"] > b["total"]


# ---------------------------------------------------------------------------
# Comparisons (A35, A40)
# ---------------------------------------------------------------------------

def test_percentage_is_na_for_zero_or_missing_comparison():
    assert np.isnan(pct_change(10.0, 0.0)) and np.isnan(pct_change(10.0, np.nan))
    assert change_status(10.0, 0.0) == ("NA", "neutral")
    assert abs_change(10.0, 4.0) == 6.0 and np.isnan(abs_change(10.0, None))


# ---------------------------------------------------------------------------
# Monthly content (A33-A39, A43, T-MO)
# ---------------------------------------------------------------------------

def test_monthly_daily_charts_show_current_month_only():
    import matplotlib.pyplot as plt

    m = monthly_clean()
    charts = build_report_charts(m)
    try:
        for key in ("hvac_daily", "kitchen_daily", "lobby_energy", "restaurant_energy"):
            ax = charts[key].axes[0]
            assert len(ax.containers) == 1, key                 # one series: no previous-month bars
            assert len(ax.containers[0]) == 31, key             # every October day, nothing paired
            labels = [t.get_text() for t in ax.get_xticklabels()]
            assert "/" not in "".join(labels), key              # no "dd/dd" pairing labels
        for key in ("lobby_daily_temperature", "restaurant_daily_temperature", "banquet_2_daily_temperature"):
            assert len(charts[key].axes[0].get_lines()) == 1, key
        assert set(m["daily"]["HVAC"]["curr"].index.day) == set(range(1, 32))
    finally:
        plt.close("all")


def test_monthly_comparisons_are_month_totals():
    m = monthly_clean()
    assert m["period"].report_type == "MONTHLY"
    assert m["hvac"]["prev"]["days"] == 30 and m["hvac"]["curr"]["days"] == 31
    observations, _ = build_summary_points(m)
    assert any("month on month" in o for o in observations)
    assert not any("week" in o.lower() for o in observations)


def test_monthly_pdf_has_no_month_length_text():
    from pypdf import PdfReader

    days = (MONTH.end - MONTH.comparison_start).days + 1
    result = generate_report("Radisson Blu Coimbatore", MONTH, synthetic_assets(MONTH.comparison_start, days),
                             radisson_layout(), reference_settings())
    text = " ".join((p.extract_text() or "") for p in PdfReader(io.BytesIO(result.pdf)).pages)
    for phrase in ("31 days", "30 days", "days in", "longer month", "shorter month", "day count"):
        assert phrase not in text
    assert "Monthly EMS Performance Report" in text and "October 2026" in text and "September 2026" in text
    assert "2.1 HVAC energy by subsystem" in text


@pytest.mark.parametrize("report_type, increase_kwh, flagged", [
    ("WEEKLY", 30.0, True), ("WEEKLY", 20.0, False), ("MONTHLY", 90.0, False), ("MONTHLY", 120.0, True)])
def test_kitchen_attention_thresholds(report_type, increase_kwh, flagged):
    """A42 / A43: > 10 % AND > 25 kWh weekly, > 100 kWh monthly."""

    m = dict(weekly_clean() if report_type == "WEEKLY" else monthly_clean())
    m["period"] = period_spec(WEEK if report_type == "WEEKLY" else MONTH)
    name = "Kitchen GF Walkin Deep"
    prev = dict(m["assets"][name]["prev"], total=increase_kwh * 5)
    curr = dict(m["assets"][name]["curr"], total=increase_kwh * 6)          # +20 % and +increase_kwh
    m["assets"] = {**m["assets"], name: {"prev": prev, "curr": curr}}
    _, attention = build_summary_points(m)
    assert any(a.startswith(name) for a in attention) is flagged


# ---------------------------------------------------------------------------
# Reading classes and the publication gate (A45-A57, T-DQ)
# ---------------------------------------------------------------------------

def test_reconstructed_and_gap_filled_are_estimated_not_measured():
    """T-DQ-10: both count toward availability (and totals) but never as measured."""

    window = ("2026-10-20 10:01", "2026-10-20 12:00")          # 120 reconstructed minutes
    gap = ("2026-10-21 10:01", "2026-10-21 10:20")             # 20 missing minutes -> gap-filled
    assets = synthetic_assets(WEEK.comparison_start, 14, reconstructed={"Chiller1": [window]}, drop={"Chiller1": [gap]})
    m = metrics_for(WEEK, assets)
    s = m["assets"]["Chiller1"]["curr"]
    assert s["reconstructed"] == 120 and s["gap_filled"] == 20 and s["estimated"] == 140
    assert s["observed"] == 7 * 1440 - 140
    frame = assets["Chiller1"].frame
    assert not frame.loc["2026-10-20 10:30", "_energy_observed"] and frame.loc["2026-10-20 10:30", "_estimated_energy"]
    # Totals include estimated energy; runtime/full-day use measured only (existing rules).
    assert np.isfinite(s["total"])
    q = assess(m)
    assert q.publishable
    assert q.coverage["current"]["assets"]["Chiller1"]["reconstructed_pct"] > 0


def test_long_gap_is_missing_and_never_filled():
    """T-DQ-1: gaps longer than 30 minutes stay missing."""

    gap = ("2026-10-21 10:01", "2026-10-21 11:00")          # 60 minutes
    m = metrics_for(WEEK, synthetic_assets(WEEK.comparison_start, 14, drop={"Chiller2": [gap]}))
    s = m["assets"]["Chiller2"]["curr"]
    assert s["gap_filled"] == 0 and s["unresolved"] >= 60


def test_one_asset_without_data_does_not_fail_but_is_identified():
    """T-DQ-7 (A46, A47)."""

    assets = synthetic_assets(WEEK.comparison_start, 14, drop={"Kitchen GF Sandwich Toaster": [("2026-10-18 00:01", "2026-10-25 00:00")]})
    q = assess(metrics_for(WEEK, assets))
    assert q.publishable and q.incomplete_data
    assert "Kitchen GF Sandwich Toaster" in q.affected_assets


def test_group_below_80_percent_fails_with_explanation():
    """T-DQ-6 (A45, A48)."""

    drop = {n: [("2026-10-18 00:01", "2026-10-21 12:00")] for n in KITCHEN}     # > 20 % of the week missing
    with pytest.raises(InsufficientDataError) as excinfo:
        generate_report("Radisson Blu Coimbatore", WEEK, synthetic_assets(WEEK.comparison_start, 14, drop=drop),
                        radisson_layout(), reference_settings())
    assert "Kitchen energy readings available" in str(excinfo.value) and "minimum 80 %" in str(excinfo.value)


def test_no_valid_peak_timestamp_fails():
    """T-DQ-9."""

    m = dict(weekly_clean())
    m["peak"] = {**m["peak"], "curr": dict(m["peak"]["curr"], complete_timestamps=0)}
    q = assess(m)
    assert not q.publishable and any("peak HVAC demand" in r for r in q.failure_reasons)


def test_incomplete_comparison_period_does_not_fail_or_label():
    """T-DQ-11 (A57, A109): † + note + 'Comparison incomplete', no 'Incomplete data' label."""

    drop = {n: [("2026-10-11 00:01", "2026-10-14 00:00")] for n in KITCHEN}    # comparison week only
    result = generate_report("Radisson Blu Coimbatore", WEEK, synthetic_assets(WEEK.comparison_start, 14, drop=drop),
                             radisson_layout(), reference_settings())
    assert result.quality.publishable
    assert result.quality.comparison_incomplete and not result.quality.incomplete_data
    from pypdf import PdfReader

    text = " ".join((p.extract_text() or "") for p in PdfReader(io.BytesIO(result.pdf)).pages)
    assert "The previous week's data is incomplete" in text and "†" in text
    assert "Data completeness" not in text


def test_both_periods_incomplete_get_label_and_comparison_disclosure():
    """T-DQ-12."""

    drop = {n: [("2026-10-11 00:01", "2026-10-12 00:00"), ("2026-10-19 00:01", "2026-10-19 06:00")] for n in KITCHEN}
    result = generate_report("Radisson Blu Coimbatore", WEEK, synthetic_assets(WEEK.comparison_start, 14, drop=drop),
                             radisson_layout(), reference_settings())
    assert result.quality.incomplete_data and result.quality.comparison_incomplete
    from pypdf import PdfReader

    text = " ".join((p.extract_text() or "") for p in PdfReader(io.BytesIO(result.pdf)).pages)
    assert "Data completeness" in text and "The previous week's data is incomplete" in text


def _settings_from(start: pd.Timestamp) -> "ReportSettings":
    """reference_settings(), but every setting first takes effect at `start` (never back-dated)."""

    s = reference_settings()
    for series in (s.setpoints, s.schedules, s.schedule_confirmed, s.thresholds):
        for name, versions in series.items():
            series[name] = [(start, v) for _, v in versions]
    return s


def test_settings_not_in_force_throughout_comparison_are_disclosed():
    """PO 2026-11-19 / A109: configuration starting mid-comparison-period is disclosed (†, note,
    'Comparison incomplete'); the report stays publishable, nothing is recalculated or estimated."""

    start = pd.Timestamp("2026-10-14 08:13")            # Wednesday of the comparison week 11-17 Oct
    settings = _settings_from(start)
    assets = synthetic_assets(WEEK.comparison_start, 14)
    m = metrics_for(WEEK, assets, settings)
    gaps = m["comparison_config_gaps"]
    assert set(gaps["setpoints"]) == set(TEMPERATURE_SENSORS)
    assert set(gaps["schedules"]) == set(gaps["thresholds"]) == set(AHUS)
    assert gaps["from"] == start
    assert m["temperature"]["Lobby"]["prev"]["config_complete"] is False
    assert temperature_change_status(m["temperature"]["Lobby"]["curr"], m["temperature"]["Lobby"]["prev"])[1] == "indicative"
    assert m["ahu_ooh"]["comparable"] is False
    q = assess(m)
    assert q.publishable and not q.incomplete_data and q.comparison_incomplete
    assert q.comparison_config_reasons == [
        "reporting settings in force only from 14 Oct 2026 08:13 (temperature setpoints: 4 sensors; "
        "AHU operating schedules: 7 AHUs; AHU operating thresholds: 7 AHUs)"]
    assert q.coverage["comparison_config_reasons"] == q.comparison_config_reasons
    observations, _ = build_summary_points(m)
    assert any("(previous week" in o and "†)" in o for o in observations)

    result = generate_report("Radisson Blu Coimbatore", WEEK, synthetic_assets(WEEK.comparison_start, 14),
                             radisson_layout(), _settings_from(start))
    assert result.quality.comparison_incomplete and not result.quality.incomplete_data
    from pypdf import PdfReader

    text = " ".join((p.extract_text() or "") for p in PdfReader(io.BytesIO(result.pdf)).pages)
    flat = " ".join(text.split())
    assert "In the previous week, reporting settings were in force only from 14 Oct 2026 08:13" in flat
    assert "comparisons marked † are indicative" in flat
    assert "The previous week's data is incomplete" not in flat     # data was complete
    assert "Data completeness" not in flat                          # no 'Incomplete data' label


def test_settings_in_force_throughout_need_no_configuration_disclosure():
    """A setpoint CHANGE within the period (24 -> 23 °C) is not a configuration gap."""

    settings = reference_settings()
    for name in ("Seasons Restaurant AHU-1", "Seasons Restaurant AHU-2"):
        settings.setpoints[name] = [(ALWAYS, 24.0), (pd.Timestamp("2026-10-14 08:13"), 23.0)]
    m = metrics_for(WEEK, synthetic_assets(WEEK.comparison_start, 14), settings)
    assert m["comparison_config_gaps"] == {"setpoints": [], "schedules": [], "thresholds": [], "from": None}
    assert all(t["prev"]["config_complete"] for t in m["temperature"].values())
    q = assess(m)
    assert q.comparison_config_reasons == [] and not q.comparison_incomplete


def test_temperature_is_never_estimated():
    """T-DQ-8: a 20-minute temperature gap stays a gap (energy gaps of that length are filled)."""

    gap = ("2026-10-20 10:01", "2026-10-20 10:20")
    assets = synthetic_assets(WEEK.comparison_start, 14, drop={"Lobby Area AHU-1": [gap]})
    m = metrics_for(WEEK, assets)
    frame = assets["Lobby Area AHU-1"].frame
    assert frame.loc["2026-10-20 10:10", "Temperature (degC)"] != frame.loc["2026-10-20 10:10", "Temperature (degC)"]  # NaN
    t = m["temperature"]["Lobby"]["curr"]
    assert t["observed"] == 7 * 1440 - 20


def test_sensorless_assets_are_not_temperature_monitored():
    m = weekly_clean()
    assert m["temperature"]["Banquet 1"]["curr"]["sensors"] == []
    assert {"Banquet 1 AHU", "Lobby Area AHU-2", "Pre Function Area AHU"} <= set(m["not_temperature_monitored"])


# ---------------------------------------------------------------------------
# Effective-dated settings (A17-A21, T-SET)
# ---------------------------------------------------------------------------

def test_setpoint_applies_per_reading_and_shows_range():
    """T-SET-1 / A20 / A21: 24 -> 23 °C effective Wed 21-Oct 00:00 splits the week."""

    settings = reference_settings()
    change = pd.Timestamp("2026-10-21 00:00")
    for name in ("Seasons Restaurant AHU-1", "Seasons Restaurant AHU-2"):
        settings.setpoints[name] = [(ALWAYS, 24.0), (change, 23.0)]
    m = metrics_for(WEEK, synthetic_assets(WEEK.comparison_start, 14), settings)
    t = m["temperature"]["Restaurant"]["curr"]
    assert t["setpoint_text"] == "23.0–24.0 °C"
    assets = synthetic_assets(WEEK.comparison_start, 14)
    spec = period_spec(WEEK)
    for a in assets.values():
        prepare_asset(a, spec.prev_start, spec.curr_end + pd.Timedelta(days=2))
    readings = pd.concat([assets[n].frame["Temperature (degC)"].dropna().loc["2026-10-18":"2026-10-24 23:59"]
                          for n in ("Seasons Restaurant AHU-1", "Seasons Restaurant AHU-2")])
    sp = np.where(readings.index < change, 24.0, 23.0)
    expected = float(np.abs(readings.to_numpy() - sp).mean())
    assert abs(t["mean_abs_deviation"] - expected) < 1e-9
    assert m["temperature"]["Lobby"]["curr"]["setpoint_text"] == "24.0 °C"


def test_setting_takes_effect_at_its_instant():
    """T-SET-8 / T-SET-9: a reading before the effective instant uses the previous value."""

    versions = [(ALWAYS, 24.0), (pd.Timestamp("2026-10-20 10:42"), 23.0), (pd.Timestamp("2026-10-25 00:00"), 22.0)]
    when = pd.DatetimeIndex(["2026-10-20 10:41", "2026-10-20 10:42", "2026-10-24 23:59", "2026-10-25 00:00"])
    assert rt.values_at(versions, when) == [24.0, 23.0, 23.0, 22.0]
    assert rt.values_at([(pd.Timestamp("2026-10-20 10:42"), 23.0)], pd.DatetimeIndex(["2026-10-20 10:00"])) == [None]


def test_area_with_different_sensor_setpoints_shows_range():
    assert setpoint_text([24.0, 23.0, 24.0]) == "23.0–24.0 °C"
    assert setpoint_text([24.0]) == "24.0 °C"
    assert setpoint_text([]) == "Not configured"


def test_missing_configuration_behaviour():
    """§5.3: no thresholds -> runtime not reported; no schedule -> no out-of-hours split; no setpoint -> NA deviation."""

    empty = ReportSettings()
    m = metrics_for(WEEK, synthetic_assets(WEEK.comparison_start, 14), empty)
    assert all(r["curr"]["status"] == "not reported" for r in m["ahu_runtime"].values())
    assert not any(r["curr"]["scheduled"] for r in m["ahu_runtime"].values())
    t = m["temperature"]["Lobby"]["curr"]
    assert t["setpoint_text"] == "Not configured" and np.isnan(t["mean_abs_deviation"]) and np.isfinite(t["mean"])


def test_operating_threshold_change_mid_period():
    """Thresholds resolve per interval: an ON threshold above every reading after the change makes those minutes non-ON."""

    settings = reference_settings()
    settings.thresholds["Lobby Area AHU-1"] = [(ALWAYS, rt.AHUSettings(0.05, None, 0.40)),
                                               (pd.Timestamp("2026-10-21 00:00"), rt.AHUSettings(0.05, None, 50.0))]
    m = metrics_for(WEEK, synthetic_assets(WEEK.comparison_start, 14), settings)
    base = metrics_for(WEEK, synthetic_assets(WEEK.comparison_start, 14))
    assert m["ahu_runtime"]["Lobby Area AHU-1"]["curr"]["hours"]["on"] < base["ahu_runtime"]["Lobby Area AHU-1"]["curr"]["hours"]["on"]


# ---------------------------------------------------------------------------
# PDF (A94-A100, T-PDF)
# ---------------------------------------------------------------------------

@functools.lru_cache(maxsize=1)
def weekly_pdf():
    return generate_report("Radisson Blu Coimbatore", WEEK, synthetic_assets(WEEK.comparison_start, 14),
                           radisson_layout(), reference_settings())


def _validate(data: bytes, **overrides):
    args = dict(site_name="Radisson Blu Coimbatore", title="Weekly EMS Performance Report",
                reporting_text="Reporting period: 18-Oct-2026 – 24-Oct-2026",
                comparison_text="Comparison period: 11-Oct-2026 – 17-Oct-2026", expected_images=10, out_of_hours=True)
    args.update(overrides)
    return validate_report_pdf(data, **args)


def test_weekly_pdf_is_valid_branded_and_embeds_source_sans():
    result = weekly_pdf()
    assert result.check.pages >= 6 and len(result.check.sha256) == 64
    from pypdf import PdfReader

    reader = PdfReader(io.BytesIO(result.pdf))
    fonts = {str(f.get_object()["/BaseFont"]) for p in reader.pages for f in (p["/Resources"].get("/Font") or {}).values()}
    assert fonts and all("SourceSans3" in f for f in fonts)
    text = " ".join((p.extract_text() or "") for p in reader.pages)
    assert "RADISSON BLU COIMBATORE" in text and "Prepared by: WiseWatts Solutions" in text
    assert "Radisson Blu - Coimbatore" not in text
    assert "Not temperature-monitored" in text
    assert result.file_name.endswith(".pdf") and b"docx" not in result.pdf.lower()


@pytest.mark.parametrize("mutate, check", [
    (lambda d: d[: len(d) // 2], "structure"),
    (lambda d: b"", "size"),
    (lambda d: d.replace(b"%PDF-", b"%XYZ-", 1), "structure"),
])
def test_corrupted_pdf_is_rejected(mutate, check):
    with pytest.raises(PdfValidationError) as excinfo:
        _validate(mutate(weekly_pdf().pdf))
    assert excinfo.value.check == check


@pytest.mark.parametrize("override, check", [
    ({"site_name": "Another Hotel"}, "content"),
    ({"reporting_text": "Reporting period: 25-Oct-2026 – 31-Oct-2026"}, "content"),
    ({"expected_images": 500}, "charts"),
])
def test_wrong_site_period_or_missing_charts_rejected(override, check):
    with pytest.raises(PdfValidationError) as excinfo:
        _validate(weekly_pdf().pdf, **override)
    assert excinfo.value.check == check


def test_pdf_missing_a_section_is_rejected(monkeypatch):
    import src.report_engine.validate_pdf as vp

    monkeypatch.setattr(vp, "REQUIRED_SECTIONS", vp.REQUIRED_SECTIONS + ("9. Section that does not exist",))
    with pytest.raises(PdfValidationError) as excinfo:
        _validate(weekly_pdf().pdf)
    assert excinfo.value.check == "content"


def test_blank_page_pdf_is_rejected():
    from reportlab.lib.pagesizes import A4
    from reportlab.pdfgen import canvas

    buf = io.BytesIO()
    c = canvas.Canvas(buf, pagesize=A4)
    for _ in range(6):
        c.showPage()
    c.save()
    data = buf.getvalue() + b"%" * 60000   # pad above the size floor; still no text
    data = data.replace(b"%%EOF", b"") + b"\n%%EOF\n"
    with pytest.raises(PdfValidationError):
        _validate(data)
