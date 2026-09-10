-- ============================================================================
-- File:
--   scripts/test/assert_derived_calculation_foundation.sql
--
-- Purpose:
--   Regression test for migration 229 (Phase 5 -- SPACE_DEW_POINT SELF slice).
--   Proves the approved contracts:
--
--     1.  Migration postconditions: DEW_POINT parameter (degC, Temperature);
--         config.parameter_calculations table + uq index + the ASSET|SPACE
--         discriminator + the asset-type gate CHECK; exactly one
--         SPACE_DEW_POINT row with the fixed attributes; the view exists,
--         security_barrier, grafana_reader-granted, no PUBLIC.
--     2.  Parameter-existence invariant: every input_parameter_refs code
--         resolves to config.parameters.
--     3.  Normal calculation: (25.0,60.0)->16.6931 and (20.0,80.0)->16.4424
--         (Magnus a=17.62 b=243.12, view rounds to 4 dp; tol 0.001).
--     4.  Missing temperature -> no output row.
--     5.  Missing humidity -> no output row.
--     6.  RH <= 0 -> no output row.
--     7.  Multiple sensors, same Space: two device-specific streams produce
--         two independent output rows -- NO grouping / averaging by Space.
--     8.  Cross-space isolation: each sensor's result carries its own space_id.
--     9.  Tenant isolation: no cross-organization row through the view.
--     10. Subject type: applicable_subject_type='SPACE', applicable_asset_
--         type_id IS NULL; the asset-type gate still rejects a SPACE row that
--         carries an asset type.
--     11. Energy safety: energy loader / parameter_routing / energy tables
--         unchanged; no persisted derived tier; no derived job.
--
--   All fixtures live inside one transaction and are rolled back. ON_ERROR_
--   STOP=1 in the .sh wrapper fails the runner on any assertion.
-- ============================================================================

BEGIN;

DO $test$
DECLARE
    org_1     UUID := 'f5000000-0000-0000-0000-0000000000a1';
    org_2     UUID := 'f5000000-0000-0000-0000-0000000000a2';
    site_1    UUID := 'f5000000-0000-0000-0000-0000000000b1';
    site_2    UUID := 'f5000000-0000-0000-0000-0000000000b2';
    bldg_1    UUID := 'f5000000-0000-0000-0000-0000000000c1';
    bldg_2    UUID := 'f5000000-0000-0000-0000-0000000000c2';
    floor_1   UUID := 'f5000000-0000-0000-0000-0000000000d1';
    floor_2   UUID := 'f5000000-0000-0000-0000-0000000000d2';
    space_a   UUID := 'f5000000-0000-0000-0000-0000000000e1';   -- "Room A"
    space_b   UUID := 'f5000000-0000-0000-0000-0000000000e2';   -- "Room B"
    space_seasons UUID := 'f5000000-0000-0000-0000-0000000000e3'; -- one room, two sensors
    space_o2  UUID := 'f5000000-0000-0000-0000-0000000000e9';
    gw_1      UUID := 'f5000000-0000-0000-0000-00000000091a';
    gw_2      UUID := 'f5000000-0000-0000-0000-00000000091b';
    dev_a     UUID := 'f5000000-0000-0000-0000-0000000000fa';
    dev_c     UUID := 'f5000000-0000-0000-0000-0000000000fc';
    dev_d     UUID := 'f5000000-0000-0000-0000-0000000000fd';
    dev_o2    UUID := 'f5000000-0000-0000-0000-0000000000f9';
    prof_air  UUID;
    v_dp      DOUBLE PRECISION;
    v_n       INT;
    v_raised  BOOLEAN;
    r         RECORD;
    b0        TIMESTAMPTZ := date_trunc('minute', now()) - INTERVAL '10 minutes';
    b1        TIMESTAMPTZ := date_trunc('minute', now()) - INTERVAL '9 minutes';
    b2        TIMESTAMPTZ := date_trunc('minute', now()) - INTERVAL '8 minutes';
    b3        TIMESTAMPTZ := date_trunc('minute', now()) - INTERVAL '7 minutes';
    b4        TIMESTAMPTZ := date_trunc('minute', now()) - INTERVAL '6 minutes';
