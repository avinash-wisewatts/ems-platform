#!/usr/bin/env bash
#
# ============================================================
# WiseWatts EMS Pipeline Verification
#
# Stage 1:
# Verify telemetry reaches mqtt_staging.
#
# Read-only.
# ============================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"

cd "${PROJECT_DIR}" || exit 1

source "${SCRIPT_DIR}/common.sh"

PIPELINE_CONFIG="${SCRIPT_DIR}/config/pipeline.conf"

if [[ ! -r "${PIPELINE_CONFIG}" ]]; then
    fail "Pipeline configuration is missing: ${PIPELINE_CONFIG}"
    summary
fi

MQTT_TABLE="$(get_config_value MQTT_STAGING_TABLE)"
RTDATA_VIEW="$(get_config_value RTDATA_VIEW)"
NORMALIZED_VIEW="$(get_config_value NORMALIZED_VIEW)"
NORMALIZED_TABLE="$(get_config_value NORMALIZED_TABLE)"
ENERGY_TABLE="$(get_config_value ENERGY_TABLE)"
ENVIRONMENT_TABLE="$(get_config_value ENVIRONMENT_TABLE)"
PIPELINE_STATE_TABLE="$(get_config_value PIPELINE_STATE_TABLE)"

if [[ -z "${MQTT_TABLE}" ||
      -z "${RTDATA_VIEW}" ||
      -z "${NORMALIZED_VIEW}" ||
      -z "${NORMALIZED_TABLE}" ||
      -z "${ENERGY_TABLE}" ||
      -z "${ENVIRONMENT_TABLE}" ||
      -z "${PIPELINE_STATE_TABLE}" ]]; then
    fail "One or more pipeline configuration values are missing"
    summary
fi

pass "Pipeline configuration loaded"
print_header
print_section "Telemetry Pipeline"

#
# PostgreSQL Connectivity
#

if psql_query "SELECT 1;" >/dev/null 2>&1; then
    pass "PostgreSQL connection succeeded"
else
    fail "Cannot connect to PostgreSQL"
    summary
fi

#
# MQTT staging count
#

STAGING_COUNT="$(
psql_query "
SELECT COUNT(*)
FROM ${MQTT_TABLE};
" 2>/dev/null || echo 0
)"

if [[ "$STAGING_COUNT" =~ ^[0-9]+$ ]] && (( STAGING_COUNT > 0 )); then
    pass "mqtt_staging contains ${STAGING_COUNT} messages"
else
    fail "mqtt_staging is empty"
fi

#
# Latest telemetry
#

LATEST_STAGING="$(
psql_query "
SELECT MAX(received_at)
FROM ${MQTT_TABLE};
" 2>/dev/null
)"

if [[ -n "$LATEST_STAGING" ]]; then
    pass "Latest MQTT message: ${LATEST_STAGING}"
else
    fail "Unable to determine latest MQTT message"
fi


#
# MQTT ingestion timestamp contract
#
# Telegraf writes an absolute ingestion instant. The landing table and both
# parsing views must expose TIMESTAMPTZ so database session time zones cannot
# shift arrival timestamps or pipeline checkpoints.
#

print_section "MQTT Timestamp Contract"

TIMESTAMPTZ_CONTRACT_COUNT="$(
    psql_query "
        SELECT COUNT(*)
        FROM information_schema.columns
        WHERE (
                table_schema = 'public'
                AND table_name = 'mqtt_staging'
                AND column_name = 'received_at'
                AND data_type = 'timestamp with time zone'
              )
           OR (
                table_schema = 'telemetry'
                AND table_name = 'v_rtdata'
                AND column_name = 'received_at'
                AND data_type = 'timestamp with time zone'
              )
           OR (
                table_schema = 'telemetry'
                AND table_name = 'v_normalized_points'
                AND column_name = 'received_at'
                AND data_type = 'timestamp with time zone'
              );
    " 2>/dev/null || echo 0
)"

if [[ "${TIMESTAMPTZ_CONTRACT_COUNT}" == "3" ]]; then
    pass "MQTT landing and parsing views expose TIMESTAMPTZ"
else
    fail "MQTT timestamp contract is invalid: expected 3 TIMESTAMPTZ columns, found ${TIMESTAMPTZ_CONTRACT_COUNT}"
fi

