/**
 * Analytics v1 -- the Trends explorer page (F3: page, route and state).
 *
 * docs/07-features/analytics/README.md "User experience" is the screen
 * specification. F3 provides the page frame, the site's catalogue, the
 * draft/applied state and the Update flow; the selectors (F4), the chart
 * (F5) and Statistics / Data quality (F6) plug into the marked regions.
 *
 * No site-name page header (D32): the site comes from the global site
 * selector. The navigation entry opens this page directly (D81).
 */
import { useEffect, useState } from "react";
import { Link } from "react-router-dom";
import { getAnalyticsCatalog } from "../../api/endpoints";
import type { AnalyticsCatalogResponse } from "../../api/types";
import { useTenant } from "../../tenant/TenantProvider";
import { EmptyState } from "../../components/states/EmptyState";
import { ErrorState } from "../../components/states/ErrorState";
import { Loading } from "../../components/states/Loading";
import { MESSAGES } from "./analyticsQuery";
import { useAnalyticsState, type UseAnalyticsState } from "./useAnalyticsState";

type CatalogState =
  | { status: "loading" }
  | { status: "ready"; catalog: AnalyticsCatalogResponse }
  | { status: "error"; error: unknown };

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
    <div className="page page--analytics" data-testid="page-analytics" aria-label="Analytics">
      {catalogState.status === "loading" ? <Loading /> : null}
      {catalogState.status === "error" ? (
        <ErrorState error={catalogState.error} onRetry={() => setCatalogNonce((n) => n + 1)} />
      ) : null}
      {catalogState.status === "ready" ? (
        <div className="analytics-layout">
          <AnalyticsResultArea analytics={analytics} />
          <AnalyticsFilterPanel analytics={analytics} />
        </div>
      ) : null}
    </div>
  );
}

/** Main area: the empty state before the first successful Update (D2),
 *  otherwise the applied result, kept visible while a new one loads (D7)
 *  and after a failed Update (D50). */
function AnalyticsResultArea({ analytics }: { analytics: UseAnalyticsState }) {
  const { applied, loading } = analytics.state;
  return (
    <main className="analytics-main" data-testid="analytics-main" aria-busy={loading}>
      {loading ? <Loading /> : null}
      {applied === null ? (
        <div className="analytics-empty" data-testid="analytics-empty-state">
          <p className="analytics-empty__title">{MESSAGES.emptyStateTitle}</p>
          <p className="analytics-empty__detail">{MESSAGES.emptyStateDetail}</p>
        </div>
      ) : (
        // F5 renders the chart and F6 Statistics / Data quality from `applied`.
        <section className="analytics-result" data-testid="analytics-result" />
      )}
    </main>
  );
}

/** Filter panel, top to bottom (D36): Update, then the selectors (F4). */
function AnalyticsFilterPanel({ analytics }: { analytics: UseAnalyticsState }) {
  const { state, hasUnappliedChanges, update } = analytics;
  return (
    <aside className="analytics-filters" data-testid="analytics-filters">
      <div className="analytics-update">
        <button
          type="button"
          className="analytics-update__button"
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
      {/* F4: Assets, Data points, Resolution, Phase type, Comparison (disabled). */}
    </aside>
  );
}
