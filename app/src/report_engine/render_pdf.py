"""PDF rendering (ReportLab). PDF is the only output (A94); nothing here
produces or exposes a Word document.

Structure and wording follow the reference weekly report: cover lines,
1 Executive Summary (KPI tiles, Key observations, Areas for attention),
2 HVAC Performance (2.1-2.6), 3 Main Kitchen Performance, 4 AHU Operating
Profile & Out-of-Hours Energy (4.1, 4.2). Layout changes (A32, A99):
A4 pages, a WiseWatts logo header, page numbers, heading + chart + table
kept together, absolute and percentage change columns (A35).

Data completeness (A59, A60): a short note in the executive summary ONLY
when the current period is incomplete; no coverage page. Comparison period
incomplete (A109): affected figures carry a dagger and a short note sits
beneath each affected table; no overall "Incomplete data" label from that.
"""

from __future__ import annotations

import io
from dataclasses import dataclass
from pathlib import Path
from typing import Optional
from xml.sax.saxutils import escape

import pandas as pd
from reportlab.lib import colors
from reportlab.lib.enums import TA_CENTER, TA_LEFT
from reportlab.lib.pagesizes import A4
from reportlab.lib.styles import ParagraphStyle
from reportlab.lib.units import inch
from reportlab.pdfbase import pdfmetrics
from reportlab.pdfbase.ttfonts import TTFont
from reportlab.pdfgen import canvas as rl_canvas
from reportlab.platypus import (
    BaseDocTemplate,
    Frame,
    Image,
    KeepTogether,
    ListFlowable,
    ListItem,
    PageBreak,
    PageTemplate,
    Paragraph,
    Spacer,
    Table,
    TableStyle,
)

from src.report_engine.charts import CHART_WIDTH_IN_REPORT, figure_png
from src.report_engine.metrics import (
    ATTENTION_BAND_PCT,
    TEMP_TOLERANCE_C,
    PeriodSpec,
    abs_change,
    change_status,
    fmt_date,
    fmt_delta,
    fmt_num,
    fmt_pct,
    is_fully_comparable,
    temperature_change_status,
)
from src.report_engine.runtime import describe_schedule

ENGINE_DIR = Path(__file__).parent
FONT_DIR = ENGINE_DIR / "fonts"
LOGO_PATH = ENGINE_DIR / "assets" / "wisewatts-logo.png"
FONT = "SourceSans3"
FONT_BOLD = "SourceSans3-Bold"
FONT_SEMIBOLD = "SourceSans3-Semibold"
FONT_ITALIC = "SourceSans3-It"

NAVY = colors.HexColor("#05245B")
TEAL = colors.HexColor("#03A9A0")
ORANGE = colors.HexColor("#FF9966")
SLATE = colors.HexColor("#8C96A8")
INK = colors.HexColor("#1F2937")
MUTED = colors.HexColor("#5B6474")
RULE = colors.HexColor("#D5DAE1")
STATUS_STYLES = {
    "favorable": ("#DDF3F1", "#02756F"),
    "unfavorable": ("#FFE3D6", "#B23C17"),
    "indicative": ("#FFF4D6", "#7A5C00"),
    "neutral": ("#F2F2F2", "#404040"),
}
PAGE_WIDTH, PAGE_HEIGHT = A4
MARGIN_X = 0.65 * inch
MARGIN_TOP = 0.85 * inch
MARGIN_BOTTOM = 0.7 * inch
CONTENT_WIDTH = PAGE_WIDTH - 2 * MARGIN_X

_registered = False


def register_fonts() -> None:
    global _registered
    if _registered:
        return
    pdfmetrics.registerFont(TTFont(FONT, str(FONT_DIR / "SourceSans3-Regular.ttf")))
    pdfmetrics.registerFont(TTFont(FONT_BOLD, str(FONT_DIR / "SourceSans3-Bold.ttf")))
    pdfmetrics.registerFont(TTFont(FONT_SEMIBOLD, str(FONT_DIR / "SourceSans3-Semibold.ttf")))
    pdfmetrics.registerFont(TTFont(FONT_ITALIC, str(FONT_DIR / "SourceSans3-It.ttf")))
    pdfmetrics.registerFontFamily(FONT, normal=FONT, bold=FONT_BOLD, italic=FONT_ITALIC, boldItalic=FONT_BOLD)
    # Every canvas starts with ReportLab's base font, which would otherwise put a
    # non-embedded Helvetica in each page's font resources (A98: all fonts are
    # embedded Source Sans 3; validate_pdf enforces it).
    from reportlab import rl_config

    rl_config.canvas_basefontname = FONT
    _registered = True


