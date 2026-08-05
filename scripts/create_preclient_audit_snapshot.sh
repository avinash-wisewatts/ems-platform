#!/usr/bin/env bash
set -Eeuo pipefail

REPO_ROOT="/opt/ems-platform"
ARCHIVE_ROOT="/home/emsadmin/ems-preclient-maintenance"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
RUN_ROOT="${ARCHIVE_ROOT}/${TIMESTAMP}"
PRIVATE_BACKUP_DIR="${RUN_ROOT}/private-recovery"
AUDIT_DIR="${RUN_ROOT}/sanitized-audit"
REPORT_DIR="${AUDIT_DIR}/reports"

DB_SERVICE="timescaledb"
DB_NAME="ems"
DB_USER="ems_admin"

log() {
    printf '\n[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

fail() {
    echo "ERROR: $*" >&2
    exit 1
}

cleanup() {
    if docker compose ps --services --status stopped 2>/dev/null \
        | grep -qx "grafana"; then
        echo "Restarting Grafana after interrupted snapshot..."
        docker compose start grafana >/dev/null 2>&1 || true
    fi
}
trap cleanup EXIT

cd "$REPO_ROOT"

mkdir -p \
    "$PRIVATE_BACKUP_DIR" \
    "$REPORT_DIR/database" \
    "$REPORT_DIR/grafana" \
    "$REPORT_DIR/runtime" \
    "$REPORT_DIR/repository" \
    "$REPORT_DIR/security"

chmod 700 "$ARCHIVE_ROOT" "$RUN_ROOT" "$PRIVATE_BACKUP_DIR"

log "Recording snapshot metadata"

cat > "${RUN_ROOT}/SNAPSHOT_INFO.txt" <<EOF
snapshot_timestamp=${TIMESTAMP}
hostname=$(hostname)
repository=${REPO_ROOT}
database=${DB_NAME}
database_service=${DB_SERVICE}
purpose=pre-client repository and runtime cleanup audit
EOF

uname -a > "${REPORT_DIR}/runtime/uname.txt"
date --iso-8601=seconds > "${REPORT_DIR}/runtime/snapshot-time.txt"
df -h > "${REPORT_DIR}/runtime/disk-usage.txt"
docker version > "${REPORT_DIR}/runtime/docker-version.txt" 2>&1 || true
docker compose version > "${REPORT_DIR}/runtime/docker-compose-version.txt" 2>&1 || true
docker compose ps -a > "${REPORT_DIR}/runtime/docker-compose-ps.txt" 2>&1 || true
docker images --digests > "${REPORT_DIR}/runtime/docker-images.txt" 2>&1 || true
docker volume ls > "${REPORT_DIR}/runtime/docker-volumes.txt" 2>&1 || true
docker network ls > "${REPORT_DIR}/runtime/docker-networks.txt" 2>&1 || true

log "Creating private PostgreSQL recovery backup"

docker compose exec -T "$DB_SERVICE" \
    pg_dump \
        -U "$DB_USER" \
        -d "$DB_NAME" \
        --format=custom \
        --compress=9 \
        --no-owner \
        --no-privileges \
    > "${PRIVATE_BACKUP_DIR}/ems-database-precleanup.dump"

docker compose exec -T "$DB_SERVICE" \
    pg_dumpall \
        -U "$DB_USER" \
        --globals-only \
    > "${PRIVATE_BACKUP_DIR}/postgres-globals-precleanup.sql"

test -s "${PRIVATE_BACKUP_DIR}/ems-database-precleanup.dump" \
    || fail "PostgreSQL backup is empty"

docker compose exec -T "$DB_SERVICE" \
    pg_restore --list \
    < "${PRIVATE_BACKUP_DIR}/ems-database-precleanup.dump" \
    > "${PRIVATE_BACKUP_DIR}/ems-database-precleanup.contents.txt"

log "Creating private repository recovery archive"

sudo tar \
    --exclude='./postgres/data' \
    --exclude='./postgres/backups' \
    --exclude='./grafana/data' \
    --exclude='./grafana/plugins' \
    --exclude='./logs' \
    --exclude='./telegraf/logs' \
    --exclude='./.venv' \
    --exclude='./venv' \
    --exclude='*/node_modules' \
    --exclude='*/__pycache__' \
    --exclude='*/.pytest_cache' \
    --exclude='*.pyc' \
    -czf "${PRIVATE_BACKUP_DIR}/ems-repository-private-precleanup.tar.gz" \
    -C "$REPO_ROOT" \
    .

sudo chown -R emsadmin:emsadmin "$RUN_ROOT"
chmod -R go-rwx "$PRIVATE_BACKUP_DIR"

log "Creating consistent private Grafana backup"

docker compose stop grafana

if [[ -d "${REPO_ROOT}/grafana/data" ]]; then
    sudo tar \
        -czf "${PRIVATE_BACKUP_DIR}/grafana-data-precleanup.tar.gz" \
        -C "${REPO_ROOT}/grafana" \
        data

    sudo chown emsadmin:emsadmin \
        "${PRIVATE_BACKUP_DIR}/grafana-data-precleanup.tar.gz"
fi

GRAFANA_DB="${REPO_ROOT}/grafana/data/grafana.db"

if [[ -f "$GRAFANA_DB" ]]; then
    sudo cp "$GRAFANA_DB" \
        "${PRIVATE_BACKUP_DIR}/grafana-precleanup.db"
    sudo chown emsadmin:emsadmin \
        "${PRIVATE_BACKUP_DIR}/grafana-precleanup.db"
    chmod 600 "${PRIVATE_BACKUP_DIR}/grafana-precleanup.db"
fi

docker compose start grafana

log "Waiting for Grafana health"

for attempt in $(seq 1 30); do
    if docker compose ps grafana 2>/dev/null \
        | grep -q "healthy"; then
        break
    fi
    sleep 2
done

log "Creating sanitized repository snapshot"

"${REPO_ROOT}/scripts/create_snapshot.sh" preclient-audit \
    | tee "${REPORT_DIR}/repository/repository-snapshot-command.txt"

REPO_SNAPSHOT="$(
    tail -n 1 \
        "${REPORT_DIR}/repository/repository-snapshot-command.txt"
)"

