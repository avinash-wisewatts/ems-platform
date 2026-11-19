"""Report charts (presentation only).

Conventions from the reference tool: WiseWatts colours (navy previous / measured,
teal latest, orange setpoint and peak, slate for AHUs), one zero-based y-axis,
hatched incomplete days, "n/a" (never zero) for days without a value, legends
below the plot, 7.2 x 3.4 in figures embedded at 6.4 in, 200 dpi.

Revision changes: charts use Source Sans 3 (A98); a monthly report's daily
charts show the CURRENT month only, with no previous-month daily series and
no day-of-month pairing (A36, A37, A39); the setpoint line follows the
effective-dated setpoint and shows a range when an area's sensors differ
(A20, A21).
"""

from __future__ import annotations

import io
import math
import textwrap
from pathlib import Path
from typing import Optional

import matplotlib

matplotlib.use("Agg")
import matplotlib.dates  # noqa: E402
import matplotlib.patches  # noqa: E402
import matplotlib.pyplot as plt  # noqa: E402
import matplotlib.ticker  # noqa: E402
import numpy as np  # noqa: E402
import pandas as pd  # noqa: E402
from matplotlib import font_manager  # noqa: E402

from src.report_engine.metrics import (  # noqa: E402
    DAILY_TEMPERATURE_AREAS,
    BANQUET_TEMPERATURE_AREAS,
    TEMP_TOLERANCE_C,
    fmt_date,
    fmt_pct,
    is_fully_comparable,
)

FONT_DIR = Path(__file__).with_name("fonts")
FONT_FAMILY = "Source Sans 3"
for _font in FONT_DIR.glob("SourceSans3-*.ttf"):
    font_manager.fontManager.addfont(str(_font))
matplotlib.rcParams["font.family"] = FONT_FAMILY
matplotlib.rcParams["pdf.fonttype"] = 42
matplotlib.rcParams["axes.unicode_minus"] = False

NAVY_HEX, TEAL_HEX, ORANGE_HEX = "05245B", "03A9A0", "FF9966"
NAVY, TEAL, ORANGE = f"#{NAVY_HEX}", f"#{TEAL_HEX}", f"#{ORANGE_HEX}"
SLATE = "#8C96A8"
INK, MUTED_INK, GRID = "#1F2937", "#5B6474", "#E3E6EB"
INCOMPLETE_FILL = "#C9CED6"
CHART_SIZE = (7.2, 3.4)
CHART_WIDTH_IN_REPORT = 6.4
DAILY_TEMPERATURE_CHART_SIZE = (7.2, 3.0)
CHART_FONT = 9
CHART_DPI = 200
SUBSYSTEM_COLOURS = {"Chillers": TEAL, "Pumps": NAVY, "Cooling towers": ORANGE, "Air handling units": SLATE}
BANQUET_PALETTE = (NAVY, TEAL, ORANGE, SLATE)
PREVIOUS_COLOUR, LATEST_COLOUR = NAVY, TEAL
INCOMPLETE_HATCH = "////"
SUBTITLE_WRAP_CHARS = 95
LEGEND_ONE_ROW_CHARS = 80
KWH_FORMAT = matplotlib.ticker.FuncFormatter(lambda v, _: f"{v:,.0f}")


def _new_chart(title: str, subtitle: Optional[str] = None, size=CHART_SIZE):
    fig, ax = plt.subplots(figsize=size)
    subtitle = textwrap.fill(subtitle, SUBTITLE_WRAP_CHARS) if subtitle else None
    lines = subtitle.count("\n") + 1 if subtitle else 0
    ax.set_title(title, loc="left", fontsize=CHART_FONT + 2, fontweight="bold", color=NAVY,
                 pad=10 + 13 * lines if subtitle else 10)
    if subtitle:
        ax.annotate(subtitle, xy=(0, 1), xycoords="axes fraction", xytext=(0, 6), textcoords="offset points",
                    fontsize=CHART_FONT, color=MUTED_INK, va="bottom")
    for side in ("top", "right"):
        ax.spines[side].set_visible(False)
    for side in ("left", "bottom"):
        ax.spines[side].set_color("#B8BEC8")
    ax.tick_params(colors=MUTED_INK, labelsize=CHART_FONT, length=3)
    ax.set_axisbelow(True)
    return fig, ax


