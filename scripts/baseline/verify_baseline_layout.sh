#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
cd "${PROJECT_ROOT}"

active=(postgres/migrations/*.sql)
if [[ ${#active[@]} -ne 1 ]] || [[ "${active[0]}" != "postgres/migrations/001_ems_platform_baseline_20260807.sql" ]]; then
    echo "ERROR: active migration directory must contain only baseline 001 before post-baseline work." >&2
    printf '  %s\n' "${active[@]}" >&2
    exit 1
fi

archive_count="$(find postgres/archive/prebaseline_20260807/migrations -maxdepth 1 -type f -name '*.sql' | wc -l)"
if [[ "${archive_count}" -lt 100 ]]; then
    echo "ERROR: historical migration archive is unexpectedly incomplete (${archive_count})." >&2
    exit 1
fi

manifest_count="$(awk -F, 'NR>1 && $2=="migration" {count++} END {print count+0}' postgres/restructure_manifest.csv)"
if [[ "${manifest_count}" -ne 1 ]]; then
    echo "ERROR: manifest must select exactly one active migration; found ${manifest_count}." >&2
    exit 1
fi

grep -q 'postgres/migrations/001_ems_platform_baseline_20260807.sql' postgres/restructure_manifest.csv

echo "PASS: baseline repository layout is valid"
echo "Archived migrations: ${archive_count}"
