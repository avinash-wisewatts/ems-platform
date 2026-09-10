import { BrowserRouter } from "react-router-dom";
import { SessionProvider } from "./auth/SessionProvider";
import { TenantProvider } from "./tenant/TenantProvider";
import { AppRoutes } from "./router";

/**
 * Provider order: Session (identity) -> Tenant (accessible sites) -> Router.
 * The app is served same-origin under /app, so the router uses that basename.
 */
export function App() {
  return (
    <BrowserRouter basename="/app">
      <SessionProvider>
        <TenantProvider>
          <AppRoutes />
        </TenantProvider>
      </SessionProvider>
    </BrowserRouter>
  );
}