def _legend_below(fig, ax, handles, labels, ncol: Optional[int] = None, offset: float = -0.2):
    if handles:
        if ncol is None:
            ncol = len(labels) if sum(len(lb) for lb in labels) <= LEGEND_ONE_ROW_CHARS else 2
        ax.legend(handles, labels, loc="upper center", bbox_to_anchor=(0.5, offset), ncol=ncol,
                  frameon=False, fontsize=CHART_FONT, labelcolor=INK, handlelength=1.8, columnspacing=1.6)
    fig.tight_layout()


def _incomplete_handle():
    return matplotlib.patches.Patch(facecolor=INCOMPLETE_FILL, edgecolor="white", hatch=INCOMPLETE_HATCH,
                                    label="Incomplete data (hatched)")


def day_labels(dates) -> list[str]:
    dates = list(dates)
    if len(dates) > 7:   # a month: day numbers only
        return [f"{pd.Timestamp(d):%d}" for d in dates]
    return [f"{pd.Timestamp(d):%a}\n{pd.Timestamp(d):%d-%b}" for d in dates]


def paired_day_labels(prev_dates, curr_dates) -> list[str]:
    """Weekly only: weekday with both weeks' dates, e.g. "Sun\\n11/18-Oct"."""

    labels = []
    for p, c in zip(map(pd.Timestamp, prev_dates), map(pd.Timestamp, curr_dates)):
        dates = f"{p:%d}/{c:%d-%b}" if p.month == c.month else f"{p:%d-%b}/{c:%d-%b}"
        labels.append(f"{c:%a}\n{dates}")
    return labels


def _month_axis_label(ax, dates) -> None:
    dates = list(dates)
    if len(dates) > 7:
        ax.set_xlabel(pd.Timestamp(dates[0]).strftime("%B %Y"), fontsize=CHART_FONT, color=MUTED_INK)


def chart_week_comparison(prev: pd.DataFrame, curr: pd.DataFrame, title: str, subtitle: str,
                          prev_label: str, curr_label: str):
    """WEEKLY only: daily energy by weekday, previous vs latest week."""

    fig, ax = _new_chart(title, subtitle)
    x = np.arange(len(curr))
    width = 0.38
    any_incomplete = False
    for offset, frame, colour, label in ((-width / 2, prev, PREVIOUS_COLOUR, prev_label),
                                         (width / 2, curr, LATEST_COLOUR, curr_label)):
        values = frame["total_kwh"].to_numpy(dtype=float)
        bars = ax.bar(x + offset, np.nan_to_num(values), width, color=colour, edgecolor="white", linewidth=1, label=label)
        for bar, complete, value in zip(bars, frame["complete"], values):
            if not np.isfinite(value):
                ax.text(bar.get_x() + bar.get_width() / 2, 0, "n/a", ha="center", va="bottom", fontsize=CHART_FONT, color=MUTED_INK)
            elif not complete:
                bar.set_hatch(INCOMPLETE_HATCH)
                any_incomplete = True
    top = np.nanmax([prev["total_kwh"].max(), curr["total_kwh"].max(), 0])
    ax.set_ylim(0, top * 1.12 if top > 0 else 1)
    ax.set_xticks(x, day_labels(curr.index))
    ax.set_ylabel("Energy (kWh)", fontsize=CHART_FONT, color=MUTED_INK)
    ax.yaxis.set_major_formatter(KWH_FORMAT)
    ax.grid(axis="y", color=GRID, linewidth=0.8)
    handles, labels = ax.get_legend_handles_labels()
    if any_incomplete:
        handles.append(_incomplete_handle())
        labels.append("Incomplete data (hatched)")
    _legend_below(fig, ax, handles, labels)
    return fig


