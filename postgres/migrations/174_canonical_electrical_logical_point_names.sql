BEGIN;

-- =====================================================================
-- Canonical electrical logical-point naming
--
-- Rename:
--
--   ENERGY_ACTIVE_POWER_*      -> ACTIVE_POWER_*
--   ENERGY_APPARENT_POWER_*    -> APPARENT_POWER_*
--   ENERGY_REACTIVE_POWER_*    -> REACTIVE_POWER_*
--   ENERGY_APPARENT_ENERGY_*   -> APPARENT_ENERGY_*
--   ENERGY_REACTIVE_ENERGY_*   -> REACTIVE_ENERGY_*
--
-- UUID identities do NOT change.
--
-- Historical telemetry.normalized_points.logical_point text is
-- deliberately NOT rewritten.
--
-- The energy routing view/procedure are changed to use logical_point_id
-- for these signals. This lets:
--
--   historical rows with old names
--   +
--   future rows with new names
--
-- route through the same canonical energy pipeline.
-- =====================================================================


-- ---------------------------------------------------------------------
-- 1. Precondition:
--    the exact 20 UUID/name pairs must still be present.
-- ---------------------------------------------------------------------

DO $$
DECLARE
    v_count integer;
    v_conflicts integer;
BEGIN

    WITH mapping(id, old_name, new_name) AS (
        VALUES
        ('adf4c51a-6c14-4e65-9f02-b37d363001f6'::uuid,
         'ENERGY_ACTIVE_POWER_L1', 'ACTIVE_POWER_L1'),
        ('b331d9ef-82fa-4e4e-b081-3582e0f5d51c'::uuid,
         'ENERGY_ACTIVE_POWER_L2', 'ACTIVE_POWER_L2'),
        ('6868ab67-7cf8-4ec3-b6d7-4119d1c7da9b'::uuid,
         'ENERGY_ACTIVE_POWER_L3', 'ACTIVE_POWER_L3'),
        ('44652ee7-57fb-4174-b4e9-4992323056fd'::uuid,
         'ENERGY_ACTIVE_POWER_TOTAL', 'ACTIVE_POWER_TOTAL'),

        ('dee482f7-32cb-466f-a7c8-51491dc36b8c'::uuid,
         'ENERGY_APPARENT_POWER_L1', 'APPARENT_POWER_L1'),
        ('e2800629-bf0c-48f9-8174-7935618e7f90'::uuid,
         'ENERGY_APPARENT_POWER_L2', 'APPARENT_POWER_L2'),
        ('40f1773e-6cf2-4a07-b25c-545151278989'::uuid,
         'ENERGY_APPARENT_POWER_L3', 'APPARENT_POWER_L3'),
        ('56b6ce2a-acf8-48be-8674-87f4e61d7e12'::uuid,
         'ENERGY_APPARENT_POWER_TOTAL', 'APPARENT_POWER_TOTAL'),

        ('61e3efa2-a04c-4157-ae99-a875157f0062'::uuid,
         'ENERGY_REACTIVE_POWER_L1', 'REACTIVE_POWER_L1'),
        ('6a7b7c26-b004-4569-9c75-defd53a9b3e4'::uuid,
         'ENERGY_REACTIVE_POWER_L2', 'REACTIVE_POWER_L2'),
        ('29777d90-4210-40a8-8632-0732d0f41a6b'::uuid,
         'ENERGY_REACTIVE_POWER_L3', 'REACTIVE_POWER_L3'),
        ('df16db14-0d1d-45f0-b637-5d55ee621227'::uuid,
         'ENERGY_REACTIVE_POWER_TOTAL', 'REACTIVE_POWER_TOTAL'),

        ('8abbdfcf-de76-43b8-8c1c-30b67f3e6a06'::uuid,
         'ENERGY_APPARENT_ENERGY_L1', 'APPARENT_ENERGY_L1'),
        ('25cee3e3-1249-44ea-862d-aafe4cd1c42b'::uuid,
         'ENERGY_APPARENT_ENERGY_L2', 'APPARENT_ENERGY_L2'),
        ('59a34763-7c77-49e2-a92a-65635ebd5956'::uuid,
         'ENERGY_APPARENT_ENERGY_L3', 'APPARENT_ENERGY_L3'),
        ('2e13ca70-a769-47d0-89e3-68396e7bcd6e'::uuid,
         'ENERGY_APPARENT_ENERGY_TOTAL', 'APPARENT_ENERGY_TOTAL'),

        ('cb060b6c-6f28-4951-92fd-02ab0226bd6c'::uuid,
         'ENERGY_REACTIVE_ENERGY_L1', 'REACTIVE_ENERGY_L1'),
        ('65e814aa-bbb5-4b11-aa51-fa234ffbd2d7'::uuid,
         'ENERGY_REACTIVE_ENERGY_L2', 'REACTIVE_ENERGY_L2'),
        ('b3947e8e-2c64-4bd1-8603-89eb351afbd9'::uuid,
         'ENERGY_REACTIVE_ENERGY_L3', 'REACTIVE_ENERGY_L3'),
        ('361ddb03-2d71-4b8a-aec5-c016ed61376d'::uuid,
         'ENERGY_REACTIVE_ENERGY_TOTAL', 'REACTIVE_ENERGY_TOTAL')
    )
    SELECT count(*)
    INTO v_count
    FROM mapping m
    JOIN metadata.logical_points lp
      ON lp.id = m.id
     AND lp.name = m.old_name;

    IF v_count <> 20 THEN
        RAISE EXCEPTION
            'Canonical rename precondition failed: expected 20 UUID/name matches, found %',
            v_count;
    END IF;


    WITH mapping(id, new_name) AS (
        VALUES
        ('adf4c51a-6c14-4e65-9f02-b37d363001f6'::uuid, 'ACTIVE_POWER_L1'),
        ('b331d9ef-82fa-4e4e-b081-3582e0f5d51c'::uuid, 'ACTIVE_POWER_L2'),
        ('6868ab67-7cf8-4ec3-b6d7-4119d1c7da9b'::uuid, 'ACTIVE_POWER_L3'),
        ('44652ee7-57fb-4174-b4e9-4992323056fd'::uuid, 'ACTIVE_POWER_TOTAL'),

        ('dee482f7-32cb-466f-a7c8-51491dc36b8c'::uuid, 'APPARENT_POWER_L1'),
        ('e2800629-bf0c-48f9-8174-7935618e7f90'::uuid, 'APPARENT_POWER_L2'),
        ('40f1773e-6cf2-4a07-b25c-545151278989'::uuid, 'APPARENT_POWER_L3'),
        ('56b6ce2a-acf8-48be-8674-87f4e61d7e12'::uuid, 'APPARENT_POWER_TOTAL'),

        ('61e3efa2-a04c-4157-ae99-a875157f0062'::uuid, 'REACTIVE_POWER_L1'),
        ('6a7b7c26-b004-4569-9c75-defd53a9b3e4'::uuid, 'REACTIVE_POWER_L2'),
        ('29777d90-4210-40a8-8632-0732d0f41a6b'::uuid, 'REACTIVE_POWER_L3'),
        ('df16db14-0d1d-45f0-b637-5d55ee621227'::uuid, 'REACTIVE_POWER_TOTAL'),

        ('8abbdfcf-de76-43b8-8c1c-30b67f3e6a06'::uuid, 'APPARENT_ENERGY_L1'),
        ('25cee3e3-1249-44ea-862d-aafe4cd1c42b'::uuid, 'APPARENT_ENERGY_L2'),
        ('59a34763-7c77-49e2-a92a-65635ebd5956'::uuid, 'APPARENT_ENERGY_L3'),
        ('2e13ca70-a769-47d0-89e3-68396e7bcd6e'::uuid, 'APPARENT_ENERGY_TOTAL'),

        ('cb060b6c-6f28-4951-92fd-02ab0226bd6c'::uuid, 'REACTIVE_ENERGY_L1'),
        ('65e814aa-bbb5-4b11-aa51-fa234ffbd2d7'::uuid, 'REACTIVE_ENERGY_L2'),
        ('b3947e8e-2c64-4bd1-8603-89eb351afbd9'::uuid, 'REACTIVE_ENERGY_L3'),
        ('361ddb03-2d71-4b8a-aec5-c016ed61376d'::uuid, 'REACTIVE_ENERGY_TOTAL')
    )
    SELECT count(*)
    INTO v_conflicts
    FROM mapping m
    JOIN metadata.logical_points lp
      ON lp.name = m.new_name
     AND lp.id <> m.id;

    IF v_conflicts <> 0 THEN
        RAISE EXCEPTION
            'Canonical rename aborted: % target logical-point names already exist',
            v_conflicts;
    END IF;

