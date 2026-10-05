/**
 * Analytics v1 -- the Trends explorer page.
 *
 * docs/07-features/analytics/README.md "User experience" is the screen
 * specification. F3 provides the page frame, the site's catalogue, the
 * draft/applied state and the Update flow; F4 the filter panel and the date
 * range; the chart (F5) and Statistics / Data quality (F6) plug into the
 * marked region.
 *
 * No site-name page header (D32): the site comes from the global site
 * selector. The navigation entry opens this page directly (D81).
 */
import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { Link } from "react-router-dom";
import { getAnalyticsCatalog } from "../../api/endpoints";
import type { AnalyticsCatalogResponse } from "../../api/types";
import { useTenant } from "../../tenant/TenantProvider";
import { localDateKey } from "../../time/calendarRanges";
import { EmptyState } from "../../components/states/EmptyState";
import { ErrorState } from "../../components/states/ErrorState";
import { Loading } from "../../components/states/Loading";
import { MESSAGES, limitsFrom, resolveDraftRange } from "./analyticsQuery";
import { useAnalyticsState, type UseAnalyticsState } from "./useAnalyticsState";
import { AnalyticsChart } from "./AnalyticsChart";
import { AnalyticsDateRange } from "./AnalyticsDateRange";
import {
  AssetSelector,
  ComparisonPlaceholder,
  DataPointSelector,
  PhaseTypeSelector,
  ResolutionSelector,
} from "./AnalyticsSelectors";

type CatalogState =
  | { status: "loading" }
  | { status: "ready"; catalog: AnalyticsCatalogResponse }
  | { status: "error"; error: unknown };

/** Narrow screens show the filters as a drawer/overlay (D82). */
export const NARROW_QUERY = "(max-width: 900px)";

function useIsNarrow(): boolean {
  const query = useMemo(
    () => (typeof window !== "undefined" && typeof window.matchMedia === "function" ? window.matchMedia(NARROW_QUERY) : null),
    [],
  );
  const [narrow, setNarrow] = useState(query?.matches ?? false);
  useEffect(() => {
    if (!query) return;
    const onChange = (event: MediaQueryListEvent) => setNarrow(event.matches);
    query.addEventListener("change", onChange);
    return () => query.removeEventListener("change", onChange);
  }, [query]);
  return narrow;
}

/** The earliest site-local date any catalogue data point has data from. */
function earliestDataDate(catalog: AnalyticsCatalogResponse, timeZone: string | null | undefined): string | null {
  let earliest: number | null = null;
  for (const asset of catalog.assets) {
    for (const point of asset.data_points) {
      if (point.available_from) {
        const t = Date.parse(point.available_from);
        if (earliest === null || t < earliest) earliest = t;
      }
    }
  }
  return earliest === null ? null : localDateKey(new Date(earliest), timeZone);
}

export function AnalyticsPage() {
  const { selectedSite } = useTenant();
  const siteId = selectedSite?.site_id ?? null;
  const [catalogState, setCatalogState] = useState<CatalogState>({ status: "loading" });
  const [catalogNonce, setCatalogNonce] = useState(0);

  useEffect(() => {
    if (!siteId) return;
    let active = true;
    setCatalogState({ status: "loading" });
    getAnalyticsCatalog(siteId)
      .then((catalog) => {
        if (active) setCatalogState({ status: "ready", catalog });
      })
      .catch((error: unknown) => {
        if (active) setCatalogState({ status: "error", error });
      });
    return () => {
      active = false;
    };
  }, [siteId, catalogNonce]);

  const catalog = catalogState.status === "ready" ? catalogState.catalog : null;
  const analytics = useAnalyticsState({ siteId, timeZone: selectedSite?.timezone, catalog });

  if (!selectedSite) {
    return (
      <EmptyState title="No site selected">
        <Link to="/select">Select a site</Link>
      </EmptyState>
    );
  }

  return (
    // A labelled section is a named region landmark, so the "Analytics" label
    // is exposed to assistive technology (on a plain div it was ignored).
    <section className="page page--analytics" data-testid="page-analytics" aria-label="Analytics">
      {catalogState.status === "loading" ? <Loading /> : null}
      {catalogState.status === "error" ? (
        <ErrorState error={catalogState.error} onRetry={() => setCatalogNonce((n) => n + 1)} />
      ) : null}
      {catalogState.status === "ready" ? (
        // Keyed by site: the panel's own view state (grouping, search, open
        // groups, drawer) starts fresh on a site change too (D35, D69).
        <AnalyticsWorkspace
          key={selectedSite.site_id}
          analytics={analytics}
          catalog={catalogState.catalog}
          timeZone={selectedSite.timezone}
        />
      ) : null}
    </section>
  );
}

