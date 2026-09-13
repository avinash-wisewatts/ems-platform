/**
 * MVP-3 -- Overall Site Health/Status, per Q71/Q79 (workshop baseline) and
 * the approved MVP-3 decision pack. Exactly three states, using the source
 * documents' own terminology:
 *
 *   HEALTHY           -- sufficient valid evidence, no attention item.
 *   NEEDS_ATTENTION    -- sufficient valid evidence, >=1 attention item.
 *   INSUFFICIENT_DATA -- not enough valid evidence to assess at all.
 *
 * INSUFFICIENT_DATA is checked FIRST and unconditionally, so "no data" or
 * "unknown" can never fall through to HEALTHY (Q79/Q80's explicit
 * requirement) -- this is a structural guarantee, not a convention callers
 * must remember to honour.
 *
 * `energyAssessable` is named explicitly (not folded into a generic
 * "signals" list) because Energy is the ONLY signal that feeds Site Health
 * in MVP-3 -- Demand and Power Quality have no approved materiality rule
 * and are informational only (see the approved decision pack). How
 * multiple signals should be combined into one Site Health verdict is
 * itself an undecided product question; this function deliberately does
 * not invent an aggregation rule for signals that do not exist yet.
 */

import type { AttentionItem, SiteHealthState } from "./types";

export function deriveSiteHealth(params: {
  energyAssessable: boolean;
  attentionItems: readonly AttentionItem[];
}): SiteHealthState {
  if (!params.energyAssessable) {
    return "INSUFFICIENT_DATA";
  }
  if (params.attentionItems.length > 0) {
    return "NEEDS_ATTENTION";
  }
  return "HEALTHY";
}

/** Q79's own example wording, reused verbatim; Q71's "N significant
 *  issue(s) detected" generalised over the attention-item count. */
export function siteHealthSummary(state: SiteHealthState, attentionItemCount: number): string {
  switch (state) {
    case "HEALTHY":
      return "No significant issues detected for the selected period.";
    case "NEEDS_ATTENTION":
      return `${attentionItemCount} significant issue${attentionItemCount === 1 ? "" : "s"} detected.`;
    case "INSUFFICIENT_DATA":
      return "Not enough valid data for a reliable assessment for the selected period.";
  }
}

export const SITE_HEALTH_LABELS: Record<SiteHealthState, string> = {
  HEALTHY: "Healthy",
  NEEDS_ATTENTION: "Needs Attention",
  INSUFFICIENT_DATA: "Insufficient Data",
};
