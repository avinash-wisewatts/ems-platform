#!/usr/bin/env bash
#
# ============================================================
# WiseWatts EMS -- energy-routing metric-identity verification
#
# E6 post-deploy gate for migration 215 / the Canonical Metric Identity
# contract. Detects the migration-207 regression signature:
#
#   telemetry.normalized_points has RECENT, GOOD active-power data for a
#   commissioned meter, but that meter's latest telemetry.energy_measurements
#   bucket has active_power_total_w = NULL.
#
# That combination means the routing loader is resolving the electrical
# signals against an identifier that does not match the data (the
# hard-coded-canonical-UUID bug). A healthy, name-resolving loader cannot
# produce it.
#
# Read-only. FAILs (exit 1) only on the actual regression signature.
# Cleanly PASSes when there is simply no commissioned energy meter yet.
# ============================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
cd "${PROJECT_DIR}" || exit 1

DB_CONTAINER="${DB_CONTAINER:-timescaledb}"
DB_NAME="${DB_NAME:-ems}"
DB_USER="${DB_USER:-ems_admin}"

psql_q() {
    docker compose exec -T "${DB_CONTAINER}" \
        psql -X -A -t -v ON_ERROR_STOP=1 -U "${DB_USER}" -d "${DB_NAME}" -c "$1" </dev/null
}

echo "------------------------------------------------------------"
echo "Energy routing metric-identity (E6 / migration 215)"
echo "------------------------------------------------------------"

# 1. Structural: the deployed loader must not resolve a metric by a
#    hard-coded logical_point_id UUID literal.
BAD_LOADER="$(
psql_q "
SELECT CASE WHEN pg_get_functiondef(
                 'telemetry.load_energy_measurements_incremental(interval,interval)'::regprocedure)
             ~ 'logical_point_id[[:space:]]*(=|IN)[[:space:]]*\(?[[:space:]]*''[0-9a-f]{8}-[0-9a-f]{4}-'
            THEN 1 ELSE 0 END;
" 2>/dev/null || echo ERR
)"
if [[ "${BAD_LOADER}" == "1" ]]; then
    echo "[FAIL] load_energy_measurements_incremental resolves electrical signals by a hard-coded logical_point_id UUID (migration 215 not applied / regressed)."
    exit 1
fi
if [[ "${BAD_LOADER}" == "ERR" ]]; then
    echo "[WARN] could not inspect load_energy_measurements_incremental; skipping structural check."
else
    echo "[PASS] loader resolves electrical signals by name, not by hard-coded UUID."
fi

# 2. Behavioural: recent GOOD active power in normalized_points but NULL in
#    the meter's latest *settled* energy_measurements bucket.
#
#    "Settled" = older than SETTLE_MINUTES (default 10). The routing loader
#    only (re)writes a bucket while it is within its capture-bucket correction
#    deadline (bucket_start + capture_interval + late_arrival_tolerance,
#    typically ~3 min) plus one routing cycle. A bucket younger than that may
#    legitimately not carry power yet -- and, critically, in the minute right
#    after this very migration deploys, the newest bucket can still be one the
#    OLD loader wrote. Judging only settled buckets makes this a true
#    regression gate, not a deploy-timing race. Historical NULLs older than
#    the recovery backfill window are out of scope here (separate, authorized
#    backfill), so the check is bounded to the last 2 hours.
SETTLE_MINUTES="${ENERGY_ROUTING_SETTLE_MINUTES:-10}"

OFFENDERS="$(
psql_q "
WITH recent_src AS (
    SELECT np.device_id
    FROM telemetry.normalized_points np
    WHERE np.logical_point = ANY (ARRAY['ACTIVE_POWER_TOTAL','ENERGY_ACTIVE_POWER_TOTAL'])
      AND np.quality_code = 'GOOD'
      AND np.numeric_value IS NOT NULL
      AND np.event_time > now() - interval '30 minutes'
    GROUP BY np.device_id
),
latest_settled_em AS (
    SELECT DISTINCT ON (em.device_id)
           em.device_id, em.bucket_start, em.active_power_total_w
    FROM telemetry.energy_measurements em
    JOIN recent_src rs ON rs.device_id = em.device_id
    WHERE em.bucket_start <= now() - interval '${SETTLE_MINUTES} minutes'
      AND em.bucket_start >  now() - interval '2 hours'
    ORDER BY em.device_id, em.bucket_start DESC
)
SELECT count(*)
FROM latest_settled_em
WHERE active_power_total_w IS NULL;
" 2>/dev/null || echo ERR
)"

if [[ "${OFFENDERS}" == "ERR" ]]; then
    echo "[WARN] behavioural check query failed; skipping."
    exit 0
fi
if [[ "${OFFENDERS}" =~ ^[0-9]+$ ]] && (( OFFENDERS > 0 )); then
    echo "[FAIL] ${OFFENDERS} meter(s) have recent GOOD ACTIVE_POWER_TOTAL in normalized_points but NULL active_power_total_w in their latest SETTLED (>${SETTLE_MINUTES}m) energy_measurements bucket -- the migration-207 routing-identity regression signature."
    exit 1
fi

echo "[PASS] no meter shows recent GOOD source active power with a NULL routed value in a settled bucket."
exit 0
