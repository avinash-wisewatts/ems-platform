#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
ACTIVE_DIR="${PROJECT_ROOT}/postgres/migrations"
ARCHIVE_DIR="${PROJECT_ROOT}/postgres/archive/prebaseline_20260807/migrations"
BASELINE="001_ems_platform_baseline_20260807.sql"

if [[ ! -f "${ACTIVE_DIR}/${BASELINE}" ]]; then
    echo "ERROR: baseline file is missing from ${ACTIVE_DIR}." >&2
    exit 1
fi

archive_count="$(find "${ARCHIVE_DIR}" -maxdepth 1 -type f -name '*.sql' | wc -l)"
if [[ "${archive_count}" -lt 100 ]]; then
    echo "ERROR: historical archive is incomplete (${archive_count} SQL files)." >&2
    exit 1
fi

# Verify every old active migration has an identical archived copy before it is
# removed from the active stream.
while IFS= read -r active; do
    name="$(basename "${active}")"
    [[ "${name}" == "${BASELINE}" ]] && continue
    archived="${ARCHIVE_DIR}/${name}"
    if [[ ! -f "${archived}" ]]; then
        echo "ERROR: archived copy is missing for ${name}." >&2
        exit 1
    fi
    if ! cmp -s "${active}" "${archived}"; then
        echo "ERROR: archived copy differs from active migration ${name}." >&2
        exit 1
    fi
done < <(find "${ACTIVE_DIR}" -maxdepth 1 -type f -name '*.sql' | sort)

find "${ACTIVE_DIR}" -maxdepth 1 -type f -name '*.sql' \
    ! -name "${BASELINE}" -delete

"${PROJECT_ROOT}/scripts/baseline/verify_baseline_layout.sh"
echo "PASS: historical migrations removed from active stream after archive verification"
