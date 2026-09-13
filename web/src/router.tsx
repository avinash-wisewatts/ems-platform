import type { ReactNode } from "react";
import { Navigate, Route, Routes } from "react-router-dom";
import { useSession } from "./auth/SessionProvider";
import { canUseShell } from "./auth/permissions";
import { AppLayout } from "./layout/AppLayout";
import { Bootstrap } from "./routes/Bootstrap";
import { SelectContext } from "./routes/SelectContext";
import { SiteOverview } from "./routes/SiteOverview";
import { PlaceholderArea } from "./routes/PlaceholderArea";
import { Forbidden } from "./routes/Forbidden";
import { NotFound } from "./routes/NotFound";
import { LoginRedirect } from "./routes/LoginRedirect";
import { Loading } from "./components/states/Loading";
import { SpacesList } from "./routes/spaces/SpacesList";
import { SpaceDetail } from "./routes/spaces/SpaceDetail";
import { AssetsList } from "./routes/assets/AssetsList";
import { AssetDetail } from "./routes/assets/AssetDetail";
import { EnergyOverview } from "./routes/energy/EnergyOverview";
import { DemandOverview } from "./routes/demand/DemandOverview";
import { PowerQualityOverview } from "./routes/power-quality/PowerQualityOverview";

/**
 * Foundation routes:
 *   /            session/tenant bootstrap -> redirect
 *   /select      organization / site picker
 *   /home        Site Overview & Attention (MVP-3)
 *   /features/*  honest placeholder namespace for later-phase features
 *   *            not found
 *
 * Real feature routes (Slice 0 / Slice A / Slice B), added under
 * /features/* per the foundation's own convention, without touching auth,
 * tenant context, routing shape, or layout:
 *   /features/spaces               Spaces list (Slice 0)
 *   /features/spaces/:spaceId      Space detail (Slice 0)
 *   /features/assets               Assets list (Slice 0)
 *   /features/assets/:assetId      Asset detail (Slice 0)
 *   /features/energy               Energy Overview (Slice A)
 *   /features/demand               Demand Overview (Slice B)
 *   /features/power-quality        Power Quality Overview (Slice B)
 * Specific routes are matched before the /features/* catch-all regardless
 * of declaration order (React Router v6 ranking); everything else under
 * /features/* still falls through to PlaceholderArea, honestly.
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
            <SiteOverview />
          </ShellGate>
        }
      />
      <Route
        path="/features/spaces"
        element={
          <ShellGate>
            <SpacesList />
          </ShellGate>
        }
      />
      <Route
        path="/features/spaces/:spaceId"
        element={
          <ShellGate>
            <SpaceDetail />
          </ShellGate>
        }
      />
      <Route
        path="/features/assets"
        element={
          <ShellGate>
            <AssetsList />
          </ShellGate>
        }
      />
      <Route
        path="/features/assets/:assetId"
        element={
          <ShellGate>
            <AssetDetail />
          </ShellGate>
        }
      />
      <Route
        path="/features/energy"
        element={
          <ShellGate>
            <EnergyOverview />
          </ShellGate>
        }
      />
      <Route
        path="/features/demand"
        element={
          <ShellGate>
            <DemandOverview />
          </ShellGate>
        }
      />
      <Route
        path="/features/power-quality"
        element={
          <ShellGate>
            <PowerQualityOverview />
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