def chart_daily_single(curr: pd.DataFrame, title: str, subtitle: str, label: str):
    """MONTHLY: the current month's daily energy trend only (no previous-month series)."""

    fig, ax = _new_chart(title, subtitle)
    x = np.arange(len(curr))
    values = curr["total_kwh"].to_numpy(dtype=float)
    bars = ax.bar(x, np.nan_to_num(values), 0.7, color=LATEST_COLOUR, edgecolor="white", linewidth=0.6, label=label)
    any_incomplete = False
    for bar, complete, value in zip(bars, curr["complete"], values):
        if not np.isfinite(value):
            ax.text(bar.get_x() + bar.get_width() / 2, 0, "n/a", ha="center", va="bottom", fontsize=CHART_FONT - 2,
                    color=MUTED_INK, rotation=90)
        elif not complete:
            bar.set_hatch(INCOMPLETE_HATCH)
            any_incomplete = True
    top = np.nanmax([np.nanmax(values, initial=0), 0])
    ax.set_ylim(0, top * 1.12 if top > 0 else 1)
    ax.set_xticks(x, day_labels(curr.index))
    ax.tick_params(axis="x", labelsize=CHART_FONT - 1)
    _month_axis_label(ax, curr.index)
    ax.set_ylabel("Energy (kWh)", fontsize=CHART_FONT, color=MUTED_INK)
    ax.yaxis.set_major_formatter(KWH_FORMAT)
    ax.grid(axis="y", color=GRID, linewidth=0.8)
    handles, labels = ax.get_legend_handles_labels()
    if any_incomplete:
        handles.append(_incomplete_handle())
        labels.append("Incomplete data (hatched)")
    _legend_below(fig, ax, handles, labels, offset=-0.28)
    return fig


def chart_stacked_daily(components: dict[str, pd.Series], daily: pd.DataFrame, title: str, subtitle: str,
                        colours: dict[str, str]):
    fig, ax = _new_chart(title, subtitle)
    x = np.arange(len(daily))
    bottom = np.zeros(len(daily))
    incomplete = ~daily["complete"].to_numpy(dtype=bool)
    monthly = len(daily) > 7
    for name, series in components.items():
        values = np.nan_to_num(series.reindex(daily.index).to_numpy(dtype=float))
        bars = ax.bar(x, values, 0.62, bottom=bottom, color=colours.get(name, SLATE), edgecolor="white", linewidth=1 if not monthly else 0.4, label=name)
        for bar, flag in zip(bars, incomplete):
            if flag:
                bar.set_hatch(INCOMPLETE_HATCH)
        bottom += values
    if not monthly:   # a month has too many bars for readable total labels
        for xi, total in zip(x, daily["total_kwh"]):
            ax.text(xi, (total if np.isfinite(total) else 0), f"{total:,.1f}" if np.isfinite(total) else "n/a",
                    ha="center", va="bottom", fontsize=CHART_FONT, color=INK, fontweight="bold")
    ax.set_ylim(0, max(np.nanmax(daily["total_kwh"].to_numpy(dtype=float), initial=0), bottom.max(), 1) * 1.12)
    ax.set_xticks(x, day_labels(daily.index))
    if monthly:
        ax.tick_params(axis="x", labelsize=CHART_FONT - 1)
        _month_axis_label(ax, daily.index)
    ax.set_ylabel("Energy (kWh)", fontsize=CHART_FONT, color=MUTED_INK)
    ax.yaxis.set_major_formatter(KWH_FORMAT)
    ax.grid(axis="y", color=GRID, linewidth=0.8)
    handles, labels = ax.get_legend_handles_labels()
    if incomplete.any():
        handles.append(_incomplete_handle())
        labels.append("Incomplete data (hatched)")
    _legend_below(fig, ax, handles, labels, offset=-0.28 if monthly else -0.2)
    return fig


