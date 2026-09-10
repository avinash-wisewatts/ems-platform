import type { ReactNode } from "react";
import { Navigate, Route, Routes } from "react-router-dom";
import { useSession } from "./auth/SessionProvider";
import { canUseShell } from "./auth/permissions";
import { AppLayout } from "./layout/AppLayout";
import { Bootstrap } from "./routes/Bootstrap";
import { SelectContext } from "./routes/SelectContext";
import { ShellHome } from "./routes/ShellHome";
import { PlaceholderArea } from "./routes/PlaceholderArea";
import { Forbidden } from "./routes/Forbidden";
import { NotFound } from "./routes/NotFound";
import { LoginRedirect } from "./routes/LoginRedirect";
import { Loading } from "./components/states/Loading";

/**
 * Foundation routes only:
 *   /            session/tenant bootstrap -> redirect
 *   /select      organization / site picker
 *   /home        the empty application shell
 *   /features/*  honest placeholder namespace for later-phase features
 *   *            not found
 *
 * Later phases add feature routes under /features/* without touching auth,
 * tenant context, routing shape, or layout.
 */

/** Gate the chrome'd routes on an authenticated, shell-permitted session. */
function ShellGate({ children }: { children: ReactNode }) {
  const { status, user } = useSession();
  if (status === "loading") return <Loading label="Starting…" />;
  if (status === "unauthenticated") return <LoginRedirect />;
  if (status === "error") return <Navigate to="/" replace />;
  if (!canUseShell(user)) return <Forbidden />;
  return <AppLayout>{children}</AppLayout>;
}

export function AppRoutes() {
  return (
    <Routes>
      <Route path="/" element={<Bootstrap />} />
      <Route
        path="/select"
        element={
          <ShellGate>
            <SelectContext />
          </ShellGate>
        }
      />
      <Route
        path="/home"
        element={
          <ShellGate>
            <ShellHome />
          </ShellGate>
        }
      />
      <Route
        path="/features/*"
        element={
          <ShellGate>
            <PlaceholderArea />
          </ShellGate>
        }
      />
      <Route path="/forbidden" element={<Forbidden />} />
      <Route
        path="*"
        element={
          <ShellGate>
            <NotFound />
          </ShellGate>
        }
      />
    </Routes>
  );
}
