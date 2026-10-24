/**
 * Reports tab -- site measurement export.
 *
 * Exports the selected assets of a site (at most REPORT_MAX_ASSETS, chosen
 * with the Analytics asset selector; every asset is preselected when the
 * site has no more than that) for a date/time range as one ZIP with one CSV
 * per asset (Timestamp (UTC), Timestamp (Site Local), then one column per
 * data point and phase the asset has). Values are the Analytics page's own
 * series at the chosen resolution, read through the Analytics API; 1 minute
 * is available for up to 14 days.
 *
 * The site selector is the global site selection (the same one the sidebar
 * and the Analytics page use); the date range is the Analytics date range
 * control, in the site's timezone, bounded by the earliest date the site's
 * catalogue has data from (ADR-014 decision 9; unbounded if the catalogue
 * cannot be read). Small exports download immediately; larger
 * ones run as a background job listed below, with a notification when ready.
 */
import { useEffect, useMemo, useState } from "react";
import { Link } from "react-router-dom";
import {
  createReportExport,
  downloadReportExportNow,
  getAnalyticsCatalog,
  getReportExportEstimate,
  retryReportExport,
} from "../../api/endpoints";
import { ApiError, ContractError } from "../../api/errors";
import type {
  AnalyticsCatalogResponse,
  AnalyticsRequestedResolution,
  ReportExportEstimate,
  ReportExportJob,
} from "../../api/types";
import { useSession } from "../../auth/SessionProvider";
import { hasPermission } from "../../auth/permissions";
import { EmptyState } from "../../components/states/EmptyState";
import { downloadBlob } from "../../export/downloadCsv";
import { formatBytes, formatExportRange, formatRequestedAt, STATUS_LABELS, STATUS_TONES } from "../../reportExports/format";
import { useReportExports } from "../../reportExports/ReportExportsProvider";
import { useTenant } from "../../tenant/TenantProvider";
import { AnalyticsDateRange } from "../analytics/AnalyticsDateRange";
import { earliestDataDate } from "../analytics/AnalyticsPage";
import { AssetSelector } from "../analytics/AnalyticsSelectors";
import { RESOLUTION_OPTIONS, resolveDraftRange, type AnalyticsRangeSelection } from "../analytics/analyticsQuery";

/** The most assets one export covers (the API's EMS_REPORT_EXPORT_MAX_ASSETS). */
export const REPORT_MAX_ASSETS = 10;

export const REPORT_MESSAGES = {
  rangeTooLarge:
    "This resolution is not available for the selected range (1 minute covers up to 14 days). Choose a shorter range, a coarser resolution or Auto.",
  selectAssets: `Select the assets to export (up to ${REPORT_MAX_ASSETS}).`,
  tooManyAssets: `Select at most ${REPORT_MAX_ASSETS} assets to export.`,
  assetsUnavailable: "Unable to load this site's assets. Please try again.",
  tooLarge: "This export is too large. Choose a shorter time range or a coarser resolution.",
  immediate: "This export will download now.",
  background: "This export will run in the background. You can leave this page; you will be notified when it is ready.",
  queued: "Export queued. You can leave this page; you will be notified when it is ready.",
  estimateFailed: "Unable to prepare the export. Please try again.",
  exportFailed: "The export could not be started. Please try again.",
  noAssets: "This site has no assets to export.",
} as const;

type EstimateState =
  | { status: "idle" }
  | { status: "loading" }
  | { status: "ready"; estimate: ReportExportEstimate }
  | { status: "error"; message: string };

function errorMessage(error: unknown, fallback: string): string {
  if (error instanceof ContractError && error.code === "time_range_too_large") return REPORT_MESSAGES.rangeTooLarge;
  if (error instanceof ContractError && error.code === "export_too_large") return REPORT_MESSAGES.tooLarge;
  if (error instanceof ContractError && error.code === "too_many_assets") return REPORT_MESSAGES.tooManyAssets;
  if (error instanceof ApiError && error.status === 429 && error.detail) return error.detail;
  return fallback;
}

function plural(n: number, word: string): string {
  return `${n.toLocaleString()} ${word}${n === 1 ? "" : "s"}`;
}