LATEST_INGESTION_AGE_SECONDS="$(
    psql_query "
        SELECT
            CASE
                WHEN MAX(received_at) IS NULL
                    THEN NULL
                ELSE GREATEST(
                    0,
                    FLOOR(
                        EXTRACT(
                            EPOCH FROM (
                                clock_timestamp() - MAX(received_at)
                            )
                        )
                    )::BIGINT
                )
            END
        FROM ${MQTT_TABLE};
    " 2>/dev/null || true
)"

if [[ "${LATEST_INGESTION_AGE_SECONDS}" =~ ^[0-9]+$ ]]; then
    pass "Latest MQTT ingestion age: ${LATEST_INGESTION_AGE_SECONDS} seconds"

    if (( LATEST_INGESTION_AGE_SECONDS > 600 )); then
        warn "No MQTT landing row has arrived within the last 10 minutes"
    fi
else
    fail "Unable to calculate latest MQTT ingestion age"
fi

FUTURE_STAGING_ROWS="$(
    psql_query "
        SELECT COUNT(*)
        FROM ${MQTT_TABLE}
        WHERE received_at > clock_timestamp() + interval '5 minutes';
    " 2>/dev/null || echo 0
)"

if [[ "${FUTURE_STAGING_ROWS}" == "0" ]]; then
    pass "No MQTT landing timestamps are unexpectedly in the future"
else
    fail "MQTT landing timestamps more than five minutes in the future: ${FUTURE_STAGING_ROWS}"
fi

print_section "Normalization Stage"

NORMALIZED_COUNT="$(
    psql_query "
        SELECT COUNT(*)
        FROM ${NORMALIZED_TABLE};
    " 2>/dev/null || echo 0
)"

if [[ "${NORMALIZED_COUNT}" =~ ^[0-9]+$ ]] &&
   (( NORMALIZED_COUNT > 0 )); then
    pass "normalized_points contains ${NORMALIZED_COUNT} rows"
else
    fail "normalized_points is empty"
fi

LATEST_NORMALIZED_EVENT="$(
    psql_query "
        SELECT MAX(event_time)
        FROM ${NORMALIZED_TABLE};
    " 2>/dev/null || true
)"

if [[ -n "${LATEST_NORMALIZED_EVENT}" ]]; then
    pass "Latest normalized event: ${LATEST_NORMALIZED_EVENT}"
else
    fail "Unable to determine latest normalized event"
fi

LATEST_NORMALIZED_CREATED="$(
    psql_query "
        SELECT MAX(created_at)
        FROM ${NORMALIZED_TABLE};
    " 2>/dev/null || true
)"

if [[ -n "${LATEST_NORMALIZED_CREATED}" ]]; then
    pass "Latest normalization insert: ${LATEST_NORMALIZED_CREATED}"
else
    fail "Unable to determine latest normalization insert"
fi

DUPLICATE_NORMALIZED_KEYS="$(
    psql_query "
        SELECT COUNT(*)
        FROM (
            SELECT
                event_time,
                device_id,
                logical_point_id
            FROM ${NORMALIZED_TABLE}
            GROUP BY
                event_time,
                device_id,
                logical_point_id
            HAVING COUNT(*) > 1
        ) duplicates;
    " 2>/dev/null || echo 0
)"

if [[ "${DUPLICATE_NORMALIZED_KEYS}" == "0" ]]; then
    pass "No duplicate normalized business keys detected"
else
    fail "Duplicate normalized business keys detected: ${DUPLICATE_NORMALIZED_KEYS}"
fi

print_section "Pipeline Checkpoints"

PIPELINE_STATE_COUNT="$(
    psql_query "
        SELECT COUNT(*)
        FROM ${PIPELINE_STATE_TABLE};
    " 2>/dev/null || echo 0
)"

if [[ "${PIPELINE_STATE_COUNT}" =~ ^[0-9]+$ ]] &&
   (( PIPELINE_STATE_COUNT > 0 )); then
    pass "Pipeline state rows discovered: ${PIPELINE_STATE_COUNT}"
else
    fail "No pipeline state rows were found"
fi

FAILED_PIPELINES="$(
    psql_query "
        SELECT COUNT(*)
        FROM ${PIPELINE_STATE_TABLE}
        WHERE last_status <> 'SUCCESS';
    " 2>/dev/null || echo 0
)"

