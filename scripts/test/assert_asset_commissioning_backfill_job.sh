#!/usr/bin/env bash
set -Eeuo pipefail

# ============================================================================
# Regression test for migration 257's job-orchestration layer:
# telemetry.process_asset_commissioning_backfill (the FOR UPDATE SKIP
# LOCKED claiming procedure) and telemetry.retry_failed_asset_
# commissioning_backfill.
#
# This CANNOT use the standard BEGIN/ROLLBACK test pattern: the claiming
# procedure issues its own internal COMMIT (required so RUNNING is
# durably visible before work begins, and so a concurrent claimer never
# sees an in-flight job) -- PostgreSQL only allows a procedure with
# internal transaction control to be called at the top level, never
# nested inside an explicit transaction block. Every fixture/assertion
# statement below is therefore its own auto-committed statement, and
# cleanup is explicit (a trap, not ROLLBACK) -- see the CLEANUP section.
#
# Covers:
#   1. PENDING -> RUNNING -> COMPLETED (asset Y).
#   8. Failure -> FAILED, with SQLSTATE + message captured (asset Z,
#      fixtured with trigger_audit_transaction_id = NULL to force a
#      deterministic failure).
#   9. Retry after failure: requeue Z, fix the underlying cause, rerun ->
#      succeeds.
#  10. Idempotent rerun: reprocessing an already-COMPLETED job (Y) is a
#      safe no-op -- same effective_from, job still reports COMPLETED.
#  11. Concurrent workers cannot process the same Asset simultaneously:
#      a background session holds a row lock on asset X's backfill
#      record; a concurrent CALL to the claiming procedure must skip it
#      (FOR UPDATE SKIP LOCKED) while still processing the unlocked
#      asset Y job in the same batch.
# ============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

psql_exec() {
    docker compose -f "${PROJECT_ROOT}/compose.test.yaml" exec -T timescaledb-test \
        psql -X -v ON_ERROR_STOP=1 -U ems_admin -d ems_test "$@"
}

scalar() {
    psql_exec -tAc "$1" | tr -d '\r'
}

BG_PID=""

cleanup() {
    if [[ -n "${BG_PID}" ]] && kill -0 "${BG_PID}" 2>/dev/null; then
        wait "${BG_PID}" 2>/dev/null || true
    fi
    psql_exec -f - <<'SQL' > /dev/null 2>&1 || true
DELETE FROM telemetry.normalized_points
WHERE device_id IN (SELECT id FROM metadata.devices WHERE external_id LIKE 'BACKFILL-JOB-TEST-%');
DELETE FROM metadata.asset_commissioning_backfill
WHERE asset_id IN (SELECT id FROM metadata.assets WHERE name LIKE 'Backfill Job Test Asset %');
DELETE FROM admin.onboarding_audit
WHERE requested_by = 'backfill-job-test-user';
DELETE FROM metadata.asset_points
WHERE asset_id IN (SELECT id FROM metadata.assets WHERE name LIKE 'Backfill Job Test Asset %');
DELETE FROM metadata.asset_devices
WHERE asset_id IN (SELECT id FROM metadata.assets WHERE name LIKE 'Backfill Job Test Asset %');
DELETE FROM metadata.assets WHERE name LIKE 'Backfill Job Test Asset %';
DELETE FROM metadata.devices WHERE external_id LIKE 'BACKFILL-JOB-TEST-%';
DELETE FROM metadata.device_models WHERE model = 'Backfill Job Test Meter';
DELETE FROM admin.portal_users WHERE username = 'backfill-job-test-user';
DELETE FROM metadata.gateways WHERE external_id = 'BACKFILL-JOB-TEST-GW';
DELETE FROM metadata.sites WHERE code = 'BACKFILL_JOB_TEST_SITE';
DELETE FROM metadata.organizations WHERE code = 'BACKFILL_JOB_TEST_ORG';
SQL
}
trap cleanup EXIT