if [[ ! -f "$REPO_SNAPSHOT" ]]; then
    fail "Sanitized repository snapshot was not created"
fi

cp "$REPO_SNAPSHOT" "${AUDIT_DIR}/"

log "Capturing repository state"

git status --short \
    > "${REPORT_DIR}/repository/git-status-short.txt" 2>&1 || true

git status \
    > "${REPORT_DIR}/repository/git-status.txt" 2>&1 || true

git branch --show-current \
    > "${REPORT_DIR}/repository/git-current-branch.txt" 2>&1 || true

git log \
    --date=iso \
    --pretty=format:'%h|%ad|%an|%s' \
    -n 100 \
    > "${REPORT_DIR}/repository/git-log-last-100.txt" 2>&1 || true

git diff --stat \
    > "${REPORT_DIR}/repository/git-diff-stat.txt" 2>&1 || true

git diff \
    > "${REPORT_DIR}/repository/git-working-tree.diff" 2>&1 || true

git diff --cached \
    > "${REPORT_DIR}/repository/git-index.diff" 2>&1 || true

find "$REPO_ROOT" -xdev \
    \( \
        -path "$REPO_ROOT/postgres/data" -o \
        -path "$REPO_ROOT/grafana/data" -o \
        -path "$REPO_ROOT/grafana/plugins" -o \
        -path "$REPO_ROOT/.git" -o \
        -path '*/node_modules' -o \
        -path '*/.venv' -o \
        -path '*/venv' \
    \) -prune -o \
    -type f \
    -printf '%P|%s bytes|%TY-%Tm-%Td %TH:%TM:%TS\n' \
    | sort \
    > "${REPORT_DIR}/repository/file-inventory.txt"

