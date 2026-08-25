#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="/opt/ems-platform"
PLUGIN_SRC="${PROJECT_ROOT}/grafana/plugin-src/wisewatts-live-datasource"
PLUGIN_OUT="${PROJECT_ROOT}/grafana/plugins/wisewatts-live-datasource"
PLUGIN_EXECUTABLE="${PLUGIN_OUT}/wisewatts_live_datasource_linux_amd64"

echo "Building the WiseWatts Grafana live-telemetry datasource plugin..."

# grafana/plugins/ is gitignored (it holds a locally built artifact, not
# source), so a fresh host checkout never has it -- without this step,
# every new environment silently reproduces "Datasource ... was not
# found" on every live-telemetry dashboard panel, because Grafana never
# has the plugin to load in the first place. This must run before
# 07_start_grafana.sh so the plugin is present the first time Grafana's
# container starts and scans its plugins directory.

if [[ ! -x "${PLUGIN_SRC}/build-plugin.sh" ]]; then
    echo "[FAIL] Plugin build script not found or not executable: ${PLUGIN_SRC}/build-plugin.sh"
    exit 1
fi

mkdir -p "${PLUGIN_OUT}"

"${PLUGIN_SRC}/build-plugin.sh"

if [[ ! -x "${PLUGIN_EXECUTABLE}" ]]; then
    echo "[FAIL] Plugin executable not found after build: ${PLUGIN_EXECUTABLE}"
    exit 1
fi

echo "[PASS] wisewatts-live-datasource plugin built and installed."
ls -la "${PLUGIN_OUT}"
