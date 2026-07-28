#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

SOURCE_MANIFEST="${PROJECT_ROOT}/postgres/restructure_manifest.csv"
TEMP_DIR="$(mktemp -d)"
BASELINE_MANIFEST="${TEMP_DIR}/baseline.csv"
FORWARD_MANIFEST="${TEMP_DIR}/forward.csv"

cleanup() {
    rm -rf "${TEMP_DIR}"
}
trap cleanup EXIT

python3 - \
    "${SOURCE_MANIFEST}" \
    "${BASELINE_MANIFEST}" \
    "${FORWARD_MANIFEST}" <<'PY'
from pathlib import Path
import csv
import re
import sys

source = Path(sys.argv[1])
baseline = Path(sys.argv[2])
forward = Path(sys.argv[3])

with source.open(newline="") as handle:
    reader = csv.DictReader(handle)
    fieldnames = reader.fieldnames
    rows = list(reader)

baseline_rows = []
forward_rows = []

for row in rows:
    if row["target_category"] != "migration":
        continue

    match = re.match(r"^(\d+)", row["source_file"])
    if not match:
        raise SystemExit(
            f"Migration filename has no numeric prefix: "
            f"{row['source_file']}"
        )

    number = int(match.group(1))

    if number <= 81:
        baseline_rows.append(row)
    else:
        forward_rows.append(row)

for path, selected_rows in (
    (baseline, baseline_rows),
    (forward, forward_rows),
):
    with path.open("w", newline="") as handle:
        writer = csv.DictWriter(
            handle,
            fieldnames=fieldnames,
            lineterminator="\n",
        )
        writer.writeheader()
        writer.writerows(selected_rows)

print(
    f"Historical migrations to baseline: {len(baseline_rows)}"
)
print(
    f"Forward migrations to apply: {len(forward_rows)}"
)
PY

COMMON_ENV=(
    "COMPOSE_FILE=${PROJECT_ROOT}/compose.test.yaml"
    "DB_CONTAINER=timescaledb-test"
    "DB_NAME=ems_test"
    "DB_USER=ems_admin"
)

echo
echo "Baselining historical migrations represented by the canonical foundation..."

env \
    "${COMMON_ENV[@]}" \
    MIGRATION_MANIFEST="${BASELINE_MANIFEST}" \
    "${PROJECT_ROOT}/scripts/apply_migrations.sh" --baseline

echo
echo "Applying ordered forward migrations..."

env \
    "${COMMON_ENV[@]}" \
    MIGRATION_MANIFEST="${FORWARD_MANIFEST}" \
    "${PROJECT_ROOT}/scripts/apply_migrations.sh"
