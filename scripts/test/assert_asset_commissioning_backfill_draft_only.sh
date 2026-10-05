#!/usr/bin/env bash
set -Eeuo pipefail

# ============================================================================
# Regression test for migration 287 (DRAFT-only initial commissioning,
# COMMISSIONING-only backfill guard, defective-record cleanup).
#
#   A. Save behaviour (one transaction, rolled back):
#      A1 ACTIVE asset, no backfill record: adding points creates no
#         record, commissioning_triggered=false, lifecycle stays ACTIVE,
#         the new points start at the Save.
#      A2 DRAFT asset: first added point -> COMMISSIONING + one PENDING
#         record + commissioning_triggered=true (behaviour preserved); a
#         second Save adds a point without re-triggering.
#      A3 INACTIVE asset: no record, commissioning_triggered=false,
#         lifecycle stays INACTIVE.
#      A4 the guard, called directly on a PENDING record of an ACTIVE
#         asset, raises and changes no asset_points row.
#   B. The real worker (telemetry.process_asset_commissioning_backfill,
#      which COMMITs internally, so fixtures are committed and removed by a
#      trap): a never-attempted PENDING record for an ACTIVE asset -- the
#      defect's exact shape -- becomes FAILED with the refusal reason; no
#      assignment start date moves; the asset stays ACTIVE; no activation.
#   C. The cleanup block, executed verbatim from the migration file
#      (between its BEGIN/END markers) inside a rolled-back transaction:
#      deletes only PENDING never-attempted records of non-COMMISSIONING
#      assets, keeps every other record and every audit row, and refuses
#      (raises, deleting nothing) when more than 2 would be deleted.
# ============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
MIGRATION="${PROJECT_ROOT}/postgres/migrations/287_asset_commissioning_backfill_draft_only.sql"

psql_exec() {
    docker compose -f "${PROJECT_ROOT}/compose.test.yaml" exec -T timescaledb-test \
        psql -X -v ON_ERROR_STOP=1 -U ems_admin -d ems_test "$@"
}

scalar() {
    psql_exec -tAc "$1" | tr -d '\r'
}

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

cleanup() {
    psql_exec -f - <<'SQL' > /dev/null 2>&1 || true
DELETE FROM metadata.asset_commissioning_backfill
WHERE asset_id IN (SELECT id FROM metadata.assets WHERE name LIKE 'M287 Test Asset %');
DELETE FROM admin.onboarding_audit WHERE requested_by = 'm287-test-user';
DELETE FROM metadata.asset_points
WHERE asset_id IN (SELECT id FROM metadata.assets WHERE name LIKE 'M287 Test Asset %');
DELETE FROM metadata.asset_devices
WHERE asset_id IN (SELECT id FROM metadata.assets WHERE name LIKE 'M287 Test Asset %');
DELETE FROM metadata.assets WHERE name LIKE 'M287 Test Asset %';
DELETE FROM metadata.devices WHERE external_id LIKE 'M287-TEST-%';
DELETE FROM metadata.device_models WHERE model = 'M287 Test Meter';
DELETE FROM admin.portal_users WHERE username = 'm287-test-user';
DELETE FROM metadata.gateways WHERE external_id = 'M287-TEST-GW';
DELETE FROM metadata.sites WHERE code = 'M287_TEST_SITE';
DELETE FROM metadata.organizations WHERE code = 'M287_TEST_ORG';
SQL
}
trap cleanup EXIT
cleanup

echo "=== Migration 287: DRAFT-only commissioning, COMMISSIONING-only backfill guard, cleanup ==="

# Shared fixture body: one org/site/gateway/user and one metered device per
# asset. Used both inside the rolled-back transactions (A, C) and committed
# for the worker scenario (B).
FIXTURE_DECLARE='
    v_category UUID; v_profile UUID; v_model UUID;
    v_org UUID; v_site UUID; v_gateway UUID; v_user BIGINT;
    v_p_active_power UUID; v_p_power_factor UUID; v_p_frequency UUID;
