"""PDF quality validation before a version is published (A100, T-PDF).

A PDF passes only when it:
  1. opens with pypdf and has a page count in range, no empty page;
  2. is 50 KB - 20 MB, structurally intact, and every page renders with
     pypdfium2 to a non-blank image;
  3. contains every required section heading for the report type, the site
     name, the exact reporting and comparison period strings and the title;
  4. embeds at least as many images as the charts produced;
  5. contains every expected table header;
  6. embeds every font, and every font is Source Sans 3.
Any failure raises PdfValidationError(check, detail); nothing is published.
"""

from __future__ import annotations

import hashlib
import io
from dataclasses import dataclass

MIN_BYTES = 50 * 1024
MAX_BYTES = 20 * 1024 * 1024
MIN_PAGES = 5
MAX_PAGES = 60

REQUIRED_SECTIONS = (
    "1. Executive Summary",
    "Key observations",
    "Areas for attention",
    "2. HVAC Performance",
    "2.1 HVAC energy by subsystem",
    "2.2 Peak HVAC demand",
    "2.3 Temperature performance against setpoint",
    "2.4 Lobby AHUs",
    "2.5 Restaurant AHUs",
    "2.6 Banquet & pre-function AHUs",
    "3. Main Kitchen Performance",
    "4. AHU Operating Profile & Out-of-Hours Energy",
    "4.1 Estimated AHU runtime",
)
REQUIRED_TABLE_HEADERS = ("Subsystem", "Peak demand (kW)", "Deviation change", "Daily average (kWh)", "Change (kWh)",
                          "Change (%)")


class PdfValidationError(Exception):
    def __init__(self, check: str, detail: str) -> None:
        super().__init__(f"{check}: {detail}")
        self.check = check
        self.detail = detail


@dataclass(frozen=True)
class PdfCheckResult:
    pages: int
    size_bytes: int
    sha256: str
    images: int


def _normalise(text: str) -> str:
    return " ".join(text.replace(" ", " ").split())


def validate_report_pdf(data: bytes, *, site_name: str, title: str, reporting_text: str, comparison_text: str,
                        expected_images: int, out_of_hours: bool) -> PdfCheckResult:
    from pypdf import PdfReader
    from pypdf.errors import PdfReadError

    if not data or len(data) < MIN_BYTES:
        raise PdfValidationError("size", f"{len(data or b'')} bytes is below the {MIN_BYTES} byte minimum")
    if len(data) > MAX_BYTES:
        raise PdfValidationError("size", f"{len(data)} bytes exceeds {MAX_BYTES}")
    if not data.startswith(b"%PDF-") or b"%%EOF" not in data[-1024:]:
        raise PdfValidationError("structure", "missing PDF header or end-of-file marker")
    try:
        reader = PdfReader(io.BytesIO(data), strict=True)
        pages = len(reader.pages)
        texts = [page.extract_text() or "" for page in reader.pages]
    except (PdfReadError, ValueError, KeyError, TypeError) as exc:
        raise PdfValidationError("open", f"PDF could not be read: {exc}") from exc
    if not MIN_PAGES <= pages <= MAX_PAGES:
        raise PdfValidationError("pages", f"{pages} pages (expected {MIN_PAGES}-{MAX_PAGES})")
    for number, text in enumerate(texts, start=1):
        if not text.strip():
            raise PdfValidationError("empty_page", f"page {number} has no text")

    full = _normalise("\n".join(texts))
    required = [site_name, site_name.upper(), title, _normalise(reporting_text), _normalise(comparison_text),
                *REQUIRED_SECTIONS, *REQUIRED_TABLE_HEADERS]
    if out_of_hours:
        required.append("4.2 Out-of-hours energy")
    missing = [item for item in required if _normalise(item) not in full]
    if missing:
        raise PdfValidationError("content", "missing: " + "; ".join(missing[:6]))

    images = 0
    fonts: dict[str, bool] = {}
    for page in reader.pages:
        resources = page.get("/Resources") or {}
        xobjects = resources.get("/XObject") or {}
        for ref in xobjects.values():
            if ref.get_object().get("/Subtype") == "/Image":
                images += 1
        for ref in (resources.get("/Font") or {}).values():
            font = ref.get_object()
            name = str(font.get("/BaseFont", ""))
            embedded = False
            descendants = font.get("/DescendantFonts")
            targets = [d.get_object() for d in descendants] if descendants else [font]
            for target in targets:
                descriptor = target.get("/FontDescriptor")
                if descriptor is not None:
                    descriptor = descriptor.get_object()
                    embedded = embedded or any(k in descriptor for k in ("/FontFile", "/FontFile2", "/FontFile3"))
            fonts[name] = fonts.get(name, True) and embedded
    if images < expected_images:
        raise PdfValidationError("charts", f"{images} embedded images, expected at least {expected_images}")
    not_embedded = [n for n, ok in fonts.items() if not ok]
    if not_embedded:
        raise PdfValidationError("fonts", "not embedded: " + ", ".join(not_embedded))
    foreign = [n for n in fonts if "SourceSans3" not in n]
    if foreign:
        raise PdfValidationError("fonts", "unexpected fonts: " + ", ".join(foreign))

    _render_check(data, pages)
    return PdfCheckResult(pages=pages, size_bytes=len(data), sha256=hashlib.sha256(data).hexdigest(), images=images)


def _render_check(data: bytes, pages: int) -> None:
    import pypdfium2 as pdfium

    try:
        document = pdfium.PdfDocument(data)
    except Exception as exc:  # pdfium raises its own error types
        raise PdfValidationError("render", f"PDF could not be opened for rendering: {exc}") from exc
    try:
        if len(document) != pages:
            raise PdfValidationError("render", f"renderer sees {len(document)} pages, reader {pages}")
        for index in range(len(document)):
            page = document[index]
            try:
                image = page.render(scale=50 / 72).to_pil().convert("L")
            finally:
                page.close()
            low, high = image.getextrema()
            if low == high:
                raise PdfValidationError("render", f"page {index + 1} renders blank")
    finally:
        document.close()