find "$REPO_ROOT" -xdev \
    \( \
        -path "$REPO_ROOT/postgres/data" -o \
        -path "$REPO_ROOT/grafana/data" -o \
        -path "$REPO_ROOT/grafana/plugins" -o \
        -path "$REPO_ROOT/.git" -o \
        -path '*/node_modules' -o \
        -path '*/.venv' -o \
        -path '*/venv' \
    \) -prune -o \
    -type f \
    \( \
        -iname '*.bak' -o \
        -iname '*.backup' -o \
        -iname '*.before-*' -o \
        -iname '*.failed-*' -o \
        -iname '*.old' -o \
        -iname '*.orig' -o \
        -iname '*.rej' -o \
        -iname '*.tmp' -o \
        -iname '*.swp' -o \
        -iname '*.tar' -o \
        -iname '*.tar.gz' -o \
        -iname '*.tgz' -o \
        -iname '*.zip' -o \
        -iname '*.7z' \
    \) \
    -printf '%P|%s bytes|%TY-%Tm-%Td %TH:%TM:%TS\n' \
    | sort \
    > "${REPORT_DIR}/repository/cleanup-candidate-files.txt"

grep -RInE \
    --exclude-dir=.git \
    --exclude-dir=postgres/data \
    --exclude-dir=grafana/data \
    --exclude-dir=grafana/plugins \
    --exclude-dir=node_modules \
    --exclude-dir=.venv \
    --exclude-dir=venv \
    --exclude='*.tar.gz' \
    --exclude='*.zip' \
    --exclude='*.dump' \
    --exclude='*.db' \
    '(public\.mqtt_staging|telemetry\.mqtt_staging|mqtt_staging|telegraf_ingest|legacy ingest|deprecated|obsolete|TODO|FIXME|temporary|workaround)' \
    "$REPO_ROOT" \
    > "${REPORT_DIR}/repository/stale-reference-search.txt" 2>&1 || true

log "Creating sanitized database schema dump"

docker compose exec -T "$DB_SERVICE" \
    pg_dump \
        -U "$DB_USER" \
        -d "$DB_NAME" \
        --schema-only \
        --no-owner \
        --no-privileges \
    > "${REPORT_DIR}/database/schema-only.sql"

log "Capturing live PostgreSQL catalog and pipeline definitions"

docker compose exec -T "$DB_SERVICE" \
psql -X -U "$DB_USER" -d "$DB_NAME" -P pager=off \
> "${REPORT_DIR}/database/database-audit.txt" <<'SQL'
\set ON_ERROR_STOP on

\echo '=== SERVER IDENTITY ==='
SELECT
    current_database(),
    current_user,
    version(),
    current_setting('server_version'),
    current_setting('TimeZone'),
    current_setting('search_path');

\echo
\echo '=== EXTENSIONS ==='
SELECT
    extname,
    extversion
FROM pg_extension
ORDER BY extname;

\echo
\echo '=== SCHEMAS ==='
SELECT
    nspname AS schema_name
FROM pg_namespace
WHERE nspname NOT LIKE 'pg_%'
  AND nspname <> 'information_schema'
ORDER BY nspname;

\echo
\echo '=== TABLES, VIEWS, MATERIALIZED VIEWS, SEQUENCES ==='
SELECT
    n.nspname AS schema_name,
    c.relname AS object_name,
    c.relkind,
    CASE c.relkind
        WHEN 'r' THEN 'table'
        WHEN 'p' THEN 'partitioned table'
        WHEN 'v' THEN 'view'
        WHEN 'm' THEN 'materialized view'
        WHEN 'S' THEN 'sequence'
        WHEN 'f' THEN 'foreign table'
        ELSE c.relkind::text
    END AS object_type,
    pg_size_pretty(pg_total_relation_size(c.oid)) AS total_size,
    c.reltuples::bigint AS estimated_rows
FROM pg_class c
JOIN pg_namespace n
  ON n.oid = c.relnamespace
WHERE n.nspname NOT LIKE 'pg_%'
  AND n.nspname <> 'information_schema'
  AND c.relkind IN ('r','p','v','m','S','f')