def _styles() -> dict[str, ParagraphStyle]:
    base = ParagraphStyle("body", fontName=FONT, fontSize=9.5, leading=13, textColor=INK, spaceAfter=5)
    return {
        "body": base,
        "small": ParagraphStyle("small", parent=base, fontSize=8.5, leading=11, textColor=MUTED),
        "note": ParagraphStyle("note", parent=base, fontSize=8.5, leading=11, textColor=colors.HexColor("#7A5C00"),
                               spaceBefore=2, spaceAfter=8),
        "h1": ParagraphStyle("h1", parent=base, fontName=FONT_BOLD, fontSize=15, leading=19, textColor=NAVY,
                             spaceBefore=10, spaceAfter=6),
        "h2": ParagraphStyle("h2", parent=base, fontName=FONT_SEMIBOLD, fontSize=11.5, leading=15, textColor=TEAL,
                             spaceBefore=8, spaceAfter=4),
        "cover_site": ParagraphStyle("cover_site", parent=base, fontName=FONT_BOLD, fontSize=20, leading=25,
                                     textColor=NAVY, alignment=TA_CENTER, spaceAfter=4),
        "cover_title": ParagraphStyle("cover_title", parent=base, fontName=FONT_BOLD, fontSize=16, leading=21,
                                      alignment=TA_CENTER, spaceAfter=8),
        "cover_line": ParagraphStyle("cover_line", parent=base, alignment=TA_CENTER, spaceAfter=2),
        "cell": ParagraphStyle("cell", parent=base, fontSize=8, leading=10, spaceAfter=0),
        "cell_head": ParagraphStyle("cell_head", parent=base, fontName=FONT_BOLD, fontSize=8, leading=10,
                                    textColor=colors.white, spaceAfter=0),
        "tile_label": ParagraphStyle("tile_label", parent=base, fontName=FONT_BOLD, fontSize=7.5, leading=9,
                                     textColor=colors.HexColor("#595959"), alignment=TA_CENTER, spaceAfter=1),
        "tile_value": ParagraphStyle("tile_value", parent=base, fontName=FONT_BOLD, fontSize=14, leading=17,
                                     textColor=NAVY, alignment=TA_CENTER, spaceAfter=1),
        "box": ParagraphStyle("box", parent=base, fontSize=9, leading=12, alignment=TA_LEFT, spaceAfter=0),
    }


def P(text: str, style: ParagraphStyle) -> Paragraph:
    return Paragraph(escape(str(text)).replace("\n", "<br/>"), style)


@dataclass
class RenderContext:
    site_name: str
    period: PeriodSpec
    comparison_incomplete: bool
    comparison_note: str
    incomplete_data: bool
    completeness_note: str


class _NumberedCanvas(rl_canvas.Canvas):
    """Canvas that knows the page count, for "Page n of N" footers."""

    def __init__(self, *args, footer_text: str = "", header_text: str = "", **kwargs):
        kwargs.setdefault("initialFontName", FONT)
        super().__init__(*args, **kwargs)
        self._saved_page_states: list[dict] = []
        self.footer_text = footer_text
        self.header_text = header_text

    def showPage(self):
        self._saved_page_states.append(dict(self.__dict__))
        self._startPage()

    def save(self):
        total = len(self._saved_page_states)
        for state in self._saved_page_states:
            self.__dict__.update(state)
            self._decorate(total)
            super().showPage()
        super().save()

    def _decorate(self, total: int) -> None:
        self.saveState()
        self.setStrokeColor(RULE)
        self.setLineWidth(0.6)
        self.line(MARGIN_X, MARGIN_BOTTOM - 14, PAGE_WIDTH - MARGIN_X, MARGIN_BOTTOM - 14)
        self.setFont(FONT, 7.5)
        self.setFillColor(MUTED)
        self.drawString(MARGIN_X, MARGIN_BOTTOM - 26, self.footer_text)
        self.drawRightString(PAGE_WIDTH - MARGIN_X, MARGIN_BOTTOM - 26, f"Page {self._pageNumber} of {total}")
        if self._pageNumber > 1:
            logo_h = 16
            if LOGO_PATH.is_file():
                self.drawImage(str(LOGO_PATH), MARGIN_X, PAGE_HEIGHT - MARGIN_TOP + 24, height=logo_h,
                               width=logo_h * 682 / 467, mask="auto")
            self.setFont(FONT, 8)
            self.drawRightString(PAGE_WIDTH - MARGIN_X, PAGE_HEIGHT - MARGIN_TOP + 28, self.header_text)
            self.line(MARGIN_X, PAGE_HEIGHT - MARGIN_TOP + 18, PAGE_WIDTH - MARGIN_X, PAGE_HEIGHT - MARGIN_TOP + 18)
        self.restoreState()


