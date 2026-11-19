"""Site energy-performance report engine (Reports -> Create report, ADR-025).

Ported from the validated Radisson Blu Coimbatore weekly report tool
(Streamlit + Word). The data acquisition layer is replaced: readings come
from EMS through the portal-scoped Analytics reads (ems_loader), never from
exported CSV files. The analytical method (alignment, <= 30-minute energy
gap estimation, interval-end attribution, coverage, peak demand, temperature
and AHU runtime rules) is kept; the output is a validated PDF (render_pdf,
validate_pdf), never a Word document.

Heavy dependencies (pandas, numpy, matplotlib, reportlab, pypdf, pypdfium2)
are imported only by the modules that need them. The web processes
(admin-portal, customer-api) never import this package; only the report
worker (src.report_worker_main) does.
"""

ENGINE_VERSION = "1.0.0"