ORDER BY n.nspname, c.relname;

\echo
\echo '=== VIEW DEFINITIONS ==='
SELECT
    schemaname,
    viewname,
    definition
FROM pg_views
WHERE schemaname NOT LIKE 'pg_%'
  AND schemaname <> 'information_schema'
ORDER BY schemaname, viewname;

\echo
\echo '=== MATERIALIZED VIEW DEFINITIONS ==='
SELECT
    schemaname,
    matviewname,
    definition
FROM pg_matviews
WHERE schemaname NOT LIKE 'pg_%'
  AND schemaname <> 'information_schema'
ORDER BY schemaname, matviewname;

\echo
\echo '=== FUNCTIONS AND PROCEDURES ==='
SELECT
    n.nspname AS schema_name,
    p.proname AS routine_name,
    pg_get_function_identity_arguments(p.oid) AS arguments,
    CASE p.prokind
        WHEN 'f' THEN 'function'
        WHEN 'p' THEN 'procedure'
        WHEN 'w' THEN 'window'
    END AS routine_type,
    pg_get_functiondef(p.oid) AS definition
FROM pg_proc p
JOIN pg_namespace n
  ON n.oid = p.pronamespace
WHERE n.nspname NOT LIKE 'pg_%'
  AND n.nspname <> 'information_schema'
  AND p.prokind IN ('f', 'p', 'w')
ORDER BY n.nspname, p.proname, arguments;

\echo
\echo '=== AGGREGATES ==='
SELECT
    n.nspname AS schema_name,
    p.proname AS aggregate_name,
    pg_get_function_identity_arguments(p.oid) AS arguments,
    pg_get_function_result(p.oid) AS result_type,
    pg_get_userbyid(p.proowner) AS owner
FROM pg_proc p
JOIN pg_namespace n
  ON n.oid = p.pronamespace
WHERE n.nspname NOT LIKE 'pg_%'
  AND n.nspname <> 'information_schema'
  AND p.prokind = 'a'
ORDER BY n.nspname, p.proname, arguments;

\echo
\echo '=== INDEXES ==='
SELECT
    schemaname,
    tablename,
    indexname,
    indexdef
FROM pg_indexes
WHERE schemaname NOT LIKE 'pg_%'
  AND schemaname <> 'information_schema'
ORDER BY schemaname, tablename, indexname;

\echo
\echo '=== CONSTRAINTS ==='
SELECT
    n.nspname AS schema_name,
    c.relname AS table_name,
    con.conname AS constraint_name,
    con.contype AS constraint_type,
    pg_get_constraintdef(con.oid, true) AS definition
FROM pg_constraint con
JOIN pg_class c
  ON c.oid = con.conrelid
JOIN pg_namespace n
  ON n.oid = c.relnamespace
WHERE n.nspname NOT LIKE 'pg_%'
  AND n.nspname <> 'information_schema'
ORDER BY n.nspname, c.relname, con.conname;

\echo
\echo '=== TRIGGERS ==='
SELECT
    event_object_schema,
    event_object_table,
    trigger_name,
    action_timing,
    event_manipulation,
    action_statement
FROM information_schema.triggers
ORDER BY event_object_schema, event_object_table, trigger_name;

\echo
\echo '=== TABLE PRIVILEGES ==='
SELECT
    grantee,
    table_schema,
    table_name,
    privilege_type
FROM information_schema.role_table_grants
WHERE table_schema NOT LIKE 'pg_%'
  AND table_schema <> 'information_schema'
ORDER BY grantee, table_schema, table_name, privilege_type;

\echo
\echo '=== TIMESCALE HYPERTABLES ==='
SELECT *
FROM timescaledb_information.hypertables
ORDER BY hypertable_schema, hypertable_name;

\echo
\echo '=== TIMESCALE CONTINUOUS AGGREGATES ==='
SELECT *
FROM timescaledb_information.continuous_aggregates
ORDER BY view_schema, view_name;

\echo
\echo '=== TIMESCALE JOBS ==='
SELECT *
FROM timescaledb_information.jobs
ORDER BY job_id;

