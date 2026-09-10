/**
 * Typed errors for the Phase 7 API client.
 *
 * The Phase 7 backend uses a flat error envelope: { "error": <code>,
 * "detail": <message> }. These classes preserve that so callers branch on a
 * stable machine-readable code rather than on HTTP status alone.
 */

export type ApiErrorEnvelope = {
  error: string;
  detail?: string;
};

export class ApiError extends Error {
  readonly status: number;
  readonly code: string;
  readonly detail: string;

  constructor(status: number, code: string, detail: string) {
    super(`${code} (${status})${detail ? `: ${detail}` : ""}`);
    this.name = "ApiError";
    this.status = status;
    this.code = code;
    this.detail = detail;
  }
}

/** 401 -- the portal session is missing or expired. */
export class UnauthenticatedError extends ApiError {
  constructor(detail = "Authentication is required.") {
    super(401, "unauthenticated", detail);
    this.name = "UnauthenticatedError";
  }
}

/**
 * 404 -- the site/space does not exist OR is not accessible to the caller.
 * The two are deliberately indistinguishable; never surface "exists but
 * forbidden" to the user.
 */
export class NotAccessibleError extends ApiError {
  constructor(detail = "Not found or not accessible.") {
    super(404, "not_found", detail);
    this.name = "NotAccessibleError";
  }
}

/** 422 -- the request violated the fixed API contract (client bug). */
export class ContractError extends ApiError {
  constructor(code: string, detail: string) {
    super(422, code, detail);
    this.name = "ContractError";
  }
}

/** The network failed, or the response was not valid JSON / not on-contract. */
export class NetworkError extends ApiError {
  constructor(detail: string, status = 0) {
    super(status, "network_error", detail);
    this.name = "NetworkError";
  }
}