echo "=== Asset commissioning backfill job-orchestration assertions (migration 257) ==="

# Fail loudly, with the SQL error visible, instead of a bare "exit 3".
run_sql() {
    if ! psql_exec -f - <<SQL
$1
SQL
    then
        echo "FAILING SQL BLOCK:" >&2
        echo "$1" >&2
        exit 1
    fi
}

# ----------------------------------------------------------------------------
# SETUP -- shared org/site/gateway/profile/user, plus assets X, Y (both a
# real device+point+telemetry fixture, PENDING backfill jobs) and Z (a
# real device+point+telemetry+valid-audit fixture too, but its initial
# backfill job is deliberately created with trigger_audit_transaction_id
# NULL, to force a deterministic first failure for scenarios 8/9).
# ----------------------------------------------------------------------------
run_sql "
DO \$setup\$
DECLARE
    v_energy_meter_category UUID;
    v_profile_id UUID;
    v_point_id UUID;
    v_org UUID; v_site UUID; v_gateway UUID; v_device_model UUID; v_user BIGINT;
    v_device_x UUID; v_device_y UUID; v_device_z UUID;
    v_asset_x UUID; v_asset_y UUID; v_asset_z UUID;
    v_ap_x UUID; v_ap_y UUID; v_ap_z UUID;
    v_audit_x UUID; v_audit_y UUID; v_audit_z UUID;
    v_now TIMESTAMPTZ := now();
