-- ============================================================================
-- File:
--   scripts/test/assert_device_specific_point_binding.sql
--
-- Purpose:
--   Regression test for migration 228 (Phase 2 amendment -- device-specific
--   asset_points / space_points binding). Proves the approved contracts:
--
--     1.  Migration postconditions: device_id + organization_id columns
--         (NOT NULL uuid), composite FK -> config.device_point_configuration,
--         ex_*_no_overlap scoped (device_id, logical_point_id,
--         effective_range), the two validation triggers, and the loader's
--         per-device Space predicate.
--     2.  A binding to a (device_id, logical_point_id) pair that has no
--         config.device_point_configuration row is rejected (composite FK).
--     3.  FOUR-AIRSENSE REPRESENTATION: four devices, one shared
--         ENV_TEMPERATURE logical_point_id, four independent space_points
--         bindings (two of them to the SAME Space) all coexist.
--     4.  Same device + same logical point + overlapping period -> rejected
--         (23P01).
--     5.  Same device + same logical point + non-overlapping historical
--         periods -> accepted; point-in-time lookup resolves each side.
--     6.  Two DIFFERENT devices may bind the same logical point over
--         overlapping periods independently.
--     7.  Cross-organization binding (org-A device -> org-B Space) is
--         rejected by trg_validate_space_point_binding; a row organization_id
--         that mismatches the device is rejected.
--     8.  LOADER: with two AirSense devices in two different Spaces, each
--         emitting ENV_TEMPERATURE (one shared logical_point_id), the
--         environment loader resolves environment_measurements.space_id to
--         each device's OWN bound Space -- not a single shared Space, not
--         NULL-by-ambiguity.
--     9.  metadata.asset_devices is untouched by this migration.
--
--   All fixtures are created inside this test's own transaction and rolled
--   back; nothing persists. ON_ERROR_STOP=1 in the .sh wrapper fails the
--   runner on any assertion.
-- ============================================================================

BEGIN;

DO $test$
DECLARE
    org_a     UUID := 'e2800000-0000-0000-0000-0000000000a1';
    org_b     UUID := 'e2800000-0000-0000-0000-0000000000a2';
    site_a    UUID := 'e2800000-0000-0000-0000-0000000000b1';
    site_b    UUID := 'e2800000-0000-0000-0000-0000000000b2';
    bldg_a    UUID := 'e2800000-0000-0000-0000-0000000000c1';
    bldg_b    UUID := 'e2800000-0000-0000-0000-0000000000c2';
    floor_a   UUID := 'e2800000-0000-0000-0000-0000000000d1';
    floor_b   UUID := 'e2800000-0000-0000-0000-0000000000d2';
    space_a1  UUID := 'e2800000-0000-0000-0000-0000000000e1';  -- "Banquet Hall 2"
    space_a2  UUID := 'e2800000-0000-0000-0000-0000000000e2';  -- "Lobby"
    space_a3  UUID := 'e2800000-0000-0000-0000-0000000000e3';  -- "Seasons Restaurant"
    space_b1  UUID := 'e2800000-0000-0000-0000-0000000000e9';  -- org-B space
    gw_a      UUID := 'e2800000-0000-0000-0000-00000000091a';
    gw_b      UUID := 'e2800000-0000-0000-0000-00000000091b';
    dev_a     UUID := 'e2800000-0000-0000-0000-0000000000f1';  -- AirSense A
    dev_b     UUID := 'e2800000-0000-0000-0000-0000000000f2';  -- AirSense B
    dev_c     UUID := 'e2800000-0000-0000-0000-0000000000f3';  -- AirSense C
    dev_d     UUID := 'e2800000-0000-0000-0000-0000000000f4';  -- AirSense D
    dev_bx    UUID := 'e2800000-0000-0000-0000-0000000000f9';  -- org-B AirSense
    prof_air  UUID;
    lp_temp   UUID;
    lp_hum    UUID;
    v_def     TEXT;
    v_raised  BOOLEAN;
    v_space   UUID;
    v_rows    BIGINT;
    e1        TIMESTAMPTZ := date_trunc('hour', clock_timestamp()) - INTERVAL '5 hours';
