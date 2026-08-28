#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="/opt/ems-platform"

echo "Validating environment configuration..."

FAILURES=0

check_file() {
    local file_path="$1"

    if [[ -f "${file_path}" ]]; then
        printf '[PASS] Environment file exists: %s\n' "${file_path}"
    else
        printf '[FAIL] Missing environment file: %s\n' "${file_path}" >&2
        FAILURES=$((FAILURES + 1))
    fi
}

check_variable() {
    local file_path="$1"
    local variable_name="$2"
    local value

    if [[ ! -f "${file_path}" ]]; then
        return
    fi

    value="$(
        awk -F= -v key="${variable_name}" '
            $1 == key {
                sub(/^[^=]*=/, "")
                print
                exit
            }
        ' "${file_path}"
    )"

    if [[ -z "${value}" ]]; then
        printf '[FAIL] %s is missing or empty in %s\n' \
            "${variable_name}" \
            "${file_path}" >&2
        FAILURES=$((FAILURES + 1))
    else
        printf '[PASS] %s is configured in %s\n' \
            "${variable_name}" \
            "${file_path}"
    fi
}

check_all_or_none() {
    # Second-broker configuration is opt-in, but must be all-or-nothing:
    # if any variable in the group is set (non-empty), every variable in the
    # group must be set. Mirrors LiveSettings._validate_second_broker so a
    # host cannot deploy a half-configured Broker #2.
    local file_path="$1"
    shift
    local group_label="$1"
    shift

    if [[ ! -f "${file_path}" ]]; then
        return
    fi

    local any_present=0
    local missing=()
    local variable_name value
    for variable_name in "$@"; do
        value="$(
            awk -F= -v key="${variable_name}" '
                $1 == key { sub(/^[^=]*=/, ""); print; exit }
            ' "${file_path}"
        )"
        if [[ -n "${value}" ]]; then
            any_present=1
        else
            missing+=("${variable_name}")
        fi
    done

    if [[ "${any_present}" -eq 0 ]]; then
        printf '[INFO] %s not configured in %s (single-broker mode)\n' \
            "${group_label}" "${file_path}"
    elif [[ "${#missing[@]}" -gt 0 ]]; then
        printf '[FAIL] %s is partially configured in %s; missing: %s\n' \
            "${group_label}" "${file_path}" "${missing[*]}" >&2
        FAILURES=$((FAILURES + 1))
    else
        printf '[PASS] %s is fully configured in %s\n' \
            "${group_label}" "${file_path}"
    fi
}

ROOT_ENV="${PROJECT_ROOT}/.env"
TELEGRAF_ENV="${PROJECT_ROOT}/telegraf/.env"
GRAFANA_ENV="${PROJECT_ROOT}/grafana/.env"
LIVE_TELEMETRY_ENV="${PROJECT_ROOT}/app/live-telemetry.env"

check_file "${ROOT_ENV}"
check_file "${TELEGRAF_ENV}"
check_file "${GRAFANA_ENV}"

check_variable "${ROOT_ENV}" "POSTGRES_USER"
check_variable "${ROOT_ENV}" "POSTGRES_PASSWORD"
check_variable "${ROOT_ENV}" "POSTGRES_DB"

check_variable "${TELEGRAF_ENV}" "MQTT_HOST"
check_variable "${TELEGRAF_ENV}" "MQTT_PORT"
check_variable "${TELEGRAF_ENV}" "MQTT_TOPIC"
check_variable "${TELEGRAF_ENV}" "MQTT_USERNAME"
check_variable "${TELEGRAF_ENV}" "MQTT_PASSWORD"

# Optional simultaneous second MQTT broker for Telegraf ingestion
# (telegraf.conf second [[inputs.mqtt_consumer]]). All-or-nothing.
check_all_or_none "${TELEGRAF_ENV}" "Telegraf Broker #2 (MQTT2_*)" \
    MQTT2_HOST MQTT2_PORT MQTT2_USERNAME MQTT2_PASSWORD

# Optional simultaneous second MQTT broker for the live-telemetry service.
# Validated consistently with LiveSettings.broker_configs(): the full set
# including a distinct client id, or nothing.
check_all_or_none "${LIVE_TELEMETRY_ENV}" "live-telemetry Broker #2 (MQTT2_*)" \
    MQTT2_HOST MQTT2_PORT MQTT2_USERNAME MQTT2_PASSWORD MQTT2_LIVE_CLIENT_ID

check_variable "${GRAFANA_ENV}" "GF_SECURITY_ADMIN_USER"
check_variable "${GRAFANA_ENV}" "GF_SECURITY_ADMIN_PASSWORD"

if git -C "${PROJECT_ROOT}" ls-files --error-unmatch \
    .env telegraf/.env grafana/.env \
    >/dev/null 2>&1; then
    echo "[FAIL] One or more environment files are tracked by Git" >&2
    FAILURES=$((FAILURES + 1))
else
    echo "[PASS] Environment files are not tracked by Git"
fi


RESOLVED_TELEGRAF_ENV="$(
    docker compose config 2>/dev/null \
    | awk '
        /^[[:space:]]{2}telegraf:[[:space:]]*$/ {
            in_service = 1
        }

        in_service &&
        /^[[:space:]]{2}[A-Za-z0-9_-]+:[[:space:]]*$/ &&
        $0 !~ /^[[:space:]]{2}telegraf:[[:space:]]*$/ {
            exit
        }

        in_service {
            print
        }
    '
)"

for variable_name in POSTGRES_USER POSTGRES_PASSWORD POSTGRES_DB; do
    if grep -qE "^[[:space:]]+${variable_name}:" \
        <<< "${RESOLVED_TELEGRAF_ENV}"; then
        printf '[PASS] Telegraf receives %s through Docker Compose\n' \
            "${variable_name}"
    else
        printf '[FAIL] Telegraf does not receive %s through Docker Compose\n' \
            "${variable_name}" >&2
        FAILURES=$((FAILURES + 1))
    fi
done

if [[ "${FAILURES}" -ne 0 ]]; then
    echo
    echo "Environment validation failed with ${FAILURES} error(s)." >&2
    exit 1
fi

echo
echo "Environment validation passed."
