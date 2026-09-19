/**
 * Buckets the flat GET .../assets/{id}/live-state point list into the six
 * "Total + phase 1/2/3" tiles the Asset View screen shows. The logical_point
 * names matched here (e.g. ACTIVE_POWER_TOTAL/_L1/_L2/_L3) are the exact,
 * already-seeded names in metadata.logical_points (migration 013's
 * electrical baseline) -- nothing invented. Voltage has no *_TOTAL point;
 * VOLTAGE_LN_AVG (the average line-to-neutral reading) is used as its
 * "Total" row, which is what that point represents. Voltage THD has no
 * logical point in the schema at all (only CURRENT_THD_* exists, matching
 * PowerQualityPoint's own current-only THD) -- it is intentionally excluded
 * from this table and rendered as a standalone "not available" tile.
 *
 * phaseLabels are parameter-specific customer-facing phase labels, NOT a
 * generic P1/P2/P3 reused across every measurement -- each measurement's
 * own established naming convention: Power P1/P2/P3, Current I1/I2/I3,
 * Voltage V1/V2/V3, Power Factor PF1/PF2/PF3, Current THD
 * I-THD1/I-THD2/I-THD3. (The raw device-profile field codes for these are
 * P/I/V/PF/D -- see docs/08-verification/mvp7-alerts-staging-lifecycle-
 * validation.md's mapping table; "D" for THD is an internal vendor field
 * code that was never customer-facing, so it is not reused here --
 * I-THD1/2/3 is this product's own customer-facing convention for it.)
 */

import type { AssetLivePoint } from "../../api/types";

export type LiveParamKey = "active_power" | "voltage" | "current" | "power_factor" | "current_thd";

export type LiveParamDef = {
  key: LiveParamKey;
  label: string;
  totalPoint: string;
  phasePoints: readonly [string, string, string];
  /** Customer-facing phase labels, specific to this parameter -- see this
   *  file's own header for the full mapping and its source. */
  phaseLabels: readonly [string, string, string];
};

// Labels carry their unit ("Power (kW)") so it's stated once in the tile
// heading rather than repeated beside every individual reading -- the unit
// is fixed per measurement type in this system (these are the exact
// engineering units the underlying logical points are seeded with), not a
// per-reading value, so it belongs on the heading, not the number.
export const LIVE_PARAM_DEFS: readonly LiveParamDef[] = [
  {
    key: "active_power",
    label: "Power (kW)",
    totalPoint: "ACTIVE_POWER_TOTAL",
    phasePoints: ["ACTIVE_POWER_L1", "ACTIVE_POWER_L2", "ACTIVE_POWER_L3"],
    phaseLabels: ["P1", "P2", "P3"],
  },
  {
    key: "voltage",
    label: "Voltage (V)",
    totalPoint: "VOLTAGE_LN_AVG",
    phasePoints: ["VOLTAGE_L1", "VOLTAGE_L2", "VOLTAGE_L3"],
    phaseLabels: ["V1", "V2", "V3"],
  },
  {
    key: "current",
    label: "Current (A)",
    totalPoint: "CURRENT_TOTAL",
    phasePoints: ["CURRENT_L1", "CURRENT_L2", "CURRENT_L3"],
    phaseLabels: ["I1", "I2", "I3"],
  },
  {
    key: "power_factor",
    label: "Power Factor",
    totalPoint: "POWER_FACTOR_TOTAL",
    phasePoints: ["POWER_FACTOR_L1", "POWER_FACTOR_L2", "POWER_FACTOR_L3"],
    phaseLabels: ["PF1", "PF2", "PF3"],
  },
  {
    key: "current_thd",
    label: "Current THD (%)",
    totalPoint: "CURRENT_THD_TOTAL",
    phasePoints: ["CURRENT_THD_L1", "CURRENT_THD_L2", "CURRENT_THD_L3"],
    phaseLabels: ["I-THD1", "I-THD2", "I-THD3"],
  },
];

export function findLivePoint(points: readonly AssetLivePoint[], logicalPoint: string): AssetLivePoint | null {
  return points.find((p) => p.logical_point === logicalPoint) ?? null;
}

/** The freshest (most recent) received_at across every point, or null if
 *  there are none -- used for the "Last updated" line. */
export function mostRecentReceivedAt(points: readonly AssetLivePoint[]): string | null {
  const values = points.map((p) => p.received_at).filter((v): v is string => v !== null);
  if (values.length === 0) return null;
  return values.reduce((latest, v) => (Date.parse(v) > Date.parse(latest) ? v : latest));
}