END
$$;


-- ---------------------------------------------------------------------
-- 2. Make the full-resolution energy view independent of these names.
--
--    Existing historical rows retain their old logical_point text.
--    Therefore routing by UUID is the durable contract.
-- ---------------------------------------------------------------------

DO $$
DECLARE
    v_definition text;
    r record;
BEGIN

    SELECT pg_get_viewdef(
        'telemetry.v_energy_measurements_full_resolution'::regclass,
        true
    )
    INTO v_definition;

    FOR r IN
        SELECT *
        FROM (
            VALUES
            ('adf4c51a-6c14-4e65-9f02-b37d363001f6',
             'ENERGY_ACTIVE_POWER_L1'),
            ('b331d9ef-82fa-4e4e-b081-3582e0f5d51c',
             'ENERGY_ACTIVE_POWER_L2'),
            ('6868ab67-7cf8-4ec3-b6d7-4119d1c7da9b',
             'ENERGY_ACTIVE_POWER_L3'),
            ('44652ee7-57fb-4174-b4e9-4992323056fd',
             'ENERGY_ACTIVE_POWER_TOTAL'),

            ('dee482f7-32cb-466f-a7c8-51491dc36b8c',
             'ENERGY_APPARENT_POWER_L1'),
            ('e2800629-bf0c-48f9-8174-7935618e7f90',
             'ENERGY_APPARENT_POWER_L2'),
            ('40f1773e-6cf2-4a07-b25c-545151278989',
             'ENERGY_APPARENT_POWER_L3'),
            ('56b6ce2a-acf8-48be-8674-87f4e61d7e12',
             'ENERGY_APPARENT_POWER_TOTAL'),

            ('61e3efa2-a04c-4157-ae99-a875157f0062',
             'ENERGY_REACTIVE_POWER_L1'),
            ('6a7b7c26-b004-4569-9c75-defd53a9b3e4',
             'ENERGY_REACTIVE_POWER_L2'),
            ('29777d90-4210-40a8-8632-0732d0f41a6b',
             'ENERGY_REACTIVE_POWER_L3'),
            ('df16db14-0d1d-45f0-b637-5d55ee621227',
             'ENERGY_REACTIVE_POWER_TOTAL'),

            ('8abbdfcf-de76-43b8-8c1c-30b67f3e6a06',
             'ENERGY_APPARENT_ENERGY_L1'),
            ('25cee3e3-1249-44ea-862d-aafe4cd1c42b',
             'ENERGY_APPARENT_ENERGY_L2'),
            ('59a34763-7c77-49e2-a92a-65635ebd5956',
             'ENERGY_APPARENT_ENERGY_L3'),
            ('2e13ca70-a769-47d0-89e3-68396e7bcd6e',
             'ENERGY_APPARENT_ENERGY_TOTAL'),

            ('cb060b6c-6f28-4951-92fd-02ab0226bd6c',
             'ENERGY_REACTIVE_ENERGY_L1'),
            ('65e814aa-bbb5-4b11-aa51-fa234ffbd2d7',
             'ENERGY_REACTIVE_ENERGY_L2'),
            ('b3947e8e-2c64-4bd1-8603-89eb351afbd9',
             'ENERGY_REACTIVE_ENERGY_L3'),
            ('361ddb03-2d71-4b8a-aec5-c016ed61376d',
             'ENERGY_REACTIVE_ENERGY_TOTAL')
        ) AS x(id_text, old_name)
    LOOP

        -- pg_get_viewdef() currently emits ::text casts.
        v_definition := replace(
            v_definition,
            format(
                'rs.logical_point = %L::text',
                r.old_name
            ),
            format(
                'rs.logical_point_id = %L::uuid',
                r.id_text
            )
        );

        -- Defensive variant in case PostgreSQL formatting changes.
        v_definition := replace(
            v_definition,
            format(
                'rs.logical_point = %L',
                r.old_name
            ),
            format(
                'rs.logical_point_id = %L::uuid',
                r.id_text
            )
        );

    END LOOP;

    IF v_definition ~
       'ENERGY_(ACTIVE_POWER|APPARENT_POWER|REACTIVE_POWER|APPARENT_ENERGY|REACTIVE_ENERGY)_(TOTAL|L1|L2|L3)'
    THEN
        RAISE EXCEPTION
            'Not all old logical-point predicates were removed from v_energy_measurements_full_resolution';
    END IF;

    EXECUTE
        'CREATE OR REPLACE VIEW telemetry.v_energy_measurements_full_resolution AS '
        || v_definition;