BEGIN
    SELECT id INTO v_energy_meter_category FROM config.device_categories WHERE lower(name) = 'energy meter' ORDER BY id LIMIT 1;
    SELECT id INTO v_profile_id FROM config.device_profiles WHERE profile_code = 'ENERGY_METER_ENISCOPE_V1';
    SELECT id INTO v_point_id FROM metadata.logical_points WHERE name = 'ACTIVE_POWER_TOTAL';

    INSERT INTO metadata.organizations(name, code, timezone)
    VALUES ('Backfill Job Test Org', 'BACKFILL_JOB_TEST_ORG', 'UTC') RETURNING id INTO v_org;
    INSERT INTO metadata.sites(organization_id, name, code, timezone, address, is_active)
    VALUES (v_org, 'Backfill Job Test Site', 'BACKFILL_JOB_TEST_SITE', 'UTC', '{}'::jsonb, TRUE) RETURNING id INTO v_site;
    INSERT INTO metadata.gateways(organization_id, site_id, name, external_id)
    VALUES (v_org, v_site, 'Backfill Job Test Gateway', 'BACKFILL-JOB-TEST-GW') RETURNING id INTO v_gateway;
    INSERT INTO metadata.device_models(vendor, model, device_type, device_category_id)
    VALUES ('WiseWatts Test', 'Backfill Job Test Meter', 'Energy Meter', v_energy_meter_category)
    ON CONFLICT (lower(COALESCE(vendor, '')), lower(model))
    DO UPDATE SET device_type = EXCLUDED.device_type, device_category_id = EXCLUDED.device_category_id
    RETURNING id INTO v_device_model;
    INSERT INTO admin.portal_users(username, display_name, password_hash, role_code, is_active, access_scope_mode, organization_id, created_by)
    VALUES ('backfill-job-test-user', 'Backfill Job Test User', 'not-a-real-hash', 'OPERATOR', TRUE, 'ORGANIZATION', v_org, 'test-fixture')
    RETURNING portal_user_id INTO v_user;

    -- Asset X (locked during the concurrency window -- scenario 11).
    INSERT INTO metadata.devices(organization_id, gateway_id, device_model_id, profile_id, name, external_id, protocol)
    VALUES (v_org, v_gateway, v_device_model, v_profile_id, 'Backfill Job Test Meter X', 'BACKFILL-JOB-TEST-X', 'MQTT') RETURNING id INTO v_device_x;
    INSERT INTO metadata.assets(organization_id, site_id, name, status, lifecycle_status, metering_requirement)
    VALUES (v_org, v_site, 'Backfill Job Test Asset X', 'draft', 'COMMISSIONING', 'DIRECT_METER_REQUIRED') RETURNING id INTO v_asset_x;
    INSERT INTO metadata.asset_devices(asset_id, device_id, relationship_type) VALUES (v_asset_x, v_device_x, 'PRIMARY_METER');
    INSERT INTO metadata.asset_points(asset_id, device_id, logical_point_id, organization_id, friendly_name, effective_from, effective_to)
    VALUES (v_asset_x, v_device_x, v_point_id, v_org, 'X', v_now, NULL) RETURNING id INTO v_ap_x;
    INSERT INTO telemetry.normalized_points(event_time, organization_id, device_id, logical_point_id, numeric_value)
    VALUES (v_now - INTERVAL '5 days', v_org, v_device_x, v_point_id, 1);
    INSERT INTO admin.onboarding_audit(id, requested_by, request_payload, result_payload)
    VALUES (gen_random_uuid(), 'backfill-job-test-user', '{}'::jsonb, jsonb_build_object('added', jsonb_build_array(jsonb_build_object('asset_point_id', v_ap_x))))
    RETURNING id INTO v_audit_x;
    INSERT INTO metadata.asset_commissioning_backfill(asset_id, status, triggered_by_portal_user_id, trigger_audit_transaction_id, requested_at)
    VALUES (v_asset_x, 'PENDING', v_user, v_audit_x, v_now);

    -- Asset Y (the normal PENDING->RUNNING->COMPLETED case -- scenarios
    -- 1 and 10).
    INSERT INTO metadata.devices(organization_id, gateway_id, device_model_id, profile_id, name, external_id, protocol)
    VALUES (v_org, v_gateway, v_device_model, v_profile_id, 'Backfill Job Test Meter Y', 'BACKFILL-JOB-TEST-Y', 'MQTT') RETURNING id INTO v_device_y;
    INSERT INTO metadata.assets(organization_id, site_id, name, status, lifecycle_status, metering_requirement)
    VALUES (v_org, v_site, 'Backfill Job Test Asset Y', 'draft', 'COMMISSIONING', 'DIRECT_METER_REQUIRED') RETURNING id INTO v_asset_y;
    INSERT INTO metadata.asset_devices(asset_id, device_id, relationship_type) VALUES (v_asset_y, v_device_y, 'PRIMARY_METER');
    INSERT INTO metadata.asset_points(asset_id, device_id, logical_point_id, organization_id, friendly_name, effective_from, effective_to)
    VALUES (v_asset_y, v_device_y, v_point_id, v_org, 'Y', v_now, NULL) RETURNING id INTO v_ap_y;
    INSERT INTO telemetry.normalized_points(event_time, organization_id, device_id, logical_point_id, numeric_value)
    VALUES (v_now - INTERVAL '7 days', v_org, v_device_y, v_point_id, 1);
    INSERT INTO admin.onboarding_audit(id, requested_by, request_payload, result_payload)
    VALUES (gen_random_uuid(), 'backfill-job-test-user', '{}'::jsonb, jsonb_build_object('added', jsonb_build_array(jsonb_build_object('asset_point_id', v_ap_y))))
    RETURNING id INTO v_audit_y;
    INSERT INTO metadata.asset_commissioning_backfill(asset_id, status, triggered_by_portal_user_id, trigger_audit_transaction_id, requested_at)
    VALUES (v_asset_y, 'PENDING', v_user, v_audit_y, v_now);

    -- Asset Z: a REAL, valid device+point+telemetry+audit fixture exists
    -- (so a later retry can genuinely succeed), but the initial backfill
    -- job deliberately points trigger_audit_transaction_id at NULL to
    -- force a deterministic first failure -- scenarios 8 and 9.
    INSERT INTO metadata.devices(organization_id, gateway_id, device_model_id, profile_id, name, external_id, protocol)
    VALUES (v_org, v_gateway, v_device_model, v_profile_id, 'Backfill Job Test Meter Z', 'BACKFILL-JOB-TEST-Z', 'MQTT') RETURNING id INTO v_device_z;
    INSERT INTO metadata.assets(organization_id, site_id, name, status, lifecycle_status, metering_requirement)
    VALUES (v_org, v_site, 'Backfill Job Test Asset Z', 'draft', 'COMMISSIONING', 'DIRECT_METER_REQUIRED') RETURNING id INTO v_asset_z;
    INSERT INTO metadata.asset_devices(asset_id, device_id, relationship_type) VALUES (v_asset_z, v_device_z, 'PRIMARY_METER');
    INSERT INTO metadata.asset_points(asset_id, device_id, logical_point_id, organization_id, friendly_name, effective_from, effective_to)
    VALUES (v_asset_z, v_device_z, v_point_id, v_org, 'Z', v_now, NULL) RETURNING id INTO v_ap_z;
    INSERT INTO telemetry.normalized_points(event_time, organization_id, device_id, logical_point_id, numeric_value)
    VALUES (v_now - INTERVAL '3 days', v_org, v_device_z, v_point_id, 1);
    INSERT INTO admin.onboarding_audit(id, requested_by, request_payload, result_payload)
    VALUES (gen_random_uuid(), 'backfill-job-test-user', '{}'::jsonb, jsonb_build_object('added', jsonb_build_array(jsonb_build_object('asset_point_id', v_ap_z))))
    RETURNING id INTO v_audit_z;
    INSERT INTO metadata.asset_commissioning_backfill(asset_id, status, triggered_by_portal_user_id, trigger_audit_transaction_id, requested_at)
    VALUES (v_asset_z, 'PENDING', v_user, NULL, v_now);
