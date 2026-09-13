import { describe, expect, it } from "vitest";
import { deriveSiteHealth, siteHealthSummary } from "./siteHealth";
import type { AttentionItem } from "./types";

const ITEM: AttentionItem = {
  metric: "ENERGY_CONSUMPTION",
  direction: "HIGH",
  what: "Unusually high consumption",
  where: "Alpha One",
  when: { from: "2026-09-01T00:00:00Z", to: "2026-09-08T00:00:00Z" },
  trigger: "+20.0% vs. typical historical consumption (threshold: 15%)",
  evidence: { eligiblePeriodCount: 8, requestedPeriodCount: 8 },
  dataQuality: { coveragePercent: 100, gapIntervalCount: 0, resetIntervalCount: 0, rolloverIntervalCount: 0, invalidIntervalCount: 0 },
  investigatePath: "/features/energy",
};

describe("deriveSiteHealth", () => {
  it("is HEALTHY when Energy is assessable and there are no attention items", () => {
    expect(deriveSiteHealth({ energyAssessable: true, attentionItems: [] })).toBe("HEALTHY");
  });

  it("is NEEDS_ATTENTION when Energy is assessable and an attention item exists", () => {
    expect(deriveSiteHealth({ energyAssessable: true, attentionItems: [ITEM] })).toBe("NEEDS_ATTENTION");
  });

  it("is INSUFFICIENT_DATA when Energy is not assessable, even with no attention items", () => {
    expect(deriveSiteHealth({ energyAssessable: false, attentionItems: [] })).toBe("INSUFFICIENT_DATA");
  });

  it("INSUFFICIENT_DATA takes priority: an unassessable signal is never reported as HEALTHY, even if an attention item somehow exists", () => {
    expect(deriveSiteHealth({ energyAssessable: false, attentionItems: [ITEM] })).toBe("INSUFFICIENT_DATA");
  });
});

describe("siteHealthSummary", () => {
  it("uses Q79's exact healthy wording", () => {
    expect(siteHealthSummary("HEALTHY", 0)).toBe("No significant issues detected for the selected period.");
  });

  it("pluralises the issue count for NEEDS_ATTENTION", () => {
    expect(siteHealthSummary("NEEDS_ATTENTION", 1)).toBe("1 significant issue detected.");
    expect(siteHealthSummary("NEEDS_ATTENTION", 2)).toBe("2 significant issues detected.");
  });

  it("explains INSUFFICIENT_DATA without implying anything about health", () => {
    expect(siteHealthSummary("INSUFFICIENT_DATA", 0)).toMatch(/not enough valid data/i);
  });
});
