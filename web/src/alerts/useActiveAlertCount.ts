/**
 * MVP-7 header notification indicator (ADR-016 decision 37): count of
 * currently Active alerts, scoped to the selected Site/context. No number
 * shown at zero (still visible); no count when no site is selected --
 * handled by the caller checking `count === null` vs `count === 0`.
 */

import { useEffect, useState } from "react";
import { getSiteAlerts } from "../api/endpoints";

export function useActiveAlertCount(siteId: string | null): number | null {
  const [count, setCount] = useState<number | null>(null);

  useEffect(() => {
    if (!siteId) {
      setCount(null);
      return;
    }
    let active = true;
    getSiteAlerts(siteId, { state: "ACTIVE", limit: 200 })
      .then((response) => {
        if (active) setCount(response.alerts.length);
      })
      .catch(() => {
        if (active) setCount(null);
      });
    return () => {
      active = false;
    };
  }, [siteId]);

  return count;
}