END;
\$setup\$;
"

BACKFILL_X=$(scalar "SELECT b.id FROM metadata.asset_commissioning_backfill b JOIN metadata.assets a ON a.id=b.asset_id WHERE a.name='Backfill Job Test Asset X';")
BACKFILL_Y=$(scalar "SELECT b.id FROM metadata.asset_commissioning_backfill b JOIN metadata.assets a ON a.id=b.asset_id WHERE a.name='Backfill Job Test Asset Y';")
BACKFILL_Z=$(scalar "SELECT b.id FROM metadata.asset_commissioning_backfill b JOIN metadata.assets a ON a.id=b.asset_id WHERE a.name='Backfill Job Test Asset Z';")
VALID_AUDIT_Z=$(scalar "SELECT id FROM admin.onboarding_audit WHERE requested_by='backfill-job-test-user' AND result_payload->'added'->0->>'asset_point_id' = (SELECT id::text FROM metadata.asset_points WHERE asset_id=(SELECT id FROM metadata.assets WHERE name='Backfill Job Test Asset Z'));")

if [[ -z "${BACKFILL_X}" || -z "${BACKFILL_Y}" || -z "${BACKFILL_Z}" || -z "${VALID_AUDIT_Z}" ]]; then
    echo "FAIL: fixture setup did not produce the expected backfill/audit IDs" >&2
    exit 1
fi

# ----------------------------------------------------------------------------
# 11. Concurrency: hold a row lock on X's backfill record in a background
#     session, then run the claiming procedure -- it must skip X (still
#     PENDING afterward) while still processing Y and Z in the same batch.
# ----------------------------------------------------------------------------
(
    psql_exec -f - <<SQL
BEGIN;
SELECT * FROM metadata.asset_commissioning_backfill WHERE id = '${BACKFILL_X}' FOR UPDATE;
SELECT pg_sleep(5);
COMMIT;
SQL
) > /tmp/backfill_job_test_lock_session.log 2>&1 &
BG_PID=$!

sleep 2  # let the background session acquire the FOR UPDATE lock

psql_exec -c "CALL telemetry.process_asset_commissioning_backfill(10);"

