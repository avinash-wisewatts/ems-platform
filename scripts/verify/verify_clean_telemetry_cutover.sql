\set ON_ERROR_STOP on

DO $$
BEGIN
  IF (SELECT c.relkind FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
      WHERE n.nspname='public' AND c.relname='mqtt_staging') <> 'v' THEN
    RAISE EXCEPTION 'public.mqtt_staging is not a view';
  END IF;
  IF to_regclass('telemetry.mqtt_staging') IS NOT NULL THEN
    RAISE EXCEPTION 'telemetry.mqtt_staging still exists';
  END IF;
  IF pg_get_viewdef('telemetry.v_rtdata'::regclass, true) NOT ILIKE '%telemetry.raw_messages%' THEN
    RAISE EXCEPTION 'v_rtdata does not read raw_messages';
  END IF;
  IF pg_get_functiondef('telemetry.load_normalized_points_incremental(interval)'::regprocedure)
       ILIKE '%public.mqtt_staging%' THEN
    RAISE EXCEPTION 'normalization procedure still reads public.mqtt_staging';
  END IF;
END $$;

SELECT 'public.mqtt_staging_kind' AS check_name,
       c.relkind::text AS result
FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
WHERE n.nspname='public' AND c.relname='mqtt_staging';

SELECT 'telemetry.mqtt_staging_absent' AS check_name,
       (to_regclass('telemetry.mqtt_staging') IS NULL)::text AS result;

SELECT 'raw_rows' AS check_name, count(*)::text AS result FROM telemetry.raw_messages
UNION ALL SELECT 'normalized_rows', count(*)::text FROM telemetry.normalized_points
UNION ALL SELECT 'energy_rows', count(*)::text FROM telemetry.energy_measurements
UNION ALL SELECT 'environment_rows', count(*)::text FROM telemetry.environment_measurements
UNION ALL SELECT 'water_rows', count(*)::text FROM telemetry.water_measurements
UNION ALL SELECT 'device_status_rows', count(*)::text FROM telemetry.device_status
ORDER BY check_name;

SELECT job_id, proc_name, hypertable_schema, hypertable_name, config, scheduled
FROM timescaledb_information.jobs
WHERE (hypertable_schema='telemetry' AND hypertable_name IN
 ('raw_messages','normalized_points','energy_measurements','environment_measurements','water_measurements','device_status'))
   OR (proc_schema='telemetry' AND proc_name IN
 ('run_normalization_job','run_energy_routing_job','run_environment_routing_job'))
ORDER BY job_id;
