/**
 * Slice 0 (Hierarchy Foundation) -- Spaces list for the selected site.
 *
 * Identity + placement only, via GET /api/v1/sites/{site_id}/spaces. No
 * environmental snapshot here -- that lives on the detail screen, reusing
 * the already-live GET /spaces/{space_id}/measurements.
 */

import { useEffect, useState } from "react";
import { Link } from "react-router-dom";
import { useTenant } from "../../tenant/TenantProvider";
import { getSiteSpaces } from "../../api/endpoints";
import type { SpaceSummary } from "../../api/types";
import { HierarchyCrumb } from "../../components/HierarchyCrumb";
import { Loading } from "../../components/states/Loading";
import { ErrorState } from "../../components/states/ErrorState";
import { EmptyState } from "../../components/states/EmptyState";

type LoadStatus = "loading" | "ready" | "error";

export function SpacesList() {
  const { selectedSite, sites } = useTenant();
  const [status, setStatus] = useState<LoadStatus>("loading");
  const [error, setError] = useState<unknown>(null);
  const [spaces, setSpaces] = useState<SpaceSummary[]>([]);
  const [nonce, setNonce] = useState(0);

  useEffect(() => {
    if (!selectedSite) return;
    let active = true;
    setStatus("loading");
    setError(null);
    getSiteSpaces(selectedSite.site_id)
      .then((res) => {
        if (!active) return;
        setSpaces(res.spaces);
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
    <div className="page page--spaces-list" data-testid="page-spaces-list">
      <HierarchyCrumb siteName={selectedSite.site_name} multiSite={sites.length > 1} />
      <h1>Spaces</h1>

      {status === "loading" ? <Loading label="Loading spaces…" /> : null}
      {status === "error" ? <ErrorState error={error} onRetry={() => setNonce((n) => n + 1)} /> : null}
      {status === "ready" && spaces.length === 0 ? (
        <EmptyState title="No spaces at this site yet" />
      ) : null}
      {status === "ready" && spaces.length > 0 ? (
        <ul className="spaces-list" data-testid="spaces-list">
          {spaces.map((space) => (
            <li key={space.space_id}>
              <Link to={`/features/spaces/${encodeURIComponent(space.space_id)}`}>
                {space.space_name}
              </Link>
            </li>
          ))}
        </ul>
      ) : null}
    </div>
  );
}
