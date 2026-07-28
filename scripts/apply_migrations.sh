#!/usr/bin/env bash
set -Eeuo pipefail

# =============================================================================
# WiseWatts EMS forward migration runner
#
# Usage
# -----
#   ./scripts/apply_migrations.sh --list
#   ./scripts/apply_migrations.sh --status
#   ./scripts/apply_migrations.sh --baseline
#   ./scripts/apply_migrations.sh
#
# Optional environment overrides
# ------------------------------
#   COMPOSE_FILE=/path/to/compose.yaml
#   MIGRATION_MANIFEST=/path/to/restructure_manifest.csv
#   DB_CONTAINER=timescaledb
#   DB_NAME=ems
#   DB_USER=ems_admin
#
# Governance
# ----------
# * Canonical DDL represents the complete clean-install state.
# * Historical migrations are baselined once on an existing canonical database.
# * New forward migrations are executed exactly once.
# * Editing an already recorded migration causes a hard checksum failure.
# * Each executed migration and its ledger insert occur in one transaction.
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

COMPOSE_FILE="${COMPOSE_FILE:-${PROJECT_ROOT}/compose.yaml}"
MIGRATION_MANIFEST="${MIGRATION_MANIFEST:-${PROJECT_ROOT}/postgres/restructure_manifest.csv}"

DB_CONTAINER="${DB_CONTAINER:-timescaledb}"
DB_NAME="${DB_NAME:-ems}"
DB_USER="${DB_USER:-ems_admin}"

MODE="${1:-apply}"

case "${MODE}" in
    apply|--list|--status|--baseline)
        ;;
    *)
        echo "Usage: $0 [--list|--status|--baseline]" >&2
        exit 2
        ;;
esac

if [[ ! -f "${COMPOSE_FILE}" ]]; then
    echo "ERROR: Compose file not found: ${COMPOSE_FILE}" >&2
    exit 1
fi

if [[ ! -f "${MIGRATION_MANIFEST}" ]]; then
    echo "ERROR: Migration manifest not found: ${MIGRATION_MANIFEST}" >&2
    exit 1
fi

compose() {
    docker compose -f "${COMPOSE_FILE}" "$@"
}

query_scalar() {
    local sql="$1"

    compose exec -T "${DB_CONTAINER}" \
        psql \
        -X \
        -U "${DB_USER}" \
        -d "${DB_NAME}" \
        -tAc "${sql}"
}

escape_sql_literal() {
    printf "%s" "$1" | sed "s/'/''/g"
}

database_identity="$(
    query_scalar "SELECT current_database() || '|' || current_user;"
)"

if [[ "${database_identity}" != "${DB_NAME}|${DB_USER}" ]]; then
    echo "ERROR: Unexpected database identity: ${database_identity}" >&2
    echo "Expected: ${DB_NAME}|${DB_USER}" >&2
    exit 1
fi

ledger_relation="$(
    query_scalar "SELECT to_regclass('admin.schema_migrations');"
)"

if [[ "${ledger_relation}" != "admin.schema_migrations" ]]; then
    echo "ERROR: admin.schema_migrations does not exist." >&2
    echo "Run the canonical deployment before applying migrations." >&2
    exit 1
fi

MIGRATION_FILES=()

while IFS=',' read -r source_file target_category target_path notes; do
    [[ "${source_file}" == "source_file" ]] && continue

    if [[ "${target_category}" == "migration" ]]; then
        MIGRATION_FILES+=("${target_path}")
    fi
done < "${MIGRATION_MANIFEST}"

