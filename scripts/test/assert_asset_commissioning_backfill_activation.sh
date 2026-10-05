#!/usr/bin/env bash
set -Eeuo pipefail

# ============================================================================
# Regression test for migration 258: backfill completion -> ACTIVE
# lifecycle transition.
#
# Like assert_asset_commissioning_backfill_job.sh, this cannot use the
# standard BEGIN/ROLLBACK pattern: telemetry.process_asset_commissioning_
# backfill issues its own internal COMMIT, which PostgreSQL only allows at
# the top level. Every statement below is auto-committed; cleanup is an
# explicit trap.
#
# Covers:
#   1. COMMISSIONING + PENDING -> remains COMMISSIONING.
#   2. COMMISSIONING + RUNNING -> remains COMMISSIONING.
#   3. COMPLETED initial backfill -> ACTIVE.
#   4. FAILED -> remains COMMISSIONING.
#   5. FAILED -> retry -> COMPLETED -> ACTIVE.
#   6. Administrator moves the Asset to INACTIVE before completion ->
#      successful backfill must not silently reactivate it.
#   7. DECOMMISSIONED before completion -> must remain DECOMMISSIONED.
#   8. Repeated completion/retry is idempotent (no duplicate activation
#      audit row, no error, stays ACTIVE).
#   9. Existing lifecycle/audit behavior (admin.commission_asset(), fully
#      untouched by this migration) remains intact.
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

cleanup() {
    psql_exec -f - <<'SQL' > /dev/null 2>&1 || true
DELETE FROM telemetry.normalized_points
WHERE device_id IN (SELECT id FROM metadata.devices WHERE external_id LIKE 'BACKFILL-ACTIVATION-TEST-%');
DELETE FROM metadata.asset_commissioning_backfill
WHERE asset_id IN (SELECT id FROM metadata.assets WHERE name LIKE 'Backfill Activation Test Asset %');
DELETE FROM admin.onboarding_audit
WHERE requested_by IN ('backfill-activation-test-user', 'system:telemetry.process_asset_commissioning_backfill')
  AND (request_payload->>'asset_id') IN (SELECT id::text FROM metadata.assets WHERE name LIKE 'Backfill Activation Test Asset %');
DELETE FROM metadata.asset_points
WHERE asset_id IN (SELECT id FROM metadata.assets WHERE name LIKE 'Backfill Activation Test Asset %');
DELETE FROM metadata.asset_devices
WHERE asset_id IN (SELECT id FROM metadata.assets WHERE name LIKE 'Backfill Activation Test Asset %');
DELETE FROM metadata.assets WHERE name LIKE 'Backfill Activation Test Asset %';
DELETE FROM metadata.devices WHERE external_id LIKE 'BACKFILL-ACTIVATION-TEST-%';
DELETE FROM metadata.device_models WHERE model = 'Backfill Activation Test Meter';
DELETE FROM admin.portal_users WHERE username = 'backfill-activation-test-user';
DELETE FROM metadata.gateways WHERE external_id = 'BACKFILL-ACTIVATION-TEST-GW';
DELETE FROM metadata.sites WHERE code = 'BACKFILL_ACTIVATION_TEST_SITE';
DELETE FROM metadata.organizations WHERE code = 'BACKFILL_ACTIVATION_TEST_ORG';
SQL
}
trap cleanup EXIT

echo "=== Asset commissioning backfill activation assertions (migration 258) ==="

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

assert_eq() {
    local desc="$1" expected="$2" actual="$3"
    if [[ "${expected}" != "${actual}" ]]; then
        echo "FAIL: ${desc} -- expected '${expected}', got '${actual}'" >&2
        exit 1
    fi
}

# ----------------------------------------------------------------------------
# SETUP -- shared org/site/gateway/profile/user, plus one device+asset per
# scenario. Assets 1/2 only need a backfill record fixtured directly (no
# worker run at all -- these scenarios assert nothing happens). Assets
# 3/4/6/7 get a real device+point+telemetry+valid-audit fixture, matching
# migration 257's test idiom, with a PENDING backfill job.
# ----------------------------------------------------------------------------
run_sql "
DO \$setup\$
DECLARE
    v_energy_meter_category UUID;
    v_profile_id UUID;
    v_point_id UUID;
    v_org UUID; v_site UUID; v_gateway UUID; v_device_model UUID; v_user BIGINT;
    v_device UUID; v_asset UUID; v_ap UUID; v_audit UUID;
    v_now TIMESTAMPTZ := now();
