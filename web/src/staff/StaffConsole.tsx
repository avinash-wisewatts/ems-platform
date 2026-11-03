/**
 * Staff user-administration console (ADR-023 Amendment 3).
 *
 * A second, minimal entry of the EMS Web App, served by the Administration
 * App at /admin/* on the staff host: it keeps Admin -> Users available to
 * WiseWatts staff once ADR-023 stage 4 removes /app and /api/v1 from the
 * Administration App. It uses ONLY the Administration App's own endpoints --
 * /api/admin/v1/* (session probe, user management), /login and /logout -- and
 * the same Users pages as the EMS Web App.
 *
 * Access: the server already requires user.manage and GLOBAL scope before it
 * serves this bundle; the console re-checks the probe so that a session that
 * changed underneath it shows a clear message instead of a broken page.
 */
import { useEffect, useState } from "react";
import { Navigate, Route, Routes } from "react-router-dom";
import { getAdminMe, type AdminMe } from "../api/adminUsers";
import { ApiError, UnauthenticatedError } from "../api/errors";
import { ErrorState } from "../components/states/ErrorState";
import { Loading } from "../components/states/Loading";
import { UserDetailPage } from "../routes/admin/UserDetailPage";
import { UsersPage } from "../routes/admin/UsersPage";

type Probe =
  | { state: "loading" }
  | { state: "ready"; me: AdminMe }
  | { state: "not-staff" }
  | { state: "error"; message: string };

/** Navigation outside the SPA; replaceable in tests. */
export const staffBrowser = {
  assign(url: string): void {
    window.location.assign(url);
  },
};

export function staffLoginUrl(nextPath: string = window.location.pathname + window.location.search): string {
  return `/login?next_path=${encodeURIComponent(nextPath)}`;
}

async function signOut(): Promise<void> {
  try {
    await fetch("/logout", { method: "POST", credentials: "same-origin" });
  } catch {
    // best effort; redirect regardless
  }
  staffBrowser.assign("/login");
}

export function StaffConsole() {
  const [probe, setProbe] = useState<Probe>({ state: "loading" });

  useEffect(() => {
    let cancelled = false;
    getAdminMe()
      .then((me) => {
        if (cancelled) return;
        setProbe(me.is_staff && me.permissions.includes("user.manage") ? { state: "ready", me } : { state: "not-staff" });
      })
      .catch((error: unknown) => {
        if (cancelled) return;
        if (error instanceof UnauthenticatedError) {
          staffBrowser.assign(staffLoginUrl());
          return;
        }
        if (error instanceof ApiError && error.status === 403) {
          setProbe({ state: "not-staff" });
          return;
        }
        setProbe({ state: "error", message: error instanceof Error ? error.message : "The console could not load." });
      });
    return () => {
      cancelled = true;
    };
  }, []);

  if (probe.state === "loading") return <Loading label="Loading staff administration" />;
  if (probe.state === "error") return <ErrorState title="The staff console could not load" error={new Error(probe.message)} />;
  if (probe.state === "not-staff") {
    return (
      <main className="staff-console staff-console--denied" data-testid="staff-console-denied">
        <h1>Staff administration</h1>
        <p>This console is available to WiseWatts staff administrators only.</p>
        <p>
          <a href="/administration/organizations">Go to the Administration App</a>
        </p>
      </main>
    );
  }

  return (
    <div className="staff-console" data-testid="staff-console">
      <header className="staff-console__header">
        <span className="staff-console__title">WiseWatts EMS · Staff administration</span>
        <nav className="staff-console__nav" aria-label="Staff administration">
          <a href="/administration/organizations">Administration App</a>
        </nav>
        <span className="staff-console__user" data-testid="staff-console-user">
          {probe.me.display_name}
        </span>
        <button type="button" onClick={() => void signOut()} data-testid="staff-console-logout">
          Sign out
        </button>
      </header>
      <main className="staff-console__main">
        <Routes>
          <Route path="/admin/users" element={<UsersPage />} />
          <Route path="/admin/users/:portalUserId" element={<UserDetailPage />} />
          <Route path="*" element={<Navigate to="/admin/users" replace />} />
        </Routes>
      </main>
    </div>
  );
}
