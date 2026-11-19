"""One report generation: prepare -> metrics -> quality gate -> charts -> PDF -> validation.

Pure computation over already-loaded readings and settings (no database
access), so it runs in a worker thread and is fully testable offline.
"""

from __future__ import annotations

from dataclasses import dataclass
from datetime import date

import matplotlib.pyplot as plt
import pandas as pd

from src.report_engine import ENGINE_VERSION
from src.report_engine.charts import build_report_charts
from src.report_engine.metrics import Layout, PeriodSpec, ReportSettings, build_summary_points, compute_report_metrics
from src.report_engine.periods import ReportPeriod
from src.report_engine.prepare import AssetData, prepare_asset
from src.report_engine.quality import QualityResult, assess
from src.report_engine.render_pdf import RenderContext, render_report
from src.report_engine.validate_pdf import PdfCheckResult, validate_report_pdf


class InsufficientDataError(Exception):
    """The current period fails the minimum publication requirements (A48)."""

    def __init__(self, quality: QualityResult) -> None:
        super().__init__(quality.failure_message)
        self.quality = quality


@dataclass
class GenerationResult:
    pdf: bytes
    check: PdfCheckResult
    quality: QualityResult
    file_name: str
    engine_version: str = ENGINE_VERSION


def _ts(day: date) -> pd.Timestamp:
    return pd.Timestamp(day)


def period_spec(period: ReportPeriod) -> PeriodSpec:
    return PeriodSpec(period.report_type, _ts(period.comparison_start), _ts(period.comparison_end),
                      _ts(period.start), _ts(period.end))


def reporting_texts(spec: PeriodSpec) -> tuple[str, str]:
    from src.report_engine.metrics import fmt_date

    if spec.weekly:
        return (f"Reporting period: {fmt_date(spec.curr_start)} – {fmt_date(spec.curr_end)}",
                f"Comparison period: {fmt_date(spec.prev_start)} – {fmt_date(spec.prev_end)}")
    return (f"Reporting period: {spec.curr_start:%B %Y} ({fmt_date(spec.curr_start)} – {fmt_date(spec.curr_end)})",
            f"Comparison period: {spec.prev_start:%B %Y} ({fmt_date(spec.prev_start)} – {fmt_date(spec.prev_end)})")


def safe_file_name(site_name: str, spec: PeriodSpec) -> str:
    stem = "".join(ch if ch.isalnum() else "_" for ch in site_name).strip("_") or "Site"
    while "__" in stem:
        stem = stem.replace("__", "_")
    if spec.weekly:
        return f"{stem}_Weekly_EMS_Report_{spec.curr_start:%d-%b-%Y}_{spec.curr_end:%d-%b-%Y}.pdf"
    return f"{stem}_Monthly_EMS_Report_{spec.curr_start:%b-%Y}.pdf"


def completeness_note(spec: PeriodSpec, quality: QualityResult) -> str:
    reasons = "; ".join(quality.incomplete_reasons[:3])
    assets = ", ".join(quality.affected_assets[:8]) + (" and others" if len(quality.affected_assets) > 8 else "")
    text = f"The {spec.curr_noun} has incomplete data ({reasons})."
    if assets:
        text += f" Meters with missing or partial days: {assets}."
    text += (" Totals include measured readings and estimated readings (EMS-reconstructed values and gaps of up to "
             "30 minutes); longer gaps are not filled and no temperature is estimated. Changes marked † are indicative.")
    return text


def comparison_note(spec: PeriodSpec, quality: QualityResult) -> str:
    reasons = "; ".join(quality.comparison_reasons[:2])
    return f"† The {spec.prev_noun}'s data is incomplete ({reasons}); changes marked † are indicative."


def generate_report(site_name: str, period: ReportPeriod, assets: dict[str, AssetData], layout: Layout,
                    settings: ReportSettings) -> GenerationResult:
    """Raises InsufficientDataError when the minimum publication requirements
    are not met, PdfValidationError when the PDF fails validation."""

    spec = period_spec(period)
    start = spec.prev_start
    for asset in assets.values():
        end_exclusive = spec.curr_end + pd.Timedelta(days=1) + pd.Timedelta(minutes=asset.interval_minutes)
        prepare_asset(asset, start, end_exclusive)
    m = compute_report_metrics(assets, layout, spec, settings)
    quality = assess(m)
    if not quality.publishable:
        raise InsufficientDataError(quality)
    observations, attention = build_summary_points(m)
    charts = build_report_charts(m)
    try:
        chart_count = len(charts)
        ctx = RenderContext(site_name=site_name, period=spec,
                            comparison_incomplete=quality.comparison_incomplete,
                            comparison_note=comparison_note(spec, quality) if quality.comparison_incomplete else "",
                            incomplete_data=quality.incomplete_data,
                            completeness_note=completeness_note(spec, quality) if quality.incomplete_data else "")
        pdf = render_report(m, charts, observations, attention, ctx)
    finally:
        plt.close("all")
    reporting, comparison = reporting_texts(spec)
    scheduled = any(r["curr"]["scheduled"] for r in m["ahu_runtime"].values())
    check = validate_report_pdf(pdf, site_name=site_name, title=spec.title, reporting_text=reporting,
                                comparison_text=comparison, expected_images=chart_count, out_of_hours=scheduled)
    return GenerationResult(pdf=pdf, check=check, quality=quality, file_name=safe_file_name(site_name, spec))