STATUS_X_DURING_LOCK=$(scalar "SELECT status FROM metadata.asset_commissioning_backfill WHERE id='${BACKFILL_X}';")
if [[ "${STATUS_X_DURING_LOCK}" != "PENDING" ]]; then
    echo "FAIL: expected asset X's backfill job to remain PENDING (skipped, FOR UPDATE SKIP LOCKED) while locked by the concurrent session, found ${STATUS_X_DURING_LOCK}" >&2
    exit 1
fi
echo "PASS: a concurrently locked backfill record is skipped (FOR UPDATE SKIP LOCKED), not double-claimed"

wait "${BG_PID}"
BG_PID=""

# ----------------------------------------------------------------------------
# 1. PENDING -> RUNNING -> COMPLETED (asset Y, processed in the batch
#    above while X was locked).
# ----------------------------------------------------------------------------
STATUS_Y=$(scalar "SELECT status FROM metadata.asset_commissioning_backfill WHERE id='${BACKFILL_Y}';")
if [[ "${STATUS_Y}" != "COMPLETED" ]]; then
    echo "FAIL: expected asset Y's backfill job to be COMPLETED, found ${STATUS_Y}" >&2
    exit 1
fi
STARTED_Y=$(scalar "SELECT (started_at IS NOT NULL)::text FROM metadata.asset_commissioning_backfill WHERE id='${BACKFILL_Y}';")
COMPLETED_Y=$(scalar "SELECT (completed_at IS NOT NULL)::text FROM metadata.asset_commissioning_backfill WHERE id='${BACKFILL_Y}';")
if [[ "${STARTED_Y}" != "true" || "${COMPLETED_Y}" != "true" ]]; then
    echo "FAIL: expected asset Y's backfill record to have started_at and completed_at set, got started=${STARTED_Y} completed=${COMPLETED_Y}" >&2
    exit 1
fi
EFFECTIVE_FROM_Y_1=$(scalar "SELECT effective_from::text FROM metadata.asset_points WHERE asset_id=(SELECT id FROM metadata.assets WHERE name='Backfill Job Test Asset Y');")
echo "PASS: PENDING -> RUNNING -> COMPLETED, with started_at/completed_at durably recorded"

# ----------------------------------------------------------------------------
# 8. Failure -> FAILED (asset Z's first attempt, NULL trigger_audit_
#    transaction_id).
# ----------------------------------------------------------------------------
STATUS_Z=$(scalar "SELECT status FROM metadata.asset_commissioning_backfill WHERE id='${BACKFILL_Z}';")
if [[ "${STATUS_Z}" != "FAILED" ]]; then
    echo "FAIL: expected asset Z's backfill job to be FAILED, found ${STATUS_Z}" >&2
    exit 1
fi
LAST_ERROR_Z=$(scalar "SELECT last_error FROM metadata.asset_commissioning_backfill WHERE id='${BACKFILL_Z}';")
if [[ -z "${LAST_ERROR_Z}" ]]; then
    echo "FAIL: expected asset Z's backfill record to have a non-empty last_error" >&2
    exit 1
fi
echo "PASS: a failing job transitions to FAILED with a captured error (last_error: ${LAST_ERROR_Z})"

# ----------------------------------------------------------------------------
# 9. Retry after failure -- requeue Z, fix the underlying cause (point it
#    at Z's own valid audit row instead of NULL), rerun -> succeeds.
# ----------------------------------------------------------------------------
RETRY_RESULT=$(scalar "SELECT telemetry.retry_failed_asset_commissioning_backfill('${BACKFILL_Z}')::text;")
if [[ "${RETRY_RESULT}" != "true" ]]; then
    echo "FAIL: expected retry_failed_asset_commissioning_backfill to return true, got ${RETRY_RESULT}" >&2
    exit 1
