/**
 * The only Phase 7 / Slice 0 / Slice B API calls the frontend is permitted
 * to make.
 *
 *   GET /api/v1/me                                       (Phase 8 session echo)
 *   GET /api/v1/sites
 *   GET /api/v1/sites/{site_id}/energy/consumption
 *   GET /api/v1/spaces/{space_id}/measurements
 *   GET /api/v1/sites/{site_id}/spaces                  (Slice 0)
 *   GET /api/v1/sites/{site_id}/assets                  (Slice 0)
 *   GET /api/v1/sites/{site_id}/demand                  (Slice B)
 *   GET /api/v1/sites/{site_id}/demand/current           (Slice B)
 *   GET /api/v1/sites/{site_id}/power-quality            (Slice B)
 *
 * No other paths, no arbitrary parameters, no generic query mechanism.
 *
 * Slice 0 scope note: getSiteAssets returns identity + placement only. It
 * does NOT expose asset_relationships (component tree) or any "spaces
 * served by an asset" concept -- neither exists as a read path yet; both
 * are explicitly deferred pending a separate product/architecture decision.
 *
 * Slice B scope note: getSiteDemandSeries takes no resolution parameter --
 * the backend has no coarser persisted demand tier to select between.
 * getSitePowerQuality returns PF plus per-phase (L1/L2/L3) THD only; there
 * is no total-THD field to request or return.
 */

import { apiGet } from "./client";
import type {
  AssetsResponse,
  CurrentDemandResponse,
  CurrentUser,
  DemandSeriesResponse,
  EnergyConsumptionResponse,
  EnergyResolution,
  MeasurementParameter,
  MeasurementResolution,
  MeasurementSeriesResponse,
  PowerQualityResolution,
  PowerQualityResponse,
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

export type DemandQuery = {
  from: string; // ISO-8601 UTC
  to: string; // ISO-8601 UTC (exclusive)
};

export function getSiteDemandSeries(
  siteId: string,
  query: DemandQuery,
  init?: RequestInit,
): Promise<DemandSeriesResponse> {
  return apiGet<DemandSeriesResponse>(
    `/sites/${encodeURIComponent(siteId)}/demand`,
    { from: query.from, to: query.to },
    init,
  );
}

export function getSiteCurrentDemand(
  siteId: string,
  init?: RequestInit,
): Promise<CurrentDemandResponse> {
  return apiGet<CurrentDemandResponse>(
    `/sites/${encodeURIComponent(siteId)}/demand/current`,
    undefined,
    init,
  );
}

export type PowerQualityQuery = {
  resolution: PowerQualityResolution;
  from: string; // ISO-8601 UTC
  to: string; // ISO-8601 UTC (exclusive)
};

export function getSitePowerQuality(
  siteId: string,
  query: PowerQualityQuery,
  init?: RequestInit,
): Promise<PowerQualityResponse> {
  return apiGet<PowerQualityResponse>(
    `/sites/${encodeURIComponent(siteId)}/power-quality`,
    { resolution: query.resolution, from: query.from, to: query.to },
    init,
  );
}
