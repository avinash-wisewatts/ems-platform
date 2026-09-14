/**
 * MVP-6 -- Q76 Site Performance Report. Shared types for the report's
 * resolved configuration (hierarchy context + period), used by both the
 * configuration screen and the generated report view.
 */

import type { ReportPeriod } from "./sitePerformanceReportRanges";
import type { AbsoluteRange } from "../time/ranges";

export type HierarchyLevel = "SITE" | "SPACE" | "ASSET";

/** The resolved, ready-to-generate configuration. `contextName` feeds the
 *  report title ("Performance Report -- [context name]"); `investigatePath`
 *  is where the Investigation section's primary link points. Per ADR-015
 *  gap resolution 1, only the title and Investigation link vary by
 *  hierarchy level -- the report's analytical content (Health/Attention/
 *  Energy/Demand/PQ) is always the Site's own data, because no Space/
 *  Asset-scoped equivalent of those analytics exists anywhere in the
 *  platform. */
export type ReportConfig = {
  siteId: string;
  siteName: string;
  hierarchyLevel: HierarchyLevel;
  contextName: string;
  investigatePath: string;
  period: ReportPeriod;
  range: AbsoluteRange;
};

export function reportTitle(config: ReportConfig): string {
  return `Performance Report — ${config.contextName}`;
}