END
$$;


-- ---------------------------------------------------------------------
-- 3. Make incremental energy routing independent of those names too.
-- ---------------------------------------------------------------------

DO $$
DECLARE
    v_definition text;
    r record;
BEGIN

    SELECT pg_get_functiondef(
        'telemetry.load_energy_measurements_incremental(interval)'::regprocedure
    )
    INTO v_definition;

    FOR r IN
        SELECT *
        FROM (
            VALUES
            ('adf4c51a-6c14-4e65-9f02-b37d363001f6',
             'ENERGY_ACTIVE_POWER_L1'),
            ('b331d9ef-82fa-4e4e-b081-3582e0f5d51c',
             'ENERGY_ACTIVE_POWER_L2'),
            ('6868ab67-7cf8-4ec3-b6d7-4119d1c7da9b',
             'ENERGY_ACTIVE_POWER_L3'),
            ('44652ee7-57fb-4174-b4e9-4992323056fd',
             'ENERGY_ACTIVE_POWER_TOTAL'),

            ('dee482f7-32cb-466f-a7c8-51491dc36b8c',
             'ENERGY_APPARENT_POWER_L1'),
            ('e2800629-bf0c-48f9-8174-7935618e7f90',
             'ENERGY_APPARENT_POWER_L2'),
            ('40f1773e-6cf2-4a07-b25c-545151278989',
             'ENERGY_APPARENT_POWER_L3'),
            ('56b6ce2a-acf8-48be-8674-87f4e61d7e12',
             'ENERGY_APPARENT_POWER_TOTAL'),

            ('61e3efa2-a04c-4157-ae99-a875157f0062',
             'ENERGY_REACTIVE_POWER_L1'),
            ('6a7b7c26-b004-4569-9c75-defd53a9b3e4',
             'ENERGY_REACTIVE_POWER_L2'),
            ('29777d90-4210-40a8-8632-0732d0f41a6b',
             'ENERGY_REACTIVE_POWER_L3'),
            ('df16db14-0d1d-45f0-b637-5d55ee621227',
             'ENERGY_REACTIVE_POWER_TOTAL'),

            ('8abbdfcf-de76-43b8-8c1c-30b67f3e6a06',
             'ENERGY_APPARENT_ENERGY_L1'),
            ('25cee3e3-1249-44ea-862d-aafe4cd1c42b',
             'ENERGY_APPARENT_ENERGY_L2'),
            ('59a34763-7c77-49e2-a92a-65635ebd5956',
             'ENERGY_APPARENT_ENERGY_L3'),
            ('2e13ca70-a769-47d0-89e3-68396e7bcd6e',
             'ENERGY_APPARENT_ENERGY_TOTAL'),

            ('cb060b6c-6f28-4951-92fd-02ab0226bd6c',
             'ENERGY_REACTIVE_ENERGY_L1'),
            ('65e814aa-bbb5-4b11-aa51-fa234ffbd2d7',
             'ENERGY_REACTIVE_ENERGY_L2'),
            ('b3947e8e-2c64-4bd1-8603-89eb351afbd9',
             'ENERGY_REACTIVE_ENERGY_L3'),
            ('361ddb03-2d71-4b8a-aec5-c016ed61376d',
             'ENERGY_REACTIVE_ENERGY_TOTAL')
        ) AS x(id_text, old_name)
    LOOP

        v_definition := replace(
            v_definition,
            format(
                'rs.logical_point = %L::text',
                r.old_name
            ),
            format(
                'rs.logical_point_id = %L::uuid',
                r.id_text
            )
        );

        v_definition := replace(
            v_definition,
            format(
                'rs.logical_point = %L',
                r.old_name
            ),
            format(
                'rs.logical_point_id = %L::uuid',
                r.id_text
            )
        );

    END LOOP;

    IF v_definition ~
       'ENERGY_(ACTIVE_POWER|APPARENT_POWER|REACTIVE_POWER|APPARENT_ENERGY|REACTIVE_ENERGY)_(TOTAL|L1|L2|L3)'
    THEN
        RAISE EXCEPTION
            'Not all old logical-point predicates were removed from load_energy_measurements_incremental';
    END IF;

    EXECUTE v_definition;

