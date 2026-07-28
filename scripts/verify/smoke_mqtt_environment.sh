#!/usr/bin/env bash
# =============================================================================
# WiseWatts EMS — Live MQTT Environment Pipeline Smoke Test
#
# Validates:
#   HiveMQ -> Telegraf -> public.mqtt_staging
#   -> telemetry.normalized_points
#   -> telemetry.environment_measurements
#
# This script publishes one synthetic Air Sense message using an existing
# mapped device. It does not modify metadata or delete telemetry.
# =============================================================================

set -Eeuo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
COMPOSE_FILE="${PROJECT_ROOT}/compose.yaml"
TELEGRAF_ENV="${PROJECT_ROOT}/telegraf/.env"

TEST_TOPIC="${SMOKE_ENV_MQTT_TOPIC:-testeniscope/chillerroom/chiller}"
TEST_UID="${SMOKE_ENV_DEVICE_UID:-80:34:28:16:09:EB:05:01}"
TIMEOUT_SECONDS="${SMOKE_TIMEOUT_SECONDS:-180}"
POLL_SECONDS="${SMOKE_POLL_SECONDS:-5}"

PAYLOAD_FILE=""
TEST_TS=""
TEST_TEMPERATURE=""
TEST_HUMIDITY=""
TEST_ILLUMINANCE=""
TEST_OCCUPANCY=""
TEST_BATTERY=""

pass() {
    printf '[PASS] %s\n' "$1"
}

fail() {
    printf '[FAIL] %s\n' "$1" >&2
    exit 1
}

info() {
    printf '[INFO] %s\n' "$1"
}

cleanup() {
    if [[ -n "${PAYLOAD_FILE}" && -f "${PAYLOAD_FILE}" ]]; then
        rm -f "${PAYLOAD_FILE}"
    fi

    unset MQTT_PASSWORD MQTT_USERNAME MQTT_HOST MQTT_PORT MQTT_TOPIC
}

trap cleanup EXIT

psql_scalar() {
    local sql="$1"

    docker compose \
        -f "${COMPOSE_FILE}" \
        exec -T timescaledb \
        psql \
            -X \
            -At \
            -v ON_ERROR_STOP=1 \
            -U ems_admin \
            -d ems \
            -c "${sql}"
}

wait_for_value() {
    local description="$1"
    local sql="$2"
    local expected="$3"
    local elapsed=0
    local actual=""

    while (( elapsed <= TIMEOUT_SECONDS )); do
        actual="$(psql_scalar "${sql}")"

        if [[ "${actual}" == "${expected}" ]]; then
            pass "${description}"
            return 0
        fi

        sleep "${POLL_SECONDS}"
        elapsed=$((elapsed + POLL_SECONDS))
    done

    printf '[DEBUG] Expected: %s\n' "${expected}" >&2
    printf '[DEBUG] Actual  : %s\n' "${actual}" >&2
    fail "${description} did not complete within ${TIMEOUT_SECONDS} seconds"
}

cd "${PROJECT_ROOT}"

[[ -f "${COMPOSE_FILE}" ]] ||
    fail "Compose file not found: ${COMPOSE_FILE}"

[[ -f "${TELEGRAF_ENV}" ]] ||
    fail "Telegraf environment file not found: ${TELEGRAF_ENV}"

command -v mosquitto_pub >/dev/null 2>&1 ||
    fail "mosquitto_pub is not installed"

docker compose -f "${COMPOSE_FILE}" ps --status running timescaledb |
    grep -q 'ems-timescaledb' ||
    fail "TimescaleDB container is not running"

docker compose -f "${COMPOSE_FILE}" ps --status running telegraf |
    grep -q 'ems-telegraf' ||
    fail "Telegraf container is not running"

set -a
# shellcheck disable=SC1090
source "${TELEGRAF_ENV}"
set +a

: "${MQTT_HOST:?MQTT_HOST is missing from telegraf/.env}"
: "${MQTT_PORT:?MQTT_PORT is missing from telegraf/.env}"
: "${MQTT_USERNAME:?MQTT_USERNAME is missing from telegraf/.env}"
: "${MQTT_PASSWORD:?MQTT_PASSWORD is missing from telegraf/.env}"

DEVICE_ID="$(
    psql_scalar "
        SELECT d.id
        FROM metadata.devices d
        JOIN metadata.device_identifiers di
          ON di.device_id = d.id
        WHERE di.identifier_type = 'MQTT_UID'
          AND lower(di.identifier_value) = lower('${TEST_UID}')
        LIMIT 1;
    "
)"

[[ -n "${DEVICE_ID}" ]] ||
    fail "No device mapping exists for MQTT UID ${TEST_UID}"

DEVICE_DETAILS="$(
    psql_scalar "
        SELECT
            d.name || '|' ||
            COALESCE(dp.profile_code, '')
        FROM metadata.devices d
        LEFT JOIN config.device_profiles dp
          ON dp.id = d.profile_id
        WHERE d.id = '${DEVICE_ID}'::uuid;
    "
)"

DEVICE_NAME="${DEVICE_DETAILS%%|*}"
PROFILE_CODE="${DEVICE_DETAILS#*|}"

[[ "${PROFILE_CODE}" == "ENVIRONMENT_SENSOR_AIRSENSE_V1" ]] ||
    fail "Unexpected Air Sense profile: ${PROFILE_CODE}"

MAPPING_COUNT="$(
    psql_scalar "
        SELECT count(*)::text
        FROM config.profile_field_mapping
        WHERE profile_id = (
            SELECT profile_id
            FROM metadata.devices
            WHERE id = '${DEVICE_ID}'::uuid
        )
          AND raw_field_name IN ('T1', 'RH', 'LL', 'PIR', 'Vbat');
    "
)"