function AnalyticsWorkspace({
  analytics,
  catalog,
  timeZone,
}: {
  analytics: UseAnalyticsState;
  catalog: AnalyticsCatalogResponse;
  timeZone: string | null | undefined;
}) {
  const narrow = useIsNarrow();
  // Visible by default and on every visit (D33, D34); on narrow screens a
  // drawer opened with Show Filters (D82). Never persisted.
  const [filtersOpen, setFiltersOpen] = useState(!narrow);
  useEffect(() => setFiltersOpen(!narrow), [narrow]);
  const minDate = useMemo(() => earliestDataDate(catalog, timeZone), [catalog, timeZone]);

  const hideFilters = useCallback(() => setFiltersOpen(false), []);

  return (
    <div className={`analytics-layout${filtersOpen && !narrow ? "" : " analytics-layout--filters-hidden"}`}>
      {/* Top right, above the filter panel and separate from it: the date
          range, then the filter-panel toggle. */}
      <div className="analytics-toolbar" data-testid="analytics-toolbar">
        <AnalyticsDateRange value={analytics.state.draft.range} timeZone={timeZone} minDate={minDate} onApply={analytics.setRange} />
        <button
          type="button"
          className="analytics-toolbar__filters"
          aria-expanded={filtersOpen}
          onClick={() => setFiltersOpen((o) => !o)}
        >
          <FilterIcon />
          {filtersOpen ? "Hide Filters" : "Show Filters"}
        </button>
      </div>
      <AnalyticsResultArea analytics={analytics} catalog={catalog} timeZone={timeZone} />
      {filtersOpen && narrow ? <div className="analytics-drawer-backdrop" aria-hidden="true" onClick={hideFilters} /> : null}
      {filtersOpen ? (
        <AnalyticsFilterPanel analytics={analytics} catalog={catalog} timeZone={timeZone} drawer={narrow} onHide={hideFilters} />
      ) : null}
    </div>
  );
}

function FilterIcon() {
  return (
    <svg viewBox="0 0 16 16" width="14" height="14" aria-hidden="true" className="analytics-icon">
      <path d="M2 3h12l-4.5 5.5V13l-3-1.5V8.5z" fill="none" stroke="currentColor" strokeWidth="1.4" strokeLinejoin="round" />
    </svg>
  );
}

/** Main area: the empty state before the first successful Update (D2),
 *  otherwise the applied result, kept visible while a new one loads (D7)
 *  and after a failed Update (D50). */
function AnalyticsResultArea({
  analytics,
  catalog,
  timeZone,
}: {
  analytics: UseAnalyticsState;
  catalog: AnalyticsCatalogResponse;
  timeZone: string | null | undefined;
}) {
  const { applied, loading } = analytics.state;
  return (
    // A section, not <main>: the app shell already provides the page's main landmark.
    <section className="analytics-main" data-testid="analytics-main" aria-busy={loading}>
      {loading ? <Loading /> : null}
      {applied === null ? (
        <div className="analytics-empty" data-testid="analytics-empty-state">
          <p className="analytics-empty__title">{MESSAGES.emptyStateTitle}</p>
          <p className="analytics-empty__detail">{MESSAGES.emptyStateDetail}</p>
        </div>
      ) : (
        // F6 adds Statistics and Data quality below the chart, from `applied`.
        <section className="analytics-result" data-testid="analytics-result">
          {/* Keyed per successful Update (each response has its own as_of):
              a new result starts unzoomed. */}
          <AnalyticsChart
            key={`${applied.response?.as_of ?? ""}|${applied.range.from}|${applied.range.to}`}
            applied={applied}
            catalog={catalog}
            timeZone={timeZone}
          />
        </section>
      )}
    </section>
  );
}

