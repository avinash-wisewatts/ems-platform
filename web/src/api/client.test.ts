import { describe, expect, it } from "vitest";
import { apiGet, buildUrl } from "./client";
import { ContractError, NetworkError, NotAccessibleError, UnauthenticatedError } from "./errors";
import { stubFetch } from "../test-utils";

describe("apiGet", () => {
  it("sends same-origin credentials and an Accept header, and returns parsed JSON", async () => {
    const mock = stubFetch(() => ({ jsonBody: { ok: 1 } }));
    const body = await apiGet<{ ok: number }>("/sites");
    expect(body).toEqual({ ok: 1 });
    const [, init] = mock.mock.calls[0]!;
    expect(init?.method).toBe("GET");
    expect(init?.credentials).toBe("same-origin");
    expect((init?.headers as Record<string, string>).Accept).toBe("application/json");
    expect(mock.mock.calls[0]![0]).toBe("/api/v1/sites");
  });

  it("builds a query string, skipping null/undefined", async () => {
    const mock = stubFetch(() => ({ jsonBody: {} }));
    await apiGet("/spaces/s1/measurements", {
      parameter: "TEMPERATURE",
      resolution: "raw",
      from: "2026-01-01T00:00:00Z",
      to: "2026-01-02T00:00:00Z",
      unused: undefined,
    });
    expect(mock.mock.calls[0]![0]).toBe(
      "/api/v1/spaces/s1/measurements?parameter=TEMPERATURE&resolution=raw&from=2026-01-01T00%3A00%3A00Z&to=2026-01-02T00%3A00%3A00Z",
    );
  });

  it("sends an array as one repeated parameter per element, in order", async () => {
    const mock = stubFetch(() => ({ jsonBody: {} }));
    await apiGet("/sites/s1/analytics/series", {
      from: "2026-06-01T00:00:00Z",
      selection: ["a1:ENERGY_IMPORT", "a2:ENERGY_EXPORT", "a1:ENERGY_EXPORT"],
      to: "2026-06-02T00:00:00Z",
    });
    expect(mock.mock.calls[0]![0]).toBe(
      "/api/v1/sites/s1/analytics/series?from=2026-06-01T00%3A00%3A00Z" +
        "&selection=a1%3AENERGY_IMPORT&selection=a2%3AENERGY_EXPORT&selection=a1%3AENERGY_EXPORT" +
        "&to=2026-06-02T00%3A00%3A00Z",
    );
  });

  it("skips null/undefined array elements and sends nothing for an empty array", async () => {
    const mock = stubFetch(() => ({ jsonBody: {} }));
    await apiGet("/x", { selection: [], other: [null, "b", undefined, 3, false] });
    expect(mock.mock.calls[0]![0]).toBe("/api/v1/x?other=b&other=3&other=false");
  });

  it("buildUrl leaves the path alone when there is nothing to send", () => {
    expect(buildUrl("/x")).toBe("/api/v1/x");
    expect(buildUrl("/x", { a: undefined, b: [] })).toBe("/api/v1/x");
  });

  it("maps 401 -> UnauthenticatedError with the flat envelope detail", async () => {
    stubFetch(() => ({ status: 401, jsonBody: { error: "unauthenticated", detail: "Authentication is required." } }));
    await expect(apiGet("/me")).rejects.toBeInstanceOf(UnauthenticatedError);
    await expect(apiGet("/me")).rejects.toMatchObject({ code: "unauthenticated", status: 401 });
  });

  it("maps 404 -> NotAccessibleError (indistinguishable from missing)", async () => {
    stubFetch(() => ({ status: 404, jsonBody: { error: "not_found", detail: "Space not found or not accessible." } }));
    await expect(apiGet("/spaces/x/measurements")).rejects.toBeInstanceOf(NotAccessibleError);
  });

  it("maps 422 -> ContractError carrying the machine-readable code", async () => {
    stubFetch(() => ({ status: 422, jsonBody: { error: "invalid_parameter", detail: "bad" } }));
    await expect(apiGet("/spaces/x/measurements")).rejects.toBeInstanceOf(ContractError);
    await expect(apiGet("/spaces/x/measurements")).rejects.toMatchObject({
      code: "invalid_parameter",
      status: 422,
    });
  });

  it("maps a thrown fetch (offline) -> NetworkError", async () => {
    stubFetch(() => {
      throw new Error("offline");
    });
    await expect(apiGet("/sites")).rejects.toBeInstanceOf(NetworkError);
  });
});