'
FIXTURE_BASE='
    SELECT id INTO v_category FROM config.device_categories WHERE lower(name) = '"'"'energy meter'"'"' ORDER BY id LIMIT 1;
    SELECT id INTO v_profile FROM config.device_profiles WHERE profile_code = '"'"'ENERGY_METER_ENISCOPE_V1'"'"';
    SELECT id INTO v_p_active_power FROM metadata.logical_points WHERE name = '"'"'ACTIVE_POWER_TOTAL'"'"';
    SELECT id INTO v_p_power_factor FROM metadata.logical_points WHERE name = '"'"'POWER_FACTOR_TOTAL'"'"';
    SELECT id INTO v_p_frequency    FROM metadata.logical_points WHERE name = '"'"'FREQUENCY'"'"';
    IF v_category IS NULL OR v_profile IS NULL OR v_p_active_power IS NULL OR v_p_power_factor IS NULL OR v_p_frequency IS NULL THEN
        RAISE EXCEPTION '"'"'Fixture prerequisites missing (energy meter category, ENERGY_METER_ENISCOPE_V1, ACTIVE_POWER_TOTAL/POWER_FACTOR_TOTAL/FREQUENCY)'"'"';
    END IF;
    INSERT INTO metadata.organizations(name, code, timezone) VALUES ('"'"'M287 Test Org'"'"', '"'"'M287_TEST_ORG'"'"', '"'"'UTC'"'"') RETURNING id INTO v_org;
    INSERT INTO metadata.sites(organization_id, name, code, timezone, address, is_active)
    VALUES (v_org, '"'"'M287 Test Site'"'"', '"'"'M287_TEST_SITE'"'"', '"'"'UTC'"'"', '"'"'{}'"'"'::jsonb, TRUE) RETURNING id INTO v_site;
    INSERT INTO metadata.gateways(organization_id, site_id, name, external_id)
    VALUES (v_org, v_site, '"'"'M287 Test Gateway'"'"', '"'"'M287-TEST-GW'"'"') RETURNING id INTO v_gateway;
    INSERT INTO metadata.device_models(vendor, model, device_type, device_category_id)
    VALUES ('"'"'WiseWatts Test'"'"', '"'"'M287 Test Meter'"'"', '"'"'Energy Meter'"'"', v_category)
    ON CONFLICT (lower(COALESCE(vendor, '"'"''"'"')), lower(model))
    DO UPDATE SET device_type = EXCLUDED.device_type, device_category_id = EXCLUDED.device_category_id
    RETURNING id INTO v_model;
    INSERT INTO admin.portal_users(username, display_name, password_hash, role_code, is_active, access_scope_mode, organization_id, created_by)
    VALUES ('"'"'m287-test-user'"'"', '"'"'M287 Test User'"'"', '"'"'not-a-real-hash'"'"', '"'"'OPERATOR'"'"', TRUE, '"'"'ORGANIZATION'"'"', v_org, '"'"'test-fixture'"'"')
    RETURNING portal_user_id INTO v_user;
'

# ----------------------------------------------------------------------------
# A. Save behaviour + direct guard call (rolled back).
# ----------------------------------------------------------------------------
run_sql "
BEGIN;
CREATE OR REPLACE FUNCTION pg_temp.m287_asset(p_org UUID, p_site UUID, p_gateway UUID, p_model UUID, p_profile UUID, p_label TEXT, p_lifecycle TEXT)
RETURNS UUID[] LANGUAGE plpgsql AS \$f\$
DECLARE v_device UUID; v_asset UUID;
BEGIN
    INSERT INTO metadata.devices(organization_id, gateway_id, device_model_id, profile_id, name, external_id, protocol)
    VALUES (p_org, p_gateway, p_model, p_profile, 'M287 Test Meter ' || p_label, 'M287-TEST-' || p_label, 'MQTT') RETURNING id INTO v_device;
    INSERT INTO metadata.assets(organization_id, site_id, name, status, lifecycle_status, metering_requirement)
    VALUES (p_org, p_site, 'M287 Test Asset ' || p_label, lower(p_lifecycle), p_lifecycle, 'DIRECT_METER_REQUIRED') RETURNING id INTO v_asset;
    INSERT INTO metadata.asset_devices(asset_id, device_id, relationship_type) VALUES (v_asset, v_device, 'PRIMARY_METER');
    RETURN ARRAY[v_asset, v_device];
END;
\$f\$;