def chart_asset_comparison(prev: pd.Series, curr: pd.Series, title: str, subtitle: str,
                           prev_label: str, curr_label: str, labels: Optional[dict[str, str]] = None):
    """Period totals per meter, previous vs current (totals, never individual days)."""

    order = curr.fillna(-1).sort_values(ascending=False).index
    height = max(CHART_SIZE[1], 0.42 * len(order) + 1.4)
    fig, ax = _new_chart(title, subtitle, size=(CHART_SIZE[0], height))
    y = np.arange(len(order))
    bar = 0.38
    ax.barh(y - bar / 2, np.nan_to_num(prev.reindex(order).to_numpy(dtype=float)), bar, color=PREVIOUS_COLOUR,
            edgecolor="white", linewidth=1, label=prev_label)
    ax.barh(y + bar / 2, np.nan_to_num(curr.reindex(order).to_numpy(dtype=float)), bar, color=LATEST_COLOUR,
            edgecolor="white", linewidth=1, label=curr_label)
    ax.set_yticks(y, [(labels or {}).get(n, n) for n in order])
    ax.invert_yaxis()
    top = np.nanmax([prev.max(), curr.max(), 0])
    ax.set_xlim(0, top * 1.08 if top > 0 else 1)
    ax.set_xlabel("Energy (kWh)", fontsize=CHART_FONT, color=MUTED_INK)
    ax.xaxis.set_major_formatter(KWH_FORMAT)
    ax.grid(axis="x", color=GRID, linewidth=0.8)
    handles, legend_labels = ax.get_legend_handles_labels()
    ax.legend(handles, legend_labels, loc="upper center", bbox_to_anchor=(0.5, -0.12 * CHART_SIZE[1] / height * 1.6),
              ncol=2, frameon=False, fontsize=CHART_FONT, labelcolor=INK)
    fig.tight_layout()
    return fig


def chart_in_out_of_hours(energy_in: pd.Series, energy_out: pd.Series, title: str, subtitle: str):
    order = energy_out.fillna(-1).sort_values(ascending=False).index
    height = max(CHART_SIZE[1], 0.42 * len(order) + 1.5)
    fig, ax = _new_chart(title, subtitle, size=(CHART_SIZE[0], height))
    y = np.arange(len(order))
    inside = np.nan_to_num(energy_in.reindex(order).to_numpy(dtype=float))
    outside = np.nan_to_num(energy_out.reindex(order).to_numpy(dtype=float))
    ax.barh(y, inside, 0.6, color=NAVY, edgecolor="white", linewidth=1, label="Within working hours")
    ax.barh(y, outside, 0.6, left=inside, color=ORANGE, edgecolor="white", linewidth=1, label="Outside working hours")
    totals = inside + outside
    for yi, total, out in zip(y, totals, outside):
        share = fmt_pct(out / total * 100) if total > 0 else "NA"
        ax.text(total, yi, f"  {share} out of hours", va="center", ha="left", fontsize=CHART_FONT, color=INK)
    ax.set_yticks(y, list(order))
    ax.invert_yaxis()
    ax.set_xlim(0, (totals.max() if len(totals) and totals.max() > 0 else 1) * 1.32)
    ax.set_xlabel("Energy (kWh)", fontsize=CHART_FONT, color=MUTED_INK)
    ax.xaxis.set_major_formatter(KWH_FORMAT)
    ax.grid(axis="x", color=GRID, linewidth=0.8)
    handles, labels = ax.get_legend_handles_labels()
    ax.legend(handles, labels, loc="upper center", bbox_to_anchor=(0.5, -0.12 * CHART_SIZE[1] / height * 1.6),
              ncol=2, frameon=False, fontsize=CHART_FONT, labelcolor=INK)
    fig.tight_layout()
    return fig


def chart_asset_daily_bars(daily: dict[str, pd.DataFrame], title: str, subtitle: str, colours: dict[str, str]):
    """Current period daily energy, one bar per asset per day (no comparison)."""

    fig, ax = _new_chart(title, subtitle)
    dates = next(iter(daily.values())).index
    monthly = len(dates) > 7
    x = np.arange(len(dates))
    width = 0.8 / max(len(daily), 1)
    any_incomplete = False
    for i, (name, frame) in enumerate(daily.items()):
        values = frame["total_kwh"].to_numpy(dtype=float)
        offset = (i - (len(daily) - 1) / 2) * width
        bars = ax.bar(x + offset, np.nan_to_num(values), width, color=colours[name], edgecolor="white",
                      linewidth=0.4 if monthly else 1, label=name)
        for bar, complete, value in zip(bars, frame["complete"], values):
            if not np.isfinite(value):
                ax.text(bar.get_x() + bar.get_width() / 2, 0, "n/a", ha="center", va="bottom",
                        fontsize=CHART_FONT - (3 if monthly else 0), color=MUTED_INK, rotation=90)
            elif not complete:
                bar.set_hatch(INCOMPLETE_HATCH)
                any_incomplete = True
    top = np.nanmax([np.nanmax(f["total_kwh"].to_numpy(dtype=float), initial=0) for f in daily.values()] + [0])
    ax.set_ylim(0, top * 1.12 if top > 0 else 1)
    ax.set_xticks(x, day_labels(dates))
    if monthly:
        ax.tick_params(axis="x", labelsize=CHART_FONT - 1)
        _month_axis_label(ax, dates)
    ax.set_ylabel("Energy (kWh)", fontsize=CHART_FONT, color=MUTED_INK)
    ax.yaxis.set_major_formatter(KWH_FORMAT)
    ax.grid(axis="y", color=GRID, linewidth=0.8)
    handles, labels = ax.get_legend_handles_labels()
    if any_incomplete:
        handles.append(_incomplete_handle())
        labels.append("Incomplete data (hatched)")
    _legend_below(fig, ax, handles, labels, offset=-0.28 if monthly else -0.2)
    return fig