END
$$;


-- ---------------------------------------------------------------------
-- 4. Demand capability uses current metadata names.
--    It does not process historical denormalized labels, so rename its
--    literal metadata comparisons to the new canonical names.
-- ---------------------------------------------------------------------

DO $$
DECLARE
    v_definition text;
    r record;
BEGIN

    SELECT pg_get_functiondef(
        'config.resolve_device_demand_method(uuid,text,integer)'::regprocedure
    )
    INTO v_definition;

    FOR r IN
        SELECT *
        FROM (
            VALUES
            ('ENERGY_ACTIVE_POWER_TOTAL', 'ACTIVE_POWER_TOTAL'),
            ('ENERGY_APPARENT_POWER_TOTAL', 'APPARENT_POWER_TOTAL'),
            ('ENERGY_APPARENT_ENERGY_TOTAL', 'APPARENT_ENERGY_TOTAL')
        ) AS x(old_name, new_name)
    LOOP

        v_definition := replace(
            v_definition,
            quote_literal(r.old_name),
            quote_literal(r.new_name)
        );

    END LOOP;

    IF v_definition ~
       'ENERGY_(ACTIVE_POWER|APPARENT_POWER|APPARENT_ENERGY)_TOTAL'
    THEN
        RAISE EXCEPTION
            'Old demand capability logical-point names remain';
    END IF;

    EXECUTE v_definition;