export function ReportsPage() {
  const { user } = useSession();
  const { sites, selectedSite, selectSite } = useTenant();
  const exports = useReportExports();
  const [range, setRange] = useState<AnalyticsRangeSelection>({ kind: "preset", preset: "TODAY" });
  const [resolution, setResolution] = useState<AnalyticsRequestedResolution>("auto");
  const [estimate, setEstimate] = useState<EstimateState>({ status: "loading" });
  const [busy, setBusy] = useState(false);
  const [notice, setNotice] = useState<{ tone: "info" | "error"; text: string } | null>(null);
  const [minDate, setMinDate] = useState<string | null>(null);
  const [catalog, setCatalog] = useState<
    { status: "loading" } | { status: "ready"; catalog: AnalyticsCatalogResponse } | { status: "error" }
  >({ status: "loading" });
  const [assetIds, setAssetIds] = useState<string[]>([]);

  const siteId = selectedSite?.site_id ?? null;
  const timeZone = selectedSite?.timezone;
  const span = useMemo(() => resolveDraftRange(range, timeZone), [range, timeZone]);
  const query = useMemo(() => ({ from: span.from, to: span.to, resolution, assetIds }), [span, resolution, assetIds]);
  const canExport = hasPermission(user, "report.export");

  useEffect(() => {
    if (!siteId || !canExport) return;
    if (query.assetIds.length === 0) {
      setEstimate({ status: "idle" });
      return;
    }
    const controller = new AbortController();
    setEstimate({ status: "loading" });
    getReportExportEstimate(siteId, query, { signal: controller.signal })
      .then((result) => setEstimate({ status: "ready", estimate: result }))
      .catch((error: unknown) => {
        if (error instanceof DOMException && error.name === "AbortError") return;
        if (controller.signal.aborted) return;
        setEstimate({ status: "error", message: errorMessage(error, REPORT_MESSAGES.estimateFailed) });
      });
    return () => controller.abort();
  }, [siteId, query, canExport]);

  useEffect(() => setNotice(null), [siteId, query]);

  // The site's assets (the Analytics catalogue) and the earliest date its
  // data starts; a small site starts with every asset selected.
  useEffect(() => {
    setMinDate(null);
    setAssetIds([]);
    setCatalog({ status: "loading" });
    if (!siteId || !canExport) return;
    const controller = new AbortController();
    getAnalyticsCatalog(siteId, { signal: controller.signal })
      .then((result) => {
        setCatalog({ status: "ready", catalog: result });
        setMinDate(earliestDataDate(result, timeZone));
        setAssetIds(result.assets.length <= REPORT_MAX_ASSETS ? result.assets.map((a) => a.asset_id) : []);
      })
      .catch((error: unknown) => {
        if (controller.signal.aborted) return;
        if (error instanceof DOMException && error.name === "AbortError") return;
        setCatalog({ status: "error" });
      });
    return () => controller.abort();
  }, [siteId, timeZone, canExport]);

  if (!canExport) {
    return <EmptyState title="Reports are not available for your account." />;
  }
  if (!selectedSite) {
    return (
      <EmptyState title="No site selected">
        <Link to="/select">Select a site</Link>
      </EmptyState>
    );
  }

  const ready = estimate.status === "ready" ? estimate.estimate : null;
  const disabled = busy || !ready || ready.mode === "too_large" || ready.asset_count === 0 || assetIds.length === 0;

  function toggleAsset(assetId: string) {
    setAssetIds((current) =>
      current.includes(assetId)
        ? current.filter((id) => id !== assetId)
        : current.length < REPORT_MAX_ASSETS
          ? [...current, assetId]
          : current,
    );
  }

  async function queueBackground(id: string) {
    await createReportExport(id, query);
    exports.refresh();
    setNotice({ tone: "info", text: REPORT_MESSAGES.queued });
  }

  async function onExport() {
    if (!ready || !siteId) return;
    setBusy(true);
    setNotice(null);
    try {
      if (ready.mode === "immediate") {
        try {
          const { blob, fileName } = await downloadReportExportNow(siteId, query);
          downloadBlob(fileName ?? "export.zip", blob);
          setNotice({ tone: "info", text: `Downloaded ${fileName ?? "export.zip"}.` });
        } catch (error) {
          // Grew past the immediate limit since the estimate: run it in the background.
          if (error instanceof ContractError && error.code === "export_requires_background") {
            await queueBackground(siteId);
          } else {
            throw error;
          }
        }
      } else {
        await queueBackground(siteId);
      }
    } catch (error) {
      setNotice({ tone: "error", text: errorMessage(error, REPORT_MESSAGES.exportFailed) });
    } finally {
      setBusy(false);
    }
  }

  return (
    <section className="page page--reports" data-testid="page-reports" aria-label="Reports">
      <header className="reports-header">
        <h1 className="reports-header__title">Reports</h1>
        <p className="reports-header__subtitle">
          Export all measurement data for up to {REPORT_MAX_ASSETS} assets of a site as a ZIP file with one CSV per
          asset.
        </p>
      </header>

      <div className="reports-card" data-testid="reports-export-form">
        <h2 className="reports-card__title">Measurement data export</h2>
        <div className="reports-controls">
          <label className="reports-field">
            <span className="reports-field__label">Site</span>
            <select
              value={selectedSite.site_id}
              onChange={(e) => selectSite(e.target.value)}
              data-testid="reports-site-select"
            >
              {sites.map((site) => (
                <option key={site.site_id} value={site.site_id}>
                  {sites.some((s) => s.organization_id !== site.organization_id)
                    ? `${site.organization_name}: ${site.site_name}`
                    : site.site_name}
                </option>
              ))}
            </select>
          </label>
          <div className="reports-field">
            <span className="reports-field__label">Date range</span>
            <AnalyticsDateRange value={range} timeZone={timeZone} minDate={minDate} onApply={setRange} />
          </div>
          <label className="reports-field">
            <span className="reports-field__label">Resolution</span>
            <select
              value={resolution}
              onChange={(e) => setResolution(e.target.value as AnalyticsRequestedResolution)}
              data-testid="reports-resolution-select"
            >
              {RESOLUTION_OPTIONS.map((option) => (
                <option key={option.value} value={option.value}>
                  {option.label}
                </option>
              ))}
            </select>
          </label>
        </div>

        <div className="reports-assets" data-testid="reports-assets">
          {catalog.status === "loading" ? <p>Loading assets…</p> : null}
          {catalog.status === "error" ? <p className="reports-summary__error">{REPORT_MESSAGES.assetsUnavailable}</p> : null}
          {catalog.status === "ready" && catalog.catalog.assets.length === 0 ? <p>{REPORT_MESSAGES.noAssets}</p> : null}
          {catalog.status === "ready" && catalog.catalog.assets.length > 0 ? (
            <AssetSelector
              assets={catalog.catalog.assets}
              selected={assetIds}
              maxAssets={REPORT_MAX_ASSETS}
              onToggle={toggleAsset}
              onSetAssets={(ids) => setAssetIds(ids.slice(0, REPORT_MAX_ASSETS))}
            />
          ) : null}
        </div>

        <div className="reports-summary" data-testid="reports-estimate" aria-live="polite">
          {estimate.status === "idle" && catalog.status === "ready" && catalog.catalog.assets.length > 0 ? (
            <p data-testid="reports-select-assets">{REPORT_MESSAGES.selectAssets}</p>
          ) : null}
          {estimate.status === "loading" ? <p>Preparing…</p> : null}
          {estimate.status === "error" ? <p className="reports-summary__error">{estimate.message}</p> : null}
          {ready ? (
            <>
              <p>
                {plural(ready.asset_count, "asset")} · {formatExportRange(ready.range_from, ready.range_to, timeZone)} ·{" "}
                {RESOLUTION_OPTIONS.find((o) => o.value === ready.resolution)?.label ?? ready.resolution}
                {ready.requested_resolution === "auto" ? " (Auto)" : ""}
              </p>
              <p className={ready.mode === "too_large" ? "reports-summary__error" : "reports-summary__mode"}>
                {ready.asset_count === 0
                  ? REPORT_MESSAGES.noAssets
                  : ready.mode === "immediate"
                    ? REPORT_MESSAGES.immediate
                    : ready.mode === "background"
                      ? REPORT_MESSAGES.background
                      : REPORT_MESSAGES.tooLarge}
              </p>
            </>
          ) : null}
        </div>

        <div className="reports-actions">
          <button
            type="button"
            className="analytics-button analytics-button--primary"
            onClick={() => void onExport()}
            disabled={disabled}
            data-testid="reports-export-button"
          >
            {busy ? "Exporting…" : "Export"}
          </button>
          {notice ? (
            <p
              className={notice.tone === "error" ? "reports-notice reports-notice--error" : "reports-notice"}
              role={notice.tone === "error" ? "alert" : "status"}
              data-testid="reports-notice"
            >
              {notice.text}
            </p>
          ) : null}
        </div>
      </div>

      <ExportJobsTable />
    </section>
  );
}