def temperature_axis_range(values: pd.Series, setpoint_low: float, setpoint_high: float, tolerance: float,
                           padding: float = 0.5, min_span: float = 4.0) -> tuple[float, float]:
    finite = values[np.isfinite(values)]
    band = [] if not np.isfinite(setpoint_low) else [setpoint_low - tolerance, setpoint_high + tolerance]
    low = min(band[:1] + ([float(finite.min())] if len(finite) else []) or [20.0]) - padding
    high = max(band[1:] + ([float(finite.max())] if len(finite) else []) or [26.0]) + padding
    if high - low < min_span:
        centre = (high + low) / 2
        low, high = centre - min_span / 2, centre + min_span / 2
    return math.floor(low * 2) / 2, math.ceil(high * 2) / 2


def _time_axis(ax, start: pd.Timestamp, days: int) -> None:
    ax.set_xlim(start, start + pd.Timedelta(days=days))
    if days <= 7:
        ax.xaxis.set_major_locator(matplotlib.dates.DayLocator())
        ax.xaxis.set_major_formatter(matplotlib.dates.DateFormatter("%a\n%d-%b"))
        for label in ax.get_xticklabels():
            label.set_horizontalalignment("left")
    else:
        ax.xaxis.set_major_locator(matplotlib.dates.DayLocator(bymonthday=(1, 5, 10, 15, 20, 25, 30)))
        ax.xaxis.set_minor_locator(matplotlib.dates.DayLocator())
        ax.xaxis.set_major_formatter(matplotlib.dates.DateFormatter("%d-%b"))


def chart_temperature(hourly: pd.Series, setpoint_low: pd.Series, setpoint_high: pd.Series, tolerance: float,
                      title: str, subtitle: str, days: int):
    """Hourly measured temperature (navy) against the setpoint in force (orange
    dashed; two lines when the area's sensors have different setpoints) and its
    comfort band. Hours without readings are gaps; nothing is interpolated."""

    fig, ax = _new_chart(title, subtitle)
    low = setpoint_low.reindex(hourly.index).to_numpy(dtype=float)
    high = setpoint_high.reindex(hourly.index).to_numpy(dtype=float)
    has_setpoint = np.isfinite(low).any()
    single = has_setpoint and np.allclose(low[np.isfinite(low)], high[np.isfinite(high)])
    if has_setpoint:
        ax.fill_between(hourly.index, low - tolerance, high + tolerance, step="post", color=TEAL, alpha=0.14, linewidth=0,
                        label=f"Setpoint ±{tolerance:g} °C band")
    ax.plot(hourly.index, hourly.to_numpy(dtype=float), color=NAVY, linewidth=1.6 if days <= 7 else 0.9,
            label="Measured temperature (hourly average)")
    finite_low = low[np.isfinite(low)]
    if has_setpoint:
        values = sorted({round(float(v), 1) for v in np.concatenate([finite_low, high[np.isfinite(high)]])})
        text = f"{values[0]:.1f} °C" if len(values) == 1 else f"{values[0]:.1f}–{values[-1]:.1f} °C"
        ax.step(hourly.index, low, where="post", color=ORANGE, linestyle="--", linewidth=2,
                label=f"Setpoint {text}" if single or len(values) == 1 else f"Setpoint range {text}")
        if not single:
            ax.step(hourly.index, high, where="post", color=ORANGE, linestyle="--", linewidth=2)
    ax.set_ylim(*temperature_axis_range(hourly, float(np.nanmin(low)) if has_setpoint else np.nan,
                                        float(np.nanmax(high)) if has_setpoint else np.nan, tolerance))
    start = hourly.index.min().normalize()
    _time_axis(ax, start, days)
    ax.set_ylabel("Temperature (°C)", fontsize=CHART_FONT, color=MUTED_INK)
    ax.grid(axis="both", color=GRID, linewidth=0.8)
    handles, labels = ax.get_legend_handles_labels()
    order = sorted(range(len(labels)), key=lambda i: (0 if labels[i].startswith("Measured") else 1 if labels[i].startswith("Setpoint ") and "band" not in labels[i] else 2))
    _legend_below(fig, ax, [handles[i] for i in order], [labels[i] for i in order])
    return fig