def _table(headers: list[str], rows: list[list], styles: dict, bold_last_row: bool = False,
           col_widths: Optional[list[float]] = None, first_col: float = 1.75 * inch) -> Table:
    """Header row in navy; a cell may be (text, status) for a status colour."""

    width = CONTENT_WIDTH
    if col_widths is None:
        rest = (width - first_col) / max(len(headers) - 1, 1)
        col_widths = [first_col] + [rest] * (len(headers) - 1)
    data = [[P(h, styles["cell_head"]) for h in headers]]
    commands = [
        ("FONTNAME", (0, 0), (-1, -1), FONT),
        ("BACKGROUND", (0, 0), (-1, 0), NAVY),
        ("VALIGN", (0, 0), (-1, -1), "MIDDLE"),
        ("GRID", (0, 0), (-1, -1), 0.4, RULE),
        ("TOPPADDING", (0, 0), (-1, -1), 3),
        ("BOTTOMPADDING", (0, 0), (-1, -1), 3),
        ("LEFTPADDING", (0, 0), (-1, -1), 4),
        ("RIGHTPADDING", (0, 0), (-1, -1), 4),
    ]
    right = ParagraphStyle("cell_right", parent=styles["cell"], alignment=2)
    for r, row in enumerate(rows, start=1):
        cells = []
        for c, value in enumerate(row):
            text, status = value if isinstance(value, tuple) else (value, None)
            style = styles["cell"] if c == 0 else right
            if (bold_last_row and r == len(rows)) or status in STATUS_STYLES:
                style = ParagraphStyle(f"b{r}{c}", parent=style, fontName=FONT_BOLD)
            if status in STATUS_STYLES:
                fill, colour = STATUS_STYLES[status]
                style = ParagraphStyle(f"s{r}{c}", parent=style, textColor=colors.HexColor(colour))
                commands.append(("BACKGROUND", (c, r), (c, r), colors.HexColor(fill)))
            cells.append(P(text, style))
        data.append(cells)
    table = Table(data, colWidths=col_widths, repeatRows=1, hAlign="CENTER")
    table.setStyle(TableStyle(commands))
    return table


def _has_dagger(rows: list[list]) -> bool:
    return any("†" in str(v[0] if isinstance(v, tuple) else v) for row in rows for v in row)


def _figure(png: bytes) -> Image:
    image = Image(io.BytesIO(png))
    scale = CHART_WIDTH_IN_REPORT * inch / image.imageWidth
    image.drawWidth = CHART_WIDTH_IN_REPORT * inch
    image.drawHeight = image.imageHeight * scale
    image.hAlign = "CENTER"
    return image


def _kpi_tiles(tiles: list[tuple[str, str, str, str]], styles: dict) -> Table:
    cols = 4 if len(tiles) > 6 else 3
    cols = min(cols, len(tiles)) or 1
    rows, commands = [], [("FONTNAME", (0, 0), (-1, -1), FONT), ("VALIGN", (0, 0), (-1, -1), "MIDDLE"),
                          ("TOPPADDING", (0, 0), (-1, -1), 6), ("BOTTOMPADDING", (0, 0), (-1, -1), 6),
                          ("LINEBELOW", (0, 0), (-1, -1), 3, colors.white),
                          ("LINEAFTER", (0, 0), (-1, -1), 3, colors.white)]
    for i in range(0, len(tiles), cols):
        row = []
        for j, (label, value, detail, status) in enumerate(tiles[i:i + cols]):
            fill, colour = STATUS_STYLES.get(status, STATUS_STYLES["neutral"])
            detail_style = ParagraphStyle(f"td{i}{j}", parent=styles["tile_label"], fontSize=8, leading=10,
                                          textColor=colors.HexColor(colour))
            row.append([P(label, styles["tile_label"]), P(value, styles["tile_value"]), P(detail, detail_style)])
            commands.append(("BACKGROUND", (j, len(rows)), (j, len(rows)), colors.HexColor(fill)))
        row += [""] * (cols - len(row))
        rows.append(row)
    table = Table(rows, colWidths=[CONTENT_WIDTH / cols] * cols, hAlign="CENTER")
    table.setStyle(TableStyle(commands))
    return table


