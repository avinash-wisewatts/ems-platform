/**
 * UX-only permission gate. Renders `children` if the current session holds
 * every required permission, otherwise `fallback` (default: the Forbidden
 * page). This never enforces access -- the backend already does.
 */

import type { ReactNode } from "react";
import { useSession } from "./SessionProvider";
import { hasPermission } from "./permissions";
import { Forbidden } from "../routes/Forbidden";

export function RequirePermission({
  anyOf,
  allOf,
  children,
  fallback = <Forbidden />,
}: {
  anyOf?: readonly string[];
  allOf?: readonly string[];
  children: ReactNode;
  fallback?: ReactNode;
}) {
  const { user } = useSession();

  const okAny = !anyOf || anyOf.some((c) => hasPermission(user, c));
  const okAll = !allOf || allOf.every((c) => hasPermission(user, c));

  return okAny && okAll ? <>{children}</> : <>{fallback}</>;
}
