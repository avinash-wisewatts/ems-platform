/**
 * Data quality (F6): the applied query's conditions in seven fixed groups
 * (README "Data quality"; ADR-022 Amendments 6 and 7). "Series not shown in
 * chart" is always expanded, repeated reasons grouped with a count; the other groups are collapsed with heading and count
 * visible, unless a group is the only one present. Absent when no condition
 * applies (general rule). Remount per Update to reset the expansion (DQ9).
 */
import { useMemo } from "react";
import type { AnalyticsCatalogResponse } from "../../api/types";
import { buildDataQuality, type DataQualityGroup } from "./analyticsDataQualityModel";
import type { AppliedQuery } from "./useAnalyticsState";

/** "Series not shown in chart": a reason shared by several selections is one
 *  line with a count, expandable to the selections in selection order
 *  (ADR-022 Amendment 7, decision 3); a reason with one selection lists it. */
function NotShownBody({ group }: { group: DataQualityGroup }) {
  return (
    <div className="analytics-dq__body">
      <ul className="analytics-dq__entries">
        {(group.reasonGroups ?? []).map((reason) =>
          reason.entries.length === 1 ? (
            <li key={reason.key} className="analytics-dq__entry" data-testid="analytics-dq-entry">
              <span className="analytics-dq__series">{reason.entries[0]!.name}</span>
              {reason.lines.map((line, i) => (
                <span key={i} className="analytics-dq__line">
                  {line}
                </span>
              ))}
            </li>
          ) : (
            <li key={reason.key} className="analytics-dq__entry" data-testid="analytics-dq-reason-group">
              <details className="analytics-dq__reason">
                <summary>
                  {reason.lines.map((line, i) => (
                    <span key={i} className="analytics-dq__line analytics-dq__line--reason">
                      {line}
                    </span>
                  ))}
                  <span className="analytics-dq__count">{reason.entries.length} selections</span>
                </summary>
                <ul className="analytics-dq__names">
                  {reason.entries.map((entry) => (
                    <li key={entry.key} data-testid="analytics-dq-entry">
                      {entry.name}
                    </li>
                  ))}
                </ul>
              </details>
            </li>
          ),
        )}
      </ul>
    </div>
  );
}

function GroupBody({ group }: { group: DataQualityGroup }) {
  return (
    <div className="analytics-dq__body">
      {group.explanation.map((text) => (
        <p key={text} className="analytics-dq__explanation">
          {text}
        </p>
      ))}
      <ul className="analytics-dq__entries">
        {group.entries.map((entry) => (
          <li key={entry.key} className="analytics-dq__entry" data-testid="analytics-dq-entry">
            <span className="analytics-dq__series">{entry.name}</span>
            {entry.lines.map((line, i) => (
              <span key={i} className="analytics-dq__line">
                {line}
              </span>
            ))}
          </li>
        ))}
      </ul>
    </div>
  );
}

export function AnalyticsDataQuality({
  applied,
  catalog,
  timeZone,
}: {
  applied: AppliedQuery;
  catalog: AnalyticsCatalogResponse | null;
  timeZone: string | null | undefined;
}) {
  const groups = useMemo(
    () =>
      buildDataQuality(
        {
          unavailable: applied.unavailable,
          order: applied.draft.assetIds.flatMap((assetId) => applied.draft.dataPoints.map((dataPoint) => ({ assetId, dataPoint }))),
          response: applied.response,
        },
        catalog,
        timeZone,
      ),
    [applied, catalog, timeZone],
  );
  if (groups.length === 0) return null;
  const onlyOne = groups.length === 1;
  return (
    <section className="analytics-card analytics-dq" data-testid="analytics-data-quality" aria-labelledby="analytics-dq-heading">
      <h2 id="analytics-dq-heading" className="analytics-card__title">
        Data quality
      </h2>
      {groups.map((group) =>
        group.id === "not-shown" ? (
          <section key={group.id} className="analytics-dq__group" data-testid={`analytics-dq-${group.id}`} aria-label={group.heading}>
            <h3 className="analytics-dq__heading">{group.heading}</h3>
            <NotShownBody group={group} />
          </section>
        ) : (
          <details key={group.id} className="analytics-dq__group" data-testid={`analytics-dq-${group.id}`} open={onlyOne}>
            <summary className="analytics-dq__heading">{group.heading}</summary>
            <GroupBody group={group} />
          </details>
        ),
      )}
    </section>
  );
}
