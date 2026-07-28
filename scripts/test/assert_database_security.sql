\set ON_ERROR_STOP on

-- =============================================================================
-- WiseWatts EMS database security contract
--
-- These assertions evaluate effective PostgreSQL privileges in the disposable
-- integration database. A test fails when a role has more or less access than
-- the production contract intends.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- Required roles
-- ---------------------------------------------------------------------------

DO
$$
BEGIN
    ---------------------------------------------------------------------------
    -- Telegraf canonical ingestion boundary
    --
    -- MQTT telemetry lands only in public.mqtt_staging. Telegraf must not
    -- access downstream normalization tables or read back landed telemetry.
    ---------------------------------------------------------------------------

    IF NOT has_schema_privilege(
        'telegraf_writer',
        'public',
        'USAGE'
    ) THEN
        RAISE EXCEPTION
            'telegraf_writer lacks USAGE on public schema';
    END IF;

    IF has_schema_privilege(
        'telegraf_writer',
        'telemetry',
        'USAGE'
    ) THEN
        RAISE EXCEPTION
            'telegraf_writer unexpectedly has USAGE on telemetry schema';
    END IF;

    IF NOT has_table_privilege(
        'telegraf_writer',
        'public.mqtt_staging',
        'INSERT'
    ) THEN
        RAISE EXCEPTION
            'telegraf_writer lacks INSERT on public.mqtt_staging';
    END IF;

    IF has_table_privilege(
        'telegraf_writer',
        'public.mqtt_staging',
        'SELECT'
    ) THEN
        RAISE EXCEPTION
            'telegraf_writer unexpectedly has SELECT on public.mqtt_staging';
    END IF;

    IF has_table_privilege(
        'telegraf_writer',
        'public.mqtt_staging',
        'UPDATE'
    ) THEN
        RAISE EXCEPTION
            'telegraf_writer unexpectedly has UPDATE on public.mqtt_staging';
    END IF;

    IF has_table_privilege(
        'telegraf_writer',
        'public.mqtt_staging',
        'DELETE'
    ) THEN
        RAISE EXCEPTION
            'telegraf_writer unexpectedly has DELETE on public.mqtt_staging';
    END IF;

    IF has_table_privilege(
        'telegraf_writer',
        'public.mqtt_staging',
        'TRUNCATE'
    ) THEN
        RAISE EXCEPTION
            'telegraf_writer unexpectedly has TRUNCATE on public.mqtt_staging';
    END IF;

    IF has_table_privilege(
        'telegraf_writer',
        'telemetry.telegraf_ingest',
        'INSERT'
    ) THEN
        RAISE EXCEPTION
            'telegraf_writer unexpectedly has INSERT on telemetry.telegraf_ingest';
    END IF;

    IF has_table_privilege(
        'telegraf_writer',
        'telemetry.mqtt_staging',
        'INSERT'
    ) THEN
        RAISE EXCEPTION
            'telegraf_writer unexpectedly has INSERT on telemetry.mqtt_staging';
    END IF;
END
$$;

-- ---------------------------------------------------------------------------
-- Application role
-- ---------------------------------------------------------------------------

DO $$
BEGIN
    IF NOT has_schema_privilege(
        'ems_app',
        'admin',
        'USAGE'
    ) THEN
        RAISE EXCEPTION
            'ems_app lacks USAGE on admin schema';
    END IF;

    IF has_table_privilege(
        'ems_app',
        'admin.schema_migrations',
        'SELECT,INSERT,UPDATE,DELETE,TRUNCATE'
    ) THEN
        RAISE EXCEPTION
            'ems_app unexpectedly has direct access to admin.schema_migrations';
    END IF;

    IF has_table_privilege(
        'ems_app',
        'telemetry.energy_measurements',
        'INSERT,UPDATE,DELETE'
    ) THEN
        RAISE EXCEPTION
            'ems_app unexpectedly writes directly to energy_measurements';
    END IF;
END
$$;

-- ---------------------------------------------------------------------------
-- SECURITY DEFINER hardening
-- ---------------------------------------------------------------------------

DO $$
DECLARE
    unsafe_functions text[];
BEGIN
    SELECT array_agg(
        format(
            '%I.%I(%s)',
            n.nspname,
            p.proname,
            pg_get_function_identity_arguments(p.oid)
        )
    )
    INTO unsafe_functions
    FROM pg_proc p
    JOIN pg_namespace n
      ON n.oid = p.pronamespace
    WHERE p.prosecdef
      AND n.nspname IN (
          'admin',
          'metadata',
          'config',
          'telemetry',
          'analytics'
      )
      AND NOT EXISTS (
          SELECT 1
          FROM unnest(coalesce(p.proconfig, ARRAY[]::text[])) setting
          WHERE setting LIKE 'search_path=%'
      );

    IF unsafe_functions IS NOT NULL THEN
        RAISE EXCEPTION
            'SECURITY DEFINER functions lack an explicit search_path: %',
            unsafe_functions;
    END IF;
END
$$;

SELECT
    rolname,
    rolcanlogin,
    rolsuper,
    rolcreaterole,
    rolcreatedb,
    rolreplication,
    rolbypassrls
FROM pg_roles
WHERE rolname IN (
    'ems_app',
    'ems_readonly',
    'grafana_reader',
    'telegraf_writer'
)
ORDER BY rolname;

SELECT 'Database security assertions passed.' AS result;

-- BEGIN TELEGRAF SECURITY CONTRACT
DO $$
BEGIN
    IF NOT has_schema_privilege(
        'telegraf_writer',
        'public',
        'USAGE'
    ) THEN
        RAISE EXCEPTION
            'telegraf_writer must have USAGE on schema public';
    END IF;

    IF NOT has_table_privilege(
        'telegraf_writer',
        'public.mqtt_staging',
        'INSERT'
    ) THEN
        RAISE EXCEPTION
            'telegraf_writer must have INSERT on public.mqtt_staging';
    END IF;

    IF has_table_privilege(
        'telegraf_writer',
        'public.mqtt_staging',
        'SELECT'
    )
    OR has_table_privilege(
        'telegraf_writer',
        'public.mqtt_staging',
        'UPDATE'
    )
    OR has_table_privilege(
        'telegraf_writer',
        'public.mqtt_staging',
        'DELETE'
    )
    OR has_table_privilege(
        'telegraf_writer',
        'public.mqtt_staging',
        'TRUNCATE'
    ) THEN
        RAISE EXCEPTION
            'telegraf_writer has excessive privileges on public.mqtt_staging';
    END IF;

    IF has_table_privilege(
        'telegraf_writer',
        'telemetry.telegraf_ingest',
        'INSERT'
    ) THEN
        RAISE EXCEPTION
            'telegraf_writer must not insert into telemetry.telegraf_ingest';
    END IF;

    IF has_table_privilege(
        'telegraf_writer',
        'telemetry.mqtt_staging',
        'INSERT'
    ) THEN
        RAISE EXCEPTION
            'telegraf_writer must not insert into telemetry.mqtt_staging';
    END IF;
END
$$;
-- END TELEGRAF SECURITY CONTRACT

