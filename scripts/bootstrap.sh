#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BOOTSTRAP_DIR="${SCRIPT_DIR}/bootstrap"

echo "====================================================="
echo " WiseWatts EMS Platform Bootstrap"
echo "====================================================="
echo

for step in \
    01_prerequisites.sh \
    02_validate_env.sh \
    03_start_database.sh \
    04_wait_database.sh \
    05_deploy_database.sh \
    06_start_telegraf.sh \
    06a_build_grafana_live_plugin.sh \
    07_start_grafana.sh \
    08_post_checks.sh \
    09_summary.sh
do
    echo
    echo "-----------------------------------------------------"
    echo "Running ${step}"
    echo "-----------------------------------------------------"

    "${BOOTSTRAP_DIR}/${step}"
done

echo
echo "====================================================="
echo " Bootstrap completed successfully."
echo "====================================================="