if [[ "${FAILED_PIPELINES}" == "0" ]]; then
    pass "All pipeline stages report SUCCESS"
else
    fail "Pipeline stages not reporting SUCCESS: ${FAILED_PIPELINES}"
fi

PIPELINES_WITH_ERRORS="$(
    psql_query "
        SELECT COUNT(*)
        FROM ${PIPELINE_STATE_TABLE}
        WHERE NULLIF(BTRIM(last_error), '') IS NOT NULL;
    " 2>/dev/null || echo 0
)"

if [[ "${PIPELINES_WITH_ERRORS}" == "0" ]]; then
    pass "No pipeline error messages are recorded"
else
    fail "Pipeline stages with recorded errors: ${PIPELINES_WITH_ERRORS}"
fi

INCOMPLETE_PIPELINES="$(
    psql_query "
        SELECT COUNT(*)
        FROM ${PIPELINE_STATE_TABLE}
        WHERE last_started_at IS NOT NULL
          AND (
              last_completed_at IS NULL
              OR last_completed_at < last_started_at
          );
    " 2>/dev/null || echo 0
)"

if [[ "${INCOMPLETE_PIPELINES}" == "0" ]]; then
    pass "No pipeline stages appear incomplete"
else
    fail "Incomplete pipeline stages detected: ${INCOMPLETE_PIPELINES}"
fi

STALE_PIPELINES="$(
    psql_query "
        SELECT COUNT(*)
        FROM ${PIPELINE_STATE_TABLE}
        WHERE last_completed_at IS NULL
           OR last_completed_at < now() - interval '10 minutes';
    " 2>/dev/null || echo 0
)"

if [[ "${STALE_PIPELINES}" == "0" ]]; then
    pass "All pipeline stages completed within the last 10 minutes"
else
    warn "Pipeline stages not completed within the last 10 minutes: ${STALE_PIPELINES}"
fi


NORMALIZATION_CHECKPOINT_AHEAD="$(
    psql_query "
        SELECT COUNT(*)
        FROM ${PIPELINE_STATE_TABLE} ps
        CROSS JOIN (
            SELECT MAX(received_at) AS newest_landing
            FROM ${MQTT_TABLE}
        ) source
        WHERE ps.pipeline_name = 'normalized_points'
          AND ps.last_received_at IS NOT NULL
          AND source.newest_landing IS NOT NULL
          AND ps.last_received_at > source.newest_landing;
    " 2>/dev/null || echo 0
)"

if [[ "${NORMALIZATION_CHECKPOINT_AHEAD}" == "0" ]]; then
    pass "Normalization checkpoint does not exceed the MQTT landing maximum"
else
    fail "Normalization checkpoint is ahead of the MQTT landing source"
fi

NORMALIZATION_CHECKPOINT_LAG_SECONDS="$(
    psql_query "
        SELECT
            CASE
                WHEN ps.last_received_at IS NULL
                  OR source.newest_landing IS NULL
                    THEN NULL
                ELSE GREATEST(
                    0,
                    FLOOR(
                        EXTRACT(
                            EPOCH FROM (
                                source.newest_landing -
                                ps.last_received_at
                            )
                        )
                    )::BIGINT
                )
            END
        FROM ${PIPELINE_STATE_TABLE} ps
        CROSS JOIN (
            SELECT MAX(received_at) AS newest_landing
            FROM ${MQTT_TABLE}
        ) source
        WHERE ps.pipeline_name = 'normalized_points';
    " 2>/dev/null || true
)"

if [[ "${NORMALIZATION_CHECKPOINT_LAG_SECONDS}" =~ ^[0-9]+$ ]]; then
    pass "Normalization checkpoint lag: ${NORMALIZATION_CHECKPOINT_LAG_SECONDS} seconds"

    if (( NORMALIZATION_CHECKPOINT_LAG_SECONDS > 600 )); then
        warn "Normalization checkpoint trails MQTT landing by more than 10 minutes"
    fi
else
    fail "Unable to calculate normalization checkpoint lag"
fi

print_section "Checkpoint Details"

while IFS='|' read -r pipeline_name last_status last_received_at last_completed_at inserted_rows; do
    [[ -z "${pipeline_name}" ]] && continue

    echo "  ${pipeline_name}"
    echo "    status          : ${last_status}"
    echo "    checkpoint      : ${last_received_at:-not set}"
    echo "    last completed  : ${last_completed_at:-not set}"
    echo "    inserted rows   : ${inserted_rows:-0}"
