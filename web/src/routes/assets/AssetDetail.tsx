/**
 * Slice 0 (Hierarchy Foundation) -- basic Asset detail.
 *
 * Identity + placement + lifecycle status only, from the already-fetched
 * Assets list (no separate "get one asset" endpoint was introduced). NO
 * component tree, NO measurements -- both explicitly out of scope for this
 * increment (no asset-scoped measurement endpoint exists yet).
 */

import { useEffect, useMemo, useState } from "react";
import { Link, useParams } from "react-router-dom";
import { useTenant } from "../../tenant/TenantProvider";
import { getSiteAssets } from "../../api/endpoints";
import type { AssetSummary } from "../../api/types";
import { HierarchyCrumb } from "../../components/HierarchyCrumb";
import { Loading } from "../../components/states/Loading";
import { ErrorState } from "../../components/states/ErrorState";

type LoadStatus = "loading" | "ready" | "error";

export function AssetDetail() {
  const { assetId } = useParams<{ assetId: string }>();
  const { selectedSite, sites } = useTenant();
  const [status, setStatus] = useState<LoadStatus>("loading");
  const [error, setError] = useState<unknown>(null);
  const [asset, setAsset] = useState<AssetSummary | null>(null);

  useEffect(() => {
    if (!selectedSite || !assetId) return;
    let active = true;
    setStatus("loading");
    setError(null);
    getSiteAssets(selectedSite.site_id)
      .then((res) => {
        if (!active) return;
        setAsset(res.assets.find((a) => a.asset_id === assetId) ?? null);
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
  }, [selectedSite, assetId]);

  const crumbLeaf = useMemo(
    () => (asset ? { label: asset.asset_name } : assetId ? { label: assetId } : null),
    [asset, assetId],
  );

  if (!selectedSite) {
    return (
      <p>
        <Link to="/select">Select a site</Link>
      </p>
    );
  }

  return (
    <div className="page page--asset-detail" data-testid="page-asset-detail">
      <HierarchyCrumb siteName={selectedSite.site_name} multiSite={sites.length > 1} leaf={crumbLeaf} />

      {status === "loading" ? <Loading label="Loading asset…" /> : null}
      {status === "error" ? <ErrorState error={error} /> : null}

      {status === "ready" && asset ? (
        <>
          <h1>{asset.asset_name}</h1>
          <dl>
            <dt>External ID</dt>
            <dd data-testid="asset-external-id">{asset.external_id}</dd>
            <dt>Status</dt>
            <dd>{asset.lifecycle_status}</dd>
            <dt>Placement</dt>
            <dd>{asset.space_id ? "Placed in a space" : "Not placed in a space"}</dd>
          </dl>
          <p className="hint">
            Component relationships and detailed measurements are not part of this increment.
          </p>
        </>
      ) : null}

      {status === "ready" && !asset ? <ErrorState title="Asset not found or not accessible" /> : null}
    </div>
  );
}
