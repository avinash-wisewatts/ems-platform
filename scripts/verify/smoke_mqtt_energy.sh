#!/usr/bin/env bash
# =============================================================================
# WiseWatts EMS — Live MQTT Energy Pipeline Smoke Test
#
# Validates:
#   HiveMQ -> Telegraf -> public.mqtt_staging (insert-only adapter)
#   -> telemetry.raw_messages (canonical persisted landing table)
#   -> telemetry.normalized_points
#   -> telemetry.energy_measurements
#
# This test publishes one synthetic energy message using an existing mapped
# device. It does not modify metadata, rebuild history, or delete telemetry.
# =============================================================================

set -Eeuo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
COMPOSE_FILE="${PROJECT_ROOT}/compose.yaml"
TELEGRAF_ENV="${PROJECT_ROOT}/telegraf/.env"

TEST_TOPIC="${SMOKE_MQTT_TOPIC:-testeniscope/chillerroom/chiller}"
TEST_UID="${SMOKE_DEVICE_UID:-80:34:28:16:09:eb:00:01}"
TIMEOUT_SECONDS="${SMOKE_TIMEOUT_SECONDS:-180}"
POLL_SECONDS="${SMOKE_POLL_SECONDS:-5}"

PAYLOAD_FILE=""
TEST_TS=""
TEST_POWER=""

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

DEVICE_NAME="$(
    psql_scalar "
        SELECT name
        FROM metadata.devices
        WHERE id = '${DEVICE_ID}'::uuid;
    "
)"

TEST_TS="$(date +%s)"

# A unique but operationally harmless synthetic active-power value.
TEST_POWER="$(
    awk -v ts="${TEST_TS}" \
        'BEGIN { printf "%.3f", 700 + (ts % 200) + ((ts % 997) / 1000) }'
)"

PAYLOAD_FILE="$(mktemp /tmp/ems-mqtt-smoke-XXXXXX.json)"

cat > "${PAYLOAD_FILE}" <<JSON
{
  "rtdata": [
    {
      "C": 1,
      "D": 0,
      "E": 11995943.02,
      "F": 50,
      "I": 187.45,
      "P": ${TEST_POWER},
      "Q": 40.25,
      "S": 129.84,
      "U": 415.2,
      "V": 239.7,
      "P1": 41.152,
      "P2": 41.152,
      "P3": 41.152,
      "I1": 62.3,
      "I2": 62.6,
      "I3": 62.55,
      "V1": 239.5,
      "V2": 239.8,
      "V3": 239.7,
      "PF": 0.9508,
      "PF1": 0.951,
      "PF2": 0.950,
      "PF3": 0.951,
      "E1": 4013298.56,
      "E2": 4448521.92,
      "E3": 3537740.34,
      "AE": 14000863.09,
      "ts": ${TEST_TS},
      "did": 1,
      "uid": "${TEST_UID}"
    }
  ]
}
JSON

python3 -m json.tool "${PAYLOAD_FILE}" >/dev/null ||
    fail "Generated payload is not valid JSON"

info "Device       : ${DEVICE_NAME}"
info "Device UID   : ${TEST_UID}"
info "Device ID    : ${DEVICE_ID}"
info "MQTT topic   : ${TEST_TOPIC}"
info "Source epoch : ${TEST_TS}"
info "Test power   : ${TEST_POWER}"

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

pass "MQTT message published successfully"

wait_for_value \
    "Message persisted in telemetry.raw_messages" \
    "
    SELECT count(*)::text
    FROM telemetry.raw_messages rm
    WHERE rm.source_protocol = 'MQTT'
      AND rm.source_topic = '${TEST_TOPIC}'
      AND EXISTS (
          SELECT 1
          FROM jsonb_array_elements(rm.payload -> 'rtdata') AS item(value)
          WHERE item.value ->> 'uid' = '${TEST_UID}'
            AND item.value ->> 'ts' = '${TEST_TS}'
            AND (item.value ->> 'P')::numeric = ${TEST_POWER}::numeric
      );
    " \
    "1"

wait_for_value \
    "Active power point persisted in telemetry.normalized_points" \
    "
    SELECT count(*)::text
    FROM telemetry.normalized_points
    WHERE device_id = '${DEVICE_ID}'::uuid
      AND event_time = to_timestamp(${TEST_TS})
      AND raw_field_name = 'P'
      AND numeric_value = ${TEST_POWER}
      AND quality_code = 'GOOD';
    " \
    "1"

wait_for_value \
    "Energy row persisted in telemetry.energy_measurements" \
    "
    SELECT count(*)::text
    FROM telemetry.energy_measurements
    WHERE device_id = '${DEVICE_ID}'::uuid
      AND source_timestamp = to_timestamp(${TEST_TS})
      -- Device profile reports P in kW; the energy domain stores watts.
      -- Use a tolerance because active_power_total_w is double precision.
      AND abs(
          active_power_total_w - (${TEST_POWER}::double precision * 1000.0)
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
            active_power_total_w,
            frequency_hz,
            power_factor_total
        FROM telemetry.energy_measurements
        WHERE device_id = '${DEVICE_ID}'::uuid
          AND source_timestamp = to_timestamp(${TEST_TS});
        "

pass "Live MQTT energy pipeline smoke test completed"