function ExportJobsTable() {
  const { jobs, loaded, error, refresh } = useReportExports();
  const { sites } = useTenant();
  const [retrying, setRetrying] = useState<string | null>(null);
  const [retryError, setRetryError] = useState<string | null>(null);

  async function onRetry(job: ReportExportJob) {
    setRetrying(job.job_id);
    setRetryError(null);
    try {
      await retryReportExport(job.job_id);
      refresh();
    } catch (err) {
      setRetryError(errorMessage(err, "The export could not be retried. Please try again."));
    } finally {
      setRetrying(null);
    }
  }

  return (
    <div className="reports-card" data-testid="reports-jobs">
      <h2 className="reports-card__title">Background exports</h2>
      <p className="reports-card__hint">Completed exports can be downloaded for a limited time, then expire.</p>
      {retryError ? (
        <p className="reports-notice reports-notice--error" role="alert">
          {retryError}
        </p>
      ) : null}
      {!loaded ? <p>Loading…</p> : null}
      {loaded && error && jobs.length === 0 ? <p className="reports-summary__error">Unable to load exports.</p> : null}
      {loaded && !error && jobs.length === 0 ? <p data-testid="reports-jobs-empty">No background exports yet.</p> : null}
      {jobs.length > 0 ? (
        <div className="reports-table-wrap">
          <table className="reports-table">
            <thead>
              <tr>
                <th scope="col">Requested</th>
                <th scope="col">Site</th>
                <th scope="col">Range</th>
                <th scope="col">Resolution</th>
                <th scope="col">Status</th>
                <th scope="col">Details</th>
                <th scope="col">
                  <span className="visually-hidden">Actions</span>
                </th>
              </tr>
            </thead>
            <tbody>
              {jobs.map((job) => {
                const site = sites.find((s) => s.site_id === job.site_id);
                return (
                  <tr key={job.job_id} data-testid={`reports-job-${job.job_id}`}>
                    <td>{formatRequestedAt(job.created_at)}</td>
                    <td>{job.site_name ?? site?.site_name ?? ""}</td>
                    <td>{formatExportRange(job.range_from, job.range_to, site?.timezone)}</td>
                    <td>{RESOLUTION_OPTIONS.find((o) => o.value === job.resolution)?.label ?? job.resolution}</td>
                    <td>
                      <span className={`reports-status reports-status--${STATUS_TONES[job.status]}`} data-testid="reports-job-status">
                        {STATUS_LABELS[job.status] ?? job.status_label}
                      </span>
                    </td>
                    <td className="reports-table__details">
                      {job.status === "FAILED" ? job.error_message : null}
                      {job.status === "COMPLETED"
                        ? `${plural(job.asset_count ?? 0, "asset")} · ${formatBytes(job.file_size_bytes)}`
                        : null}
                      {job.status === "EXPIRED" ? "The file has expired. Export again to download it." : null}
                    </td>
                    <td className="reports-table__actions">
                      {job.download_url ? (
                        <a href={job.download_url} download data-testid="reports-job-download">
                          Download
                        </a>
                      ) : null}
                      {job.status === "FAILED" ? (
                        <button
                          type="button"
                          onClick={() => void onRetry(job)}
                          disabled={retrying === job.job_id}
                          data-testid="reports-job-retry"
                        >
                          {retrying === job.job_id ? "Retrying…" : "Retry"}
                        </button>
                      ) : null}
                    </td>
                  </tr>
                );
              })}
            </tbody>
          </table>
        </div>
      ) : null}
    </div>
  );
}