[[ "${MAPPING_COUNT}" == "5" ]] ||
    fail "Expected five Air Sense field mappings, found ${MAPPING_COUNT}"

TEST_TS="$(date +%s)"

# Generate unique but operationally plausible values.
TEST_TEMPERATURE="$(
    awk -v ts="${TEST_TS}" \
        'BEGIN { printf "%.3f", 20 + ((ts % 900) / 100.0) }'
)"

TEST_HUMIDITY="$(
    awk -v ts="${TEST_TS}" \
        'BEGIN { printf "%.3f", 40 + ((ts % 1500) / 100.0) }'
)"

TEST_ILLUMINANCE="$((200 + TEST_TS % 500))"
TEST_OCCUPANCY="$((600 + TEST_TS % 300))"

TEST_BATTERY="$(
    awk -v ts="${TEST_TS}" \
        'BEGIN { printf "%.3f", 3.5 + ((ts % 90) / 1000.0) }'
)"

PAYLOAD_FILE="$(mktemp /tmp/ems-environment-smoke-XXXXXX.json)"

cat > "${PAYLOAD_FILE}" <<JSON
{
  "rtdata": [
    {
      "C": 0,
      "LL": ${TEST_ILLUMINANCE},
      "RH": ${TEST_HUMIDITY},
      "T1": ${TEST_TEMPERATURE},
      "hi": 2150901782,
      "lo": 166397185,
      "ts": ${TEST_TS},
      "PIR": ${TEST_OCCUPANCY},
      "did": "04",
      "fmt": 1526595607,
      "uid": "${TEST_UID}",
      "Stat": 36,
      "Vbat": ${TEST_BATTERY},
      "ain1": 0.001,
      "ain2": 0.001,
      "ain3": 0,
      "ain4": 0.001,
      "dis1": 0,
      "PIR_t": 485100,
      "hi_id2": 334728,
      "lo_id2": 10570
    }
  ]
}
JSON

python3 -m json.tool "${PAYLOAD_FILE}" >/dev/null ||
    fail "Generated payload is not valid JSON"

info "Device       : ${DEVICE_NAME}"
info "Device UID   : ${TEST_UID}"
info "Device ID    : ${DEVICE_ID}"
info "Profile      : ${PROFILE_CODE}"
info "MQTT topic   : ${TEST_TOPIC}"
info "Source epoch : ${TEST_TS}"
info "Temperature  : ${TEST_TEMPERATURE} degC"
info "Humidity     : ${TEST_HUMIDITY} %"
info "Illuminance  : ${TEST_ILLUMINANCE} lux"
info "Occupancy    : ${TEST_OCCUPANCY}"
info "Battery      : ${TEST_BATTERY} V"

mosquitto_pub \
    -h "${MQTT_HOST}" \
    -p "${MQTT_PORT}" \
    --cafile /etc/ssl/certs/ca-certificates.crt \
    -V mqttv311 \
    -q 1 \
    -t "${TEST_TOPIC}" \
    -u "${MQTT_USERNAME}" \
    -P "${MQTT_PASSWORD}" \
    -f "${PAYLOAD_FILE}"

pass "MQTT environment message published successfully"

wait_for_value \
    "Message reached public.mqtt_staging" \
    "
    SELECT count(*)::text
    FROM public.mqtt_staging
    WHERE tags ->> 'topic' = '${TEST_TOPIC}'
      AND fields ->> 'value' LIKE '%\"ts\": ${TEST_TS}%'
      AND lower(fields ->> 'value') LIKE
          lower('%\"uid\": \"${TEST_UID}\"%');
    " \
    "1"

wait_for_value \
    "Five environment points persisted in telemetry.normalized_points" \
    "
    SELECT count(*)::text
    FROM telemetry.normalized_points
    WHERE device_id = '${DEVICE_ID}'::uuid
      AND event_time = to_timestamp(${TEST_TS})
      AND raw_field_name IN ('T1', 'RH', 'LL', 'PIR', 'Vbat')
      AND quality_code = 'GOOD';
    " \
    "5"

wait_for_value \
    "Environment row persisted in telemetry.environment_measurements" \
    "
    SELECT count(*)::text
    FROM telemetry.environment_measurements
    WHERE device_id = '${DEVICE_ID}'::uuid
      AND received_at = to_timestamp(${TEST_TS})
      AND source_timestamp = to_timestamp(${TEST_TS})
      AND abs(
          temperature_c::double precision -
          ${TEST_TEMPERATURE}::double precision
      ) < 0.001
      AND abs(
          humidity_percent::double precision -
          ${TEST_HUMIDITY}::double precision
      ) < 0.001
      AND abs(
          illuminance_lux::double precision -
          ${TEST_ILLUMINANCE}::double precision
      ) < 0.001
      AND abs(
          occupancy_activity::double precision -
          ${TEST_OCCUPANCY}::double precision
      ) < 0.001
      AND abs(
          battery_voltage_v::double precision -
          ${TEST_BATTERY}::double precision
      ) < 0.001;
    " \
    "1"

info "Final verification:"

docker compose \
    -f "${COMPOSE_FILE}" \
    exec -T timescaledb \
    psql \
        -X \
        -P pager=off \
        -U ems_admin \
        -d ems \
        -c "
        SELECT
            received_at,
            source_timestamp,
            device_id,
            asset_id,
            temperature_c,
            humidity_percent,
            illuminance_lux,
            occupancy_activity,
            battery_voltage_v
        FROM telemetry.environment_measurements
        WHERE device_id = '${DEVICE_ID}'::uuid
          AND received_at = to_timestamp(${TEST_TS});
        "

pass "Live MQTT environment pipeline smoke test completed"