/** Filter panel, top to bottom (D36): Update, Assets, Data points, Resolution,
 *  Phase type, Comparison (disabled placeholder). */
function AnalyticsFilterPanel({
  analytics,
  catalog,
  timeZone,
  drawer,
  onHide,
}: {
  analytics: UseAnalyticsState;
  catalog: AnalyticsCatalogResponse;
  timeZone: string | null | undefined;
  drawer: boolean;
  onHide: () => void;
}) {
  const { state, hasUnappliedChanges, update } = analytics;
  const limits = limitsFrom(catalog);
  const range = resolveDraftRange(state.draft.range, timeZone);
  // As a drawer the panel is modal: focus moves into it and Escape closes it.
  const hideRef = useRef<HTMLButtonElement>(null);
  useEffect(() => {
    if (!drawer) return;
    hideRef.current?.focus();
    const onKey = (event: KeyboardEvent) => {
      if (event.key === "Escape") onHide();
    };
    document.addEventListener("keydown", onKey);
    return () => document.removeEventListener("keydown", onKey);
  }, [drawer, onHide]);
  return (
    <aside
      className={`analytics-filters${drawer ? " analytics-filters--drawer" : ""}`}
      data-testid="analytics-filters"
      aria-label="Filters"
      {...(drawer ? { role: "dialog", "aria-modal": true } : {})}
    >
      {drawer ? (
        <div className="analytics-filters__header">
          <span className="analytics-filters__title">Filters</span>
          <button ref={hideRef} type="button" className="analytics-filters__hide" onClick={onHide}>
            Hide Filters
          </button>
        </div>
      ) : null}
      <div className="analytics-update">
        <button
          type="button"
          className="analytics-button analytics-button--primary analytics-update__button"
          data-testid="analytics-update"
          disabled={!hasUnappliedChanges || state.loading}
          onClick={update}
        >
          Update
        </button>
        {hasUnappliedChanges ? (
          <span className="analytics-update__pending" data-testid="analytics-changes-not-applied">
            {MESSAGES.changesNotApplied}
          </span>
        ) : null}
        {state.validationMessage ? (
          <p className="analytics-update__message" role="alert" data-testid="analytics-validation-message">
            {state.validationMessage}
          </p>
        ) : null}
        {state.errorMessage ? (
          <p className="analytics-update__message" role="alert" data-testid="analytics-error-message">
            {state.errorMessage}
          </p>
        ) : null}
        {state.resolutionNotice ? (
          <p className="analytics-update__notice" role="status" data-testid="analytics-resolution-notice">
            {state.resolutionNotice}
          </p>
        ) : null}
      </div>
      <AssetSelector
        assets={catalog.assets}
        selected={state.draft.assetIds}
        maxAssets={limits.maxAssets}
        onToggle={analytics.toggleAsset}
        onSetAssets={analytics.setAssets}
      />
      <DataPointSelector
        catalog={catalog}
        range={range}
        selected={state.draft.dataPoints}
        maxDataPoints={limits.maxDataPoints}
        onToggle={analytics.toggleDataPoint}
        onSetDataPoints={analytics.setDataPoints}
      />
      <ResolutionSelector value={state.draft.resolution} range={range} catalog={catalog} onChange={analytics.setResolution} />
      <PhaseTypeSelector value={state.draft.phase} onChange={analytics.setPhase} />
      <ComparisonPlaceholder />
    </aside>
  );
}