def _bullets(items: list[str], styles: dict) -> ListFlowable:
    return ListFlowable([ListItem(P(item, styles["body"]), leftIndent=12) for item in items],
                        bulletType="bullet", start="•", leftIndent=12, bulletFontName=FONT)


def _box(text: str, styles: dict, fill: str = "#FFF4D6", edge: str = "#E5C46B") -> Table:
    table = Table([[Paragraph(text, styles["box"])]], colWidths=[CONTENT_WIDTH])
    table.setStyle(TableStyle([("FONTNAME", (0, 0), (-1, -1), FONT), ("BACKGROUND", (0, 0), (-1, -1), colors.HexColor(fill)),
                               ("BOX", (0, 0), (-1, -1), 0.6, colors.HexColor(edge)),
                               ("LEFTPADDING", (0, 0), (-1, -1), 8), ("RIGHTPADDING", (0, 0), (-1, -1), 8),
                               ("TOPPADDING", (0, 0), (-1, -1), 6), ("BOTTOMPADDING", (0, 0), (-1, -1), 6)]))
    return table


def energy_rows(groups: dict[str, dict], total_label: Optional[str] = None, total_stats: Optional[dict] = None) -> list[list]:
    """name, previous, current, change kWh, change %, comparable daily avg/min/max."""

    rows = []
    items = list(groups.items()) + ([(total_label, total_stats)] if total_label else [])
    for name, s in items:
        c, p = s["curr"], s["prev"]
        comparable = is_fully_comparable(c, p)
        delta = abs_change(c["total"], p["total"])
        delta_text = fmt_delta(delta) + ("" if comparable or pd.isna(delta) else "†")
        rows.append([name, fmt_num(p["total"], 1), fmt_num(c["total"], 1), delta_text,
                     change_status(c["total"], p["total"], comparable=comparable),
                     fmt_num(c["avg_day"], 1), fmt_num(c["min_day"], 1), fmt_num(c["max_day"], 1)])
    return rows


def _energy_headers(period: PeriodSpec, first: str) -> list[str]:
    prev, curr = ("Previous week", "Latest week") if period.weekly else ("Previous month", "Reporting month")
    return [first, f"{prev} (kWh)", f"{curr} (kWh)", "Change (kWh)", "Change (%)",
            "Daily average (kWh)", "Daily minimum (kWh)", "Daily maximum (kWh)"]


ENERGY_COLS = [1.55 * inch] + [(CONTENT_WIDTH - 1.55 * inch) / 7] * 7