DO \$a\$
DECLARE
    ${FIXTURE_DECLARE}
    v_ids UUID[]; v_result JSONB; v_count INTEGER; v_lifecycle TEXT; v_from TIMESTAMPTZ; v_backfill UUID; v_raised BOOLEAN;
    v_before JSONB; v_after JSONB; v_active UUID;
BEGIN
    ${FIXTURE_BASE}

    -- A1. ACTIVE asset without a backfill record (the legacy / defect shape).
    v_ids := pg_temp.m287_asset(v_org, v_site, v_gateway, v_model, v_profile, 'ACTIVE', 'ACTIVE');
    v_result := admin.save_asset_point_assignments(v_user, v_ids[1], v_ids[2],
        jsonb_build_array(jsonb_build_object('logical_point_id', v_p_active_power), jsonb_build_object('logical_point_id', v_p_power_factor)));
    IF (v_result->>'commissioning_triggered')::boolean IS NOT FALSE THEN
        RAISE EXCEPTION 'A1: expected commissioning_triggered=false for an ACTIVE asset, got %', v_result;
    END IF;
    IF v_result->>'backfill_record_id' IS NOT NULL OR jsonb_array_length(v_result->'added') <> 2 THEN
        RAISE EXCEPTION 'A1: expected 2 added points and no backfill_record_id, got %', v_result;
    END IF;
    SELECT count(*) INTO v_count FROM metadata.asset_commissioning_backfill WHERE asset_id = v_ids[1];
    SELECT lifecycle_status INTO v_lifecycle FROM metadata.assets WHERE id = v_ids[1];
    SELECT min(effective_from) INTO v_from FROM metadata.asset_points WHERE asset_id = v_ids[1];
    IF v_count <> 0 OR v_lifecycle <> 'ACTIVE' OR v_from IS DISTINCT FROM now() THEN
        RAISE EXCEPTION 'A1: expected no backfill record, ACTIVE, points starting at the Save; got records=%, lifecycle=%, effective_from=% (now=%)', v_count, v_lifecycle, v_from, now();
    END IF;
    RAISE NOTICE 'PASS A1: ACTIVE asset -- no backfill record, commissioning_triggered=false, lifecycle ACTIVE, points start at the Save';

    -- A2. DRAFT asset: initial commissioning preserved.
    v_ids := pg_temp.m287_asset(v_org, v_site, v_gateway, v_model, v_profile, 'DRAFT', 'DRAFT');
    v_result := admin.save_asset_point_assignments(v_user, v_ids[1], v_ids[2],
        jsonb_build_array(jsonb_build_object('logical_point_id', v_p_active_power)));
    IF (v_result->>'commissioning_triggered')::boolean IS NOT TRUE OR v_result->>'backfill_record_id' IS NULL THEN
        RAISE EXCEPTION 'A2: expected commissioning_triggered=true with a backfill_record_id for a DRAFT asset, got %', v_result;
    END IF;
    SELECT lifecycle_status INTO v_lifecycle FROM metadata.assets WHERE id = v_ids[1];
    SELECT count(*) INTO v_count FROM metadata.asset_commissioning_backfill
    WHERE asset_id = v_ids[1] AND status = 'PENDING' AND id = (v_result->>'backfill_record_id')::uuid
      AND trigger_audit_transaction_id = (v_result->>'audit_transaction_id')::uuid;
    IF v_lifecycle <> 'COMMISSIONING' OR v_count <> 1 THEN
        RAISE EXCEPTION 'A2: expected COMMISSIONING with one PENDING record linked to the Save audit, got lifecycle=%, matching records=%', v_lifecycle, v_count;
    END IF;
    v_result := admin.save_asset_point_assignments(v_user, v_ids[1], v_ids[2],
        jsonb_build_array(jsonb_build_object('logical_point_id', v_p_active_power), jsonb_build_object('logical_point_id', v_p_frequency)));
    SELECT count(*) INTO v_count FROM metadata.asset_commissioning_backfill WHERE asset_id = v_ids[1];
    IF (v_result->>'commissioning_triggered')::boolean IS NOT FALSE OR v_count <> 1 THEN
        RAISE EXCEPTION 'A2: a second Save must not re-trigger (triggered=%, records=%)', v_result->>'commissioning_triggered', v_count;
    END IF;
    RAISE NOTICE 'PASS A2: DRAFT asset -- COMMISSIONING + one PENDING record + commissioning_triggered=true; second Save does not re-trigger';

    -- A3. INACTIVE asset: not initial commissioning.
    v_ids := pg_temp.m287_asset(v_org, v_site, v_gateway, v_model, v_profile, 'INACTIVE', 'INACTIVE');
    v_result := admin.save_asset_point_assignments(v_user, v_ids[1], v_ids[2],
        jsonb_build_array(jsonb_build_object('logical_point_id', v_p_active_power)));
    SELECT count(*) INTO v_count FROM metadata.asset_commissioning_backfill WHERE asset_id = v_ids[1];
    SELECT lifecycle_status INTO v_lifecycle FROM metadata.assets WHERE id = v_ids[1];
    IF (v_result->>'commissioning_triggered')::boolean IS NOT FALSE OR v_count <> 0 OR v_lifecycle <> 'INACTIVE' THEN
        RAISE EXCEPTION 'A3: expected INACTIVE unchanged, no record, triggered=false; got lifecycle=%, records=%, result=%', v_lifecycle, v_count, v_result;
    END IF;
    RAISE NOTICE 'PASS A3: INACTIVE asset -- no backfill record, commissioning_triggered=false, lifecycle INACTIVE';

    -- A4. The guard, called directly: a PENDING record on the ACTIVE asset
    -- (A1), linked to A1's real Save audit row, is refused and changes nothing.
    SELECT id INTO v_active FROM metadata.assets WHERE name = 'M287 Test Asset ACTIVE';
    INSERT INTO metadata.asset_commissioning_backfill(asset_id, status, triggered_by_portal_user_id, trigger_audit_transaction_id)
    SELECT v_active, 'PENDING', v_user, a.id
    FROM admin.onboarding_audit a
    WHERE a.requested_by = 'm287-test-user' AND a.request_payload->>'asset_id' = v_active::text
    RETURNING id INTO v_backfill;
    SELECT jsonb_agg(to_jsonb(ap) ORDER BY ap.id) INTO v_before FROM metadata.asset_points ap WHERE ap.asset_id = v_active;
    v_raised := FALSE;
    BEGIN
        PERFORM telemetry.backfill_asset_commissioning_points(v_backfill);
    EXCEPTION WHEN OTHERS THEN
        v_raised := SQLERRM LIKE '%refused%not COMMISSIONING%';
    END;
    SELECT jsonb_agg(to_jsonb(ap) ORDER BY ap.id) INTO v_after FROM metadata.asset_points ap WHERE ap.asset_id = v_active;
    IF NOT v_raised OR v_before IS DISTINCT FROM v_after THEN
        RAISE EXCEPTION 'A4: expected the guard to refuse an ACTIVE asset''s record without changing asset_points (raised=%)', v_raised;
    END IF;
    RAISE NOTICE 'PASS A4: the backfill function refuses a non-COMMISSIONING record and changes no asset_points row';
