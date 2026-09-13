/**
 * Slice 0 (Hierarchy Foundation) -- basic Space detail.
 *
 * Deliberately minimal: identity (from the already-fetched Spaces list --
 * no separate "get one space" endpoint was introduced for this) plus one
 * live reading via the already-existing, already-live
 * GET /spaces/{space_id}/measurements. A full environmental screen (trend,
 * comfort band, multiple parameters) is out of scope for this increment.
 */

import { useEffect, useMemo, useState } from "react";
import { Link, useParams } from "react-router-dom";
import { useTenant } from "../../tenant/TenantProvider";
import { getSiteSpaces, getSpaceMeasurements } from "../../api/endpoints";
import type { SpaceSummary, MeasurementPoint } from "../../api/types";
import { HierarchyCrumb } from "../../components/HierarchyCrumb";
import { Loading } from "../../components/states/Loading";
import { ErrorState } from "../../components/states/ErrorState";
import { NoDataYet } from "../../components/states/NoDataYet";
import { QualityIndicator } from "../../components/QualityIndicator";

type LoadStatus = "loading" | "ready" | "error";

function latestPoint(points: MeasurementPoint[]): MeasurementPoint | null {
  return points.length ? points[points.length - 1]! : null;
}

export function SpaceDetail() {
  const { spaceId } = useParams<{ spaceId: string }>();
  const { selectedSite, sites } = useTenant();
  const [status, setStatus] = useState<LoadStatus>("loading");
  const [error, setError] = useState<unknown>(null);
  const [space, setSpace] = useState<SpaceSummary | null>(null);
  const [temperature, setTemperature] = useState<MeasurementPoint | null>(null);
  const [noTemperatureData, setNoTemperatureData] = useState(false);

  useEffect(() => {
    if (!selectedSite || !spaceId) return;
    let active = true;
    setStatus("loading");
    setError(null);

    const to = new Date();
    const from = new Date(to.getTime() - 24 * 3600 * 1000);

    Promise.all([
      getSiteSpaces(selectedSite.site_id),
      getSpaceMeasurements(spaceId, {
        parameter: "TEMPERATURE",
        resolution: "raw",
        from: from.toISOString(),
        to: to.toISOString(),
      }),
    ])
      .then(([spacesRes, measurementsRes]) => {
        if (!active) return;
        setSpace(spacesRes.spaces.find((s) => s.space_id === spaceId) ?? null);
        setNoTemperatureData(measurementsRes.no_data);
        setTemperature(latestPoint(measurementsRes.series));
        setStatus("ready");
      })
      .catch((err: unknown) => {
        if (!active) return;
        setError(err);
        setStatus("error");
      });
    return () => {
      active = false;
    };
  }, [selectedSite, spaceId]);

  const crumbLeaf = useMemo(
    () => (space ? { label: space.space_name } : spaceId ? { label: spaceId } : null),
    [space, spaceId],
  );

  if (!selectedSite) {
    return (
      <p>
        <Link to="/select">Select a site</Link>
      </p>
    );
  }

  return (
    <div className="page page--space-detail" data-testid="page-space-detail">
      <HierarchyCrumb siteName={selectedSite.site_name} multiSite={sites.length > 1} leaf={crumbLeaf} />

      {status === "loading" ? <Loading label="Loading space…" /> : null}
      {status === "error" ? <ErrorState error={error} /> : null}

      {status === "ready" && space ? (
        <>
          <h1>{space.space_name}</h1>
          <p className="hint">{space.space_code}</p>

          <section className="space-detail-reading">
            <h2>Temperature</h2>
            {noTemperatureData || !temperature ? (
              <NoDataYet />
            ) : (
              <p data-testid="space-temperature">
                {temperature.value.toFixed(1)} °C
                <QualityIndicator code={temperature.quality} showWhenUnknown />
              </p>
            )}
          </section>
        </>
      ) : null}

      {status === "ready" && !space ? <ErrorState title="Space not found or not accessible" /> : null}
    </div>
  );
}
