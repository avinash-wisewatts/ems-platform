#!/usr/bin/env bash
set -Eeuo pipefail

# =============================================================================
# WiseWatts EMS canonical database deployment runner
#
# Purpose
# -------
# Builds or reconciles the database from the canonical project definition.
#
# Included by default:
#   1. canonical DDL
#   2. reference seeds
#   3. TimescaleDB/background jobs
#
# Excluded by default:
#   - historical migrations
#   - demo data
#   - maintenance and destructive scripts
#
# Why the manifest is used
# ------------------------
# SQL files were reorganized into purpose-specific directories. The manifest
# preserves their original version-number order across those directories so
# dependencies continue to execute in the intended sequence.
#
# Usage
# -----
#   ./scripts/deploy_database.sh --list
#   ./scripts/deploy_database.sh
#
# Environment overrides
# ---------------------
#   DB_CONTAINER=timescaledb
#   DB_NAME=ems
#   DB_USER=ems_admin
#
# IMPORTANT
# ---------
# Always review --list before execution.
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

MANIFEST_FILE="${PROJECT_ROOT}/postgres/restructure_manifest.csv"

DB_CONTAINER="${DB_CONTAINER:-timescaledb}"
DB_NAME="${DB_NAME:-ems}"
DB_USER="${DB_USER:-ems_admin}"

MODE="${1:-deploy}"

case "$MODE" in
    deploy|--list)
        ;;
    *)
        echo "Usage: $0 [--list]" >&2
        exit 2
        ;;
esac

if [[ ! -f "$MANIFEST_FILE" ]]; then
    echo "ERROR: Deployment manifest not found:" >&2
    echo "       $MANIFEST_FILE" >&2
    exit 1
fi

# Only these categories are safe for standard canonical deployment.
DEPLOY_CATEGORIES=(
    canonical
    reference
    jobs
)

is_deploy_category() {
    local candidate="$1"
    local allowed

    for allowed in "${DEPLOY_CATEGORIES[@]}"; do
        if [[ "$candidate" == "$allowed" ]]; then
            return 0
        fi
    done

    return 1
}

# Manifest columns:
# source_file,target_category,target_path,notes
#
# The manifest is intentionally read in its existing row order, which preserves
# the original numbered SQL deployment sequence.
DEPLOY_FILES=()

while IFS=',' read -r source_file target_category target_path notes; do
    # Skip header.
    if [[ "$source_file" == "source_file" ]]; then
        continue
    fi

    if is_deploy_category "$target_category"; then
        DEPLOY_FILES+=("$target_path")
    fi
done < "$MANIFEST_FILE"

if [[ ${#DEPLOY_FILES[@]} -eq 0 ]]; then
    echo "ERROR: No canonical deployment files found in manifest." >&2
    exit 1
fi

# Validate every manifest-selected file before listing or executing anything.
VALIDATION_ERRORS=0

for relative_path in "${DEPLOY_FILES[@]}"; do
    absolute_path="${PROJECT_ROOT}/${relative_path}"

    if [[ ! -f "$absolute_path" ]]; then
        echo "ERROR: Manifest-selected SQL file is missing:" >&2
        echo "       $relative_path" >&2
        VALIDATION_ERRORS=1
    fi
done

if [[ "$VALIDATION_ERRORS" -ne 0 ]]; then
    exit 1
fi

if [[ "$MODE" == "--list" ]]; then
    echo "Canonical production deployment order:"
    echo

    counter=1

    for relative_path in "${DEPLOY_FILES[@]}"; do
        printf '  %02d. %s\n' "$counter" "$relative_path"
        counter=$((counter + 1))
    done

    echo
    echo "Files selected: ${#DEPLOY_FILES[@]}"
    echo
    echo "Included categories:"
    printf '  %s\n' "${DEPLOY_CATEGORIES[@]}"

    echo
    echo "Excluded categories:"
    echo "  migration"
    echo "  demo"
    echo "  maintenance"

    exit 0
fi

cd "$PROJECT_ROOT"

echo "WiseWatts EMS canonical database deployment"
echo "============================================"
echo "Database container: $DB_CONTAINER"
echo "Database:           $DB_NAME"
echo "Database user:      $DB_USER"
echo "Manifest:           $MANIFEST_FILE"
echo "Files to execute:   ${#DEPLOY_FILES[@]}"
echo

for relative_path in "${DEPLOY_FILES[@]}"; do
    absolute_path="${PROJECT_ROOT}/${relative_path}"

    echo "------------------------------------------------------------"
    echo "Executing: $relative_path"
    echo "------------------------------------------------------------"

    docker compose exec -T "$DB_CONTAINER" \
        psql \
        -X \
        -v ON_ERROR_STOP=1 \
        -v db_name="$DB_NAME" \
        -U "$DB_USER" \
        -d "$DB_NAME" \
        -f - < "$absolute_path"

    echo
done

echo "Canonical database deployment completed successfully."