def chart_daily_temperature_comparison(prev: pd.Series, curr: pd.Series, title: str, subtitle: str,
                                       prev_label: str, curr_label: str):
    """WEEKLY only: daily average temperature by weekday, previous vs latest week."""

    fig, ax = _new_chart(title, subtitle, size=DAILY_TEMPERATURE_CHART_SIZE)
    x = np.arange(len(curr))
    for frame, colour, marker, label in ((prev, PREVIOUS_COLOUR, "o", prev_label), (curr, LATEST_COLOUR, "s", curr_label)):
        ax.plot(x, frame.to_numpy(dtype=float), color=colour, marker=marker, markersize=7, linewidth=2, label=label)
    _daily_temperature_axes(ax, pd.concat([prev, curr]).dropna(), len(x))
    ax.set_xticks(x, paired_day_labels(prev.index, curr.index))
    handles, labels = ax.get_legend_handles_labels()
    _legend_below(fig, ax, handles, labels, offset=-0.34)
    return fig


def chart_daily_temperature_single(curr: pd.Series, title: str, subtitle: str, label: str):
    """MONTHLY: the current month's daily average temperature only."""

    fig, ax = _new_chart(title, subtitle, size=DAILY_TEMPERATURE_CHART_SIZE)
    x = np.arange(len(curr))
    ax.plot(x, curr.to_numpy(dtype=float), color=LATEST_COLOUR, marker="s", markersize=4, linewidth=1.6, label=label)
    _daily_temperature_axes(ax, curr.dropna(), len(x))
    ax.set_xticks(x, day_labels(curr.index))
    ax.tick_params(axis="x", labelsize=CHART_FONT - 1)
    _month_axis_label(ax, curr.index)
    handles, labels = ax.get_legend_handles_labels()
    _legend_below(fig, ax, handles, labels, offset=-0.4)
    return fig


def _daily_temperature_axes(ax, values: pd.Series, count: int) -> None:
    low, high = (float(values.min()), float(values.max())) if len(values) else (20.0, 26.0)
    low, high = low - 0.5, high + 0.5
    if high - low < 2.0:
        centre = (high + low) / 2
        low, high = centre - 1.0, centre + 1.0
    ax.set_ylim(math.floor(low * 2) / 2, math.ceil(high * 2) / 2)
    ax.set_xlim(-0.4, count - 0.6)
    ax.set_ylabel("Daily average (°C)", fontsize=CHART_FONT, color=MUTED_INK)
    ax.grid(axis="y", color=GRID, linewidth=0.8)


