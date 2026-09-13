/**
 * MVP-3 materiality policy -- the ONLY place the 15% Energy Attention
 * threshold is defined. Approved product decision: "Energy Attention
 * materiality threshold = 15% deviation from the Slice C historical typical
 * reference" (MVP-3 Implementation Decision Pack).
 *
 * Deliberately separable from the comparison/reference CALCULATION
 * (energy/comparison.ts, unmodified) so the policy can evolve later --
 * metric-specific, site-specific, or variability-based thresholds -- without
 * redesigning the Attention/Site-Health architecture. No configuration UI
 * and no Admin Portal surface exist for this yet: for MVP-3 the policy is a
 * plain, centrally-defined constant, per the approved decision pack (`Do
 * NOT build configuration UI now`).
 *
 * Extension points, not built now:
 *   - per-site policy: change MVP3_MATERIALITY_POLICY to a (siteId) => ...
 *     lookup -- callers already pass through a single policy value, so this
 *     changes only this module.
 *   - per-metric policy: add new keys (e.g. DEMAND) once a rule is approved
 *     for that metric.
 *   - variability-based method: add a new `method` value and evaluator; the
 *     `EnergyMaterialityPolicy` shape and `evaluateEnergyAttention`'s
 *     signature do not need to change for this.
 */

export type EnergyMaterialityPolicy = {
  metric: "ENERGY_CONSUMPTION";
  method: "PERCENT_DEVIATION_FROM_TYPICAL_REFERENCE";
  /** Trigger when |deviation%| >= this value. Inclusive both directions. */
  thresholdPercent: number;
};

export const MVP3_MATERIALITY_POLICY: Readonly<{ ENERGY_CONSUMPTION: EnergyMaterialityPolicy }> = {
  ENERGY_CONSUMPTION: {
    metric: "ENERGY_CONSUMPTION",
    method: "PERCENT_DEVIATION_FROM_TYPICAL_REFERENCE",
    thresholdPercent: 15,
  },
};
