#!/usr/bin/env bash
set -euo pipefail

DB_CONTAINER="timescaledb"
DB_NAME="ems"
DB_USER="ems_admin"

DDL_DIR="/opt/ems-platform/postgres/ddl"

echo "Deploying EMS database..."

for file in \
    00_extensions.sql \
    01_schemas.sql \
    02_roles.sql \
    03_admin.sql \
    04_metadata.sql \
    05_lookup_data.sql \
    06_device_profiles.sql \
    07_telemetry.sql \
    08_indexes.sql \
    09_constraints.sql \
    10_functions.sql \
    11_views.sql \
    12_continuous_aggregates.sql \
    13_retention.sql \
    14_compression.sql
do
    echo
    echo "======================================================"
    echo "Executing $file"
    echo "======================================================"

    docker compose exec -T "$DB_CONTAINER" \
        psql \
        -v ON_ERROR_STOP=1 \
        -U "$DB_USER" \
        -d "$DB_NAME" \
        < "$DDL_DIR/$file"
done

echo
echo "Database deployment completed successfully."