END;
\$a\$;
ROLLBACK;
"
echo "PASS: A. Save behaviour (ACTIVE / DRAFT / INACTIVE) and the direct guard call"

# ----------------------------------------------------------------------------
# B. The real worker on committed fixtures: the defect's exact shape.
# ----------------------------------------------------------------------------
run_sql "
DO \$b\$
DECLARE
    ${FIXTURE_DECLARE}
    v_device UUID; v_asset UUID; v_result JSONB;
BEGIN
    ${FIXTURE_BASE}
    INSERT INTO metadata.devices(organization_id, gateway_id, device_model_id, profile_id, name, external_id, protocol)
    VALUES (v_org, v_gateway, v_model, v_profile, 'M287 Test Meter WORKER', 'M287-TEST-WORKER', 'MQTT') RETURNING id INTO v_device;
    INSERT INTO metadata.assets(organization_id, site_id, name, status, lifecycle_status, metering_requirement)
    VALUES (v_org, v_site, 'M287 Test Asset WORKER', 'active', 'ACTIVE', 'DIRECT_METER_REQUIRED') RETURNING id INTO v_asset;
    INSERT INTO metadata.asset_devices(asset_id, device_id, relationship_type) VALUES (v_asset, v_device, 'PRIMARY_METER');
    v_result := admin.save_asset_point_assignments(v_user, v_asset, v_device,
        jsonb_build_array(jsonb_build_object('logical_point_id', v_p_active_power)));
    -- Recreate what the defect left behind: a never-attempted PENDING
    -- record for this ACTIVE asset, pointing at the real Save audit row.
    INSERT INTO metadata.asset_commissioning_backfill(asset_id, status, triggered_by_portal_user_id, trigger_audit_transaction_id)
    VALUES (v_asset, 'PENDING', v_user, (v_result->>'audit_transaction_id')::uuid);
