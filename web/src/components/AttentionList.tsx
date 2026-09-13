/**
 * MVP-3 -- Attention/Exceptions list (Q70 item 2, Q72, Q98). Renders each
 * AttentionItem's What/Where/When/Metric/Trigger/Evidence/Data-Quality/
 * Investigate fields. Generic over AttentionItem's `metric` union --
 * currently only ENERGY_CONSUMPTION exists; this component does not assume
 * that is the only one that ever will.
 *
 * Analytical and transparent only: no ranking, no severity beyond what is
 * already implied by direction/trigger text, no recommendation, no "what
 * should I do" content.
 */

import { Link } from "react-router-dom";
import type { AttentionItem } from "../attention/types";

function metricLabel(metric: AttentionItem["metric"]): string {
  switch (metric) {
    case "ENERGY_CONSUMPTION":
      return "Energy Consumption";
  }
}

export function AttentionList({ items }: { items: readonly AttentionItem[] }) {
  if (items.length === 0) {
    return (
      <p className="hint" data-testid="attention-empty">
        No active issues for the selected period.
      </p>
    );
  }

  return (
    <ul className="attention-list" data-testid="attention-list">
      {items.map((item, index) => (
        <li key={`${item.metric}-${index}`} className="attention-item" data-testid="attention-item">
          <p className="attention-item__what" data-testid="attention-item-what">
            {item.what}
          </p>
          <p className="attention-item__where" data-testid="attention-item-where">
            {item.where}
          </p>
          <p className="attention-item__metric" data-testid="attention-item-metric">
            {metricLabel(item.metric)}
          </p>
          <p className="attention-item__trigger" data-testid="attention-item-trigger">
            {item.trigger}
          </p>
          <p className="hint" data-testid="attention-item-evidence">
            Based on {item.evidence.eligiblePeriodCount} of {item.evidence.requestedPeriodCount} comparable
            historical periods.
          </p>
          <p className="hint" data-testid="attention-item-data-quality">
            {item.dataQuality.coveragePercent !== null
              ? `Coverage: ${item.dataQuality.coveragePercent.toFixed(0)}%`
              : "Coverage information not available."}
          </p>
          <Link to={item.investigatePath} data-testid="attention-item-investigate">
            Investigate →
          </Link>
        </li>
      ))}
    </ul>
  );
}