\echo
\echo '=== TIMESCALE JOB STATS ==='
SELECT *
FROM timescaledb_information.job_stats
ORDER BY job_id;

\echo
\echo '=== LIVE INGESTION OBJECT DEFINITIONS ==='
SELECT
    n.nspname AS schema_name,
    c.relname AS object_name,
    c.relkind,
    CASE
        WHEN c.relkind = 'v'
        THEN pg_get_viewdef(c.oid, true)
        ELSE NULL
    END AS view_definition
FROM pg_class c
JOIN pg_namespace n
  ON n.oid = c.relnamespace
WHERE c.relname IN (
    'raw_messages',
    'mqtt_staging',
    'v_rtdata',
    'v_normalized_points',
    'normalized_points',
    'energy_measurements'
)
ORDER BY n.nspname, c.relname;

\echo
\echo '=== TELEMETRY TABLE COUNTS ==='
SELECT
    schemaname,
    relname,
    n_live_tup,
    n_dead_tup,
    last_analyze,
    last_autoanalyze,
    last_vacuum,
    last_autovacuum
FROM pg_stat_user_tables
WHERE schemaname IN ('telemetry','analytics','metadata','config','admin','integration')
ORDER BY schemaname, relname;
SQL

log "Capturing metadata and orphan inventories without secrets"

docker compose exec -T "$DB_SERVICE" \
psql -X -U "$DB_USER" -d "$DB_NAME" -P pager=off \
> "${REPORT_DIR}/database/metadata-and-orphans.txt" <<'SQL'
\set ON_ERROR_STOP off

\echo '=== ORGANIZATIONS ==='
SELECT *
FROM metadata.organizations
ORDER BY created_at NULLS LAST, id;

\echo
\echo '=== SITES ==='
SELECT *
FROM metadata.sites
ORDER BY organization_id, created_at NULLS LAST, id;

\echo
\echo '=== GATEWAYS ==='
SELECT *
FROM metadata.gateways
ORDER BY organization_id, site_id, created_at NULLS LAST, id;

\echo
\echo '=== DEVICES ==='
SELECT *
FROM metadata.devices
ORDER BY organization_id, gateway_id, created_at NULLS LAST, id;

\echo
\echo '=== DEVICE IDENTIFIERS ==='
SELECT *
FROM metadata.device_identifiers
ORDER BY device_id, identifier_type, identifier_value;

\echo
\echo '=== ASSETS ==='
SELECT *
FROM metadata.assets
ORDER BY organization_id, site_id, parent_asset_id NULLS FIRST, id;

\echo
\echo '=== ASSET DEVICE ASSIGNMENTS ==='
SELECT *
FROM metadata.asset_devices
ORDER BY asset_id, device_id;

\echo
\echo '=== GRAFANA ORGANIZATION MAPPINGS ==='
SELECT *
FROM metadata.grafana_organization_map
ORDER BY organization_id;

\echo
\echo '=== DATABASE FOREIGN-KEY ORPHAN CHECKS ==='
WITH foreign_keys AS (
    SELECT
        con.oid,
        ns_child.nspname AS child_schema,
        child.relname AS child_table,
        ns_parent.nspname AS parent_schema,
        parent.relname AS parent_table,
        con.conname,
        con.conkey,
        con.confkey
    FROM pg_constraint con
    JOIN pg_class child
      ON child.oid = con.conrelid
    JOIN pg_namespace ns_child
      ON ns_child.oid = child.relnamespace
    JOIN pg_class parent
      ON parent.oid = con.confrelid
    JOIN pg_namespace ns_parent
      ON ns_parent.oid = parent.relnamespace
    WHERE con.contype = 'f'
      AND ns_child.nspname NOT LIKE 'pg_%'
)
SELECT
    child_schema,
    child_table,
    conname,
    parent_schema,
    parent_table
FROM foreign_keys
ORDER BY child_schema, child_table, conname;