done < <(
    psql_query "
        SELECT
            pipeline_name,
            last_status,
            COALESCE(last_received_at::text, ''),
            COALESCE(last_completed_at::text, ''),
            last_inserted_rows
        FROM ${PIPELINE_STATE_TABLE}
        ORDER BY pipeline_name;
    " 2>/dev/null || true
)

print_section "Energy Measurement Stage"

ENERGY_COUNT="$(
    psql_query "
        SELECT COUNT(*)
        FROM ${ENERGY_TABLE};
    " 2>/dev/null || echo 0
)"

if [[ "${ENERGY_COUNT}" =~ ^[0-9]+$ ]] &&
   (( ENERGY_COUNT > 0 )); then
    pass "energy_measurements contains ${ENERGY_COUNT} rows"
else
    fail "energy_measurements is empty"
fi

LATEST_ENERGY_RECEIVED="$(
    psql_query "
        SELECT MAX(received_at)
        FROM ${ENERGY_TABLE};
    " 2>/dev/null || true
)"

if [[ -n "${LATEST_ENERGY_RECEIVED}" ]]; then
    pass "Latest energy measurement received_at: ${LATEST_ENERGY_RECEIVED}"
else
    fail "Unable to determine latest energy measurement"
fi

LATEST_ENERGY_SOURCE="$(
    psql_query "
        SELECT MAX(source_timestamp)
        FROM ${ENERGY_TABLE}
        WHERE source_timestamp IS NOT NULL;
    " 2>/dev/null || true
)"

if [[ -n "${LATEST_ENERGY_SOURCE}" ]]; then
    pass "Latest energy source timestamp: ${LATEST_ENERGY_SOURCE}"
else
    warn "No source timestamps are present in energy_measurements"
fi

DUPLICATE_ENERGY_KEYS="$(
    psql_query "
        SELECT COUNT(*)
        FROM (
            SELECT
                received_at,
                device_id
            FROM ${ENERGY_TABLE}
            GROUP BY
                received_at,
                device_id
            HAVING COUNT(*) > 1
        ) duplicates;
    " 2>/dev/null || echo 0
)"

if [[ "${DUPLICATE_ENERGY_KEYS}" == "0" ]]; then
    pass "No duplicate energy measurement business keys detected"
else
    fail "Duplicate energy measurement business keys detected: ${DUPLICATE_ENERGY_KEYS}"
fi

NULL_DEVICE_ROWS="$(
    psql_query "
        SELECT COUNT(*)
        FROM ${ENERGY_TABLE}
        WHERE device_id IS NULL;
    " 2>/dev/null || echo 0
)"

if [[ "${NULL_DEVICE_ROWS}" == "0" ]]; then
    pass "All energy measurements are linked to a device"
else
    fail "Energy measurements without device linkage: ${NULL_DEVICE_ROWS}"
fi

NULL_ORGANIZATION_ROWS="$(
    psql_query "
        SELECT COUNT(*)
        FROM ${ENERGY_TABLE}
        WHERE organization_id IS NULL;
    " 2>/dev/null || echo 0
)"

if [[ "${NULL_ORGANIZATION_ROWS}" == "0" ]]; then
    pass "All energy measurements are linked to an organization"
else
    fail "Energy measurements without organization linkage: ${NULL_ORGANIZATION_ROWS}"
fi

NULL_SITE_ROWS="$(
    psql_query "
        SELECT COUNT(*)
        FROM ${ENERGY_TABLE}
        WHERE site_id IS NULL;
    " 2>/dev/null || echo 0
)"

if [[ "${NULL_SITE_ROWS}" == "0" ]]; then
    pass "All energy measurements are linked to a site"
else
    fail "Energy measurements without site linkage: ${NULL_SITE_ROWS}"
fi

print_section "Environment Measurement Stage"

ENVIRONMENT_COUNT="$(
    psql_query "
        SELECT COUNT(*)
        FROM ${ENVIRONMENT_TABLE};
    " 2>/dev/null || echo 0
)"

if [[ "${ENVIRONMENT_COUNT}" =~ ^[0-9]+$ ]] &&
   (( ENVIRONMENT_COUNT > 0 )); then
    pass "environment_measurements contains ${ENVIRONMENT_COUNT} rows"