BEGIN
    SELECT id INTO v_energy_meter_category FROM config.device_categories WHERE lower(name) = 'energy meter' ORDER BY id LIMIT 1;
    SELECT id INTO v_profile_id FROM config.device_profiles WHERE profile_code = 'ENERGY_METER_ENISCOPE_V1';
    SELECT id INTO v_point_id FROM metadata.logical_points WHERE name = 'ACTIVE_POWER_TOTAL';

    INSERT INTO metadata.organizations(name, code, timezone)
    VALUES ('Backfill Activation Test Org', 'BACKFILL_ACTIVATION_TEST_ORG', 'UTC') RETURNING id INTO v_org;
    INSERT INTO metadata.sites(organization_id, name, code, timezone, address, is_active)
    VALUES (v_org, 'Backfill Activation Test Site', 'BACKFILL_ACTIVATION_TEST_SITE', 'UTC', '{}'::jsonb, TRUE) RETURNING id INTO v_site;
    INSERT INTO metadata.gateways(organization_id, site_id, name, external_id)
    VALUES (v_org, v_site, 'Backfill Activation Test Gateway', 'BACKFILL-ACTIVATION-TEST-GW') RETURNING id INTO v_gateway;
    INSERT INTO metadata.device_models(vendor, model, device_type, device_category_id)
    VALUES ('WiseWatts Test', 'Backfill Activation Test Meter', 'Energy Meter', v_energy_meter_category)
    ON CONFLICT (lower(COALESCE(vendor, '')), lower(model))
    DO UPDATE SET device_type = EXCLUDED.device_type, device_category_id = EXCLUDED.device_category_id
    RETURNING id INTO v_device_model;
    INSERT INTO admin.portal_users(username, display_name, password_hash, role_code, is_active, access_scope_mode, organization_id, created_by)
    VALUES ('backfill-activation-test-user', 'Backfill Activation Test User', 'not-a-real-hash', 'OPERATOR', TRUE, 'ORGANIZATION', v_org, 'test-fixture')
    RETURNING portal_user_id INTO v_user;

    -- Asset 1: COMMISSIONING + PENDING (no device/point needed -- worker never runs on it).
    INSERT INTO metadata.assets(organization_id, site_id, name, status, lifecycle_status, metering_requirement)
    VALUES (v_org, v_site, 'Backfill Activation Test Asset 1', 'draft', 'COMMISSIONING', 'DIRECT_METER_REQUIRED') RETURNING id INTO v_asset;
    INSERT INTO metadata.asset_commissioning_backfill(asset_id, status, triggered_by_portal_user_id, requested_at)
    VALUES (v_asset, 'PENDING', v_user, v_now);

    -- Asset 2: COMMISSIONING + RUNNING (fixtured directly, simulating a
    -- job the worker has claimed but not finished).
    INSERT INTO metadata.assets(organization_id, site_id, name, status, lifecycle_status, metering_requirement)
    VALUES (v_org, v_site, 'Backfill Activation Test Asset 2', 'draft', 'COMMISSIONING', 'DIRECT_METER_REQUIRED') RETURNING id INTO v_asset;
    INSERT INTO metadata.asset_commissioning_backfill(asset_id, status, triggered_by_portal_user_id, requested_at, started_at)
    VALUES (v_asset, 'RUNNING', v_user, v_now, v_now);

    -- Asset 3: real fixture, PENDING -> will COMPLETE -> ACTIVE (scenario 3), later reused for idempotent rerun (scenario 8).
    INSERT INTO metadata.devices(organization_id, gateway_id, device_model_id, profile_id, name, external_id, protocol)
    VALUES (v_org, v_gateway, v_device_model, v_profile_id, 'Backfill Activation Meter 3', 'BACKFILL-ACTIVATION-TEST-3', 'MQTT') RETURNING id INTO v_device;
    INSERT INTO metadata.assets(organization_id, site_id, name, status, lifecycle_status, metering_requirement)
    VALUES (v_org, v_site, 'Backfill Activation Test Asset 3', 'draft', 'COMMISSIONING', 'DIRECT_METER_REQUIRED') RETURNING id INTO v_asset;
    INSERT INTO metadata.asset_devices(asset_id, device_id, relationship_type) VALUES (v_asset, v_device, 'PRIMARY_METER');
    INSERT INTO metadata.asset_points(asset_id, device_id, logical_point_id, organization_id, friendly_name, effective_from, effective_to)
    VALUES (v_asset, v_device, v_point_id, v_org, '3', v_now, NULL) RETURNING id INTO v_ap;
    INSERT INTO telemetry.normalized_points(event_time, organization_id, device_id, logical_point_id, numeric_value)
    VALUES (v_now - INTERVAL '2 days', v_org, v_device, v_point_id, 1);
    INSERT INTO admin.onboarding_audit(id, requested_by, request_payload, result_payload)
    VALUES (gen_random_uuid(), 'backfill-activation-test-user', '{}'::jsonb, jsonb_build_object('added', jsonb_build_array(jsonb_build_object('asset_point_id', v_ap))))
    RETURNING id INTO v_audit;
    INSERT INTO metadata.asset_commissioning_backfill(asset_id, status, triggered_by_portal_user_id, trigger_audit_transaction_id, requested_at)
    VALUES (v_asset, 'PENDING', v_user, v_audit, v_now);

    -- Asset 4: PENDING with NULL trigger_audit_transaction_id -> forces a
    -- deterministic FAILED (scenario 4), then a real fixture is attached
    -- separately for the retry (scenario 5).
    INSERT INTO metadata.devices(organization_id, gateway_id, device_model_id, profile_id, name, external_id, protocol)
    VALUES (v_org, v_gateway, v_device_model, v_profile_id, 'Backfill Activation Meter 4', 'BACKFILL-ACTIVATION-TEST-4', 'MQTT') RETURNING id INTO v_device;
    INSERT INTO metadata.assets(organization_id, site_id, name, status, lifecycle_status, metering_requirement)
    VALUES (v_org, v_site, 'Backfill Activation Test Asset 4', 'draft', 'COMMISSIONING', 'DIRECT_METER_REQUIRED') RETURNING id INTO v_asset;
    INSERT INTO metadata.asset_devices(asset_id, device_id, relationship_type) VALUES (v_asset, v_device, 'PRIMARY_METER');
    INSERT INTO metadata.asset_points(asset_id, device_id, logical_point_id, organization_id, friendly_name, effective_from, effective_to)
    VALUES (v_asset, v_device, v_point_id, v_org, '4', v_now, NULL) RETURNING id INTO v_ap;
    INSERT INTO telemetry.normalized_points(event_time, organization_id, device_id, logical_point_id, numeric_value)
    VALUES (v_now - INTERVAL '2 days', v_org, v_device, v_point_id, 1);
    INSERT INTO admin.onboarding_audit(id, requested_by, request_payload, result_payload)
    VALUES (gen_random_uuid(), 'backfill-activation-test-user', '{}'::jsonb, jsonb_build_object('added', jsonb_build_array(jsonb_build_object('asset_point_id', v_ap))))
    RETURNING id INTO v_audit;
    INSERT INTO metadata.asset_commissioning_backfill(asset_id, status, triggered_by_portal_user_id, trigger_audit_transaction_id, requested_at)
    VALUES (v_asset, 'PENDING', v_user, NULL, v_now);
    -- stash the VALID audit id for later use by the retry step (asset 4's real audit row).

    -- Asset 6: real fixture, PENDING -> administrator moves it to
    -- INACTIVE before the worker runs (scenario 6).
    INSERT INTO metadata.devices(organization_id, gateway_id, device_model_id, profile_id, name, external_id, protocol)
    VALUES (v_org, v_gateway, v_device_model, v_profile_id, 'Backfill Activation Meter 6', 'BACKFILL-ACTIVATION-TEST-6', 'MQTT') RETURNING id INTO v_device;
    INSERT INTO metadata.assets(organization_id, site_id, name, status, lifecycle_status, metering_requirement)
    VALUES (v_org, v_site, 'Backfill Activation Test Asset 6', 'draft', 'COMMISSIONING', 'DIRECT_METER_REQUIRED') RETURNING id INTO v_asset;
    INSERT INTO metadata.asset_devices(asset_id, device_id, relationship_type) VALUES (v_asset, v_device, 'PRIMARY_METER');
    INSERT INTO metadata.asset_points(asset_id, device_id, logical_point_id, organization_id, friendly_name, effective_from, effective_to)
    VALUES (v_asset, v_device, v_point_id, v_org, '6', v_now, NULL) RETURNING id INTO v_ap;
    INSERT INTO telemetry.normalized_points(event_time, organization_id, device_id, logical_point_id, numeric_value)
    VALUES (v_now - INTERVAL '2 days', v_org, v_device, v_point_id, 1);
    INSERT INTO admin.onboarding_audit(id, requested_by, request_payload, result_payload)
    VALUES (gen_random_uuid(), 'backfill-activation-test-user', '{}'::jsonb, jsonb_build_object('added', jsonb_build_array(jsonb_build_object('asset_point_id', v_ap))))
    RETURNING id INTO v_audit;
    INSERT INTO metadata.asset_commissioning_backfill(asset_id, status, triggered_by_portal_user_id, trigger_audit_transaction_id, requested_at)
    VALUES (v_asset, 'PENDING', v_user, v_audit, v_now);

    -- Asset 7: same as 6, but moved to DECOMMISSIONED before completion (scenario 7).
    INSERT INTO metadata.devices(organization_id, gateway_id, device_model_id, profile_id, name, external_id, protocol)
    VALUES (v_org, v_gateway, v_device_model, v_profile_id, 'Backfill Activation Meter 7', 'BACKFILL-ACTIVATION-TEST-7', 'MQTT') RETURNING id INTO v_device;
    INSERT INTO metadata.assets(organization_id, site_id, name, status, lifecycle_status, metering_requirement)
    VALUES (v_org, v_site, 'Backfill Activation Test Asset 7', 'draft', 'COMMISSIONING', 'DIRECT_METER_REQUIRED') RETURNING id INTO v_asset;
    INSERT INTO metadata.asset_devices(asset_id, device_id, relationship_type) VALUES (v_asset, v_device, 'PRIMARY_METER');
    INSERT INTO metadata.asset_points(asset_id, device_id, logical_point_id, organization_id, friendly_name, effective_from, effective_to)
    VALUES (v_asset, v_device, v_point_id, v_org, '7', v_now, NULL) RETURNING id INTO v_ap;
    INSERT INTO telemetry.normalized_points(event_time, organization_id, device_id, logical_point_id, numeric_value)
    VALUES (v_now - INTERVAL '2 days', v_org, v_device, v_point_id, 1);
    INSERT INTO admin.onboarding_audit(id, requested_by, request_payload, result_payload)
    VALUES (gen_random_uuid(), 'backfill-activation-test-user', '{}'::jsonb, jsonb_build_object('added', jsonb_build_array(jsonb_build_object('asset_point_id', v_ap))))
    RETURNING id INTO v_audit;
    INSERT INTO metadata.asset_commissioning_backfill(asset_id, status, triggered_by_portal_user_id, trigger_audit_transaction_id, requested_at)
    VALUES (v_asset, 'PENDING', v_user, v_audit, v_now);

    -- Asset 9: plain DRAFT asset, NOT_REQUIRED metering, for the
    -- admin.commission_asset() regression check (scenario 9) -- entirely
    -- unrelated to the asset_points/backfill machinery.
    INSERT INTO metadata.assets(organization_id, site_id, name, status, lifecycle_status, metering_requirement)
    VALUES (v_org, v_site, 'Backfill Activation Test Asset 9', 'draft', 'DRAFT', 'NOT_REQUIRED');
END;
\$setup\$;
"

ASSET1=$(scalar "SELECT id FROM metadata.assets WHERE name='Backfill Activation Test Asset 1';")
ASSET2=$(scalar "SELECT id FROM metadata.assets WHERE name='Backfill Activation Test Asset 2';")
ASSET3=$(scalar "SELECT id FROM metadata.assets WHERE name='Backfill Activation Test Asset 3';")
ASSET4=$(scalar "SELECT id FROM metadata.assets WHERE name='Backfill Activation Test Asset 4';")
ASSET6=$(scalar "SELECT id FROM metadata.assets WHERE name='Backfill Activation Test Asset 6';")
ASSET7=$(scalar "SELECT id FROM metadata.assets WHERE name='Backfill Activation Test Asset 7';")
ASSET9=$(scalar "SELECT id FROM metadata.assets WHERE name='Backfill Activation Test Asset 9';")

BACKFILL3=$(scalar "SELECT id FROM metadata.asset_commissioning_backfill WHERE asset_id='${ASSET3}';")
BACKFILL4=$(scalar "SELECT id FROM metadata.asset_commissioning_backfill WHERE asset_id='${ASSET4}';")
BACKFILL6=$(scalar "SELECT id FROM metadata.asset_commissioning_backfill WHERE asset_id='${ASSET6}';")
BACKFILL7=$(scalar "SELECT id FROM metadata.asset_commissioning_backfill WHERE asset_id='${ASSET7}';")
VALID_AUDIT_4=$(scalar "SELECT id FROM admin.onboarding_audit WHERE requested_by='backfill-activation-test-user' AND (result_payload->'added'->0->>'asset_point_id')=(SELECT id::text FROM metadata.asset_points WHERE asset_id='${ASSET4}');")

for v in "ASSET1:${ASSET1}" "ASSET2:${ASSET2}" "ASSET3:${ASSET3}" "ASSET4:${ASSET4}" "ASSET6:${ASSET6}" "ASSET7:${ASSET7}" "ASSET9:${ASSET9}" "BACKFILL3:${BACKFILL3}" "BACKFILL4:${BACKFILL4}" "BACKFILL6:${BACKFILL6}" "BACKFILL7:${BACKFILL7}" "VALID_AUDIT_4:${VALID_AUDIT_4}"; do
    name="${v%%:*}"; val="${v#*:}"
    if [[ -z "${val}" ]]; then
        echo "FAIL: fixture setup did not produce ${name}" >&2
        exit 1
    fi
done

# ----------------------------------------------------------------------------
# 1 & 2: PENDING / RUNNING -> remain COMMISSIONING (no worker run at all).
# ----------------------------------------------------------------------------
assert_eq "asset 1 (PENDING backfill) stays COMMISSIONING" "COMMISSIONING" "$(scalar "SELECT lifecycle_status FROM metadata.assets WHERE id='${ASSET1}';")"
echo "PASS: an asset with a PENDING backfill remains COMMISSIONING"

assert_eq "asset 2 (RUNNING backfill) stays COMMISSIONING" "COMMISSIONING" "$(scalar "SELECT lifecycle_status FROM metadata.assets WHERE id='${ASSET2}';")"
echo "PASS: an asset with a RUNNING backfill remains COMMISSIONING"

# ----------------------------------------------------------------------------
# 6 & 7: administrator moves the asset away BEFORE the worker runs.
# ----------------------------------------------------------------------------
run_sql "UPDATE metadata.assets SET lifecycle_status='INACTIVE', status='inactive' WHERE id='${ASSET6}';"
run_sql "UPDATE metadata.assets SET lifecycle_status='DECOMMISSIONED', status='inactive' WHERE id='${ASSET7}';"

# ----------------------------------------------------------------------------
# Run the worker -- processes assets 3 (succeeds -> should activate),
# 4 (fails -- NULL trigger), 6 (succeeds -- but must NOT reactivate,
# already moved to INACTIVE), 7 (succeeds -- must NOT reactivate,
# DECOMMISSIONED).
# ----------------------------------------------------------------------------
psql_exec -c "CALL telemetry.process_asset_commissioning_backfill(10);"

# ----------------------------------------------------------------------------
# 3. COMPLETED initial backfill -> ACTIVE.
# ----------------------------------------------------------------------------
assert_eq "asset 3's backfill status" "COMPLETED" "$(scalar "SELECT status FROM metadata.asset_commissioning_backfill WHERE id='${BACKFILL3}';")"
assert_eq "asset 3's lifecycle_status" "ACTIVE" "$(scalar "SELECT lifecycle_status FROM metadata.assets WHERE id='${ASSET3}';")"
echo "PASS: a successfully completed initial backfill transitions the asset to ACTIVE"

# ----------------------------------------------------------------------------
# 4. FAILED -> remains COMMISSIONING.
# ----------------------------------------------------------------------------
assert_eq "asset 4's backfill status" "FAILED" "$(scalar "SELECT status FROM metadata.asset_commissioning_backfill WHERE id='${BACKFILL4}';")"
assert_eq "asset 4's lifecycle_status" "COMMISSIONING" "$(scalar "SELECT lifecycle_status FROM metadata.assets WHERE id='${ASSET4}';")"
echo "PASS: a FAILED backfill leaves the asset in COMMISSIONING (not activated)"

# ----------------------------------------------------------------------------
# 5. FAILED -> retry -> COMPLETED -> ACTIVE.
# ----------------------------------------------------------------------------
RETRY_RESULT=$(scalar "SELECT telemetry.retry_failed_asset_commissioning_backfill('${BACKFILL4}')::text;")
assert_eq "retry return value" "true" "${RETRY_RESULT}"
run_sql "UPDATE metadata.asset_commissioning_backfill SET trigger_audit_transaction_id='${VALID_AUDIT_4}' WHERE id='${BACKFILL4}';"
psql_exec -c "CALL telemetry.process_asset_commissioning_backfill(10);"

assert_eq "asset 4's backfill status after retry" "COMPLETED" "$(scalar "SELECT status FROM metadata.asset_commissioning_backfill WHERE id='${BACKFILL4}';")"
assert_eq "asset 4's lifecycle_status after retry" "ACTIVE" "$(scalar "SELECT lifecycle_status FROM metadata.assets WHERE id='${ASSET4}';")"
echo "PASS: FAILED -> retry -> COMPLETED -> ACTIVE"

# ----------------------------------------------------------------------------
# 6 & 7 (continued): the completed-but-diverted jobs must not have
# reactivated the asset.
# ----------------------------------------------------------------------------
assert_eq "asset 6's backfill status" "COMPLETED" "$(scalar "SELECT status FROM metadata.asset_commissioning_backfill WHERE id='${BACKFILL6}';")"
assert_eq "asset 6's lifecycle_status (must stay INACTIVE)" "INACTIVE" "$(scalar "SELECT lifecycle_status FROM metadata.assets WHERE id='${ASSET6}';")"
echo "PASS: a successful backfill does not silently reactivate an asset an administrator moved to INACTIVE"

assert_eq "asset 7's backfill status" "COMPLETED" "$(scalar "SELECT status FROM metadata.asset_commissioning_backfill WHERE id='${BACKFILL7}';")"
assert_eq "asset 7's lifecycle_status (must stay DECOMMISSIONED)" "DECOMMISSIONED" "$(scalar "SELECT lifecycle_status FROM metadata.assets WHERE id='${ASSET7}';")"
echo "PASS: a successful backfill does not reactivate a DECOMMISSIONED asset"

# ----------------------------------------------------------------------------
# 8. Repeated completion/retry is idempotent -- rerun asset 3's
# already-COMPLETED/ACTIVE job; must stay ACTIVE, no duplicate activation
# audit row, no error.
# ----------------------------------------------------------------------------
AUDIT_COUNT_BEFORE=$(scalar "SELECT count(*) FROM admin.onboarding_audit WHERE (request_payload->>'asset_id')='${ASSET3}' AND request_payload->>'operation'='ACTIVATE_ASSET_AFTER_COMMISSIONING_BACKFILL';")
run_sql "UPDATE metadata.asset_commissioning_backfill SET status='PENDING', started_at=NULL, completed_at=NULL WHERE id='${BACKFILL3}';"
psql_exec -c "CALL telemetry.process_asset_commissioning_backfill(10);"
AUDIT_COUNT_AFTER=$(scalar "SELECT count(*) FROM admin.onboarding_audit WHERE (request_payload->>'asset_id')='${ASSET3}' AND request_payload->>'operation'='ACTIVATE_ASSET_AFTER_COMMISSIONING_BACKFILL';")

assert_eq "asset 3's backfill status after idempotent rerun" "COMPLETED" "$(scalar "SELECT status FROM metadata.asset_commissioning_backfill WHERE id='${BACKFILL3}';")"
assert_eq "asset 3's lifecycle_status after idempotent rerun" "ACTIVE" "$(scalar "SELECT lifecycle_status FROM metadata.assets WHERE id='${ASSET3}';")"
assert_eq "activation audit row count before rerun" "1" "${AUDIT_COUNT_BEFORE}"
assert_eq "activation audit row count after idempotent rerun (must not duplicate)" "1" "${AUDIT_COUNT_AFTER}"
echo "PASS: reprocessing an already-COMPLETED/ACTIVE job is idempotent -- no duplicate activation, no error"

# ----------------------------------------------------------------------------
# 9. Existing lifecycle/audit behavior (admin.commission_asset(), fully
# untouched by this migration) remains intact.
# ----------------------------------------------------------------------------
COMMISSION_RESULT=$(scalar "SELECT (admin.commission_asset((SELECT portal_user_id FROM admin.portal_users WHERE username='backfill-activation-test-user'), '${ASSET9}')->>'success')::text;")
assert_eq "admin.commission_asset() success" "true" "${COMMISSION_RESULT}"
assert_eq "asset 9's lifecycle_status after admin.commission_asset()" "ACTIVE" "$(scalar "SELECT lifecycle_status FROM metadata.assets WHERE id='${ASSET9}';")"
echo "PASS: admin.commission_asset() (untouched by this migration) still works exactly as before"

echo "Asset commissioning backfill activation assertions (migration 258) passed."
