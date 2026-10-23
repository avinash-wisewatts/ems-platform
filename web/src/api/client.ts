/**
 * Minimal same-origin client for the Phase 7 /api/v1 API.
 *
 * - Sends the existing portal session cookie automatically (same-origin;
 *   `credentials: "same-origin"`). No bearer tokens, no second auth system,
 *   no CSRF token needed for these GET-only reads (SameSite=Lax + same-origin).
 *   The only writes are the Reports tab's own export jobs (apiPostJson): JSON
 *   bodies, which the server requires, so a cross-site form cannot send one.
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

type QueryScalar = string | number | boolean | undefined | null;
/** A scalar, or an array sent as one repeated parameter per element, in order
 *  (e.g. Analytics `selection=...&selection=...`). Null/undefined elements
 *  are skipped; an empty array sends nothing. */
export type QueryValue = QueryScalar | readonly QueryScalar[];

export function buildUrl(path: string, query?: Record<string, QueryValue>): string {
  const url = `${API_BASE}${path}`;
  if (!query) return url;
  const params = new URLSearchParams();
  for (const [key, value] of Object.entries(query)) {
    const values = Array.isArray(value) ? value : [value];
    for (const item of values) {
      if (item === undefined || item === null) continue;
      params.append(key, String(item));
    }
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

/** POST a JSON body (the Reports tab's export jobs -- the only /api/v1 writes). */
export async function apiPostJson<T>(path: string, body: unknown, init?: RequestInit): Promise<T> {
  let response: Response;
  try {
    response = await fetch(buildUrl(path), {
      method: "POST",
      credentials: "same-origin",
      headers: { Accept: "application/json", "Content-Type": "application/json", ...(init?.headers ?? {}) },
      body: JSON.stringify(body ?? {}),
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

/** GET a file (e.g. a ZIP). The file name comes from Content-Disposition. */
export async function apiGetFile(
  path: string,
  query?: Record<string, QueryValue>,
  init?: RequestInit,
): Promise<{ blob: Blob; fileName: string | null }> {
  let response: Response;
  try {
    response = await fetch(buildUrl(path, query), { method: "GET", credentials: "same-origin", ...init });
  } catch (cause) {
    throw new NetworkError(cause instanceof Error ? cause.message : "Request failed");
  }
  if (!response.ok) {
    throw await toTypedError(response);
  }
  return { blob: await response.blob(), fileName: contentDispositionFileName(response.headers.get("Content-Disposition")) };
}

/** The file name of a Content-Disposition header (RFC 6266 filename* first). */
export function contentDispositionFileName(header: string | null): string | null {
  if (!header) return null;
  const extended = /filename\*=UTF-8''([^;]+)/i.exec(header);
  if (extended) {
    try {
      return decodeURIComponent(extended[1]!.trim());
    } catch {
      // fall through to the plain filename
    }
  }
  const plain = /filename="([^"]*)"/i.exec(header) ?? /filename=([^;]+)/i.exec(header);
  return plain ? plain[1]!.trim() : null;
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
