import { useNavigate } from "react-router-dom";
import { useTenant } from "../tenant/TenantProvider";
import { Loading } from "../components/states/Loading";
import { ErrorState } from "../components/states/ErrorState";
import { EmptyState } from "../components/states/EmptyState";

/**
 * Organization / site selection. Skipped automatically when exactly one site
 * is accessible (TenantProvider auto-selects). The site list is already
 * scope-filtered by the backend.
 */
export function SelectContext() {
  const { status, error, organizations, sites, selectSite, reload } = useTenant();
  const navigate = useNavigate();

  if (status === "loading") return <Loading label="Loading your organizations…" />;
  if (status === "error") return <ErrorState error={error} onRetry={reload} title="Could not load your sites" />;

  if (sites.length === 0) {
    return (
      <EmptyState title="No accessible sites">
        Your account is not associated with any site yet. Contact an administrator.
      </EmptyState>
    );
  }

  return (
    <div className="page page--select" data-testid="page-select-context">
      <h1>Select a site</h1>
      {organizations.map((org) => (
        <section key={org.organization_id} className="org-group">
          <h2 className="org-group__name">Organization {org.organization_id}</h2>
          <ul className="site-list">
            {org.sites.map((site) => (
              <li key={site.site_id}>
                <button
                  type="button"
                  className="site-list__item"
                  onClick={() => {
                    selectSite(site.site_id);
                    navigate("/dashboard");
                  }}
                >
                  <span className="site-list__name">{site.site_name}</span>
                  <span className="site-list__code">{site.site_code}</span>
                </button>
              </li>
            ))}
          </ul>
        </section>
      ))}
    </div>
  );
}
