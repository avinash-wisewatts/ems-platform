/**
 * A genuine request failure (network error, backend 5xx, malformed response).
 * NOT used for "no data in range" -- that is NoDataYet and is a normal state.
 */

import { ApiError } from "../../api/errors";

export function ErrorState({
  error,
  onRetry,
  title = "Something went wrong",
}: {
  error?: unknown;
  onRetry?: () => void;
  title?: string;
}) {
  const detail =
    error instanceof ApiError
      ? error.detail || error.message
      : error instanceof Error
        ? error.message
        : undefined;

  return (
    <div className="state state--error" role="alert" data-testid="state-error">
      <p className="state__title">{title}</p>
      {detail ? <p className="state__detail">{detail}</p> : null}
      {onRetry ? (
        <button type="button" onClick={onRetry}>
          Try again
        </button>
      ) : null}
    </div>
  );
}
