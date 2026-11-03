/**
 * /account/password -- any signed-in portal user (ADMIN, OPERATOR, VIEWER)
 * changes their own password through the Administration App
 * (POST /api/admin/v1/me/password: current password required, refused while
 * the account is locked). Not available on the customer host, which has no
 * /api/admin route (ADR-023); the page says so instead of failing.
 */
import { useEffect, useState } from "react";
import { customerSignInAvailable } from "../../api/client";
import { Loading } from "../../components/states/Loading";
import { ChangeOwnPasswordSection } from "../admin/UserDetailPage";

let cached: Promise<boolean> | null = null;

/** True where the Administration App serves the SPA (not the customer host). Cached per page load. */
export function ownPasswordChangeAvailable(): Promise<boolean> {
  cached ??= customerSignInAvailable().then((customer) => !customer);
  return cached;
}

/** Test hook. */
export function resetOwnPasswordChangeAvailability(): void {
  cached = null;
}

export function ChangePasswordPage() {
  const [available, setAvailable] = useState<boolean | null>(null);

  useEffect(() => {
    let active = true;
    void ownPasswordChangeAvailable().then((value) => {
      if (active) setAvailable(value);
    });
    return () => {
      active = false;
    };
  }, []);

  return (
    <div className="admin-page" data-testid="account-password-page">
      <header className="admin-header">
        <div>
          <h1 className="admin-header__title">Change password</h1>
          <p className="admin-header__subtitle">You need your current password.</p>
        </div>
      </header>
      {available === null ? <Loading label="Loading" /> : null}
      {available === true ? <ChangeOwnPasswordSection /> : null}
      {available === false ? (
        <p className="admin-card" data-testid="account-password-unavailable">
          Password changes are not available here. Ask your administrator to reset your password.
        </p>
      ) : null}
    </div>
  );
}
