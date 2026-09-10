/**
 * Maps the Phase 7 no-data contract to a CALM, non-error state.
 *
 * Phase 7 returns HTTP 200 with { ..., "no_data": true, "series": [] } when a
 * space/site is accessible but the chosen range contains no data (e.g. a
 * newly-commissioned device). Per the architecture: "no data yet" is never an
 * application failure -- no red, no retry-as-if-broken.
 */

export function NoDataYet({
  message = "No data for the selected range.",
}: {
  message?: string;
}) {
  return (
    <div className="state state--no-data" role="status" data-testid="state-no-data">
      <p>{message}</p>
    </div>
  );
}