fi
STATUS_Z_AFTER_RETRY=$(scalar "SELECT status FROM metadata.asset_commissioning_backfill WHERE id='${BACKFILL_Z}';")
if [[ "${STATUS_Z_AFTER_RETRY}" != "PENDING" ]]; then
    echo "FAIL: expected asset Z's backfill job to be back to PENDING after retry, found ${STATUS_Z_AFTER_RETRY}" >&2
    exit 1
fi

run_sql "UPDATE metadata.asset_commissioning_backfill SET trigger_audit_transaction_id = '${VALID_AUDIT_Z}' WHERE id = '${BACKFILL_Z}';"
psql_exec -c "CALL telemetry.process_asset_commissioning_backfill(10);"

STATUS_Z_FINAL=$(scalar "SELECT status FROM metadata.asset_commissioning_backfill WHERE id='${BACKFILL_Z}';")
if [[ "${STATUS_Z_FINAL}" != "COMPLETED" ]]; then
    echo "FAIL: expected asset Z's backfill job to COMPLETE after retry with the underlying cause fixed, found ${STATUS_Z_FINAL}" >&2
    exit 1
fi
echo "PASS: retry after failure (requeue FAILED -> PENDING, fix the cause, rerun) succeeds"

# ----------------------------------------------------------------------------
# 10. Idempotent rerun -- reprocessing an already-COMPLETED job (Y) is a
#     safe no-op: same effective_from, still COMPLETED.
# ----------------------------------------------------------------------------
run_sql "UPDATE metadata.asset_commissioning_backfill SET status='PENDING', started_at=NULL, completed_at=NULL WHERE id = '${BACKFILL_Y}';"
psql_exec -c "CALL telemetry.process_asset_commissioning_backfill(10);"

STATUS_Y_RERUN=$(scalar "SELECT status FROM metadata.asset_commissioning_backfill WHERE id='${BACKFILL_Y}';")
EFFECTIVE_FROM_Y_2=$(scalar "SELECT effective_from::text FROM metadata.asset_points WHERE asset_id=(SELECT id FROM metadata.assets WHERE name='Backfill Job Test Asset Y');")
ATTEMPT_COUNT_Y=$(scalar "SELECT attempt_count FROM metadata.asset_commissioning_backfill WHERE id='${BACKFILL_Y}';")

if [[ "${STATUS_Y_RERUN}" != "COMPLETED" ]]; then
    echo "FAIL: expected asset Y's backfill job to COMPLETE again on rerun, found ${STATUS_Y_RERUN}" >&2
    exit 1
fi
if [[ "${EFFECTIVE_FROM_Y_1}" != "${EFFECTIVE_FROM_Y_2}" ]]; then
    echo "FAIL: expected effective_from to converge (unchanged) on an idempotent rerun, was ${EFFECTIVE_FROM_Y_1} now ${EFFECTIVE_FROM_Y_2}" >&2
    exit 1
fi
if [[ "${ATTEMPT_COUNT_Y}" -lt 2 ]]; then
    echo "FAIL: expected attempt_count >= 2 after a genuine rerun, found ${ATTEMPT_COUNT_Y}" >&2
    exit 1
fi
echo "PASS: reprocessing an already-COMPLETED job is idempotent -- effective_from converges, no spurious change"

# ----------------------------------------------------------------------------
# Once the lock is released, X's job can be claimed and completes too.
# ----------------------------------------------------------------------------
psql_exec -c "CALL telemetry.process_asset_commissioning_backfill(10);"
STATUS_X_FINAL=$(scalar "SELECT status FROM metadata.asset_commissioning_backfill WHERE id='${BACKFILL_X}';")
if [[ "${STATUS_X_FINAL}" != "COMPLETED" ]]; then
    echo "FAIL: expected asset X's backfill job to complete once no longer locked, found ${STATUS_X_FINAL}" >&2
    exit 1
fi
echo "PASS: the previously-locked job is claimed and completes normally once the lock is released"

echo "Asset commissioning backfill job-orchestration assertions (migration 257) passed."