END;
\$b\$;
"
ASSET_W=$(scalar "SELECT id FROM metadata.assets WHERE name = 'M287 Test Asset WORKER';")
FROM_BEFORE=$(scalar "SELECT string_agg(id || '=' || effective_from, ',' ORDER BY id) FROM metadata.asset_points WHERE asset_id = '${ASSET_W}';")
ACTIVATIONS_BEFORE=$(scalar "SELECT count(*) FROM admin.onboarding_audit WHERE request_payload->>'asset_id' = '${ASSET_W}' AND requested_by <> 'm287-test-user';")

psql_exec -c "CALL telemetry.process_asset_commissioning_backfill(10);" > /dev/null

STATUS=$(scalar "SELECT status FROM metadata.asset_commissioning_backfill WHERE asset_id = '${ASSET_W}';")
LAST_ERROR=$(scalar "SELECT last_error FROM metadata.asset_commissioning_backfill WHERE asset_id = '${ASSET_W}';")
FROM_AFTER=$(scalar "SELECT string_agg(id || '=' || effective_from, ',' ORDER BY id) FROM metadata.asset_points WHERE asset_id = '${ASSET_W}';")
LIFECYCLE=$(scalar "SELECT lifecycle_status FROM metadata.assets WHERE id = '${ASSET_W}';")
ACTIVATIONS_AFTER=$(scalar "SELECT count(*) FROM admin.onboarding_audit WHERE request_payload->>'asset_id' = '${ASSET_W}' AND requested_by <> 'm287-test-user';")

if [[ "${STATUS}" != "FAILED" ]]; then
    echo "FAIL: B. expected the worker to mark the ACTIVE asset's record FAILED, found ${STATUS}" >&2; exit 1
fi
if [[ "${LAST_ERROR}" != *"refused"*"not COMMISSIONING"* ]]; then
    echo "FAIL: B. expected the refusal reason in last_error, found: ${LAST_ERROR}" >&2; exit 1
fi
if [[ -z "${FROM_BEFORE}" || "${FROM_BEFORE}" != "${FROM_AFTER}" ]]; then
    echo "FAIL: B. assignment start dates changed: before=${FROM_BEFORE} after=${FROM_AFTER}" >&2; exit 1
fi
if [[ "${LIFECYCLE}" != "ACTIVE" || "${ACTIVATIONS_BEFORE}" != "${ACTIVATIONS_AFTER}" ]]; then
    echo "FAIL: B. expected ACTIVE and no activation audit; lifecycle=${LIFECYCLE}, activation rows ${ACTIVATIONS_BEFORE}->${ACTIVATIONS_AFTER}" >&2; exit 1
fi
echo "PASS: B. the worker marks a non-COMMISSIONING record FAILED (${LAST_ERROR%%:*}: refused ...), moves no start date, no lifecycle change, no activation"

# ----------------------------------------------------------------------------
# C. The migration's cleanup block, verbatim, on fixtures (rolled back).
# ----------------------------------------------------------------------------
cleanup  # remove B's committed fixtures; C builds its own, inside rolled-back transactions
CLEANUP_BLOCK="$(sed -n '/^-- BEGIN M287 DEFECTIVE BACKFILL CLEANUP$/,/^-- END M287 DEFECTIVE BACKFILL CLEANUP$/p' "${MIGRATION}" | tr -d '\r')"
if [[ "$(printf '%s\n' "${CLEANUP_BLOCK}" | grep -c 'DELETE FROM metadata.asset_commissioning_backfill')" != "1" ]]; then
    echo "FAIL: C. could not extract the cleanup block from ${MIGRATION}" >&2; exit 1
fi

