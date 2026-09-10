/**
 * Bootstraps the EXISTING authenticated portal session into React.
 *
 * On mount it calls GET /api/v1/me (a session echo -- no second auth system).
 *   - 200  -> authenticated; identity + permissions available
 *   - 401  -> unauthenticated; the app routes the user to the existing
 *             server-rendered /login page (no SPA login form, no parallel
 *             auth). The session cookie is created there and reused here.
 *   - other -> a load error (network / backend down)
 *
 * There is no token handling and nothing sensitive is stored: /api/v1/me
 * returns only the already-safe fields the signed session already holds.
 */

import { createContext, useCallback, useContext, useEffect, useMemo, useState } from "react";
import type { ReactNode } from "react";
import { getCurrentUser } from "../api/endpoints";
import { loginUrl } from "../api/client";
import { UnauthenticatedError } from "../api/errors";
import type { CurrentUser } from "../api/types";

export type SessionStatus = "loading" | "authenticated" | "unauthenticated" | "error";

export type SessionState = {
  status: SessionStatus;
  user: CurrentUser | null;
  error: Error | null;
  reload: () => void;
  /** Send the browser to the existing login page, preserving the return path. */
  goToLogin: () => void;
};

const SessionContext = createContext<SessionState | null>(null);

export function SessionProvider({
  children,
  /** Test seam: inject a resolver instead of hitting the network. */
  loader = getCurrentUser,
}: {
  children: ReactNode;
  loader?: () => Promise<CurrentUser>;
}) {
  const [status, setStatus] = useState<SessionStatus>("loading");
  const [user, setUser] = useState<CurrentUser | null>(null);
  const [error, setError] = useState<Error | null>(null);
  const [nonce, setNonce] = useState(0);

  const reload = useCallback(() => setNonce((n) => n + 1), []);
  const goToLogin = useCallback(() => window.location.assign(loginUrl()), []);

  useEffect(() => {
    let active = true;
    setStatus("loading");
    setError(null);
    loader()
      .then((u) => {
        if (!active) return;
        setUser(u);
        setStatus("authenticated");
      })
      .catch((err: unknown) => {
        if (!active) return;
        if (err instanceof UnauthenticatedError) {
          setUser(null);
          setStatus("unauthenticated");
          return;
        }
        setUser(null);
        setError(err instanceof Error ? err : new Error("Failed to load session"));
        setStatus("error");
      });
    return () => {
      active = false;
    };
  }, [loader, nonce]);

  const value = useMemo<SessionState>(
    () => ({ status, user, error, reload, goToLogin }),
    [status, user, error, reload, goToLogin],
  );

  return <SessionContext.Provider value={value}>{children}</SessionContext.Provider>;
}

export function useSession(): SessionState {
  const ctx = useContext(SessionContext);
  if (!ctx) throw new Error("useSession must be used within <SessionProvider>");
  return ctx;
}
