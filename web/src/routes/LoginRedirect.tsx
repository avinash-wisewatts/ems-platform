import { useEffect } from "react";
import { loginUrl } from "../api/client";

/**
 * Unauthenticated users are sent to the EXISTING server-rendered /login page.
 * There is no SPA login form and no parallel auth: the session cookie created
 * by /login is the same one this app reuses.
 */
export function LoginRedirect() {
  useEffect(() => {
    window.location.assign(loginUrl("/app/"));
  }, []);

  return (
    <div className="page page--message" data-testid="page-login-redirect">
      <h1>Sign in required</h1>
      <p>
        Redirecting to sign in… If nothing happens, <a href={loginUrl("/app/")}>continue here</a>.
      </p>
    </div>
  );
}