CLEANUP_FIXTURES="
CREATE OR REPLACE FUNCTION pg_temp.m287_record(p_org UUID, p_site UUID, p_gateway UUID, p_model UUID, p_profile UUID, p_user BIGINT,
                                                p_label TEXT, p_lifecycle TEXT, p_status TEXT, p_attempts INTEGER)
RETURNS UUID LANGUAGE plpgsql AS \$f\$
DECLARE v_device UUID; v_asset UUID; v_audit UUID := gen_random_uuid(); v_record UUID;
BEGIN
    INSERT INTO metadata.devices(organization_id, gateway_id, device_model_id, profile_id, name, external_id, protocol)
    VALUES (p_org, p_gateway, p_model, p_profile, 'M287 Test Meter ' || p_label, 'M287-TEST-' || p_label, 'MQTT') RETURNING id INTO v_device;
    INSERT INTO metadata.assets(organization_id, site_id, name, status, lifecycle_status, metering_requirement)
    VALUES (p_org, p_site, 'M287 Test Asset ' || p_label, lower(p_lifecycle), p_lifecycle, 'DIRECT_METER_REQUIRED') RETURNING id INTO v_asset;
    INSERT INTO admin.onboarding_audit(id, requested_by, request_payload, result_payload)
    VALUES (v_audit, 'm287-test-user', jsonb_build_object('operation', 'SAVE_ASSET_POINT_ASSIGNMENTS', 'asset_id', v_asset), '{}'::jsonb);
    INSERT INTO metadata.asset_commissioning_backfill(asset_id, status, triggered_by_portal_user_id, trigger_audit_transaction_id, attempt_count,
                                                      started_at, completed_at, failed_at)
    VALUES (v_asset, p_status, p_user, v_audit, p_attempts,
            CASE WHEN p_status <> 'PENDING' THEN now() - interval '2 hours' END,
            CASE WHEN p_status = 'COMPLETED' THEN now() - interval '1 hour' END,
            CASE WHEN p_status = 'FAILED' THEN now() - interval '1 hour' END)
    RETURNING id INTO v_record;
    RETURN v_record;
END;
\$f\$;
CREATE TEMP TABLE m287_fixture (label TEXT, record_id UUID);
DO \$c\$
DECLARE
    ${FIXTURE_DECLARE}
BEGIN
    ${FIXTURE_BASE}
    -- Defective: never-attempted PENDING on non-COMMISSIONING assets.
    INSERT INTO m287_fixture VALUES ('DEFECT_ACTIVE',   pg_temp.m287_record(v_org, v_site, v_gateway, v_model, v_profile, v_user, 'DEFECT_ACTIVE',   'ACTIVE',        'PENDING',   0));
    INSERT INTO m287_fixture VALUES ('DEFECT_INACTIVE', pg_temp.m287_record(v_org, v_site, v_gateway, v_model, v_profile, v_user, 'DEFECT_INACTIVE', 'INACTIVE',      'PENDING',   0));
    -- Must survive.
    INSERT INTO m287_fixture VALUES ('KEEP_COMMISSIONING', pg_temp.m287_record(v_org, v_site, v_gateway, v_model, v_profile, v_user, 'KEEP_COMMISSIONING', 'COMMISSIONING', 'PENDING',   0));
    INSERT INTO m287_fixture VALUES ('KEEP_COMPLETED',     pg_temp.m287_record(v_org, v_site, v_gateway, v_model, v_profile, v_user, 'KEEP_COMPLETED',     'ACTIVE',        'COMPLETED', 1));
    INSERT INTO m287_fixture VALUES ('KEEP_ATTEMPTED',     pg_temp.m287_record(v_org, v_site, v_gateway, v_model, v_profile, v_user, 'KEEP_ATTEMPTED',     'ACTIVE',        'PENDING',   1));
    INSERT INTO m287_fixture VALUES ('KEEP_FAILED',        pg_temp.m287_record(v_org, v_site, v_gateway, v_model, v_profile, v_user, 'KEEP_FAILED',        'ACTIVE',        'FAILED',    1));
END;
\$c\$;
"