def chart_peak_demand(total_kw: pd.Series, peak_kw: float, peak_time: Optional[pd.Timestamp],
                      previous_peak_kw: float, title: str, subtitle: str, days: int, meters: int,
                      curr_noun: str, prev_noun: str):
    fig, ax = _new_chart(title, subtitle)
    ax.plot(total_kw.index, total_kw.to_numpy(dtype=float), color=NAVY, linewidth=0.7 if days <= 7 else 0.4,
            label=f"HVAC demand, all {meters} meters observed")
    if np.isfinite(previous_peak_kw):
        ax.axhline(previous_peak_kw, color=TEAL, linestyle=":", linewidth=1.8,
                   label=f"{prev_noun.capitalize()} peak {previous_peak_kw:,.1f} kW")
    top = np.nanmax([total_kw.max() if len(total_kw) else 0, previous_peak_kw if np.isfinite(previous_peak_kw) else 0, 0])
    ax.set_ylim(0, top * 1.4 if top > 0 else 1)
    start = total_kw.index.min().normalize() if len(total_kw) else pd.Timestamp("2000-01-01")
    if peak_time is not None and np.isfinite(peak_kw):
        ax.scatter([peak_time], [peak_kw], s=70, color=ORANGE, edgecolor="white", linewidth=1.5, zorder=5,
                   label=f"{curr_noun.capitalize()} peak {peak_kw:,.1f} kW")
        left_half = (peak_time - total_kw.index.min()) < (total_kw.index.max() - total_kw.index.min()) / 2
        shift = pd.Timedelta(hours=6 * max(1, days // 7))
        label_at = (peak_time + (shift if left_half else -shift), top * 1.12)
        ax.annotate(f"Peak {peak_kw:,.1f} kW\n{fmt_date(peak_time)} {peak_time:%H:%M}", xy=(peak_time, peak_kw),
                    xytext=label_at, textcoords="data", ha="left" if left_half else "right",
                    va="bottom", fontsize=CHART_FONT, color=INK, fontweight="bold",
                    bbox={"boxstyle": "round,pad=0.3", "facecolor": "white", "edgecolor": ORANGE, "linewidth": 1},
                    arrowprops={"arrowstyle": "-", "color": ORANGE, "linewidth": 1})
    _time_axis(ax, start, days)
    ax.set_ylabel("Demand (kW)", fontsize=CHART_FONT, color=MUTED_INK)
    ax.yaxis.set_major_formatter(KWH_FORMAT)
    ax.grid(axis="y", color=GRID, linewidth=0.8)
    handles, labels = ax.get_legend_handles_labels()
    _legend_below(fig, ax, handles, labels)
    return fig


def figure_png(fig) -> bytes:
    """PNG bytes at CHART_DPI; the figure is closed. Raises ValueError for a blank image."""

    buf = io.BytesIO()
    fig.savefig(buf, format="png", dpi=CHART_DPI, bbox_inches="tight", facecolor="white")
    plt.close(fig)
    data = buf.getvalue()
    if not png_has_content(data):
        raise ValueError("chart rendered blank")
    return data


def png_has_content(data: bytes) -> bool:
    from PIL import Image

    with Image.open(io.BytesIO(data)) as image:
        extrema = image.convert("L").getextrema()
    return extrema[0] != extrema[1]


# ---------------------------------------------------------------------------
# All charts of a report
# ---------------------------------------------------------------------------

def chart_key(area: str) -> str:
    return area.lower().replace(" ", "_")


def build_report_charts(m: dict) -> dict:
    """Every chart, keyed by name; render_pdf embeds exactly these."""

    period = m["period"]
    layout = m["layout"]
    (prev_start, prev_end), (curr_start, curr_end) = m["weeks"]["prev"], m["weeks"]["curr"]
    days = (curr_end - curr_start).days + 1
    weekly = period.weekly
    if weekly:
        prev_label = f"Previous week ({prev_start:%d-%b} – {prev_end:%d-%b})"
        curr_label = f"Latest week ({curr_start:%d-%b} – {curr_end:%d-%b})"
    else:
        prev_label = f"Previous month ({prev_start:%B %Y})"
        curr_label = f"Reporting month ({curr_start:%B %Y})"
    pk = m["peak"]
    hvac_count = len(layout.hvac_names)
    kitchen_count = len(layout.kitchen_names)

    def daily(group: str, title: str, subtitle: str):
        if weekly:
            return chart_week_comparison(m["daily"][group]["prev"], m["daily"][group]["curr"], title,
                                         subtitle + ", by day of week", prev_label, curr_label)
        return chart_daily_single(m["daily"][group]["curr"], title, subtitle + ", daily trend for the reporting month", curr_label)

    charts = {
        "hvac_daily": daily("HVAC", "Daily HVAC energy", f"All {hvac_count} HVAC meters"),
        "hvac_subsystems": chart_stacked_daily(m["subsystem_daily"], m["daily"]["HVAC"]["curr"],
                                               f"{curr_label.split(' (')[0]} HVAC energy by subsystem",
                                               "Daily totals labelled (kWh)" if weekly else "Daily energy (kWh) by subsystem",
                                               SUBSYSTEM_COLOURS),
        "hvac_peak": chart_peak_demand(pk["curr"]["total_kw"], pk["curr"]["peak_kw"], pk["curr"]["time"], pk["prev"]["peak_kw"],
                                       f"{curr_label.split(' (')[0]} HVAC demand and peak",
                                       f"1-minute readings across all {hvac_count} HVAC meters (gaps left blank)",
                                       days, hvac_count, period.curr_noun, period.prev_noun),
    }
    for area in ("Lobby", "Restaurant"):
        t = m["temperature"][area]["curr"]
        if t["sensors"]:
            low, high = m["hourly_setpoint"][area]
            charts[f"{area.lower()}_temperature"] = chart_temperature(
                m["hourly_temperature"][area], low, high, TEMP_TOLERANCE_C, f"{area} temperature against setpoint",
                f"Line shows hourly averages of recorded readings ({', '.join(t['sensors'])}). Statistics use every "
                f"individual reading: {fmt_pct(t['within_band_pct'])} within ±{TEMP_TOLERANCE_C:g} °C.", days)
            charts[f"{area.lower()}_daily_temperature"] = daily_temperature_chart(m, area, prev_label, curr_label)
        charts[f"{area.lower()}_energy"] = daily(area, f"Daily {area.lower()} AHU energy",
                                                 " + ".join(m["energy_areas"][area]))
    charts["kitchen_daily"] = daily("Kitchen", "Daily kitchen energy", f"All {kitchen_count} kitchen meters")
    kitchen_labels = {n: n.replace("Kitchen GF ", "") + ("" if is_fully_comparable(m["assets"][n]["curr"], m["assets"][n]["prev"]) else " †")
                      for n in layout.kitchen_names}
    charts["kitchen_meters"] = chart_asset_comparison(
        pd.Series({n: m["assets"][n]["prev"]["total"] for n in layout.kitchen_names}, dtype=float),
        pd.Series({n: m["assets"][n]["curr"]["total"] for n in layout.kitchen_names}, dtype=float),
        f"{'Weekly' if weekly else 'Monthly'} energy by kitchen meter",
        f"† incomplete data in at least one {period.unit}; comparison is indicative",
        prev_label, curr_label, kitchen_labels)
    banquet = m["asset_daily"]["Banquet & pre-function"]
    if banquet:
        colours = {n: BANQUET_PALETTE[i % len(BANQUET_PALETTE)] for i, n in enumerate(banquet)}
        charts["banquet_energy"] = chart_asset_daily_bars(
            banquet, f"{curr_label.split(' (')[0]} banquet & pre-function AHU energy",
            f"Daily energy per AHU, {curr_start:%d-%b} – {curr_end:%d-%b}", colours)
    for area in BANQUET_TEMPERATURE_AREAS:
        if m["temperature"][area]["curr"]["sensors"]:
            charts[f"{chart_key(area)}_daily_temperature"] = daily_temperature_chart(m, area, prev_label, curr_label)
    scheduled = {n: r["curr"] for n, r in m.get("ahu_runtime", {}).items() if r["curr"]["scheduled"]}
    if scheduled:
        charts["ahu_out_of_hours"] = chart_in_out_of_hours(
            pd.Series({n: r["energy_in"] for n, r in scheduled.items()}, dtype=float),
            pd.Series({n: r["energy_out"] for n, r in scheduled.items()}, dtype=float),
            f"{curr_label.split(' (')[0]} AHU energy within and outside working hours",
            f"AHUs with configured working hours; {curr_label}")
    return charts


def daily_temperature_chart(m: dict, area: str, prev_label: str, curr_label: str):
    sensors = ", ".join(m["temperature"][area]["curr"]["sensors"]) or "no sensor"
    subtitle = f"Daily mean of all recorded readings ({sensors}); gaps show days without readings"
    if m["period"].weekly:
        return chart_daily_temperature_comparison(
            m["daily_temperature"][area]["prev"], m["daily_temperature"][area]["curr"],
            f"{area} daily average temperature, week on week", subtitle, prev_label, curr_label)
    return chart_daily_temperature_single(m["daily_temperature"][area]["curr"],
                                          f"{area} daily average temperature", subtitle, curr_label)


assert set(DAILY_TEMPERATURE_AREAS) >= set(BANQUET_TEMPERATURE_AREAS)
