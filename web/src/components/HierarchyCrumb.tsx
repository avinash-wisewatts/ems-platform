/**
 * Shared breadcrumb for the customer hierarchy (Site [> Space] / Site [>
 * Asset]). Semantic labels only -- never an internal ID. Built once here so
 * every later slice (Demand, PQ, Attention, Investigation) reuses it rather
 * than each screen inventing its own.
 *
 * Deliberately flat -- Site, then at most one Space or Asset. It does NOT
 * render a Building/Floor level (not part of the MVP customer journey) and
 * does NOT render a component-tree path (asset_relationships is out of
 * scope for this increment; see endpoints.ts).
 */

import { Link } from "react-router-dom";

export type HierarchyCrumbProps = {
  siteName: string;
  /** The current leaf, if any -- a space or an asset, never both. */
  leaf?: { label: string } | null;
};

export function HierarchyCrumb({ siteName, leaf }: HierarchyCrumbProps) {
  return (
    <nav className="hierarchy-crumb" aria-label="Location" data-testid="hierarchy-crumb">
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
