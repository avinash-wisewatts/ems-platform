/**
 * Shared breadcrumb for the customer hierarchy (Site [> Space] / Site [>
 * Asset]). Semantic labels only -- never an internal ID. Built once here so
 * every later slice (Demand, PQ, Attention, Investigation) reuses it rather
 * than each screen inventing its own.
 *
 * At most Site, then one Space or Asset leaf. It does NOT render a
 * Building/Floor level (not part of the MVP customer journey) and does NOT
 * render a component-tree path (asset_relationships is out of scope for
 * this increment; see endpoints.ts).
 *
 * MVP-1 closeout: an optional leading "Sites" segment represents the
 * Portfolio level (Q69/Q101 -- Portfolio -> Site -> Space -> Asset), shown
 * only via `multiSite` -- a caller passes whether the signed-in user has
 * more than one accessible site. Per Q62, a single-site customer is not
 * taxed with portfolio ceremony, so it stays hidden for them. This does not
 * display an organisation name here -- GET /api/v1/sites does now return one
 * (organization_name) -- but no product decision has approved showing it in
 * THIS breadcrumb's Portfolio segment, across every existing screen that
 * renders it, so the segment stays a plain, non-identifying link back to the
 * site list rather than silently picking up a new label everywhere at once.
 */

import { Link } from "react-router-dom";

export type HierarchyCrumbProps = {
  siteName: string;
  /** True when the signed-in user has access to more than one site --
   *  renders the Portfolio-level "Sites" segment ahead of the site name. */
  multiSite?: boolean;
  /** The current leaf, if any -- a space or an asset, never both. */
  leaf?: { label: string } | null;
  /** Optional text override for the Portfolio-level segment. Defaults to
   *  "Sites" (unchanged) -- only the WiseWatts Main Dashboard's context bar
   *  passes "Portfolio" to match the agreed visual design; every other
   *  existing caller is unaffected. */
  portfolioLabel?: string;
  /** Optional route override for the site-name segment. Defaults to "/home"
   *  (unchanged) -- the Main Dashboard passes "/dashboard" since that is its
   *  own landing route; every other existing caller is unaffected. */
  siteHref?: string;
};

export function HierarchyCrumb({
  siteName,
  multiSite = false,
  leaf,
  portfolioLabel = "Sites",
  siteHref = "/home",
}: HierarchyCrumbProps) {
  return (
    <nav className="hierarchy-crumb" aria-label="Location" data-testid="hierarchy-crumb">
      {multiSite ? (
        <>
          <Link to="/select" data-testid="hierarchy-crumb-portfolio">
            {portfolioLabel}
          </Link>
          <span aria-hidden="true"> ▸ </span>
        </>
      ) : null}
      <Link to={siteHref}>{siteName}</Link>
      {leaf ? (
        <>
          <span aria-hidden="true"> ▸ </span>
          <span data-testid="hierarchy-crumb-leaf">{leaf.label}</span>
        </>
      ) : null}
    </nav>
  );
}
