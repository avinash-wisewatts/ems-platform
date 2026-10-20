#!/usr/bin/env bash
# Build templates b2t_b1 (production's B1 state, 546a718: canonical deploy +
# 135 manifest migrations) and b2t_b2 (b2t_b1 after the real runner at
# ba2cb4b applied the 14 B2 migrations). LOCAL ONLY -- see lib.sh.
set -Eeuo pipefail
source "$(dirname "$0")/lib.sh"
B1_SHA=546a718dce6bcc005bcf32cff87947be3e9cb0fe
B2_SHA=ba2cb4be254644c3ebd4a30b02b68f1d1ae4d601
DB=b2e2e

src() {  # $1 sha -> exported tree with LF line endings (migration 267 needs LF)
  local dir="$B2T_WORK/src_${1:0:7}"
  rm -rf "$dir"; mkdir -p "$dir"
  git -C "$REPO" -c core.autocrlf=false archive "$1" | tar -x -C "$dir"
  echo "$dir"
}
# Stop the scheduler and close sessions so the database can serve as a template.
freeze() {
  adm -d "$1" -c "SELECT _timescaledb_functions.stop_background_workers()" >/dev/null
  adm -d postgres -c "SELECT count(pg_terminate_backend(pid)) FROM pg_stat_activity WHERE datname = '$1' AND pid <> pg_backend_pid()" >/dev/null
}
runner() {  # $1 source tree
  (cd "$1" && COMPOSE_FILE="$1/compose.test.yaml" DB_CONTAINER=timescaledb-test DB_NAME=$DB DB_USER=ems_admin \
     ./scripts/apply_migrations.sh)
}

SRC=$(src $B1_SHA)
adm -d postgres -c "DROP DATABASE IF EXISTS $DB WITH (FORCE)" -c "CREATE DATABASE $DB"
while IFS=',' read -r _ cat path _; do
  case "$cat" in canonical|reference|jobs) adm -v db_name=$DB -d $DB -f - < "$SRC/$path" > /dev/null ;; esac
done < "$SRC/postgres/restructure_manifest.csv"
runner "$SRC" > "$B2T_WORK/apply_b1.log" 2>&1
echo "546a718: $(grep -cE '^APPLY' "$B2T_WORK/apply_b1.log") APPLY"
freeze $DB
adm -d postgres -c "DROP DATABASE IF EXISTS b2t_b1" -c "CREATE DATABASE b2t_b1 TEMPLATE $DB"

SRC=$(src $B2_SHA)
runner "$SRC" > "$B2T_WORK/apply_b2.log" 2>&1
echo "ba2cb4b: $(grep -cE '^APPLY' "$B2T_WORK/apply_b2.log") APPLY, $(grep -cE '^SKIP' "$B2T_WORK/apply_b2.log") SKIP (expect 14, 135)"
freeze $DB
adm -d postgres -c "DROP DATABASE IF EXISTS b2t_b2" -c "CREATE DATABASE b2t_b2 TEMPLATE $DB" -c "DROP DATABASE $DB WITH (FORCE)"
echo TEMPLATES-READY
