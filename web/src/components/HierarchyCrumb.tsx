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
 * display an organisation name: GET /api/v1/sites exposes no such field
 * today (only an opaque organization_id), and inventing or showing that ID
 * would violate the no-implementation-identifiers rule -- so the segment is
 * a plain, non-identifying link back to the site list, not an org label.
 */

import { Link } from "react-router-dom";

export type HierarchyCrumbProps = {
  siteName: string;
  /** True when the signed-in user has access to more than one site --
   *  renders the Portfolio-level "Sites" segment ahead of the site name. */
  multiSite?: boolean;
  /** The current leaf, if any -- a space or an asset, never both. */
  leaf?: { label: string } | null;
};

export function HierarchyCrumb({ siteName, multiSite = false, leaf }: HierarchyCrumbProps) {
  return (
    <nav className="hierarchy-crumb" aria-label="Location" data-testid="hierarchy-crumb">
      {multiSite ? (
        <>
          <Link to="/select" data-testid="hierarchy-crumb-portfolio">
            Sites
          </Link>
          <span aria-hidden="true"> ▸ </span>
        </>
      ) : null}
      <Link to="/home">{siteName}</Link>
      {leaf ? (
        <>
          <span aria-hidden="true"> ▸ </span>
          <span data-testid="hierarchy-crumb-leaf">{leaf.label}</span>
        </>
      ) : null}
    </nav>
  );
}
