/**
 * MVP-6 -- Q76 Site Performance Report. Configuration step (EMS-REQ-111):
 * hierarchy context (Site/Space/Asset) + reporting period (current-calendar
 * Weekly/Monthly/Quarterly/Yearly, or Custom). Reports area only -- this
 * screen is not reachable from any other screen (see ADR-015 Decision,
 * "Access").
 */

import { useEffect, useState } from "react";
import { useTenant } from "../../tenant/TenantProvider";
import { getSiteAssets, getSiteSpaces } from "../../api/endpoints";
import type { AssetSummary, SpaceSummary } from "../../api/types";
import {
  REPORT_PERIODS,
  REPORT_PERIOD_LABELS,
  resolveCalendarPeriod,
  type ReportPeriod,
} from "../../reports/sitePerformanceReportRanges";
import type { HierarchyLevel, ReportConfig } from "../../reports/sitePerformanceReport";
import { Loading } from "../../components/states/Loading";
import { ErrorState } from "../../components/states/ErrorState";
import { EmptyState } from "../../components/states/EmptyState";
import { Link } from "react-router-dom";

type LoadStatus = "loading" | "ready" | "error";

export function SitePerformanceReportConfig({
  onGenerate,
  initial,
}: {
  onGenerate: (config: ReportConfig) => void;
  /** Preserves the previous selection across "Change" (EMS-REQ-115). */
  initial?: ReportConfig | null;
}) {
  const { selectedSite } = useTenant();
  const [status, setStatus] = useState<LoadStatus>("loading");
  const [error, setError] = useState<unknown>(null);
  const [spaces, setSpaces] = useState<SpaceSummary[]>([]);
  const [assets, setAssets] = useState<AssetSummary[]>([]);
  const [nonce, setNonce] = useState(0);

  const [hierarchyLevel, setHierarchyLevel] = useState<HierarchyLevel>(initial?.hierarchyLevel ?? "SITE");
  const [spaceId, setSpaceId] = useState<string>(initial?.hierarchyLevel === "SPACE" ? "" : "");
  const [assetId, setAssetId] = useState<string>(initial?.hierarchyLevel === "ASSET" ? "" : "");
  const [period, setPeriod] = useState<ReportPeriod>(initial?.period ?? "MONTHLY");
  const [customFrom, setCustomFrom] = useState<string>("");
  const [customTo, setCustomTo] = useState<string>("");

  useEffect(() => {
    if (!selectedSite) return;
    let active = true;
    setStatus("loading");
    setError(null);
    Promise.all([getSiteSpaces(selectedSite.site_id), getSiteAssets(selectedSite.site_id)])
      .then(([spacesRes, assetsRes]) => {
        if (!active) return;
        setSpaces(spacesRes.spaces);
        setAssets(assetsRes.assets);
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

  if (status === "loading") return <Loading label="Loading Spaces and Assets…" />;
  if (status === "error") return <ErrorState error={error} onRetry={() => setNonce((n) => n + 1)} />;

  const canGenerate = hierarchyLevel === "SITE" || (hierarchyLevel === "SPACE" ? !!spaceId : !!assetId);
  const customValid = period !== "CUSTOM" || (!!customFrom && !!customTo && customFrom < customTo);

  function handleGenerate() {
    if (!selectedSite) return;
    let contextName = selectedSite.site_name;
    let investigatePath = "/features/spaces";
    if (hierarchyLevel === "SPACE") {
      const space = spaces.find((s) => s.space_id === spaceId);
      contextName = space?.space_name ?? selectedSite.site_name;
      investigatePath = space ? `/features/spaces/${encodeURIComponent(space.space_id)}` : "/features/spaces";
    } else if (hierarchyLevel === "ASSET") {
      const asset = assets.find((a) => a.asset_id === assetId);
      contextName = asset?.asset_name ?? selectedSite.site_name;
      investigatePath = asset ? `/features/assets/${encodeURIComponent(asset.asset_id)}` : "/features/assets";
    }

    const range =
      period === "CUSTOM"
        ? { from: new Date(customFrom).toISOString(), to: new Date(customTo).toISOString() }
        : resolveCalendarPeriod(period);

    onGenerate({
      siteId: selectedSite.site_id,
      siteName: selectedSite.site_name,
      hierarchyLevel,
      contextName,
      investigatePath,
      period,
      range,
    });
  }

  return (
    <div className="report-config" data-testid="report-config">
      <h2>Configure report</h2>

      <fieldset className="report-config__hierarchy">
        <legend>Hierarchy context</legend>
        <label>
          <input
            type="radio"
            name="hierarchy-level"
            checked={hierarchyLevel === "SITE"}
            onChange={() => setHierarchyLevel("SITE")}
          />
          Site — {selectedSite.site_name}
        </label>
        <label>
          <input
            type="radio"
            name="hierarchy-level"
            checked={hierarchyLevel === "SPACE"}
            onChange={() => setHierarchyLevel("SPACE")}
            disabled={spaces.length === 0}
          />
          Space
          {hierarchyLevel === "SPACE" ? (
            <select
              aria-label="Select a space"
              value={spaceId}
              onChange={(e) => setSpaceId(e.target.value)}
              data-testid="report-config-space-select"
            >
              <option value="">Select a space…</option>
              {spaces.map((s) => (
                <option key={s.space_id} value={s.space_id}>
                  {s.space_name}
                </option>
              ))}
            </select>
          ) : null}
        </label>
        <label>
          <input
            type="radio"
            name="hierarchy-level"
            checked={hierarchyLevel === "ASSET"}
            onChange={() => setHierarchyLevel("ASSET")}
            disabled={assets.length === 0}
          />
          Asset
          {hierarchyLevel === "ASSET" ? (
            <select
              aria-label="Select an asset"
              value={assetId}
              onChange={(e) => setAssetId(e.target.value)}
              data-testid="report-config-asset-select"
            >
              <option value="">Select an asset…</option>
              {assets.map((a) => (
                <option key={a.asset_id} value={a.asset_id}>
                  {a.asset_name}
                </option>
              ))}
            </select>
          ) : null}
        </label>
      </fieldset>

      <fieldset className="report-config__period">
        <legend>Reporting period</legend>
        {REPORT_PERIODS.map((p) => (
          <label key={p}>
            <input type="radio" name="report-period" checked={period === p} onChange={() => setPeriod(p)} />
            {REPORT_PERIOD_LABELS[p]}
          </label>
        ))}
        {period === "CUSTOM" ? (
          <div className="report-config__custom-dates">
            <label>
              From
              <input
                type="date"
                value={customFrom}
                onChange={(e) => setCustomFrom(e.target.value)}
                data-testid="report-config-custom-from"
              />
            </label>
            <label>
              To
              <input
                type="date"
                value={customTo}
                onChange={(e) => setCustomTo(e.target.value)}
                data-testid="report-config-custom-to"
              />
            </label>
            <p className="hint">
              Any dates may be selected. Periods with no available data are reported honestly, not hidden.
            </p>
          </div>
        ) : null}
      </fieldset>

      <button
        type="button"
        onClick={handleGenerate}
        disabled={!canGenerate || !customValid}
        data-testid="report-config-generate"
      >
        Generate report
      </button>
    </div>
  );
}
