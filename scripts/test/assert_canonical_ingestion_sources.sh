#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$PROJECT_ROOT"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

grep -q \
  'CREATE TABLE IF NOT EXISTS telemetry.raw_messages' \
  postgres/ddl/07_telemetry_archive.sql \
  || fail "canonical raw_messages table definition is missing"

grep -q \
  'CREATE OR REPLACE VIEW public.mqtt_staging' \
  postgres/ddl/07_01_telegraf_mqtt_staging.sql \
  || fail "public.mqtt_staging adapter view is missing"

grep -q \
  'INSTEAD OF INSERT ON public.mqtt_staging' \
  postgres/ddl/07_01_telegraf_mqtt_staging.sql \
  || fail "public.mqtt_staging insert trigger is missing"

grep -q \
  'FROM telemetry.raw_messages' \
  postgres/ddl/23_views.sql \
  || fail "v_rtdata does not read telemetry.raw_messages"

grep -q \
  'FROM telemetry.raw_messages' \
  postgres/ddl/41_incremental_normalization_loader.sql \
  || fail "normalization loader does not checkpoint against raw_messages"

if grep -q \
  'FROM public.mqtt_staging' \
  postgres/ddl/23_views.sql \
  postgres/ddl/41_incremental_normalization_loader.sql
then
    fail "active parser or normalization loader still reads public.mqtt_staging"
fi

if grep -Eq \
  '^[[:space:]]*CREATE TABLE.*telemetry\.(mqtt_staging|telegraf_ingest)' \
  postgres/ddl/07_02_mqtt_staging.sql \
  postgres/ddl/07_03_telegraf_ingest.sql
then
    fail "retired persistent staging table is still executable"
fi

python3 <<'PY2'
from pathlib import Path

rows = []
for line in Path("postgres/restructure_manifest.csv").read_text().splitlines():
    if not line or line.startswith("source_file,"):
        continue
    parts = line.split(",", 3)
    rows.append(parts)

by_name = {row[0]: row for row in rows}

assert by_name["07_telemetry_archive.sql"][1] == "canonical"
assert by_name["07_01_telegraf_mqtt_staging.sql"][1] == "canonical"
assert by_name["07_02_mqtt_staging.sql"][1] == "legacy"
assert by_name["07_03_telegraf_ingest.sql"][1] == "legacy"
assert by_name["07_04_telegraf_writer_grants.sql"][1] == "canonical"

order = [row[0] for row in rows]
assert order.index("07_telemetry_archive.sql") < order.index(
    "07_01_telegraf_mqtt_staging.sql"
)
assert order.index("07_01_telegraf_mqtt_staging.sql") < order.index(
    "07_04_telegraf_writer_grants.sql"
)
PY2

echo "PASS: canonical ingestion source assertions passed"