END
$$;


-- ---------------------------------------------------------------------
-- 5. Rename canonical metadata.
-- ---------------------------------------------------------------------

DO $$
DECLARE
    v_updated integer;
BEGIN

    WITH mapping(id, old_name, new_name) AS (
        VALUES
        ('adf4c51a-6c14-4e65-9f02-b37d363001f6'::uuid,
         'ENERGY_ACTIVE_POWER_L1', 'ACTIVE_POWER_L1'),
        ('b331d9ef-82fa-4e4e-b081-3582e0f5d51c'::uuid,
         'ENERGY_ACTIVE_POWER_L2', 'ACTIVE_POWER_L2'),
        ('6868ab67-7cf8-4ec3-b6d7-4119d1c7da9b'::uuid,
         'ENERGY_ACTIVE_POWER_L3', 'ACTIVE_POWER_L3'),
        ('44652ee7-57fb-4174-b4e9-4992323056fd'::uuid,
         'ENERGY_ACTIVE_POWER_TOTAL', 'ACTIVE_POWER_TOTAL'),

        ('dee482f7-32cb-466f-a7c8-51491dc36b8c'::uuid,
         'ENERGY_APPARENT_POWER_L1', 'APPARENT_POWER_L1'),
        ('e2800629-bf0c-48f9-8174-7935618e7f90'::uuid,
         'ENERGY_APPARENT_POWER_L2', 'APPARENT_POWER_L2'),
        ('40f1773e-6cf2-4a07-b25c-545151278989'::uuid,
         'ENERGY_APPARENT_POWER_L3', 'APPARENT_POWER_L3'),
        ('56b6ce2a-acf8-48be-8674-87f4e61d7e12'::uuid,
         'ENERGY_APPARENT_POWER_TOTAL', 'APPARENT_POWER_TOTAL'),

        ('61e3efa2-a04c-4157-ae99-a875157f0062'::uuid,
         'ENERGY_REACTIVE_POWER_L1', 'REACTIVE_POWER_L1'),
        ('6a7b7c26-b004-4569-9c75-defd53a9b3e4'::uuid,
         'ENERGY_REACTIVE_POWER_L2', 'REACTIVE_POWER_L2'),
        ('29777d90-4210-40a8-8632-0732d0f41a6b'::uuid,
         'ENERGY_REACTIVE_POWER_L3', 'REACTIVE_POWER_L3'),
        ('df16db14-0d1d-45f0-b637-5d55ee621227'::uuid,
         'ENERGY_REACTIVE_POWER_TOTAL', 'REACTIVE_POWER_TOTAL'),

        ('8abbdfcf-de76-43b8-8c1c-30b67f3e6a06'::uuid,
         'ENERGY_APPARENT_ENERGY_L1', 'APPARENT_ENERGY_L1'),
        ('25cee3e3-1249-44ea-862d-aafe4cd1c42b'::uuid,
         'ENERGY_APPARENT_ENERGY_L2', 'APPARENT_ENERGY_L2'),
        ('59a34763-7c77-49e2-a92a-65635ebd5956'::uuid,
         'ENERGY_APPARENT_ENERGY_L3', 'APPARENT_ENERGY_L3'),
        ('2e13ca70-a769-47d0-89e3-68396e7bcd6e'::uuid,
         'ENERGY_APPARENT_ENERGY_TOTAL', 'APPARENT_ENERGY_TOTAL'),

        ('cb060b6c-6f28-4951-92fd-02ab0226bd6c'::uuid,
         'ENERGY_REACTIVE_ENERGY_L1', 'REACTIVE_ENERGY_L1'),
        ('65e814aa-bbb5-4b11-aa51-fa234ffbd2d7'::uuid,
         'ENERGY_REACTIVE_ENERGY_L2', 'REACTIVE_ENERGY_L2'),
        ('b3947e8e-2c64-4bd1-8603-89eb351afbd9'::uuid,
         'ENERGY_REACTIVE_ENERGY_L3', 'REACTIVE_ENERGY_L3'),
        ('361ddb03-2d71-4b8a-aec5-c016ed61376d'::uuid,
         'ENERGY_REACTIVE_ENERGY_TOTAL', 'REACTIVE_ENERGY_TOTAL')
    )
    UPDATE metadata.logical_points lp
       SET name = mapping.new_name
      FROM mapping
     WHERE lp.id = mapping.id
       AND lp.name = mapping.old_name;

    GET DIAGNOSTICS v_updated = ROW_COUNT;

    IF v_updated <> 20 THEN
        RAISE EXCEPTION
            'Expected to rename 20 logical points; renamed %',
            v_updated;
    END IF;

END
$$;


COMMIT;