\echo
\echo '=== TELEMETRY COUNTS BY ORGANIZATION ==='
SELECT
    organization_id,
    count(*) AS energy_rows,
    min(received_at) AS earliest_received,
    max(received_at) AS latest_received
FROM telemetry.energy_measurements
GROUP BY organization_id
ORDER BY organization_id;

\echo
\echo '=== RAW MESSAGE SUMMARY BY TOPIC ==='
SELECT
    source_topic,
    count(*) AS raw_message_count,
    min(received_at) AS earliest_received,
    max(received_at) AS latest_received
FROM telemetry.raw_messages
GROUP BY source_topic
ORDER BY source_topic;
SQL

log "Capturing sanitized Grafana inventory"

if [[ -f "${PRIVATE_BACKUP_DIR}/grafana-precleanup.db" ]]; then
    python3 - \
        "${PRIVATE_BACKUP_DIR}/grafana-precleanup.db" \
        "${REPORT_DIR}/grafana/grafana-inventory.txt" <<'PY'
import sqlite3
import sys
from pathlib import Path

db_path = Path(sys.argv[1])
output_path = Path(sys.argv[2])

queries = [
    (
        "GRAFANA DATABASE VERSION",
        """
        SELECT version, migration_log
        FROM migration_log
        ORDER BY id DESC
        LIMIT 20
        """,
    ),
    (
        "GRAFANA ORGANIZATIONS",
        """
        SELECT id, version, name, created, updated
        FROM org
        ORDER BY id
        """,
    ),
    (
        "GRAFANA USERS",
        """
        SELECT id, version, login, email, name, is_admin,
               is_disabled, created, updated
        FROM user
        ORDER BY id
        """,
    ),
    (
        "GRAFANA ORGANIZATION MEMBERSHIPS",
        """
        SELECT
            ou.org_id,
            o.name AS org_name,
            ou.user_id,
            u.login,
            u.email,
            ou.role,
            ou.created,
            ou.updated
        FROM org_user ou
        LEFT JOIN org o ON o.id = ou.org_id
        LEFT JOIN user u ON u.id = ou.user_id
        ORDER BY ou.org_id, ou.user_id
        """,
    ),
    (
        "GRAFANA DATASOURCES — SECRET FIELDS EXCLUDED",
        """
        SELECT
            id,
            org_id,
            version,
            type,
            name,
            access,
            url,
            database,
            user,
            is_default,
            json_data,
            created,
            updated
        FROM data_source
        ORDER BY org_id, id
        """,
    ),
    (
        "GRAFANA DASHBOARDS",
        """
        SELECT
            id,
            org_id,
            uid,
            title,
            slug,
            is_folder,
            folder_id,
            created,
            updated
        FROM dashboard
        ORDER BY org_id, is_folder DESC, title
        """,
    ),
    (
        "GRAFANA PLAYLISTS",
        """
        SELECT id, org_id, name, interval, created_at, updated_at
        FROM playlist
        ORDER BY org_id, id
        """,
    ),
    (
        "GRAFANA ALERT RULE COUNTS",
        """
        SELECT org_id, count(*) AS alert_rule_count
        FROM alert_rule
        GROUP BY org_id
        ORDER BY org_id
        """,
    ),
]

def format_row(row):
    return " | ".join("" if value is None else str(value) for value in row)

connection = sqlite3.connect(f"file:{db_path}?mode=ro", uri=True)

with output_path.open("w", encoding="utf-8") as output:
    for title, query in queries:
        output.write(f"\n=== {title} ===\n")
        try:
            cursor = connection.execute(query)
            columns = [item[0] for item in cursor.description]
            output.write(format_row(columns) + "\n")
            output.write("-" * 100 + "\n")
            for row in cursor.fetchall():
                output.write(format_row(row) + "\n")
        except sqlite3.Error as error:
            output.write(f"QUERY UNAVAILABLE: {error}\n")

connection.close()
PY
else
    echo "Grafana database not found." \
        > "${REPORT_DIR}/grafana/grafana-inventory.txt"
fi

log "Capturing service configuration without environment values"

