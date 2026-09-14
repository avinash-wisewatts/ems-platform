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
 *   GET /api/v1/sites/{site_id}/energy/consumption/evidence (Slice C)
 *   GET /api/v1/sites/{site_id}/energy/consumption/typical-reference (Slice C)
 *   GET /api/v1/sites/{site_id}/telemetry-freshness (MVP-4)
 *   GET /api/v1/sites/{site_id}/alerts                (MVP-7)
 *   GET /api/v1/alerts/{alert_id}                      (MVP-7)
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
  Alert,
  AlertListResponse,
  AlertState,
  AssetsResponse,
  CurrentDemandResponse,
  CurrentUser,
  DemandSeriesResponse,
  EnergyConsumptionEvidenceResponse,
  EnergyConsumptionResponse,
  EnergyResolution,
  EnergyTypicalReferenceResponse,
  MeasurementParameter,
  MeasurementResolution,
  MeasurementSeriesResponse,
  PowerQualityResolution,
  PowerQualityResponse,
  SitesResponse,
  SiteTelemetryFreshnessResponse,
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

/** Slice C (C2). Additive parallel read of the SAME two historians
 *  getSiteEnergyConsumption reads -- does not call or replace it. */
export function getSiteEnergyConsumptionEvidence(
  siteId: string,
  query: EnergyQuery,
  init?: RequestInit,
): Promise<EnergyConsumptionEvidenceResponse> {
  return apiGet<EnergyConsumptionEvidenceResponse>(
    `/sites/${encodeURIComponent(siteId)}/energy/consumption/evidence`,
    { resolution: query.resolution, from: query.from, to: query.to },
    init,
  );
}

export type TypicalReferenceQuery = {
  from: string; // ISO-8601 UTC -- must span exactly 1, 7, 30, 90, or 365 whole days
  to: string; // ISO-8601 UTC (exclusive)
};

/** Slice C. Comparable-period historical reference (migration 236). One
 *  bounded call -- never N follow-up requests. Additive alongside, and has
 *  no dependency on, getSiteEnergyConsumptionEvidence above. */
export function getSiteEnergyTypicalReference(
  siteId: string,
  query: TypicalReferenceQuery,
  init?: RequestInit,
): Promise<EnergyTypicalReferenceResponse> {
  return apiGet<EnergyTypicalReferenceResponse>(
    `/sites/${encodeURIComponent(siteId)}/energy/consumption/typical-reference`,
    { from: query.from, to: query.to },
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

/** MVP-4 -- device connectivity/freshness, per domain. No query
 *  parameters: this is always a "right now" read. */
export function getSiteTelemetryFreshness(
  siteId: string,
  init?: RequestInit,
): Promise<SiteTelemetryFreshnessResponse> {
  return apiGet<SiteTelemetryFreshnessResponse>(
    `/sites/${encodeURIComponent(siteId)}/telemetry-freshness`,
    undefined,
    init,
  );
}

export type AlertListQuery = {
  state?: AlertState;
  condition_key?: string;
  from?: string;
  to?: string;
  limit?: number;
  before?: string; // infinite-scroll cursor: triggered_at of the last row already seen
};

/** MVP-7 (ADR-016/ADR-017). In-product only. */
export function getSiteAlerts(
  siteId: string,
  query: AlertListQuery,
  init?: RequestInit,
): Promise<AlertListResponse> {
  return apiGet<AlertListResponse>(
    `/sites/${encodeURIComponent(siteId)}/alerts`,
    {
      state: query.state,
      condition_key: query.condition_key,
      from: query.from,
      to: query.to,
      limit: query.limit,
      before: query.before,
    },
    init,
  );
}

/** MVP-7. An unknown or inaccessible alert_id resolves as NotAccessibleError,
 *  identical to every other portal-scoped resource this client reads. */
export function getAlertDetail(alertId: string, init?: RequestInit): Promise<Alert> {
  return apiGet<Alert>(`/alerts/${encodeURIComponent(alertId)}`, undefined, init);
}
