#!/usr/bin/env bash
#
# ============================================================================
# WiseWatts EMS — Complete Platform Verification
#
# Purpose:
#   Run every supported verification suite in a deterministic order and return
#   a single overall platform result.
#
# Verification order:
#   1. Database structure
#   2. Metadata integrity
#   3. Telemetry pipeline
#   4. TimescaleDB jobs and lifecycle policies
#
# Exit codes:
#   0 = every verification suite passed
#   1 = one or more verification suites failed
#
# Safety:
#   This script only invokes read-only verification scripts.
# ============================================================================

set -u
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

cd "${PROJECT_ROOT}" || {
    echo "[FAIL] Unable to enter project directory: ${PROJECT_ROOT}"
    exit 1
}

GREEN='\033[0;32m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'

TOTAL_SUITES=0
PASSED_SUITES=0
FAILED_SUITES=0

run_suite() {
    local script_name="$1"
    local display_name="$2"
    local script_path="${SCRIPT_DIR}/${script_name}"

    ((TOTAL_SUITES++))

    echo
    echo "================================================================"
    echo " Running: ${display_name}"
    echo " Script : ${script_path}"
    echo "================================================================"
    echo

    if [[ ! -f "${script_path}" ]]; then
        echo -e "${RED}[FAIL]${NC} Verification script is missing: ${script_path}"
        ((FAILED_SUITES++))
        return
    fi

    if [[ ! -x "${script_path}" ]]; then
        echo -e "${RED}[FAIL]${NC} Verification script is not executable: ${script_path}"
        ((FAILED_SUITES++))
        return
    fi

    if "${script_path}"; then
        echo
        echo -e "${GREEN}[SUITE PASS]${NC} ${display_name}"
        ((PASSED_SUITES++))
    else
        echo
        echo -e "${RED}[SUITE FAIL]${NC} ${display_name}"
        ((FAILED_SUITES++))
    fi
}

echo
echo "================================================================"
echo " WiseWatts EMS Platform — Complete Verification"
echo "================================================================"
echo " Project root: ${PROJECT_ROOT}"
echo " Started at : $(date --iso-8601=seconds)"
echo "================================================================"

run_suite "verify_database.sh" "Database Structure Verification"
run_suite "verify_metadata.sh" "Metadata Integrity Verification"
run_suite "verify_pipeline.sh" "Telemetry Pipeline Verification"
run_suite "verify_jobs.sh" "TimescaleDB Job Verification"

echo
echo "================================================================"
echo " Complete Verification Summary"
echo "================================================================"
echo " Suites executed : ${TOTAL_SUITES}"
echo " Suites passed   : ${PASSED_SUITES}"
echo " Suites failed   : ${FAILED_SUITES}"
echo " Completed at    : $(date --iso-8601=seconds)"
echo

if [[ "${FAILED_SUITES}" -eq 0 ]]; then
    echo -e "${GREEN}OVERALL PLATFORM RESULT: PASS${NC}"
    exit 0
else
    echo -e "${RED}OVERALL PLATFORM RESULT: FAIL${NC}"
    exit 1
fi