def render_report(m: dict, charts: dict, observations: list[str], attention: list[str], ctx: RenderContext) -> bytes:
    """The report PDF as bytes. Chart figures are rendered (and closed) here."""

    register_fonts()
    styles = _styles()
    period = ctx.period
    pngs = {key: figure_png(fig) for key, fig in charts.items()}
    hv, kt, pk = m["hvac"], m["kitchen"], m["peak"]
    (prev_start, prev_end), (curr_start, curr_end) = m["weeks"]["prev"], m["weeks"]["curr"]
    vs = f"vs {period.prev_noun}"
    story: list = []

    def comparison_note_if(rows: list[list]) -> None:
        if ctx.comparison_incomplete and _has_dagger(rows):
            story.append(P(ctx.comparison_note, styles["note"]))

    # Cover
    if LOGO_PATH.is_file():
        logo = Image(str(LOGO_PATH), width=0.9 * inch, height=0.9 * inch * 467 / 682)
        logo.hAlign = "CENTER"
        story += [logo, Spacer(1, 6)]
    story.append(P(ctx.site_name.upper(), styles["cover_site"]))
    story.append(P(period.title, styles["cover_title"]))
    if period.weekly:
        reporting = f"Reporting period: {fmt_date(curr_start)} – {fmt_date(curr_end)}"
        comparison = f"Comparison period: {fmt_date(prev_start)} – {fmt_date(prev_end)}"
    else:
        reporting = f"Reporting period: {curr_start:%B %Y} ({fmt_date(curr_start)} – {fmt_date(curr_end)})"
        comparison = f"Comparison period: {prev_start:%B %Y} ({fmt_date(prev_start)} – {fmt_date(prev_end)})"
    story.append(Paragraph(f"<b>{escape(reporting)}</b>", styles["cover_line"]))
    story.append(P(comparison, styles["cover_line"]))
    story.append(P(f"Prepared for: {ctx.site_name} Engineering & Facilities Management", styles["cover_line"]))
    story.append(P("Prepared by: WiseWatts Solutions", styles["cover_line"]))
    story.append(Spacer(1, 10))

    # 1. Executive summary
    story.append(P("1. Executive Summary", styles["h1"]))
    tiles = []
    for label, cur, prev, unit, comparable in (
        ("TOTAL HVAC ENERGY", hv["curr"]["total"], hv["prev"]["total"], "kWh", m["comparable"]["hvac"]),
        ("PEAK HVAC DEMAND", pk["curr"]["peak_kw"], pk["prev"]["peak_kw"], "kW", m["comparable"]["peak"]),
        ("TOTAL KITCHEN ENERGY", kt["curr"]["total"], kt["prev"]["total"], "kWh", m["comparable"]["kitchen"]),
    ):
        text, status = change_status(cur, prev, comparable=comparable)
        delta = abs_change(cur, prev)
        detail = (f"{fmt_delta(delta, 1, ' ' + unit)} ({text}) {vs}" if text != "NA" and pd.notna(delta)
                  else (f"{fmt_delta(delta, 1, ' ' + unit)} {vs}" if pd.notna(delta) else "No comparison"))
        tiles.append((label, fmt_num(cur, 1, f" {unit}"), detail, status))
    ooh = m["ahu_ooh"]
    if ooh["curr"]["assets"]:
        text, status = change_status(ooh["curr"]["energy_out"], ooh["prev"]["energy_out"], comparable=ooh["comparable"])
        tiles.append(("AHU OUT-OF-HOURS ENERGY", fmt_num(ooh["curr"]["energy_out"], 1, " kWh"),
                      f"{fmt_pct(ooh['curr']['ooh_pct'])} of scheduled AHU energy; "
                      f"{text + ' ' + vs if text != 'NA' else 'no comparison'}", status))
    for area, temps in m["temperature"].items():
        t = temps["curr"]
        if not t["sensors"]:
            continue
        within = t["within_band_pct"]
        status = "neutral" if pd.isna(within) else ("unfavorable" if within < ATTENTION_BAND_PCT else "favorable")
        detail = (f"{fmt_pct(within)} within ±{TEMP_TOLERANCE_C:g} °C of {t['setpoint_text']} "
                  f"(prev. {fmt_pct(temps['prev']['within_band_pct'])})"
                  if t["setpoint_text"] != "Not configured" else "Setpoint not configured")
        tiles.append((f"{area.upper()} TEMPERATURE", fmt_num(t["mean"], 1, " °C"), detail, status))
    story.append(_kpi_tiles(tiles, styles))
    story.append(Spacer(1, 8))
    if ctx.incomplete_data:
        story.append(_box(f"<b>Data completeness.</b> {escape(ctx.completeness_note)}", styles))
        story.append(Spacer(1, 6))
    story.append(P("Key observations", styles["h2"]))
    story.append(_bullets(observations, styles))
    story.append(P("Areas for attention", styles["h2"]))
    story.append(_bullets(attention or [f"No items require immediate attention this {period.unit}."], styles))

    # 2. HVAC
    story.append(P("2. HVAC Performance", styles["h1"]))
    rows = energy_rows(m["hvac_subsystems"], "Total HVAC", hv)
    block = [P("2.1 HVAC energy by subsystem", styles["h2"]), _figure(pngs["hvac_daily"])]
    story.append(KeepTogether(block))
    story.append(KeepTogether([_figure(pngs["hvac_subsystems"]),
                               _table(_energy_headers(period, "Subsystem"), rows, styles, bold_last_row=True, col_widths=ENERGY_COLS)]))
    comparison_note_if(rows)

    meters = len(m["layout"].hvac_names)
    prev_h, curr_h = ("Previous week", "Latest week") if period.weekly else ("Previous month", "Reporting month")
    peak_rows = [
        ["Peak demand (kW)", fmt_num(pk["prev"]["peak_kw"], 1), fmt_num(pk["curr"]["peak_kw"], 1),
         fmt_delta(abs_change(pk["curr"]["peak_kw"], pk["prev"]["peak_kw"])) + ("" if m["comparable"]["peak"] else "†"),
         change_status(pk["curr"]["peak_kw"], pk["prev"]["peak_kw"], comparable=m["comparable"]["peak"])],
        ["Date and time"] + [f"{fmt_date(pk[w]['time'])} {pk[w]['time']:%H:%M}" if pk[w]["time"] is not None else "NA"
                             for w in ("prev", "curr")] + ["", ""],
    ]
    story.append(KeepTogether([
        P("2.2 Peak HVAC demand", styles["h2"]),
        P(f"Peak demand is the highest simultaneous total of instantaneous power across the {meters} HVAC "
          f"meters, using only times at which all {meters} meters reported.", styles["body"]),
        _figure(pngs["hvac_peak"]),
        _table(["Metric", prev_h, curr_h, "Change (kW)", "Change (%)"], peak_rows, styles, first_col=1.9 * inch),
    ]))
    comparison_note_if(peak_rows)

    story.append(P("2.3 Temperature performance against setpoint", styles["h2"]))
    story.append(P(f"Performance is measured against each temperature sensor's setpoint in force at the time of each "
                   f"reading, with a ±{TEMP_TOLERANCE_C:g} °C comfort band, using recorded readings only. Deviation is the "
                   "average absolute difference from setpoint; a lower deviation means closer control. Where an area's "
                   "sensors have different setpoints, or a setpoint changed during the period, the applicable range is "
                   "shown. Temperature charts show hourly averages for readability; all temperature figures, including the "
                   "executive summary, use every individual recorded reading. Temperature is never estimated.", styles["body"]))
    temp_rows, no_sensor = [], []
    for area, temps in m["temperature"].items():
        t, tp = temps["curr"], temps["prev"]
        if not (tp["sensors"] or t["sensors"]):
            no_sensor.append(area)
            temp_rows.append([area, "—", "Not temperature-monitored", "NA", "NA", "NA"])
            continue
        cfg = "" if tp.get("config_complete", True) or pd.isna(tp["mean_abs_deviation"]) else "†"
        temp_rows.append([area, t["setpoint_text"],
                          f"{fmt_num(tp['mean'], 1)} / {fmt_num(t['mean'], 1)}",
                          f"{fmt_num(tp['mean_abs_deviation'], 1)}{cfg} / {fmt_num(t['mean_abs_deviation'], 1)}",
                          temperature_change_status(t, tp),
                          f"{fmt_pct(tp['within_band_pct'])}{cfg} / {fmt_pct(t['within_band_pct'])}"])
    story.append(_table(["Area", "Setpoint", "Avg temp °C (prev / latest)", "Deviation °C (prev / latest)",
                         "Deviation change", f"Within ±{TEMP_TOLERANCE_C:g} °C (prev / latest)"], temp_rows, styles,
                        first_col=1.2 * inch))
    comparison_note_if(temp_rows)
    unmonitored = m.get("not_temperature_monitored", [])
    if unmonitored:
        story.append(P(f"Not temperature-monitored: {', '.join(unmonitored)}. These AHUs have no temperature sensor in "
                       "EMS; their energy is included in every energy figure, and no temperature is estimated for them.",
                       styles["small"]))

    section = 4
    for area in ("Lobby", "Restaurant"):
        names = m["energy_areas"][area]
        rows = energy_rows({n: m["assets"][n] for n in names})
        block = [P(f"2.{section} {area} AHUs", styles["h2"])]
        section += 1
        if f"{area.lower()}_temperature" in pngs:
            block.append(_figure(pngs[f"{area.lower()}_temperature"]))
        story.append(KeepTogether(block))
        if f"{area.lower()}_daily_temperature" in pngs:
            story.append(_figure(pngs[f"{area.lower()}_daily_temperature"]))
        story.append(KeepTogether([_figure(pngs[f"{area.lower()}_energy"]),
                                   _table(_energy_headers(period, "Asset"), rows, styles, col_widths=ENERGY_COLS)]))
        comparison_note_if(rows)

    area = "Banquet & pre-function"
    rows = energy_rows({n: m["assets"][n] for n in m["energy_areas"][area]})
    block = [P(f"2.{section} {area} AHUs", styles["h2"])]
    if "banquet_energy" in pngs:
        block.append(_figure(pngs["banquet_energy"]))
    block.append(_table(_energy_headers(period, "Asset"), rows, styles, col_widths=ENERGY_COLS))
    story.append(KeepTogether(block))
    comparison_note_if(rows)
    for hall in ("Banquet 1", "Banquet 2"):
        key = f"{hall.lower().replace(' ', '_')}_daily_temperature"
        t = m["temperature"][hall]
        if key not in pngs or pd.isna(t["curr"]["mean"]):
            continue
        summary = (f"{hall} average temperature ({', '.join(t['curr']['sensors'])}): {fmt_num(t['curr']['mean'], 1)} °C in the "
                   f"{period.curr_noun} and {fmt_num(t['prev']['mean'], 1)} °C in the {period.prev_noun}, against "
                   f"{t['curr']['setpoint_text']}; {fmt_pct(t['curr']['within_band_pct'])} of {period.curr_noun} readings were "
                   f"within ±{TEMP_TOLERANCE_C:g} °C ({period.prev_noun} {fmt_pct(t['prev']['within_band_pct'])}).")
        story.append(KeepTogether([P(summary, styles["body"]), _figure(pngs[key])]))

    # 3. Kitchen
    story.append(P("3. Main Kitchen Performance", styles["h1"]))
    story.append(_figure(pngs["kitchen_daily"]))
    rows = energy_rows({n: m["assets"][n] for n in m["layout"].kitchen_names}, "Total kitchen", kt)
    story.append(KeepTogether([_figure(pngs["kitchen_meters"]),
                               _table(_energy_headers(period, "Asset"), rows, styles, bold_last_row=True, col_widths=ENERGY_COLS)]))
    comparison_note_if(rows)

    # 4. AHU operating profile
    _ahu_section(story, m, pngs, styles, ctx)

    out = io.BytesIO()
    doc = BaseDocTemplate(out, pagesize=A4, leftMargin=MARGIN_X, rightMargin=MARGIN_X,
                          topMargin=MARGIN_TOP, bottomMargin=MARGIN_BOTTOM,
                          title=f"{ctx.site_name} {period.title}", author="WiseWatts Solutions",
                          subject=reporting, creator="WiseWatts EMS")
    frame = Frame(MARGIN_X, MARGIN_BOTTOM, CONTENT_WIDTH, PAGE_HEIGHT - MARGIN_TOP - MARGIN_BOTTOM, id="body")
    doc.addPageTemplates([PageTemplate(id="page", frames=[frame])])
    footer = f"WiseWatts Solutions | {period.title} | {ctx.site_name}"
    header = f"{ctx.site_name} · {period.title} · {reporting.replace('Reporting period: ', '')}"

    def make_canvas(*args, **kwargs):
        return _NumberedCanvas(*args, footer_text=footer, header_text=header, **kwargs)

    doc.build(story, canvasmaker=make_canvas)
    return out.getvalue()


