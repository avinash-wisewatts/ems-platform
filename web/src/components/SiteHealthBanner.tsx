/**
 * MVP-3 -- Overall Site Health/Status banner (Q70 item 1, Q71, Q79). A
 * concise, traceable summary -- deliberately NOT a proprietary 0-100 score.
 */

import { SITE_HEALTH_LABELS } from "../attention/siteHealth";
import type { SiteHealthState } from "../attention/types";

export function SiteHealthBanner({ state, summary }: { state: SiteHealthState; summary: string }) {
  return (
    <section
      className={`site-health site-health--${state.toLowerCase().replace(/_/g, "-")}`}
      data-testid="site-health-banner"
      data-state={state}
    >
      <h2 data-testid="site-health-label">{SITE_HEALTH_LABELS[state]}</h2>
      <p data-testid="site-health-summary">{summary}</p>
    </section>
  );
}
