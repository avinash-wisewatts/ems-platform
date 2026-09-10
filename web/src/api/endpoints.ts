/**
 * The only Phase 7 API calls the frontend is permitted to make.
 *
 *   GET /api/v1/me                                       (Phase 8 session echo)
 *   GET /api/v1/sites
 *   GET /api/v1/sites/{site_id}/energy/consumption
 *   GET /api/v1/spaces/{space_id}/measurements
 *
 * No other paths, no arbitrary parameters, no generic query mechanism.
 */

import { apiGet } from "./client";
import type {
  CurrentUser,
  EnergyConsumptionResponse,
  EnergyResolution,
  MeasurementParameter,
  MeasurementResolution,
  MeasurementSeriesResponse,
  SitesResponse,
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