def _ahu_section(story: list, m: dict, pngs: dict, styles: dict, ctx: RenderContext) -> None:
    period = ctx.period
    runtime = m["ahu_runtime"]
    if not runtime:
        return
    prev_h, curr_h = (("previous week", "latest week") if period.weekly else ("previous month", "reporting month"))
    story.append(PageBreak())
    story.append(P("4. AHU Operating Profile & Out-of-Hours Energy", styles["h1"]))
    story.append(P("Runtime is estimated from each AHU's metered energy: every minute is classed as operating, "
                   "standby, off or uncertain against operating thresholds set for that AHU. These figures are estimates, "
                   "not measured equipment status. Minutes that cannot be clearly classified count half towards the "
                   "estimate.", styles["body"]))
    story.append(P("4.1 Estimated AHU runtime", styles["h2"]))

    def ok(r):
        return r["status"] == "ok"

    def runtime_text(r):
        return fmt_num(r["runtime_h"], 1) if ok(r) else r["status"].capitalize()

    config_gap = set(m.get("ahu_comparison_config_gap", []))
    rows = []
    for name, r in runtime.items():
        p, c = r["prev"], r["curr"]
        rows.append([name, runtime_text(p) + ("†" if name in config_gap else ""), runtime_text(c),
                     fmt_pct(c["operating_pct"]) if ok(c) else "NA",
                     fmt_num(c["standby_h"], 1) if pd.notna(c["standby_h"]) else "n/a"])
    story.append(_table(["AHU", f"Estimated runtime, {prev_h} (h)", f"Estimated runtime, {curr_h} (h)",
                         "Operating time (%)", f"Standby, {curr_h} (h)"], rows, styles, first_col=2.2 * inch))
    notes = [f"Operating time is the estimated runtime as a share of all hours in the {curr_h}. "
             "Standby is shown only where a distinct standby level is configured (n/a otherwise)."]
    low_confidence = [n for n, r in runtime.items() if r["curr"].get("low_confidence_standby")]
    if low_confidence:
        notes.append(f"Standby for {', '.join(low_confidence)} is a very low consumption level whose boundary with 'off' "
                     "is uncertain, so standby hours are indicative.")
    story.append(P(" ".join(notes), styles["small"]))
    if ctx.comparison_incomplete and _has_dagger(rows):
        story.append(P(ctx.comparison_note, styles["note"]))

    scheduled = {n: r for n, r in runtime.items() if r["curr"]["scheduled"]}
    if not scheduled or "ahu_out_of_hours" not in pngs:
        return
    rows = []
    for name, r in scheduled.items():
        p, c = r["prev"], r["curr"]
        versions = m["ahu_schedules"].get(name) or []
        hours = describe_schedule(versions[-1]) if versions else "No schedule"
        if len(versions) > 1:
            hours += " (changed during period)"
        if not m["ahu_confirmed"].get(name):
            hours += " (provisional)"
        comparable = (is_fully_comparable(m["assets"][name]["curr"], m["assets"][name]["prev"])
                      and name not in config_gap)
        delta = abs_change(c["energy_out"], p["energy_out"])
        rows.append([f"{name}\n{hours}", fmt_num(c["energy_total"], 1), fmt_num(c["energy_in"], 1), fmt_num(c["energy_out"], 1),
                     f"{fmt_pct(p['ooh_pct'])} / {fmt_pct(c['ooh_pct'])}",
                     fmt_delta(delta) + ("" if comparable or pd.isna(delta) else "†"),
                     change_status(c["energy_out"], p["energy_out"], comparable=comparable),
                     fmt_num(c["runtime_out_h"], 1)])
    ooh = m["ahu_ooh"]
    runtime_out = [r["curr"]["runtime_out_h"] for r in scheduled.values()]
    delta = abs_change(ooh["curr"]["energy_out"], ooh["prev"]["energy_out"])
    rows.append(["Scheduled AHUs", fmt_num(ooh["curr"]["energy_total"], 1), fmt_num(ooh["curr"]["energy_in"], 1),
                 fmt_num(ooh["curr"]["energy_out"], 1), f"{fmt_pct(ooh['prev']['ooh_pct'])} / {fmt_pct(ooh['curr']['ooh_pct'])}",
                 fmt_delta(delta) + ("" if ooh["comparable"] or pd.isna(delta) else "†"),
                 change_status(ooh["curr"]["energy_out"], ooh["prev"]["energy_out"], comparable=ooh["comparable"]),
                 fmt_num(sum(runtime_out), 1) if all(pd.notna(x) for x in runtime_out) else "NA"])
    story.append(KeepTogether([
        P("4.2 Out-of-hours energy", styles["h2"]),
        _figure(pngs["ahu_out_of_hours"]),
        _table(["AHU and working hours", f"Total energy, {curr_h} (kWh)", "Within hours (kWh)", "Outside hours (kWh)",
                "Outside-hours share (prev / latest)", "Outside-hours change (kWh)", "Outside-hours change (%)",
                "Outside-hours runtime (h)"], rows, styles, bold_last_row=True, first_col=1.75 * inch),
    ]))
    if ctx.comparison_incomplete and _has_dagger(rows):
        story.append(P(ctx.comparison_note, styles["note"]))
    story.append(P("Total energy matches Section 2 and includes short estimated gaps; runtime uses measured readings "
                   "only. Working hours marked provisional are not yet confirmed by the hotel. Energy used outside working "
                   "hours is not necessarily avoidable: some areas, such as the lobby, may need continuous conditioning, "
                   "and events or pre-cooling can require operation outside these hours.", styles["small"]))
