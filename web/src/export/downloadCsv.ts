/**
 * Q75 -- smallest reusable browser download utility for CSV content.
 * Deliberately generic (not Energy-specific) so Demand/Power Quality/the
 * dedicated Export area can reuse it later without duplicating this file --
 * none of those are implemented by this change.
 *
 * Mirrors reports/pdf.ts's separation of "build the content" (pure,
 * testable) from "trigger the browser download" (DOM-only, thin) -- no
 * equivalent generic Blob/anchor download helper existed anywhere in this
 * codebase before this file (reports/pdf.ts uses jsPDF's own `doc.save()`,
 * which is PDF-library-specific and not reusable for CSV).
 */

/** Triggers a browser download of `content` as a file named `filename`.
 *  DOM-only; not unit-tested for byte-for-byte content (that's
 *  buildEnergyConsumptionExportCsv's job) -- this function's only
 *  responsibility is invoking the browser download mechanism correctly. */
export function downloadTextFile(filename: string, content: string, mimeType: string): void {
  const blob = new Blob([content], { type: mimeType });
  const url = URL.createObjectURL(blob);
  try {
    const anchor = document.createElement("a");
    anchor.href = url;
    anchor.download = filename;
    document.body.appendChild(anchor);
    anchor.click();
    document.body.removeChild(anchor);
  } finally {
    URL.revokeObjectURL(url);
  }
}

/** CSV-specific convenience wrapper over downloadTextFile. */
export function downloadCsv(filename: string, csvContent: string): void {
  downloadTextFile(filename, csvContent, "text/csv;charset=utf-8;");
}