else
    fail "environment_measurements is empty"
fi

LATEST_ENVIRONMENT_RECEIVED="$(
    psql_query "
        SELECT MAX(received_at)
        FROM ${ENVIRONMENT_TABLE};
    " 2>/dev/null || true
)"

if [[ -n "${LATEST_ENVIRONMENT_RECEIVED}" ]]; then
    pass "Latest environment measurement received_at: ${LATEST_ENVIRONMENT_RECEIVED}"
else
    fail "Unable to determine latest environment measurement"
fi

LATEST_ENVIRONMENT_SOURCE="$(
    psql_query "
        SELECT MAX(source_timestamp)
        FROM ${ENVIRONMENT_TABLE}
        WHERE source_timestamp IS NOT NULL;
    " 2>/dev/null || true
)"

if [[ -n "${LATEST_ENVIRONMENT_SOURCE}" ]]; then
    pass "Latest environment source timestamp: ${LATEST_ENVIRONMENT_SOURCE}"
else
    warn "No source timestamps are present in environment_measurements"
fi

DUPLICATE_ENVIRONMENT_KEYS="$(
    psql_query "
        SELECT COUNT(*)
        FROM (
            SELECT
                received_at,
                device_id
            FROM ${ENVIRONMENT_TABLE}
            WHERE device_id IS NOT NULL
            GROUP BY
                received_at,
                device_id
            HAVING COUNT(*) > 1
        ) duplicates;
    " 2>/dev/null || echo 0
)"

if [[ "${DUPLICATE_ENVIRONMENT_KEYS}" == "0" ]]; then
    pass "No duplicate environment measurement business keys detected"
else
    fail "Duplicate environment measurement business keys detected: ${DUPLICATE_ENVIRONMENT_KEYS}"
fi

NULL_ENVIRONMENT_ORGANIZATIONS="$(
    psql_query "
        SELECT COUNT(*)
        FROM ${ENVIRONMENT_TABLE}
        WHERE organization_id IS NULL;
    " 2>/dev/null || echo 0
)"

if [[ "${NULL_ENVIRONMENT_ORGANIZATIONS}" == "0" ]]; then
    pass "All environment measurements are linked to an organization"
else
    fail "Environment measurements without organization linkage: ${NULL_ENVIRONMENT_ORGANIZATIONS}"
fi

UNLINKED_ENVIRONMENT_ROWS="$(
    psql_query "
        SELECT COUNT(*)
        FROM ${ENVIRONMENT_TABLE}
        WHERE gateway_id IS NULL
          AND device_id IS NULL
          AND asset_id IS NULL;
    " 2>/dev/null || echo 0
)"

if [[ "${UNLINKED_ENVIRONMENT_ROWS}" == "0" ]]; then
    pass "All environment measurements have source linkage"
else
    fail "Environment measurements without gateway, device, or asset linkage: ${UNLINKED_ENVIRONMENT_ROWS}"
fi

EMPTY_ENVIRONMENT_MEASUREMENTS="$(
    psql_query "
        SELECT COUNT(*)
        FROM ${ENVIRONMENT_TABLE}
        WHERE temperature_c IS NULL
          AND humidity_percent IS NULL
          AND pressure_hpa IS NULL
          AND co2_ppm IS NULL
          AND voc_ppb IS NULL
          AND battery_voltage_v IS NULL
          AND signal_strength_dbm IS NULL
          AND illuminance_lux IS NULL
          AND occupancy_activity IS NULL;
    " 2>/dev/null || echo 0
)"

if [[ "${EMPTY_ENVIRONMENT_MEASUREMENTS}" == "0" ]]; then
    pass "All environment rows contain at least one measurement"
else
    fail "Environment rows without measurement values: ${EMPTY_ENVIRONMENT_MEASUREMENTS}"
fi

MISSING_ENVIRONMENT_DEVICE_ROWS="$(
    psql_query "
        SELECT COUNT(*)
        FROM ${ENVIRONMENT_TABLE}
        WHERE device_id IS NULL;
    " 2>/dev/null || echo 0
)"

if [[ "${MISSING_ENVIRONMENT_DEVICE_ROWS}" == "0" ]]; then
    pass "All environment measurements are linked to a device"
else
    warn "Environment measurements without device linkage: ${MISSING_ENVIRONMENT_DEVICE_ROWS}"
fi

summary
