/**
 * A server-generated temporary password, shown exactly once. It lives only in
 * this component's props (React state of the page that received it): it is
 * never written to storage, the URL or the console, and it is gone on
 * navigation or reload. The server keeps only its Argon2id hash.
 */

import { useState } from "react";

export function TemporaryPasswordNotice({ password }: { password: string }) {
  const [copied, setCopied] = useState<"idle" | "copied" | "failed">("idle");

  async function copy() {
    try {
      await navigator.clipboard.writeText(password);
      setCopied("copied");
    } catch {
      setCopied("failed");
    }
  }

  return (
    <div className="admin-temp-password" data-testid="temporary-password">
      <p className="admin-temp-password__label">Temporary password — shown only once</p>
      <div className="admin-temp-password__row">
        <code className="admin-temp-password__value" data-testid="temporary-password-value">
          {password}
        </code>
        <button type="button" className="analytics-button" onClick={() => void copy()}>
          {copied === "copied" ? "Copied" : "Copy"}
        </button>
      </div>
      <p className="admin-field__hint">
        Give it to the user through a secure channel. It cannot be shown again; reset the password if it is lost. Ask
        the user to change it after signing in.
        {copied === "failed" ? " Copying failed — select the text and copy it manually." : ""}
      </p>
    </div>
  );
}