if [[ ${#MIGRATION_FILES[@]} -eq 0 ]]; then
    echo "No migration files were selected."
    exit 0
fi

for relative_path in "${MIGRATION_FILES[@]}"; do
    absolute_path="${PROJECT_ROOT}/${relative_path}"

    if [[ ! -f "${absolute_path}" ]]; then
        echo "ERROR: Migration file is missing: ${relative_path}" >&2
        exit 1
    fi
done

if [[ "${MODE}" == "--list" ]]; then
    printf '%s\n' "${MIGRATION_FILES[@]}"
    exit 0
fi

echo "WiseWatts EMS migration runner"
echo "=============================="
echo "Database:  ${database_identity}"
echo "Manifest:  ${MIGRATION_MANIFEST}"
echo "Mode:      ${MODE}"
echo "Migrations selected: ${#MIGRATION_FILES[@]}"
echo

for relative_path in "${MIGRATION_FILES[@]}"; do
    absolute_path="${PROJECT_ROOT}/${relative_path}"
    filename="$(basename "${relative_path}")"
    migration_id="${filename%.sql}"
    checksum="$(sha256sum "${absolute_path}" | awk '{print $1}')"

    migration_id_sql="$(escape_sql_literal "${migration_id}")"
    relative_path_sql="$(escape_sql_literal "${relative_path}")"
    checksum_sql="$(escape_sql_literal "${checksum}")"

    existing_record="$(
        query_scalar "
            SELECT checksum_sha256 || '|' || application_mode
            FROM admin.schema_migrations
            WHERE migration_id = '${migration_id_sql}';
        "
    )"

    if [[ -n "${existing_record}" ]]; then
        existing_checksum="${existing_record%%|*}"
        existing_mode="${existing_record#*|}"

        if [[ "${existing_checksum}" != "${checksum}" ]]; then
            echo "ERROR: Applied migration checksum mismatch." >&2
            echo "Migration: ${migration_id}" >&2
            echo "File:      ${relative_path}" >&2
            echo "Recorded:  ${existing_checksum}" >&2
            echo "Current:   ${checksum}" >&2
            exit 1
        fi

        echo "SKIP  ${migration_id} (${existing_mode})"
        continue
    fi

    if [[ "${MODE}" == "--status" ]]; then
        echo "PENDING ${migration_id} ${relative_path}"
        continue
    fi

    if [[ "${MODE}" == "--baseline" ]]; then
        compose exec -T "${DB_CONTAINER}" \
            psql \
            -X \
            -v ON_ERROR_STOP=1 \
            -U "${DB_USER}" \
            -d "${DB_NAME}" \
            -c "
                INSERT INTO admin.schema_migrations (
                    migration_id,
                    file_path,
                    checksum_sha256,
                    execution_ms,
                    application_mode
                )
                VALUES (
                    '${migration_id_sql}',
                    '${relative_path_sql}',
                    '${checksum_sql}',
                    0,
                    'baseline'
                );
            "

        echo "BASELINE ${migration_id}"
        continue
    fi

    echo "APPLY ${migration_id}"

    {
        echo '\set ON_ERROR_STOP on'
        echo 'BEGIN;'
        echo 'SELECT clock_timestamp() AS migration_started_at \gset'
        cat "${absolute_path}"
        cat <<SQL

INSERT INTO admin.schema_migrations (
    migration_id,
    file_path,
    checksum_sha256,
    execution_ms,
    application_mode
)
VALUES (
    :'migration_id',
    :'file_path',
    :'checksum_sha256',
    GREATEST(
        0,
        floor(
            extract(
                epoch FROM (
                    clock_timestamp() -
                    :'migration_started_at'::timestamptz
                )
            ) * 1000
        )::bigint
    ),
    'applied'
);

COMMIT;
SQL
    } |
    compose exec -T "${DB_CONTAINER}" \
        psql \
        -X \
        -v ON_ERROR_STOP=1 \
        -v migration_id="${migration_id}" \
        -v file_path="${relative_path}" \
        -v checksum_sha256="${checksum}" \
        -U "${DB_USER}" \
        -d "${DB_NAME}" \
        -f -

    echo "APPLIED ${migration_id}"
done

if [[ "${MODE}" == "--status" ]]; then
    exit 0
fi

echo
echo "Migration operation completed successfully."
