import { describe, expect, it } from "vitest";
import {
  getCurrentUser,
  getSiteEnergyConsumption,
  getSites,
  getSpaceMeasurements,
} from "./endpoints";
import { stubFetch } from "../test-utils";

describe("Phase 7 endpoint bindings", () => {
  it("getCurrentUser hits GET /api/v1/me", async () => {
    const mock = stubFetch(() => ({ jsonBody: { role_code: "ADMIN", permissions: [] } }));
    await getCurrentUser();
    expect(mock.mock.calls[0]![0]).toBe("/api/v1/me");
  });

  it("getSites hits GET /api/v1/sites", async () => {
    const mock = stubFetch(() => ({ jsonBody: { sites: [] } }));
    await getSites();
    expect(mock.mock.calls[0]![0]).toBe("/api/v1/sites");
  });

  it("getSpaceMeasurements passes exactly parameter/resolution/from/to", async () => {
    const mock = stubFetch(() => ({
      jsonBody: {
        space_id: "s1",
        parameter: "DEW_POINT",
        unit: "degC",
        resolution: "raw",
        from: "2026-06-01T00:00:00Z",
        to: "2026-06-01T06:00:00Z",
        no_data: false,
        series: [],
      },
    }));
    await getSpaceMeasurements("s 1", {
      parameter: "DEW_POINT",
      resolution: "raw",
      from: "2026-06-01T00:00:00Z",
      to: "2026-06-01T06:00:00Z",
    });
    const url = mock.mock.calls[0]![0] as string;
    expect(url).toBe(
      "/api/v1/spaces/s%201/measurements?parameter=DEW_POINT&resolution=raw&from=2026-06-01T00%3A00%3A00Z&to=2026-06-01T06%3A00%3A00Z",
    );
  });

  it("getSiteEnergyConsumption passes exactly resolution/from/to", async () => {
    const mock = stubFetch(() => ({
      jsonBody: {
        site_id: "site1",
        resolution: "1h",
        from: "2026-06-01T00:00:00Z",
        to: "2026-06-02T00:00:00Z",
        no_data: true,
        series: [],
      },
    }));
    const res = await getSiteEnergyConsumption("site1", {
      resolution: "1h",
      from: "2026-06-01T00:00:00Z",
      to: "2026-06-02T00:00:00Z",
    });
    expect(res.no_data).toBe(true);
    expect(mock.mock.calls[0]![0]).toBe(
      "/api/v1/sites/site1/energy/consumption?resolution=1h&from=2026-06-01T00%3A00%3A00Z&to=2026-06-02T00%3A00%3A00Z",
    );
  });
});
