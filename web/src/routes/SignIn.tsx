import { useEffect, useState } from "react";
import type { FormEvent } from "react";
import { Navigate, useSearchParams } from "react-router-dom";
import { browser, customerSignInAvailable, loginUrl, safeNextPath, signIn } from "../api/client";
import { useSession } from "../auth/SessionProvider";
import { Loading } from "../components/states/Loading";

const INVALID = "Invalid username or password.";
const UNAVAILABLE = "Sign-in is unavailable right now. Please try again.";

/**
 * The app's own sign-in page (ADR-023). On the customer host it signs in
 * through the customer API (POST /auth/login), whose session is separate
 * from the Administration App's. Where the app is still served through the
 * Administration App (no /auth/*), it hands over to that app's existing
 * server-rendered /login instead -- so the page works on both paths during
 * the transition. Every failure shows one generic message.
 */
export function SignIn() {
  const session = useSession();
  const [params] = useSearchParams();
  const next = safeNextPath(params.get("next"));
  const [mode, setMode] = useState<"probing" | "form">("probing");
  const [username, setUsername] = useState("");
  const [password, setPassword] = useState("");
  const [submitting, setSubmitting] = useState(false);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    let active = true;
    void customerSignInAvailable().then((available) => {
      if (!active) return;
      if (available) setMode("form");
      else browser.assign(loginUrl(`/app${next}`));
    });
    return () => {
      active = false;
    };
  }, [next]);

  if (session.status === "authenticated") return <Navigate to={next} replace />;
  if (mode === "probing") return <Loading label="Preparing sign-in…" />;

  async function onSubmit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    setSubmitting(true);
    setError(null);
    const result = await signIn(username.trim(), password);
    if (result === "ok") {
      // A full load, so the session and the accessible sites load afresh.
      browser.assign(`/app${next}`);
      return;
    }
    setPassword("");
    setError(result === "invalid" ? INVALID : UNAVAILABLE);
    setSubmitting(false);
  }

  return (
    <div className="page page--message sign-in" data-testid="page-sign-in">
      <h1>Sign in to WiseWatts EMS</h1>
      <form className="sign-in__form" onSubmit={(event) => void onSubmit(event)}>
        <label className="sign-in__field">
          <span>Username</span>
          <input
            name="username"
            type="text"
            autoComplete="username"
            value={username}
            onChange={(event) => setUsername(event.target.value)}
            required
            disabled={submitting}
          />
        </label>
        <label className="sign-in__field">
          <span>Password</span>
          <input
            name="password"
            type="password"
            autoComplete="current-password"
            value={password}
            onChange={(event) => setPassword(event.target.value)}
            required
            disabled={submitting}
          />
        </label>
        {error ? (
          <p className="sign-in__error" role="alert">
            {error}
          </p>
        ) : null}
        <button
          type="submit"
          className="analytics-button analytics-button--primary"
          disabled={submitting || !username.trim() || !password}
        >
          {submitting ? "Signing in…" : "Sign in"}
        </button>
      </form>
    </div>
  );
}
