/**
 * MVP-6 -- Q76 Site Performance Report. The single PDF-generation
 * foundation for this codebase (first use of any document-generation
 * library here) -- matching how `recharts` was adopted once as "the one
 * charting foundation" for `ChartFrame.tsx`: no other PDF library may be
 * added; every report's PDF export goes through this module.
 *
 * Library: jsPDF (MIT), pinned to 4.2.1 -- 2.5.2 (the version `npm install
 * jspdf` resolves to by default) carries multiple published critical CVEs
 * (ReDoS/DoS, PDF/AcroForm JS-injection, path traversal, XMP injection);
 * 4.2.1 is the current release with none of those advisories outstanding
 * (verified via `npm audit` this session).
 *
 * Generated entirely client-side, synchronously -- see ADR-015 gap
 * resolutions 4-5: no backend report-generation job exists anywhere in
 * this repository, and none is introduced here. The Site Performance
 * Report is a small, fixed-structure document (not an open-ended data
 * export), so synchronous generation is the practical case; this module
 * never blocks or discards the already-rendered in-app report if PDF
 * generation is slow or throws (EMS-REQ-116) -- callers must catch errors
 * around calling it, not treat a thrown error here as fatal to the page.
 *
 * Content only, not a pixel clone of the in-app view: same information,
 * a PDF-appropriate text layout (EMS-REQ-114).
 */

import { jsPDF } from "jspdf";

export type PdfSection =
  | { available: true; lines: string[] }
  | { available: false; reason: string };

export type SitePerformanceReportPdfData = {
  title: string;
  periodLabel: string;
  generatedAt: string; // human-readable, already formatted by the caller
  siteHealth: PdfSection;
  attention: PdfSection;
  energy: PdfSection;
  demand: PdfSection;
  powerQuality: PdfSection;
  investigation: string[];
};

const PAGE_MARGIN = 14;
const LINE_HEIGHT = 6;
const PAGE_HEIGHT = 297; // A4 mm

function renderSection(doc: jsPDF, heading: string, section: PdfSection, y: number): number {
  doc.setFont("helvetica", "bold");
  doc.setFontSize(13);
  doc.text(heading, PAGE_MARGIN, y);
  y += LINE_HEIGHT;

  doc.setFont("helvetica", "normal");
  doc.setFontSize(10);
  const lines = section.available ? section.lines : [section.reason];
  for (const line of lines) {
    const wrapped = doc.splitTextToSize(line, 180) as string[];
    for (const w of wrapped) {
      if (y > PAGE_HEIGHT - PAGE_MARGIN) {
        doc.addPage();
        y = PAGE_MARGIN;
      }
      doc.text(w, PAGE_MARGIN, y);
      y += LINE_HEIGHT;
    }
  }
  return y + LINE_HEIGHT / 2;
}

/** Builds the PDF document. Throws on failure -- callers handle the error
 *  (EMS-REQ-116: the in-app report must remain intact regardless). */
export function buildSitePerformanceReportPdf(data: SitePerformanceReportPdfData): jsPDF {
  const doc = new jsPDF({ unit: "mm", format: "a4" });
  let y = PAGE_MARGIN;

  doc.setFont("helvetica", "bold");
  doc.setFontSize(18);
  doc.text(data.title, PAGE_MARGIN, y);
  y += LINE_HEIGHT + 2;

  doc.setFont("helvetica", "normal");
  doc.setFontSize(10);
  doc.text(`Period: ${data.periodLabel}`, PAGE_MARGIN, y);
  y += LINE_HEIGHT;
  doc.text(`Generated: ${data.generatedAt}`, PAGE_MARGIN, y);
  y += LINE_HEIGHT + 2;

  y = renderSection(doc, "Overall Site Health / Status", data.siteHealth, y);
  y = renderSection(doc, "Attention / Exceptions", data.attention, y);
  y = renderSection(doc, "Energy Performance", data.energy, y);
  y = renderSection(doc, "Maximum Demand", data.demand, y);
  y = renderSection(doc, "Power Quality", data.powerQuality, y);
  y = renderSection(doc, "Investigation paths", { available: true, lines: data.investigation }, y);

  return doc;
}

/** Generates and triggers a browser download. Separated from
 *  buildSitePerformanceReportPdf so tests can exercise document
 *  construction without touching the DOM download path. */
export function downloadSitePerformanceReportPdf(data: SitePerformanceReportPdfData, filename: string): void {
  const doc = buildSitePerformanceReportPdf(data);
  doc.save(filename);
}
