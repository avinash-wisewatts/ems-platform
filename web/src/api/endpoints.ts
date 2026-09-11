/**
 * The only Phase 7 / Slice 0 API calls the frontend is permitted to make.
 *
 *   GET /api/v1/me                                       (Phase 8 session echo)
 *   GET /api/v1/sites
 *   GET /api/v1/sites/{site_id}/energy/consumption
 *   GET /api/v1/spaces/{space_id}/measurements
 *   GET /api/v1/sites/{site_id}/spaces                  (Slice 0)
 *   GET /api/v1/sites/{site_id}/assets                  (Slice 0)
 *
 * No other paths, no arbitrary parameters, no generic query mechanism.
 *
 * Slice 0 scope note: getSiteAssets returns identity + placement only. It
 * does NOT expose asset_relationships (component tree) or any "spaces
 * served by an asset" concept -- neither exists as a read path yet; both
 * are explicitly deferred pending a separate product/architecture decision.
 */

import { apiGet } from "./client";
import type {
  AssetsResponse,
  CurrentUser,
  EnergyConsumptionResponse,
  EnergyResolution,
  MeasurementParameter,
  MeasurementResolution,
  MeasurementSeriesResponse,
  SitesResponse,
  SpacesResponse,
} from "./types";

export function getCurrentUser(init?: RequestInit): Promise<CurrentUser> {
  return apiGet<CurrentUser>("/me", undefined, init);
}

export function getSites(init?: RequestInit): Promise<SitesResponse> {
  return apiGet<SitesResponse>("/sites", undefined, init);
}

export type MeasurementQuery = {
  parameter: MeasurementParameter;
  resolution: MeasurementResolution;
  from: string; // ISO-8601 UTC
  to: string; // ISO-8601 UTC (exclusive)
};

export function getSpaceMeasurements(
  spaceId: string,
  query: MeasurementQuery,
  init?: RequestInit,
): Promise<MeasurementSeriesResponse> {
  return apiGet<MeasurementSeriesResponse>(
    `/spaces/${encodeURIComponent(spaceId)}/measurements`,
    { parameter: query.parameter, resolution: query.resolution, from: query.from, to: query.to },
    init,
  );
}

export type EnergyQuery = {
  resolution: EnergyResolution;
  from: string; // ISO-8601 UTC
  to: string; // ISO-8601 UTC (exclusive)
};

export function getSiteEnergyConsumption(
  siteId: string,
  query: EnergyQuery,
  init?: RequestInit,
): Promise<EnergyConsumptionResponse> {
  return apiGet<EnergyConsumptionResponse>(
    `/sites/${encodeURIComponent(siteId)}/energy/consumption`,
    { resolution: query.resolution, from: query.from, to: query.to },
    init,
  );
}

export function getSiteSpaces(siteId: string, init?: RequestInit): Promise<SpacesResponse> {
  return apiGet<SpacesResponse>(`/sites/${encodeURIComponent(siteId)}/spaces`, undefined, init);
}

export function getSiteAssets(siteId: string, init?: RequestInit): Promise<AssetsResponse> {
  return apiGet<AssetsResponse>(`/sites/${encodeURIComponent(siteId)}/assets`, undefined, init);
}