run_sql "
BEGIN;
${CLEANUP_FIXTURES}
CREATE TEMP TABLE m287_audit_before AS SELECT count(*) AS n FROM admin.onboarding_audit;
${CLEANUP_BLOCK}
DO \$check\$
DECLARE v_remaining TEXT;
BEGIN
    SELECT string_agg(f.label, ',' ORDER BY f.label) INTO v_remaining
    FROM m287_fixture f JOIN metadata.asset_commissioning_backfill b ON b.id = f.record_id;
    IF v_remaining IS DISTINCT FROM 'KEEP_ATTEMPTED,KEEP_COMMISSIONING,KEEP_COMPLETED,KEEP_FAILED' THEN
        RAISE EXCEPTION 'C1: expected only the two defective records deleted; remaining fixture records: %', v_remaining;
    END IF;
    IF (SELECT n FROM m287_audit_before) <> (SELECT count(*) FROM admin.onboarding_audit) THEN
        RAISE EXCEPTION 'C1: the cleanup must not touch admin.onboarding_audit';
    END IF;
    RAISE NOTICE 'PASS C1: cleanup deleted exactly the 2 defective records; COMMISSIONING / COMPLETED / attempted / FAILED records and all audit rows kept';
END;
\$check\$;
ROLLBACK;
"
echo "PASS: C1. the migration's cleanup block deletes only the defective records"

# C2. Three defective records: the block must refuse and delete nothing.
if psql_exec -f - > /dev/null 2>&1 <<SQL
BEGIN;
${CLEANUP_FIXTURES}
INSERT INTO m287_fixture
SELECT 'DEFECT_THIRD', pg_temp.m287_record(o.id, s.id, g.id, m.id, p.id, u.portal_user_id, 'DEFECT_THIRD', 'ACTIVE', 'PENDING', 0)
FROM metadata.organizations o JOIN metadata.sites s ON s.organization_id = o.id JOIN metadata.gateways g ON g.site_id = s.id
CROSS JOIN (SELECT id FROM metadata.device_models WHERE model = 'M287 Test Meter') m
CROSS JOIN (SELECT id FROM config.device_profiles WHERE profile_code = 'ENERGY_METER_ENISCOPE_V1') p
CROSS JOIN (SELECT portal_user_id FROM admin.portal_users WHERE username = 'm287-test-user') u
WHERE o.code = 'M287_TEST_ORG';
${CLEANUP_BLOCK}
ROLLBACK;
SQL
then
    echo "FAIL: C2. expected the cleanup block to refuse when more than 2 defective records exist" >&2; exit 1
fi
REFUSAL=$(psql_exec -f - 2>&1 <<SQL || true
BEGIN;
${CLEANUP_FIXTURES}
INSERT INTO m287_fixture
SELECT 'DEFECT_THIRD', pg_temp.m287_record(o.id, s.id, g.id, m.id, p.id, u.portal_user_id, 'DEFECT_THIRD', 'ACTIVE', 'PENDING', 0)
FROM metadata.organizations o JOIN metadata.sites s ON s.organization_id = o.id JOIN metadata.gateways g ON g.site_id = s.id
CROSS JOIN (SELECT id FROM metadata.device_models WHERE model = 'M287 Test Meter') m
CROSS JOIN (SELECT id FROM config.device_profiles WHERE profile_code = 'ENERGY_METER_ENISCOPE_V1') p
CROSS JOIN (SELECT portal_user_id FROM admin.portal_users WHERE username = 'm287-test-user') u
WHERE o.code = 'M287_TEST_ORG';
${CLEANUP_BLOCK}
ROLLBACK;
SQL
)
if [[ "${REFUSAL}" != *"Migration 287 cleanup refused: 3 defective PENDING backfill records found"* ]]; then
    echo "FAIL: C2. expected the explicit refusal message, got: ${REFUSAL}" >&2; exit 1
fi
LEFTOVER=$(scalar "SELECT count(*) FROM metadata.assets WHERE name LIKE 'M287 Test Asset DEFECT%' OR name LIKE 'M287 Test Asset KEEP%';")
if [[ "${LEFTOVER}" != "0" ]]; then
    echo "FAIL: C2. the refused cleanup transaction left fixtures behind (${LEFTOVER})" >&2; exit 1
fi
echo "PASS: C2. with 3 defective records the cleanup refuses (raises) and deletes nothing"

echo "=== Migration 287 assertions passed ==="