BEGIN
    -- ==================================================================
    -- 1. Migration postconditions.
    -- ==================================================================
    IF NOT EXISTS (SELECT 1 FROM admin.schema_migrations WHERE migration_id='229_derived_calculation_foundation') THEN
        RAISE EXCEPTION 'TEST 1 FAILED: admin.schema_migrations has no row for migration 229.';
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM config.parameters p
        JOIN config.engineering_units eu ON eu.id=p.unit_id
        JOIN config.point_categories pc ON pc.id=p.parameter_category_id
        WHERE p.code='DEW_POINT' AND eu.symbol='degC' AND pc.name='Temperature'
    ) THEN
        RAISE EXCEPTION 'TEST 1 FAILED: DEW_POINT parameter missing or wrong unit/category.';
    END IF;
    IF to_regclass('config.parameter_calculations') IS NULL THEN
        RAISE EXCEPTION 'TEST 1 FAILED: config.parameter_calculations missing.';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_indexes WHERE schemaname='config' AND indexname='uq_parameter_calculations_output_version') THEN
        RAISE EXCEPTION 'TEST 1 FAILED: uq_parameter_calculations_output_version missing.';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid='config.parameter_calculations'::regclass AND conname='ck_parameter_calculations_asset_type_gated') THEN
        RAISE EXCEPTION 'TEST 1 FAILED: ck_parameter_calculations_asset_type_gated missing.';
    END IF;
    IF (SELECT count(*) FROM config.parameter_calculations) <> 1 THEN
        RAISE EXCEPTION 'TEST 1 FAILED: expected exactly one config.parameter_calculations row, found %.', (SELECT count(*) FROM config.parameter_calculations);
    END IF;
    SELECT * INTO r FROM config.parameter_calculations pc JOIN config.parameters op ON op.id=pc.output_parameter_id WHERE op.code='DEW_POINT';
    IF r.applicable_subject_type <> 'SPACE' OR r.applicable_asset_type_id IS NOT NULL
       OR r.null_handling <> 'NULL_IF_REQUIRED_MISSING' OR r.materialization_strategy <> 'VIEW'
       OR (r.formula_definition->>'engine') <> 'SQL_EXPR' OR jsonb_array_length(r.input_parameter_refs) <> 2 THEN
        RAISE EXCEPTION 'TEST 1 FAILED: SPACE_DEW_POINT attributes incorrect.';
    END IF;
    IF to_regclass('analytics.v_space_dew_point_1min') IS NULL THEN
        RAISE EXCEPTION 'TEST 1 FAILED: analytics.v_space_dew_point_1min missing.';
    END IF;
    IF NOT has_table_privilege('grafana_reader','analytics.v_space_dew_point_1min','SELECT')
       OR has_table_privilege('public','analytics.v_space_dew_point_1min','SELECT') THEN
        RAISE EXCEPTION 'TEST 1 FAILED: dew-point view grant convention wrong.';
    END IF;
    RAISE NOTICE 'TEST 1 passed: migration 229 postconditions.';

    -- ==================================================================
    -- 2. Parameter-existence invariant.
    -- ==================================================================
    SELECT count(*) INTO v_n
    FROM config.parameter_calculations pc
    CROSS JOIN LATERAL jsonb_array_elements(pc.input_parameter_refs) ref
    WHERE NOT EXISTS (SELECT 1 FROM config.parameters p WHERE p.code = ref->>'parameter_code');
    IF v_n <> 0 THEN RAISE EXCEPTION 'TEST 2 FAILED: % unresolved input parameter code(s).', v_n; END IF;
    RAISE NOTICE 'TEST 2 passed: parameter-existence invariant.';

    -- ==================================================================
    -- Shared fixtures.
    -- ==================================================================
    SELECT id INTO prof_air FROM config.device_profiles WHERE profile_code='ENVIRONMENT_SENSOR_AIRSENSE_V1';
    IF prof_air IS NULL THEN RAISE EXCEPTION 'Fixture: AirSense profile missing.'; END IF;

    INSERT INTO metadata.organizations (id,name,code) VALUES
        (org_1,'PH5 Org 1','PH5_ORG_1'),(org_2,'PH5 Org 2','PH5_ORG_2');
    INSERT INTO metadata.sites (id,organization_id,name,code) VALUES
        (site_1,org_1,'PH5 Site 1','PH5_SITE_1'),(site_2,org_2,'PH5 Site 2','PH5_SITE_2');
    INSERT INTO metadata.buildings (id,organization_id,site_id,name,code) VALUES
        (bldg_1,org_1,site_1,'PH5 B1','PH5_B1'),(bldg_2,org_2,site_2,'PH5 B2','PH5_B2');
    INSERT INTO metadata.floors (id,organization_id,building_id,name,code) VALUES
        (floor_1,org_1,bldg_1,'PH5 F1','PH5_F1'),(floor_2,org_2,bldg_2,'PH5 F2','PH5_F2');
    INSERT INTO metadata.spaces (id,organization_id,floor_id,name,code) VALUES
        (space_a,org_1,floor_1,'PH5 Room A','PH5_ROOM_A'),
        (space_b,org_1,floor_1,'PH5 Room B','PH5_ROOM_B'),
        (space_seasons,org_1,floor_1,'PH5 Seasons','PH5_SEASONS'),
        (space_o2,org_2,floor_2,'PH5 Room O2','PH5_ROOM_O2');
    INSERT INTO metadata.gateways (id,organization_id,site_id,name,external_id) VALUES
        (gw_1,org_1,site_1,'PH5 GW1','PH5-GW-1'),(gw_2,org_2,site_2,'PH5 GW2','PH5-GW-2');
    INSERT INTO metadata.devices (id,organization_id,gateway_id,name,external_id,profile_id) VALUES
        (dev_a,org_1,gw_1,'PH5 AirSense A','PH5-AIR-A',prof_air),
        (dev_c,org_1,gw_1,'PH5 AirSense C','PH5-AIR-C',prof_air),
        (dev_d,org_1,gw_1,'PH5 AirSense D','PH5-AIR-D',prof_air),
        (dev_o2,org_2,gw_2,'PH5 AirSense O2','PH5-AIR-O2',prof_air);

    -- The view joins metadata.grafana_organization_map and filters is_active.
    INSERT INTO metadata.grafana_organization_map (organization_id, grafana_org_id, is_active)
    VALUES (org_1, 950001, TRUE), (org_2, 950002, TRUE);

    -- Direct environment_measurements fixtures (the view's only source).
    -- (bucket_start, device_id) is unique.
    INSERT INTO telemetry.environment_measurements
        (bucket_start, received_at, source_timestamp, organization_id, site_id, device_id, space_id, temperature_c, humidity_percent)
    VALUES
        -- normal calc (T=25.0, RH=60.0 -> ~16.6955) and (T=20.0, RH=80.0 -> ~16.4424)
        (b0, b0, b0, org_1, site_1, dev_a, space_a, 25.0, 60.0),
        (b1, b1, b1, org_1, site_1, dev_a, space_a, 20.0, 80.0),
        -- missing temperature -> no row
        (b2, b2, b2, org_1, site_1, dev_a, space_a, NULL, 55.0),
        -- missing humidity -> no row
        (b3, b3, b3, org_1, site_1, dev_a, space_a, 22.0, NULL),
        -- RH <= 0 -> no row
        (b4, b4, b4, org_1, site_1, dev_a, space_a, 22.0, 0.0),
        -- multiple sensors, same Space, same bucket -> two independent rows
        (b0, b0, b0, org_1, site_1, dev_c, space_seasons, 27.0, 55.0),
        (b0, b0, b0, org_1, site_1, dev_d, space_seasons, 27.5, 52.0),
        -- cross-space isolation: dev_c also reports Room B in another bucket
        (b1, b1, b1, org_1, site_1, dev_c, space_b, 24.0, 50.0),
        -- tenant isolation: org_2 sensor
        (b0, b0, b0, org_2, site_2, dev_o2, space_o2, 21.0, 65.0),
        -- a row with NO space_id (unbound) -> must not appear
        (b2, b2, b2, org_1, site_1, dev_c, NULL, 23.0, 45.0);

    -- ==================================================================
    -- 3. Normal calculation.
    -- ==================================================================
    SELECT dew_point_c INTO v_dp FROM analytics.v_space_dew_point_1min
    WHERE device_id=dev_a AND bucket_start=b0;
    IF v_dp IS NULL OR abs(v_dp - 16.6931) > 0.001 THEN
        RAISE EXCEPTION 'TEST 3 FAILED: dew point for (25.0, 60.0) expected 16.6931 (Magnus a=17.62,b=243.12, round 4dp), got %.', v_dp;
    END IF;
    SELECT dew_point_c INTO v_dp FROM analytics.v_space_dew_point_1min
    WHERE device_id=dev_a AND bucket_start=b1;
    IF v_dp IS NULL OR abs(v_dp - 16.4424) > 0.001 THEN
        RAISE EXCEPTION 'TEST 3 FAILED: dew point for (20.0, 80.0) expected 16.4424 (Magnus a=17.62,b=243.12, round 4dp), got %.', v_dp;
    END IF;
    RAISE NOTICE 'TEST 3 passed: normal calculation (Magnus a=17.62 b=243.12).';

    -- ==================================================================
    -- 4/5/6. Missing input / RH<=0 -> no row.
    -- ==================================================================
    IF EXISTS (SELECT 1 FROM analytics.v_space_dew_point_1min WHERE device_id=dev_a AND bucket_start=b2) THEN
        RAISE EXCEPTION 'TEST 4 FAILED: missing temperature produced a row.';
    END IF;
    IF EXISTS (SELECT 1 FROM analytics.v_space_dew_point_1min WHERE device_id=dev_a AND bucket_start=b3) THEN
        RAISE EXCEPTION 'TEST 5 FAILED: missing humidity produced a row.';
    END IF;
    IF EXISTS (SELECT 1 FROM analytics.v_space_dew_point_1min WHERE device_id=dev_a AND bucket_start=b4) THEN
        RAISE EXCEPTION 'TEST 6 FAILED: RH<=0 produced a row.';
    END IF;
    IF EXISTS (SELECT 1 FROM analytics.v_space_dew_point_1min WHERE device_id=dev_c AND bucket_start=b2) THEN
        RAISE EXCEPTION 'TEST 6 FAILED: a NULL-space_id measurement produced a row.';
    END IF;
    RAISE NOTICE 'TEST 4/5/6 passed: missing temperature / humidity / RH<=0 / unbound -> no row.';

    -- ==================================================================
    -- 7. Multiple sensors, same Space -> two independent rows, no averaging.
    -- ==================================================================
    SELECT count(*) INTO v_n FROM analytics.v_space_dew_point_1min
    WHERE space_id=space_seasons AND bucket_start=b0;
    IF v_n <> 2 THEN
        RAISE EXCEPTION 'TEST 7 FAILED: expected 2 rows for one Space + one bucket (per-sensor), got %.', v_n;
    END IF;
    SELECT count(DISTINCT dew_point_c) INTO v_n FROM analytics.v_space_dew_point_1min
    WHERE space_id=space_seasons AND bucket_start=b0;
    IF v_n <> 2 THEN
        RAISE EXCEPTION 'TEST 7 FAILED: the two sensor rows were collapsed/averaged (distinct dew points = %).', v_n;
    END IF;
    SELECT count(DISTINCT device_id) INTO v_n FROM analytics.v_space_dew_point_1min
    WHERE space_id=space_seasons AND bucket_start=b0;
    IF v_n <> 2 THEN RAISE EXCEPTION 'TEST 7 FAILED: device identity not preserved (distinct device_id = %).', v_n; END IF;
    RAISE NOTICE 'TEST 7 passed: two sensors in one Space -> two independent per-sensor rows.';

    -- ==================================================================
    -- 8. Cross-space isolation.
    -- ==================================================================
    SELECT space_id INTO r FROM analytics.v_space_dew_point_1min WHERE device_id=dev_c AND bucket_start=b1;
    IF r.space_id IS DISTINCT FROM space_b THEN
        RAISE EXCEPTION 'TEST 8 FAILED: dev_c b1 row should carry space_b, got %.', r.space_id;
    END IF;
    IF EXISTS (SELECT 1 FROM analytics.v_space_dew_point_1min WHERE device_id=dev_c AND bucket_start=b1 AND space_id=space_seasons) THEN
        RAISE EXCEPTION 'TEST 8 FAILED: dev_c result leaked into the Seasons Space.';
    END IF;
    RAISE NOTICE 'TEST 8 passed: each sensor result stays with its own Space.';

    -- ==================================================================
    -- 9. Tenant isolation.
    -- ==================================================================
    SELECT count(*) INTO v_n FROM analytics.v_space_dew_point_1min
    WHERE grafana_org_id = 950001 AND organization_id = org_2;
    IF v_n <> 0 THEN RAISE EXCEPTION 'TEST 9 FAILED: org_2 rows visible under org_1 grafana_org_id.'; END IF;
    SELECT count(*) INTO v_n FROM analytics.v_space_dew_point_1min
    WHERE grafana_org_id = 950002 AND device_id = dev_o2;
    IF v_n <> 1 THEN RAISE EXCEPTION 'TEST 9 FAILED: org_2 sensor not visible under its own grafana_org_id (got %).', v_n; END IF;
    RAISE NOTICE 'TEST 9 passed: tenant isolation via grafana_organization_map.';

    -- ==================================================================
    -- 10. Subject type + asset-type gate.
    -- ==================================================================
    IF (SELECT applicable_subject_type FROM config.parameter_calculations
        JOIN config.parameters op ON op.id=output_parameter_id WHERE op.code='DEW_POINT') <> 'SPACE' THEN
        RAISE EXCEPTION 'TEST 10 FAILED: SPACE_DEW_POINT is not applicable_subject_type=SPACE.';
    END IF;
    v_raised := FALSE;
    BEGIN
        INSERT INTO config.parameter_calculations
            (output_parameter_id, formula_definition, input_parameter_refs, applicable_subject_type, applicable_asset_type_id, null_handling)
        SELECT (SELECT id FROM config.parameters WHERE code='TEMPERATURE'),
               '{"engine":"SQL_EXPR"}'::jsonb, '[]'::jsonb, 'SPACE',
               (SELECT id FROM metadata.asset_types LIMIT 1), 'NULL_IF_ANY_MISSING';
        RAISE EXCEPTION 'TEST 10 FAILED: a SPACE row carrying an asset type was accepted.';
    EXCEPTION
        WHEN check_violation THEN v_raised := TRUE;
        WHEN OTHERS THEN
            IF SQLERRM LIKE 'TEST 10 FAILED:%' THEN RAISE; END IF;
            RAISE EXCEPTION 'TEST 10 FAILED: expected check_violation, got % (%)', SQLSTATE, SQLERRM;
    END;
    IF NOT v_raised THEN RAISE EXCEPTION 'TEST 10 FAILED: asset-type gate did not fire.'; END IF;
    RAISE NOTICE 'TEST 10 passed: applicable_subject_type=SPACE; asset-type gate rejects SPACE+asset_type.';

    -- ==================================================================
    -- 11. Energy safety.
    -- ==================================================================
    DECLARE v_e TEXT;
    BEGIN
        v_e := pg_get_functiondef('telemetry.load_energy_measurements_incremental(interval,interval)'::regprocedure);
        IF position('parameter_calculations' IN v_e) <> 0 OR position('space_id' IN v_e) <> 0
           OR position('space_points' IN v_e) <> 0 OR position('dew_point' IN lower(v_e)) <> 0 THEN
            RAISE EXCEPTION 'TEST 11 FAILED: energy loader references a Phase 2/3/5 object.';
        END IF;
        IF position('telemetry.energy_measurements' IN v_e) = 0 THEN
            RAISE EXCEPTION 'TEST 11 FAILED: energy loader no longer targets telemetry.energy_measurements.';
        END IF;
    END;
    IF (SELECT count(*) FROM config.parameter_routing WHERE is_active AND destination_table='telemetry.environment_measurements') <> 12 THEN
        RAISE EXCEPTION 'TEST 11 FAILED: config.parameter_routing active AirSense rows != 12.';
    END IF;
    IF to_regclass('analytics.derived_parameter_values') IS NOT NULL THEN
        RAISE EXCEPTION 'TEST 11 FAILED: analytics.derived_parameter_values exists (Phase 5 is view-only).';
    END IF;
    IF EXISTS (SELECT 1 FROM timescaledb_information.jobs WHERE proc_name ~* 'dew_point|derived_parameter') THEN
        RAISE EXCEPTION 'TEST 11 FAILED: a derived-parameter job exists.';
    END IF;
    RAISE NOTICE 'TEST 11 passed: energy subsystem / routing / persisted tier / jobs untouched.';
END;
$test$;

ROLLBACK;

SELECT 'Phase 5 (migration 229) SPACE_DEW_POINT derived-calculation foundation assertions passed.' AS result;
