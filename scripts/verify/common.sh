#!/usr/bin/env bash
#
# ============================================================
# WiseWatts EMS Verification Library
#
# Shared helper functions used by all verification scripts.
#
# This file MUST NOT modify database state.
# ============================================================

PASS_COUNT=0
WARN_COUNT=0
FAIL_COUNT=0

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

print_header() {
    echo
    echo "============================================================"
    echo " WiseWatts EMS Platform Verification"
    echo "============================================================"
    echo
}

print_section() {
    echo
    echo "------------------------------------------------------------"
    echo "$1"
    echo "------------------------------------------------------------"
}

pass() {
    echo -e "${GREEN}[PASS]${NC} $1"
    ((PASS_COUNT++))
}

warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
    ((WARN_COUNT++))
}

fail() {
    echo -e "${RED}[FAIL]${NC} $1"
    ((FAIL_COUNT++))
}

summary() {

    echo
    echo "============================================================"
    echo "Verification Summary"
    echo "============================================================"

    echo "PASS : $PASS_COUNT"
    echo "WARN : $WARN_COUNT"
    echo "FAIL : $FAIL_COUNT"

    echo

    if [ "$FAIL_COUNT" -eq 0 ]; then
        echo -e "${GREEN}OVERALL RESULT : PASS${NC}"
        exit 0
    else
        echo -e "${RED}OVERALL RESULT : FAIL${NC}"
        exit 1
    fi
}

psql_query() {
    docker compose exec -T timescaledb \
        psql \
        -X \
        -v ON_ERROR_STOP=1 \
        -U ems_admin \
        -d ems \
        -t \
        -A \
        -c "$1" \
        </dev/null
}

get_config_value() {
    local key="$1"
    local config_file="${SCRIPT_DIR}/config/pipeline.conf"

    if [[ ! -r "${config_file}" ]]; then
        return 1
    fi

    grep -m1 "^${key}=" "${config_file}" \
        | cut -d= -f2-
}
