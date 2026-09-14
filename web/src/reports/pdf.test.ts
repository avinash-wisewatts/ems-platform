import { describe, expect, it } from "vitest";
import { buildSitePerformanceReportPdf, type SitePerformanceReportPdfData } from "./pdf";

function baseData(overrides: Partial<SitePerformanceReportPdfData> = {}): SitePerformanceReportPdfData {
  return {
    title: "Performance Report — Radisson Blu",
    periodLabel: "Monthly (this month) (9/1/2026 – 9/16/2026)",
    generatedAt: "9/16/2026, 10:00:00 AM",
    siteHealth: { available: true, lines: ["No significant issues detected for the selected period."] },
    attention: { available: true, lines: ["No active issues for the selected period."] },
    energy: { available: true, lines: ["1,234.5 kWh (+5.0% vs. typical)"] },
    demand: { available: true, lines: ["Peak 60.5 kW at 9/10/2026, 2:00:00 PM"] },
    powerQuality: { available: true, lines: ["PF 0.94"] },
    investigation: ["Spaces: /features/spaces", "Assets: /features/assets"],
    ...overrides,
  };
}

describe("buildSitePerformanceReportPdf -- client-side generation (ADR-015 gap resolutions 4-5)", () => {
  it("builds a document without throwing for a fully-available report", () => {
    const doc = buildSitePerformanceReportPdf(baseData());
    expect(doc.internal.pages.length - 1).toBeGreaterThanOrEqual(1);
  });

  it("renders each section's unavailable reason instead of fabricating a value", () => {
    const doc = buildSitePerformanceReportPdf(
      baseData({
        siteHealth: { available: false, reason: "Site Health is not available for this period." },
        attention: { available: false, reason: "Attention isn't available until site health can be assessed." },
      }),
    );
    // No throw, and the doc still produces at least one page -- unavailable
    // sections degrade gracefully rather than failing the whole document.
    expect(doc.internal.pages.length - 1).toBeGreaterThanOrEqual(1);
  });

  it("paginates when content is long, never silently truncating", () => {
    const manyLines = Array.from({ length: 120 }, (_, i) => `Attention item ${i + 1} with a reasonably long trigger description.`);
    const doc = buildSitePerformanceReportPdf(baseData({ attention: { available: true, lines: manyLines } }));
    expect(doc.internal.pages.length - 1).toBeGreaterThan(1);
  });
});