cp compose.yaml \
    "${REPORT_DIR}/runtime/compose.yaml"

find telegraf grafana/provisioning grafana/dashboards caddy \
    -type f \
    ! -name '.env' \
    ! -name '.env.*' \
    ! -name '*.key' \
    ! -name '*.pem' \
    ! -name '*.p12' \
    ! -name '*.pfx' \
    ! -name '*.jks' \
    -print0 2>/dev/null \
    | sort -z \
    | xargs -0 -r sha256sum \
    > "${REPORT_DIR}/runtime/configuration-checksums.txt"

docker compose exec -T telegraf \
    sh -c '
        echo "=== TELEGRAF VERSION ==="
        telegraf version
        echo
        echo "=== CONFIGURATION STRUCTURE ==="
        grep -nE "^\[\[|^[[:space:]]*[a-zA-Z0-9_.-]+[[:space:]]*=" \
            /etc/telegraf/telegraf.conf \
        | sed -E \
            -e "s/(password|token|secret|username)[[:space:]]*=.*/\1 = \"REDACTED\"/Ig" \
            -e "s#(postgres(ql)?://)[^@[:space:]]+@#\1REDACTED@#Ig"
    ' \
    > "${REPORT_DIR}/runtime/telegraf-loaded-config-structure.txt" \
    2>&1 || true

log "Scanning sanitized snapshot for likely secret-bearing names"

tar -tzf "${AUDIT_DIR}/$(basename "$REPO_SNAPSHOT")" \
    > "${REPORT_DIR}/security/sanitized-snapshot-file-list.txt"

grep -Ei \
    '(^|/)(\.env($|\.)|secrets?/|credentials?/)|\.(key|pem|p12|pfx|jks|keystore)$|id_(rsa|ed25519)$' \
    "${REPORT_DIR}/security/sanitized-snapshot-file-list.txt" \
    > "${REPORT_DIR}/security/forbidden-file-name-check.txt" \
    || true

if [[ -s "${REPORT_DIR}/security/forbidden-file-name-check.txt" ]]; then
    fail "Sanitized bundle contains likely secret-bearing file names"
fi

log "Generating checksums"

(
    cd "$RUN_ROOT"
    find private-recovery sanitized-audit \
        -type f \
        -print0 \
        | sort -z \
        | xargs -0 sha256sum
) > "${RUN_ROOT}/SHA256SUMS.txt"

log "Packaging sanitized audit bundle"

SANITIZED_BUNDLE="${ARCHIVE_ROOT}/ems-preclient-audit-${TIMESTAMP}.tar.gz"

tar \
    -czf "$SANITIZED_BUNDLE" \
    -C "$RUN_ROOT" \
    sanitized-audit \
    SNAPSHOT_INFO.txt \
    SHA256SUMS.txt

chmod 600 "$SANITIZED_BUNDLE"

log "Verifying sanitized audit bundle"

tar -tzf "$SANITIZED_BUNDLE" \
    > "${RUN_ROOT}/sanitized-bundle-list.txt"

if grep -Eiq \
    '(^|/)\.env($|\.)|(^|/)(secrets?|credentials?)/|\.(key|pem|p12|pfx|jks|keystore)$|(^|/)grafana-precleanup\.db$|\.dump$' \
    "${RUN_ROOT}/sanitized-bundle-list.txt"; then
    fail "Sanitized audit bundle contains a prohibited file"
fi

log "Snapshot completed"

echo
echo "PRIVATE RECOVERY DIRECTORY — KEEP ON SERVER, DO NOT UPLOAD:"
echo "$PRIVATE_BACKUP_DIR"
echo
echo "SANITIZED AUDIT BUNDLE — UPLOAD THIS FILE:"
echo "$SANITIZED_BUNDLE"
echo
echo "Repository snapshot included inside audit bundle:"
echo "${AUDIT_DIR}/$(basename "$REPO_SNAPSHOT")"
echo
echo "Checksums:"
sha256sum "$SANITIZED_BUNDLE"
echo
ls -lh "$SANITIZED_BUNDLE"
