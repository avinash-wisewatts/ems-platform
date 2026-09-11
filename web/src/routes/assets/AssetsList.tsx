/**
 * Slice 0 (Hierarchy Foundation) -- Assets list for the selected site.
 *
 * Identity + placement only, via GET /api/v1/sites/{site_id}/assets. NO
 * component tree, NO "spaces served by" -- explicitly deferred (see
 * endpoints.ts and migration 232's header).
 */

import { useEffect, useState } from "react";
import { Link } from "react-router-dom";
import { useTenant } from "../../tenant/TenantProvider";
import { getSiteAssets } from "../../api/endpoints";
import type { AssetSummary } from "../../api/types";
import { HierarchyCrumb } from "../../components/HierarchyCrumb";
import { Loading } from "../../components/states/Loading";
import { ErrorState } from "../../components/states/ErrorState";
import { EmptyState } from "../../components/states/EmptyState";

type LoadStatus = "loading" | "ready" | "error";

export function AssetsList() {
  const { selectedSite } = useTenant();
  const [status, setStatus] = useState<LoadStatus>("loading");
  const [error, setError] = useState<unknown>(null);
  const [assets, setAssets] = useState<AssetSummary[]>([]);
  const [nonce, setNonce] = useState(0);

  useEffect(() => {
    if (!selectedSite) return;
    let active = true;
    setStatus("loading");
    setError(null);
    getSiteAssets(selectedSite.site_id)
      .then((res) => {
        if (!active) return;
        setAssets(res.assets);
        setStatus("ready");
      })
      .catch((err: unknown) => {
        if (!active) return;
        setError(err);
        setStatus("error");
      });
    return () => {
      active = false;
    };
  }, [selectedSite, nonce]);

  if (!selectedSite) {
    return (
      <EmptyState title="No site selected">
        <Link to="/select">Select a site</Link>
      </EmptyState>
    );
  }

  return (
    <div className="page page--assets-list" data-testid="page-assets-list">
      <HierarchyCrumb siteName={selectedSite.site_name} />
      <h1>Assets</h1>

      {status === "loading" ? <Loading label="Loading assets…" /> : null}
      {status === "error" ? <ErrorState error={error} onRetry={() => setNonce((n) => n + 1)} /> : null}
      {status === "ready" && assets.length === 0 ? (
        <EmptyState title="No assets at this site yet" />
      ) : null}
      {status === "ready" && assets.length > 0 ? (
        <ul className="assets-list" data-testid="assets-list">
          {assets.map((asset) => (
            <li key={asset.asset_id}>
              <Link to={`/features/assets/${encodeURIComponent(asset.asset_id)}`}>
                {asset.asset_name}
              </Link>
              {asset.space_id === null ? (
                <span className="hint"> — not placed in a space</span>
              ) : null}
            </li>
          ))}
        </ul>
      ) : null}
    </div>
  );
}