BEGIN
    -- ==================================================================
    -- 1. Migration postconditions.
    -- ==================================================================
    IF NOT EXISTS (SELECT 1 FROM admin.schema_migrations
                   WHERE migration_id = '228_device_specific_asset_space_point_binding') THEN
        RAISE EXCEPTION 'TEST 1 FAILED: admin.schema_migrations has no row for migration 228.';
    END IF;

    FOR v_def IN SELECT unnest(ARRAY['asset_points','space_points'])
    LOOP
        IF NOT EXISTS (
            SELECT 1 FROM information_schema.columns
            WHERE table_schema='metadata' AND table_name=v_def
              AND column_name='device_id' AND data_type='uuid' AND is_nullable='NO'
        ) THEN
            RAISE EXCEPTION 'TEST 1 FAILED: metadata.%.device_id missing / nullable / wrong type.', v_def;
        END IF;
        IF NOT EXISTS (
            SELECT 1 FROM information_schema.columns
            WHERE table_schema='metadata' AND table_name=v_def
              AND column_name='organization_id' AND data_type='uuid' AND is_nullable='NO'
        ) THEN
            RAISE EXCEPTION 'TEST 1 FAILED: metadata.%.organization_id missing / nullable / wrong type.', v_def;
        END IF;
        IF NOT EXISTS (
            SELECT 1 FROM pg_constraint c
            JOIN pg_class rel ON rel.oid=c.conrelid
            JOIN pg_namespace n ON n.oid=rel.relnamespace
            JOIN pg_class frel ON frel.oid=c.confrelid
            JOIN pg_namespace fn ON fn.oid=frel.relnamespace
            WHERE c.conname = v_def||'_device_point_fkey' AND c.contype='f'
              AND n.nspname='metadata' AND rel.relname=v_def
              AND fn.nspname='config' AND frel.relname='device_point_configuration'
        ) THEN
            RAISE EXCEPTION 'TEST 1 FAILED: metadata.%_device_point_fkey missing / wrong target.', v_def;
        END IF;

        SELECT pg_get_constraintdef(c.oid) INTO v_def
        FROM pg_constraint c
        JOIN pg_class rel ON rel.oid=c.conrelid
        JOIN pg_namespace n ON n.oid=rel.relnamespace
        WHERE c.conname = 'ex_'||v_def||'_no_overlap' AND n.nspname='metadata';
        IF v_def IS NULL OR position('device_id WITH =' IN v_def) = 0
           OR position('logical_point_id WITH =' IN v_def) = 0
           OR position('effective_range WITH &&' IN v_def) = 0 THEN
            RAISE EXCEPTION 'TEST 1 FAILED: exclusion not scoped (device_id, logical_point_id, effective_range): %', v_def;
        END IF;
    END LOOP;

    IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname='trg_validate_asset_point_binding'
                   AND tgrelid='metadata.asset_points'::regclass) THEN
        RAISE EXCEPTION 'TEST 1 FAILED: trg_validate_asset_point_binding missing.';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname='trg_validate_space_point_binding'
                   AND tgrelid='metadata.space_points'::regclass) THEN
        RAISE EXCEPTION 'TEST 1 FAILED: trg_validate_space_point_binding missing.';
    END IF;

    IF position('sp.device_id = ranked.device_id' IN
        pg_get_functiondef('telemetry.load_environment_measurements_incremental(interval,interval)'::regprocedure)) = 0 THEN
        RAISE EXCEPTION 'TEST 1 FAILED: environment loader does not scope Space resolution by device.';
    END IF;
    RAISE NOTICE 'TEST 1 passed: migration 228 postconditions.';

    -- ==================================================================
    -- Shared fixtures.
    -- ==================================================================
    SELECT id INTO prof_air FROM config.device_profiles WHERE profile_code='ENVIRONMENT_SENSOR_AIRSENSE_V1';
    IF prof_air IS NULL THEN
        RAISE EXCEPTION 'Fixture assumption violated: ENVIRONMENT_SENSOR_AIRSENSE_V1 profile must exist.';
    END IF;
    SELECT id INTO lp_temp FROM metadata.logical_points WHERE name='ENV_TEMPERATURE';
    SELECT id INTO lp_hum  FROM metadata.logical_points WHERE name='ENV_RELATIVE_HUMIDITY';
    IF lp_temp IS NULL OR lp_hum IS NULL THEN
        RAISE EXCEPTION 'Fixture assumption violated: seeded AirSense logical points must exist.';
    END IF;

    INSERT INTO metadata.organizations (id,name,code) VALUES
        (org_a,'PH2-228 Org A','PH2_228_ORG_A'),
        (org_b,'PH2-228 Org B','PH2_228_ORG_B');
    INSERT INTO metadata.sites (id,organization_id,name,code) VALUES
        (site_a,org_a,'PH2-228 Site A','PH2_228_SITE_A'),
        (site_b,org_b,'PH2-228 Site B','PH2_228_SITE_B');
    INSERT INTO metadata.buildings (id,organization_id,site_id,name,code) VALUES
        (bldg_a,org_a,site_a,'PH2-228 Bldg A','PH2_228_BLDG_A'),
        (bldg_b,org_b,site_b,'PH2-228 Bldg B','PH2_228_BLDG_B');
    INSERT INTO metadata.floors (id,organization_id,building_id,name,code) VALUES
        (floor_a,org_a,bldg_a,'PH2-228 Floor A','PH2_228_FLOOR_A'),
        (floor_b,org_b,bldg_b,'PH2-228 Floor B','PH2_228_FLOOR_B');
    INSERT INTO metadata.spaces (id,organization_id,floor_id,name,code) VALUES
        (space_a1,org_a,floor_a,'PH2-228 Banquet Hall 2','PH2_228_BANQUET_2'),
        (space_a2,org_a,floor_a,'PH2-228 Lobby','PH2_228_LOBBY'),
        (space_a3,org_a,floor_a,'PH2-228 Seasons Restaurant','PH2_228_SEASONS'),
        (space_b1,org_b,floor_b,'PH2-228 Org B Space','PH2_228_ORG_B_SPACE');
    INSERT INTO metadata.gateways (id,organization_id,site_id,name,external_id) VALUES
        (gw_a,org_a,site_a,'PH2-228 GW A','PH2-228-GW-A'),
        (gw_b,org_b,site_b,'PH2-228 GW B','PH2-228-GW-B');
    INSERT INTO metadata.devices (id,organization_id,gateway_id,name,external_id,profile_id) VALUES
        (dev_a,org_a,gw_a,'PH2-228 AirSense A','PH2-228-AIR-A',prof_air),
        (dev_b,org_a,gw_a,'PH2-228 AirSense B','PH2-228-AIR-B',prof_air),
        (dev_c,org_a,gw_a,'PH2-228 AirSense C','PH2-228-AIR-C',prof_air),
        (dev_d,org_a,gw_a,'PH2-228 AirSense D','PH2-228-AIR-D',prof_air),
        (dev_bx,org_b,gw_b,'PH2-228 AirSense OrgB','PH2-228-AIR-BX',prof_air);

    -- config.device_point_configuration rows for every AirSense point on each
    -- of these devices are created automatically by the profile-mapping sync
    -- when the device row is inserted above, so the composite binding FK
    -- (device_id, logical_point_id) -> config.device_point_configuration has
    -- its targets already. (Verified below in test 2 for the negative case.)

    -- ==================================================================
    -- 2. Composite FK: no device_point_configuration row -> rejected.
    -- ==================================================================
    v_raised := FALSE;
    BEGIN
        INSERT INTO metadata.space_points (space_id,logical_point_id,device_id,organization_id,effective_from)
        VALUES (space_a1, lp_temp, 'e2800000-0000-0000-0000-0000000000ff', org_a, '2026-01-01T00:00:00Z');
        RAISE EXCEPTION 'TEST 2 FAILED: space_points accepted a (device,logical_point) with no device_point_configuration row.';
    EXCEPTION
        WHEN foreign_key_violation THEN v_raised := TRUE;
        WHEN OTHERS THEN
            IF SQLERRM LIKE 'TEST %' THEN RAISE; END IF;
            RAISE EXCEPTION 'TEST 2 FAILED: expected foreign_key_violation, got % (%)', SQLSTATE, SQLERRM;
    END;
    IF NOT v_raised THEN RAISE EXCEPTION 'TEST 2 FAILED: no exception.'; END IF;
    RAISE NOTICE 'TEST 2 passed: composite FK to config.device_point_configuration enforced.';

    -- ==================================================================
    -- 3. Four-AirSense representation.
    --   A -> Banquet Hall 2, B -> Lobby, C -> Seasons, D -> Seasons.
    --   All four share lp_temp; two share space_a3. All must coexist.
    -- ==================================================================
    INSERT INTO metadata.space_points (space_id,logical_point_id,device_id,organization_id,effective_from) VALUES
        (space_a1, lp_temp, dev_a, org_a, '2026-01-01T00:00:00Z'),
        (space_a1, lp_hum , dev_a, org_a, '2026-01-01T00:00:00Z'),
        (space_a2, lp_temp, dev_b, org_a, '2026-01-01T00:00:00Z'),
        (space_a2, lp_hum , dev_b, org_a, '2026-01-01T00:00:00Z'),
        (space_a3, lp_temp, dev_c, org_a, '2026-01-01T00:00:00Z'),
        (space_a3, lp_hum , dev_c, org_a, '2026-01-01T00:00:00Z'),
        (space_a3, lp_temp, dev_d, org_a, '2026-01-01T00:00:00Z'),
        (space_a3, lp_hum , dev_d, org_a, '2026-01-01T00:00:00Z');

    SELECT count(*) INTO v_rows
    FROM metadata.space_points
    WHERE logical_point_id = lp_temp
      AND device_id IN (dev_a,dev_b,dev_c,dev_d);
    IF v_rows <> 4 THEN
        RAISE EXCEPTION 'TEST 3 FAILED: expected 4 coexisting ENV_TEMPERATURE bindings, got %', v_rows;
    END IF;
    IF (SELECT count(DISTINCT space_id) FROM metadata.space_points
        WHERE logical_point_id=lp_temp AND device_id IN (dev_c,dev_d)) <> 1 THEN
        RAISE EXCEPTION 'TEST 3 FAILED: devices C and D should both resolve to one Space.';
    END IF;
    RAISE NOTICE 'TEST 3 passed: four-AirSense representation (shared logical_point_id, four device-scoped bindings).';

    -- ==================================================================
    -- 4. Same device + same point + overlap -> 23P01.
    -- ==================================================================
    v_raised := FALSE;
    BEGIN
        INSERT INTO metadata.space_points (space_id,logical_point_id,device_id,organization_id,effective_from,effective_to)
        VALUES (space_a2, lp_temp, dev_a, org_a, '2026-02-01T00:00:00Z', '2026-03-01T00:00:00Z');
        RAISE EXCEPTION 'TEST 4 FAILED: overlapping binding for the same device+point was accepted.';
    EXCEPTION
        WHEN OTHERS THEN
            IF SQLERRM LIKE 'TEST %' THEN RAISE; END IF;
            IF SQLSTATE <> '23P01' THEN
                RAISE EXCEPTION 'TEST 4 FAILED: expected exclusion_violation (23P01), got % (%)', SQLSTATE, SQLERRM;
            END IF;
            v_raised := TRUE;
    END;
    IF NOT v_raised THEN RAISE EXCEPTION 'TEST 4 FAILED: no exception.'; END IF;
    RAISE NOTICE 'TEST 4 passed: same device+point overlap rejected.';

    -- ==================================================================
    -- 5. Same device + same point + non-overlapping history -> accepted,
    --    point-in-time lookup resolves each side.
    -- ==================================================================
    UPDATE metadata.space_points
    SET effective_to = '2026-06-01T00:00:00Z'
    WHERE device_id = dev_a AND logical_point_id = lp_temp AND effective_to IS NULL;

    INSERT INTO metadata.space_points (space_id,logical_point_id,device_id,organization_id,effective_from)
    VALUES (space_a2, lp_temp, dev_a, org_a, '2026-06-01T00:00:00Z');

    SELECT space_id INTO v_space FROM metadata.space_points
    WHERE device_id=dev_a AND logical_point_id=lp_temp
      AND effective_range @> '2026-03-15T00:00:00Z'::TIMESTAMPTZ;
    IF v_space IS DISTINCT FROM space_a1 THEN
        RAISE EXCEPTION 'TEST 5 FAILED: pre-move lookup should resolve space_a1, got %', v_space;
    END IF;
    SELECT space_id INTO v_space FROM metadata.space_points
    WHERE device_id=dev_a AND logical_point_id=lp_temp
      AND effective_range @> '2026-09-01T00:00:00Z'::TIMESTAMPTZ;
    IF v_space IS DISTINCT FROM space_a2 THEN
        RAISE EXCEPTION 'TEST 5 FAILED: post-move lookup should resolve space_a2, got %', v_space;
    END IF;
    RAISE NOTICE 'TEST 5 passed: non-overlapping historical re-binding + point-in-time resolution.';

    -- ==================================================================
    -- 6. Different devices, same point, overlapping periods -> independent.
    --    dev_b, dev_c, dev_d each hold an open [2026-01-01, inf) lp_temp
    --    binding from test 3 -- three overlapping windows for one logical
    --    point across three devices, all coexisting under the device-scoped
    --    exclusion.
    -- ==================================================================
    SELECT count(*) INTO v_rows
    FROM metadata.space_points a
    JOIN metadata.space_points b
      ON a.logical_point_id = b.logical_point_id
     AND a.device_id <> b.device_id
     AND a.effective_range && b.effective_range
    WHERE a.logical_point_id = lp_temp;
    IF v_rows = 0 THEN
        RAISE EXCEPTION 'TEST 6 FAILED: expected overlapping same-point bindings across different devices to coexist.';
    END IF;
    RAISE NOTICE 'TEST 6 passed: different devices bind the same logical point independently (% overlapping cross-device pairs).', v_rows;

    -- ==================================================================
    -- 7. Tenant safety.
    -- ==================================================================
    v_raised := FALSE;
    BEGIN
        -- org-A device -> org-B Space.
        INSERT INTO metadata.space_points (space_id,logical_point_id,device_id,organization_id,effective_from)
        VALUES (space_b1, lp_temp, dev_a, org_a, '2026-01-01T00:00:00Z');
        RAISE EXCEPTION 'TEST 7 FAILED: cross-organization binding (org-A device -> org-B Space) was accepted.';
    EXCEPTION
        WHEN OTHERS THEN
            IF SQLERRM LIKE 'TEST %' THEN RAISE; END IF;
            IF SQLERRM NOT LIKE '%crosses organizations%' THEN
                RAISE EXCEPTION 'TEST 7 FAILED: expected a cross-organization rejection, got % (%)', SQLSTATE, SQLERRM;
            END IF;
            v_raised := TRUE;
    END;
    IF NOT v_raised THEN RAISE EXCEPTION 'TEST 7 FAILED: no exception (cross-org).'; END IF;

    v_raised := FALSE;
    BEGIN
        -- device in org-A, but row organization_id = org-B.
        INSERT INTO metadata.space_points (space_id,logical_point_id,device_id,organization_id,effective_from)
        VALUES (space_a1, lp_temp, dev_b, org_b, '2027-01-01T00:00:00Z');
        RAISE EXCEPTION 'TEST 7 FAILED: mismatched row organization_id was accepted.';
    EXCEPTION
        WHEN OTHERS THEN
            IF SQLERRM LIKE 'TEST %' THEN RAISE; END IF;
            IF SQLERRM NOT LIKE '%does not match the device%' THEN
                RAISE EXCEPTION 'TEST 7 FAILED: expected an organization_id-mismatch rejection, got % (%)', SQLSTATE, SQLERRM;
            END IF;
            v_raised := TRUE;
    END;
    IF NOT v_raised THEN RAISE EXCEPTION 'TEST 7 FAILED: no exception (org_id mismatch).'; END IF;
    RAISE NOTICE 'TEST 7 passed: cross-tenant + organization_id-mismatch bindings rejected.';

    -- ==================================================================
    -- 8. Loader: per-device Space resolution.
    --   dev_a bound to space_a1, dev_b bound to space_a2 (from test 3 / 5;
    --   dev_a's current lp_temp window is [2026-06-01, inf) -> space_a2, so
    --   use a fresh device pair to keep the intent crisp).
    -- ==================================================================
    -- Clean slate for two devices with a single, current binding each.
    DELETE FROM metadata.space_points WHERE device_id IN (dev_c, dev_d);
    INSERT INTO metadata.space_points (space_id,logical_point_id,device_id,organization_id,effective_from) VALUES
        (space_a1, lp_temp, dev_c, org_a, e1 - INTERVAL '1 day'),
        (space_a3, lp_temp, dev_d, org_a, e1 - INTERVAL '1 day');

    INSERT INTO config.telemetry_capture_policies
        (site_id, capture_interval_seconds, alignment_mode, late_arrival_tolerance_seconds, effective_from, is_enabled)
    VALUES (site_a, 300, 'WALL_CLOCK', 900, e1 - INTERVAL '2 days', TRUE);

    INSERT INTO telemetry.normalized_points
        (event_time,organization_id,site_id,device_id,logical_point_id,device_uid,logical_point,numeric_value,quality_code,platform_received_at)
    VALUES
        (e1,org_a,site_a,dev_c,lp_temp,'PH2-228-AIR-C','ENV_TEMPERATURE',22.0,'GOOD',e1),
        (e1,org_a,site_a,dev_d,lp_temp,'PH2-228-AIR-D','ENV_TEMPERATURE',26.5,'GOOD',e1);

    UPDATE telemetry.pipeline_state SET last_received_at = e1 - INTERVAL '10 minutes'
    WHERE pipeline_name='environment_measurements';
    DROP TABLE IF EXISTS tmp_environment_candidates;
    CALL telemetry.load_environment_measurements_incremental(INTERVAL '15 minutes', NULL);

    SELECT space_id INTO v_space FROM telemetry.environment_measurements WHERE device_id=dev_c;
    IF v_space IS DISTINCT FROM space_a1 THEN
        RAISE EXCEPTION 'TEST 8 FAILED: device C temperature should resolve to space_a1 (Banquet Hall 2), got %', v_space;
    END IF;
    SELECT space_id INTO v_space FROM telemetry.environment_measurements WHERE device_id=dev_d;
    IF v_space IS DISTINCT FROM space_a3 THEN
        RAISE EXCEPTION 'TEST 8 FAILED: device D temperature should resolve to space_a3 (Seasons), got %', v_space;
    END IF;
    SELECT count(*) INTO v_rows FROM telemetry.environment_measurements WHERE device_id IN (dev_c,dev_d);
    IF v_rows <> 2 THEN
        RAISE EXCEPTION 'TEST 8 FAILED: expected 2 routed rows, got %', v_rows;
    END IF;
    RAISE NOTICE 'TEST 8 passed: environment loader resolves each device to its OWN bound Space.';

    -- ==================================================================
    -- 9. asset_devices untouched.
    -- ==================================================================
    IF EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema='metadata' AND table_name='asset_devices'
          AND column_name IN ('device_id','asset_id','relationship_type')
        HAVING count(*) <> 3
    ) THEN
        RAISE EXCEPTION 'TEST 9 FAILED: metadata.asset_devices core columns changed.';
    END IF;
    IF EXISTS (
        SELECT 1 FROM pg_trigger
        WHERE tgrelid = 'metadata.asset_devices'::regclass
          AND tgname LIKE '%point_binding%'
    ) THEN
        RAISE EXCEPTION 'TEST 9 FAILED: a point-binding trigger was attached to metadata.asset_devices.';
    END IF;
    RAISE NOTICE 'TEST 9 passed: metadata.asset_devices untouched.';
END;
$test$;

ROLLBACK;

SELECT 'Phase 2 amendment (migration 228) device-specific asset_points/space_points binding assertions passed.' AS result;
