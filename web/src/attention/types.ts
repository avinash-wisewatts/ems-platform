/**
 * MVP-3 -- Site Overview & Attention. Shared types for the Attention/Site
 * Health layer.
 *
 * `AttentionItem` is deliberately generic over `metric` (a discriminated
 * union of exactly one member today) so that Demand/Power-Quality Attention
 * rules -- if and when a materiality rule is approved for them -- can be
 * added as new union members and new evaluator functions, without changing
 * this type's shape, `deriveSiteHealth`, or the `AttentionList` component.
 * No such rule exists yet for Demand/PF/THD (see energyAttention.ts and the
 * approved MVP-3 decision pack) -- nothing here anticipates one.
 */

export type AttentionDirection = "HIGH" | "LOW";

/** Q98's shape: What -> Where -> When -> Metric -> Trigger -> Evidence ->
 *  Data Quality -> Investigate. "When" is a period, not an instant --
 *  Energy Attention is a period-level assessment (current period vs.
 *  typical), not a single-timestamp event. */
export type AttentionItem = {
  metric: "ENERGY_CONSUMPTION";
  direction: AttentionDirection;
  /** Customer-facing headline, e.g. "Unusually high consumption". */
  what: string;
  /** Site name -- MVP-3 Attention is site-scoped only (no per-space/
   *  per-asset attention; no energy attribution model exists for that). */
  where: string;
  /** The evaluated period, half-open ISO-8601 UTC. */
  when: { from: string; to: string };
  /** Human-readable trigger explanation, includes the actual deviation and
   *  the policy threshold applied -- never a bare "15" with no context. */
  trigger: string;
  /** Comparison basis evidence -- how many of the requested comparable
   *  historical periods were actually used. */
  evidence: { eligiblePeriodCount: number; requestedPeriodCount: number };
  /** Current period's own coverage/evidence counters (independent of the
   *  trigger calculation -- attached, never suppressing). */
  dataQuality: {
    coveragePercent: number | null;
    gapIntervalCount: number;
    resetIntervalCount: number;
    rolloverIntervalCount: number;
    invalidIntervalCount: number;
  };
  /** In-app path to the full screen for this metric. */
  investigatePath: string;
};

export type SiteHealthState = "HEALTHY" | "NEEDS_ATTENTION" | "INSUFFICIENT_DATA";
