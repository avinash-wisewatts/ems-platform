import { Navigate } from "react-router-dom";
import { useSession } from "../auth/SessionProvider";
import { useTenant } from "../tenant/TenantProvider";
import { canUseShell } from "../auth/permissions";
import { Loading } from "../components/states/Loading";
import { ErrorState } from "../components/states/ErrorState";
import { Forbidden } from "./Forbidden";
import { LoginRedirect } from "./LoginRedirect";

/**
 * Root route. Sequences: session -> shell permission -> tenant -> destination.
 * Keeps every downstream route free of auth/tenant plumbing.
 */
export function Bootstrap() {
  const session = useSession();
  const tenant = useTenant();

  if (session.status === "loading") return <Loading label="Starting…" />;
  if (session.status === "unauthenticated") return <LoginRedirect />;
  if (session.status === "error") {
    return <ErrorState error={session.error} onRetry={session.reload} title="Could not start the application" />;
  }

  // authenticated
  if (!canUseShell(session.user)) return <Forbidden />;

  if (tenant.status === "loading") return <Loading label="Loading your sites…" />;
  if (tenant.status === "error") {
    return <ErrorState error={tenant.error} onRetry={tenant.reload} title="Could not load your sites" />;
  }

  if (!tenant.selectedSite && tenant.sites.length !== 1 && tenant.sites.length > 0) {
    return <Navigate to="/select" replace />;
  }
  // WiseWatts redesign: the Main Dashboard is now the landing screen.
  // SiteOverview (/home) is unchanged and still reachable from the sidebar's
  // Archive section.
  return <Navigate to="/dashboard" replace />;
}
