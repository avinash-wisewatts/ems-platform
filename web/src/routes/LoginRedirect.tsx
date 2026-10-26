import { Navigate } from "react-router-dom";
import { currentAppPath, safeNextPath } from "../api/client";

/**
 * Unauthenticated users go to the app's own sign-in page (routes/SignIn.tsx),
 * which signs in through the customer API on the customer host and hands
 * over to the Administration App's existing /login where the app is still
 * served through it (ADR-023). The current location is the return path.
 */
export function LoginRedirect() {
  return <Navigate to={`/sign-in?next=${encodeURIComponent(safeNextPath(currentAppPath()))}`} replace />;
}
