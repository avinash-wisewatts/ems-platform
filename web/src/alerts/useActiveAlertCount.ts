/**
 * Header Active-alert indicator (ADR-024 §11): the number of currently Active
 * rule-based alerts for the selected site. No number at zero (the bell stays
 * visible); null when no site is selected or the count could not be read.
 * Refreshes every 60 s (the evaluator runs every minute) and when another
 * part of the app signals a change (window event "ww:alerts-changed").
 */

import { useEffect, useState } from "react";
import { getSiteAlerts } from "../api/endpoints";

export const ALERTS_CHANGED_EVENT = "ww:alerts-changed";
const REFRESH_MS = 60_000;

export function useActiveAlertCount(siteId: string | null): number | null {
  const [count, setCount] = useState<number | null>(null);

  useEffect(() => {
    if (!siteId) {
      setCount(null);
      return;
    }
    let active = true;
    const load = () => {
      getSiteAlerts(siteId, { states: ["ACTIVE"], limit: 200 })
        .then((response) => {
          if (active) setCount(response.alerts.length);
        })
        .catch(() => {
          if (active) setCount(null);
        });
    };
    load();
    const timer = window.setInterval(load, REFRESH_MS);
    window.addEventListener(ALERTS_CHANGED_EVENT, load);
    return () => {
      active = false;
      window.clearInterval(timer);
      window.removeEventListener(ALERTS_CHANGED_EVENT, load);
    };
  }, [siteId]);

  return count;
}
