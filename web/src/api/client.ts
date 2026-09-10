/**
 * Minimal same-origin client for the Phase 7 /api/v1 API.
 *
 * - Sends the existing portal session cookie automatically (same-origin;
 *   `credentials: "same-origin"`). No bearer tokens, no second auth system,
 *   no CSRF token needed for these GET-only reads (SameSite=Lax + same-origin).
 * - Never talks to anything except /api/v1/*.
 * - Maps the flat Phase 7 error envelope onto typed errors.
 */

import {
  ApiError,
  ContractError,
  NetworkError,
  NotAccessibleError,
  UnauthenticatedError,
  type ApiErrorEnvelope,
} from "./errors";

const API_BASE = "/api/v1";

type QueryValue = string | number | boolean | undefined | null;

function buildUrl(path: string, query?: Record<string, QueryValue>): string {
  const url = `${API_BASE}${path}`;
  if (!query) return url;
  const params = new URLSearchParams();
  for (const [key, value] of Object.entries(query)) {
    if (value === undefined || value === null) continue;
    params.append(key, String(value));
  }
  const qs = params.toString();
  return qs ? `${url}?${qs}` : url;
}

function isEnvelope(body: unknown): body is ApiErrorEnvelope {
  return typeof body === "object" && body !== null && typeof (body as { error?: unknown }).error === "string";
}

async function toTypedError(response: Response): Promise<ApiError> {
  let body: unknown = null;
  try {
    body = await response.json();
  } catch {
    // fall through with body = null
  }
  const code = isEnvelope(body) ? body.error : "unknown";
  const detail = isEnvelope(body) && body.detail ? body.detail : response.statusText;

  switch (response.status) {
    case 401:
      return new UnauthenticatedError(detail);
    case 404:
      return new NotAccessibleError(detail);
    case 422:
      return new ContractError(code, detail);
    default:
      return new ApiError(response.status, code, detail);
  }
}

export async function apiGet<T>(
  path: string,
  query?: Record<string, QueryValue>,
  init?: RequestInit,
): Promise<T> {
  let response: Response;
  try {
    response = await fetch(buildUrl(path, query), {
      method: "GET",
      credentials: "same-origin",
      headers: { Accept: "application/json", ...(init?.headers ?? {}) },
      ...init,
    });
  } catch (cause) {
    throw new NetworkError(cause instanceof Error ? cause.message : "Request failed");
  }

  if (!response.ok) {
    throw await toTypedError(response);
  }

  try {
    return (await response.json()) as T;
  } catch {
    throw new NetworkError("The response was not valid JSON", response.status);
  }
}

/** Reuse the existing portal logout, then hand off to the existing login page. */
export async function logout(): Promise<void> {
  try {
    await fetch("/logout", { method: "POST", credentials: "same-origin" });
  } catch {
    // best effort; redirect regardless
  }
  window.location.assign(loginUrl());
}

/** URL of the existing server-rendered login page, preserving the return path. */
export function loginUrl(nextPath: string = window.location.pathname + window.location.search): string {
  return `/login?next_path=${encodeURIComponent(nextPath)}`;
}
