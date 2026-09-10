/**
 * Organization / site context for the shell.
 *
 *   User (session)  ->  Organizations  ->  Accessible sites  ->  Selected site
 *
 * The accessible-site list comes from GET /api/v1/sites, which the backend
 * has ALREADY filtered by the caller's scope (admin.list_accessible_sites).
 * Organizations are derived from that list. The selected site is transient UI
 * state (persisted per browser tab) and is ALWAYS re-validated against the
 * accessible list -- it is never an authorization input. The backend
 * re-derives scope on every data call regardless.
 */

import { createContext, useCallback, useContext, useEffect, useMemo, useState } from "react";
import type { ReactNode } from "react";
import { getSites } from "../api/endpoints";
import type { SiteSummary, SitesResponse } from "../api/types";

const SELECTED_SITE_KEY = "ems.web.selectedSiteId";

export type OrganizationGroup = {
  organization_id: string;
  sites: SiteSummary[];
};

export type TenantStatus = "loading" | "ready" | "error";

export type TenantState = {
  status: TenantStatus;
  error: Error | null;
  sites: SiteSummary[];
  organizations: OrganizationGroup[];
  selectedSite: SiteSummary | null;
  selectSite: (siteId: string | null) => void;
  reload: () => void;
};

const TenantContext = createContext<TenantState | null>(null);

function groupByOrganization(sites: SiteSummary[]): OrganizationGroup[] {
  const map = new Map<string, SiteSummary[]>();
  for (const site of sites) {
    const bucket = map.get(site.organization_id) ?? [];
    bucket.push(site);
    map.set(site.organization_id, bucket);
  }
  return [...map.entries()]
    .map(([organization_id, groupSites]) => ({
      organization_id,
      sites: [...groupSites].sort((a, b) => a.site_name.localeCompare(b.site_name)),
    }))
    .sort((a, b) => a.organization_id.localeCompare(b.organization_id));
}

function readStoredSelection(): string | null {
  try {
    return window.sessionStorage.getItem(SELECTED_SITE_KEY);
  } catch {
    return null;
  }
}

function writeStoredSelection(siteId: string | null): void {
  try {
    if (siteId) window.sessionStorage.setItem(SELECTED_SITE_KEY, siteId);
    else window.sessionStorage.removeItem(SELECTED_SITE_KEY);
  } catch {
    /* sessionStorage unavailable -- selection is simply not persisted */
  }
}

export function TenantProvider({
  children,
  loader = getSites,
}: {
  children: ReactNode;
  loader?: () => Promise<SitesResponse>;
}) {
  const [status, setStatus] = useState<TenantStatus>("loading");
  const [error, setError] = useState<Error | null>(null);
  const [sites, setSites] = useState<SiteSummary[]>([]);
  const [selectedSiteId, setSelectedSiteId] = useState<string | null>(readStoredSelection);
  const [nonce, setNonce] = useState(0);

  const reload = useCallback(() => setNonce((n) => n + 1), []);

  useEffect(() => {
    let active = true;
    setStatus("loading");
    setError(null);
    loader()
      .then((res) => {
        if (!active) return;
        setSites(res.sites);
        setStatus("ready");
      })
      .catch((err: unknown) => {
        if (!active) return;
        setError(err instanceof Error ? err : new Error("Failed to load sites"));
        setStatus("error");
      });
    return () => {
      active = false;
    };
  }, [loader, nonce]);

  const selectSite = useCallback((siteId: string | null) => {
    setSelectedSiteId(siteId);
    writeStoredSelection(siteId);
  }, []);

  // Re-validate the stored/selected id against the accessible list. Auto-select
  // when exactly one site is accessible.
  useEffect(() => {
    if (status !== "ready") return;
    const ids = new Set(sites.map((s) => s.site_id));
    if (selectedSiteId && !ids.has(selectedSiteId)) {
      selectSite(null);
      return;
    }
    if (!selectedSiteId && sites.length === 1) {
      selectSite(sites[0]!.site_id);
    }
  }, [status, sites, selectedSiteId, selectSite]);

  const organizations = useMemo(() => groupByOrganization(sites), [sites]);
  const selectedSite = useMemo(
    () => sites.find((s) => s.site_id === selectedSiteId) ?? null,
    [sites, selectedSiteId],
  );

  const value = useMemo<TenantState>(
    () => ({ status, error, sites, organizations, selectedSite, selectSite, reload }),
    [status, error, sites, organizations, selectedSite, selectSite, reload],
  );

  return <TenantContext.Provider value={value}>{children}</TenantContext.Provider>;
}

export function useTenant(): TenantState {
  const ctx = useContext(TenantContext);
  if (!ctx) throw new Error("useTenant must be used within <TenantProvider>");
  return ctx;
}
